import Foundation

public protocol GitServicing: Sendable {
    func validateGitInstalled() async throws -> String
    func repositoryRoot(for url: URL) async throws -> URL
    func isRepository(_ url: URL) async -> Bool
    func cloneRepository(from remoteURL: String, to destinationURL: URL) async throws -> GitCommandResult
    func initializeRepository(at url: URL) async throws -> Repository
    func status(in repositoryURL: URL) async throws -> GitStatus
    func identity(in repositoryURL: URL) async throws -> GitIdentity
    func diff(for change: GitChange, in repositoryURL: URL, staged: Bool) async throws -> DiffContent
    func stage(paths: [String], in repositoryURL: URL) async throws -> GitCommandResult
    func unstage(paths: [String], in repositoryURL: URL) async throws -> GitCommandResult
    func discard(paths: [String], in repositoryURL: URL) async throws -> GitCommandResult
    func commit(summary: String, description: String, author: GitIdentity?, amend: Bool, in repositoryURL: URL) async throws -> GitCommandResult
    func branches(in repositoryURL: URL) async throws -> [GitBranch]
    func createBranch(named name: String, checkout: Bool, in repositoryURL: URL) async throws -> GitCommandResult
    func checkoutBranch(named name: String, in repositoryURL: URL) async throws -> GitCommandResult
    func renameBranch(from oldName: String?, to newName: String, in repositoryURL: URL) async throws -> GitCommandResult
    func deleteBranch(named name: String, force: Bool, in repositoryURL: URL) async throws -> GitCommandResult
    func mergeBranch(named name: String, in repositoryURL: URL) async throws -> GitCommandResult
    func remotes(in repositoryURL: URL) async throws -> [GitRemote]
    func addRemote(named name: String, url: String, in repositoryURL: URL) async throws -> GitCommandResult
    func setRemote(named name: String, url: String, in repositoryURL: URL) async throws -> GitCommandResult
    func removeRemote(named name: String, in repositoryURL: URL) async throws -> GitCommandResult
    func fetch(in repositoryURL: URL) async throws -> GitCommandResult
    func pull(in repositoryURL: URL) async throws -> GitCommandResult
    func push(in repositoryURL: URL, setUpstreamBranch: String?) async throws -> GitCommandResult
    func history(in repositoryURL: URL, limit: Int) async throws -> [GitCommit]
    func filesChanged(in commit: GitCommit, repositoryURL: URL) async throws -> [GitCommitFile]
    func diff(for commit: GitCommit, file: GitCommitFile?, repositoryURL: URL) async throws -> DiffContent
}

public actor GitService: GitServicing {
    public static let shared = GitService()

    private let executableURL: URL
    private let fileManager: FileManager
    private let keychainStore: KeychainStore
    private let maxDiffBytes: Int
    private let maxSyntheticDiffLines: Int

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        fileManager: FileManager = .default,
        keychainStore: KeychainStore = KeychainStore(),
        maxDiffBytes: Int = 900_000,
        maxSyntheticDiffLines: Int = 5_000
    ) {
        self.executableURL = executableURL
        self.fileManager = fileManager
        self.keychainStore = keychainStore
        self.maxDiffBytes = maxDiffBytes
        self.maxSyntheticDiffLines = maxSyntheticDiffLines
    }

    public func validateGitInstalled() async throws -> String {
        do {
            let result = try await runGit(["--version"], in: nil)
            return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw GitError.gitMissing
        }
    }

    public func repositoryRoot(for url: URL) async throws -> URL {
        let result = try await runGit(["rev-parse", "--show-toplevel"], in: url)
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { throw GitError.invalidRepository(url) }
        return URL(fileURLWithPath: path)
    }

    public func isRepository(_ url: URL) async -> Bool {
        do {
            _ = try await repositoryRoot(for: url)
            return true
        } catch {
            return false
        }
    }

    public func cloneRepository(from remoteURL: String, to destinationURL: URL) async throws -> GitCommandResult {
        try await runGit(["clone", "--progress", remoteURL, destinationURL.path], in: nil)
    }

    public func initializeRepository(at url: URL) async throws -> Repository {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await runGit(["init"], in: url)
        let root = try await repositoryRoot(for: url)
        return Repository(url: root)
    }

    public func status(in repositoryURL: URL) async throws -> GitStatus {
        let result = try await runGit(["status", "--porcelain=v1", "-z", "--branch"], in: repositoryURL)
        return GitParsers.parseStatus(result.standardOutput)
    }

    public func identity(in repositoryURL: URL) async throws -> GitIdentity {
        let nameResult = try await runGit(["config", "--get", "user.name"], in: repositoryURL, allowFailure: true)
        let emailResult = try await runGit(["config", "--get", "user.email"], in: repositoryURL, allowFailure: true)
        return GitIdentity(
            name: cleanOptional(nameResult.standardOutput),
            email: cleanOptional(emailResult.standardOutput)
        )
    }

    public func diff(for change: GitChange, in repositoryURL: URL, staged: Bool) async throws -> DiffContent {
        try validateRelativePath(change.path)

        if change.isUntracked && !staged {
            return try syntheticDiffForUntrackedFile(change.path, repositoryURL: repositoryURL)
        }

        var arguments = ["diff", "--find-renames", "--find-copies", "--binary"]
        if staged {
            arguments.append("--cached")
        }
        arguments.append("--")
        arguments.append(change.path)

        let result = try await runGit(arguments, in: repositoryURL)
        return diffContent(path: change.path, text: result.standardOutput)
    }

    public func stage(paths: [String], in repositoryURL: URL) async throws -> GitCommandResult {
        let arguments = try pathArguments(base: ["add", "--"], paths: paths, emptyMeansAll: true)
        return try await runGit(arguments, in: repositoryURL)
    }

    public func unstage(paths: [String], in repositoryURL: URL) async throws -> GitCommandResult {
        let arguments = try pathArguments(base: ["restore", "--staged", "--"], paths: paths, emptyMeansAll: true)
        do {
            return try await runGit(arguments, in: repositoryURL)
        } catch GitError.commandFailed(let result) where result.standardError.localizedCaseInsensitiveContains("could not resolve HEAD") {
            let fallbackPaths = try pathArguments(base: ["rm", "--cached", "--ignore-unmatch", "-r", "--"], paths: paths, emptyMeansAll: true)
            return try await runGit(fallbackPaths, in: repositoryURL)
        }
    }

    public func discard(paths: [String], in repositoryURL: URL) async throws -> GitCommandResult {
        for path in paths {
            try validateRelativePath(path)
        }

        let currentStatus = try await status(in: repositoryURL)
        let untracked = Set(currentStatus.changes.filter(\.isUntracked).map(\.path))
        let trackedPaths = paths.filter { !untracked.contains($0) }
        let untrackedPaths = paths.filter { untracked.contains($0) }

        var lastResult = GitCommandResult(command: ["git"], workingDirectory: repositoryURL, exitCode: 0, standardOutput: "", standardError: "")

        if !trackedPaths.isEmpty {
            lastResult = try await runGit(["restore", "--worktree", "--"] + trackedPaths, in: repositoryURL)
        }

        for path in untrackedPaths {
            let fileURL = repositoryURL.appendingPathComponent(path)
            guard fileURL.path.hasPrefix(repositoryURL.path + "/") else {
                throw GitError.unsafePath(path)
            }
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }

        if !untrackedPaths.isEmpty {
            let message = "Removed \(untrackedPaths.count) untracked \(untrackedPaths.count == 1 ? "file" : "files")."
            lastResult = GitCommandResult(command: ["git", "clean"], workingDirectory: repositoryURL, exitCode: 0, standardOutput: message, standardError: "")
        }

        return lastResult
    }

    public func commit(summary: String, description: String, author: GitIdentity?, amend: Bool, in repositoryURL: URL) async throws -> GitCommandResult {
        let cleanedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedSummary.isEmpty else { throw GitError.emptyCommitSummary }

        var arguments = ["commit"]
        if amend {
            arguments.append("--amend")
        }
        if let author, let name = cleanOptional(author.name), let email = cleanOptional(author.email) {
            arguments += ["--author", "\(name) <\(email)>"]
        }
        arguments += ["-m", cleanedSummary]

        let cleanedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanedDescription.isEmpty {
            arguments += ["-m", cleanedDescription]
        }

        return try await runGit(arguments, in: repositoryURL)
    }

    public func branches(in repositoryURL: URL) async throws -> [GitBranch] {
        let result = try await runGit(["branch", "--format=%(HEAD)%09%(refname:short)%09%(upstream:short)"], in: repositoryURL)
        var divergences: [String: (Int, Int)] = [:]

        for line in result.standardOutput.split(whereSeparator: \.isNewline).map(String.init) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, !parts[1].isEmpty, !parts[2].isEmpty else { continue }
            let branch = parts[1]
            let upstream = parts[2]
            let divergenceResult = try await runGit(["rev-list", "--left-right", "--count", "\(branch)...\(upstream)"], in: repositoryURL, allowFailure: true)
            divergences["\(branch)\u{1f}\(upstream)"] = GitParsers.parseDivergence(divergenceResult.standardOutput)
        }

        let divergenceSnapshot = divergences
        return GitParsers.parseBranches(result.standardOutput) { branch, upstream in
            divergenceSnapshot["\(branch)\u{1f}\(upstream)"] ?? (0, 0)
        }
    }

    public func createBranch(named name: String, checkout: Bool, in repositoryURL: URL) async throws -> GitCommandResult {
        let cleaned = try validateRefName(name)
        if checkout {
            return try await runGit(["checkout", "-b", cleaned], in: repositoryURL)
        }
        return try await runGit(["branch", cleaned], in: repositoryURL)
    }

    public func checkoutBranch(named name: String, in repositoryURL: URL) async throws -> GitCommandResult {
        let cleaned = try validateRefName(name)
        return try await runGit(["checkout", cleaned], in: repositoryURL)
    }

    public func renameBranch(from oldName: String?, to newName: String, in repositoryURL: URL) async throws -> GitCommandResult {
        let newName = try validateRefName(newName)
        if let oldName, !oldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return try await runGit(["branch", "-m", try validateRefName(oldName), newName], in: repositoryURL)
        }
        return try await runGit(["branch", "-m", newName], in: repositoryURL)
    }

    public func deleteBranch(named name: String, force: Bool = false, in repositoryURL: URL) async throws -> GitCommandResult {
        let cleaned = try validateRefName(name)
        return try await runGit(["branch", force ? "-D" : "-d", cleaned], in: repositoryURL)
    }

    public func mergeBranch(named name: String, in repositoryURL: URL) async throws -> GitCommandResult {
        let cleaned = try validateRefName(name)
        return try await runGit(["merge", "--no-ff", cleaned], in: repositoryURL)
    }

    public func remotes(in repositoryURL: URL) async throws -> [GitRemote] {
        let result = try await runGit(["remote", "-v"], in: repositoryURL)
        return GitParsers.parseRemotes(result.standardOutput)
    }

    public func addRemote(named name: String, url: String, in repositoryURL: URL) async throws -> GitCommandResult {
        try validateRemoteName(name)
        return try await runGit(["remote", "add", name, url], in: repositoryURL)
    }

    public func setRemote(named name: String, url: String, in repositoryURL: URL) async throws -> GitCommandResult {
        try validateRemoteName(name)
        return try await runGit(["remote", "set-url", name, url], in: repositoryURL)
    }

    public func removeRemote(named name: String, in repositoryURL: URL) async throws -> GitCommandResult {
        try validateRemoteName(name)
        return try await runGit(["remote", "remove", name], in: repositoryURL)
    }

    public func fetch(in repositoryURL: URL) async throws -> GitCommandResult {
        try await runGit(["fetch", "--all", "--prune", "--progress"], in: repositoryURL)
    }

    public func pull(in repositoryURL: URL) async throws -> GitCommandResult {
        try await runGit(["pull", "--ff-only", "--progress"], in: repositoryURL)
    }

    public func push(in repositoryURL: URL, setUpstreamBranch: String? = nil) async throws -> GitCommandResult {
        if let branch = setUpstreamBranch, !branch.isEmpty {
            return try await runGit(["push", "--set-upstream", "origin", try validateRefName(branch), "--progress"], in: repositoryURL)
        }
        return try await runGit(["push", "--progress"], in: repositoryURL)
    }

    public func history(in repositoryURL: URL, limit: Int = 200) async throws -> [GitCommit] {
        let result = try await runGit([
            "log",
            "--date=iso-strict",
            "--pretty=format:%H%x1f%h%x1f%an%x1f%ae%x1f%ad%x1f%s%x1e",
            "--max-count=\(max(1, min(limit, 1_000)))"
        ], in: repositoryURL, allowFailure: true)

        if result.exitCode != 0 {
            return []
        }

        return GitParsers.parseCommits(result.standardOutput)
    }

    public func filesChanged(in commit: GitCommit, repositoryURL: URL) async throws -> [GitCommitFile] {
        let result = try await runGit(["diff-tree", "--no-commit-id", "--name-status", "-r", "-M", "-z", commit.hash], in: repositoryURL)
        return GitParsers.parseCommitFiles(result.standardOutput)
    }

    public func diff(for commit: GitCommit, file: GitCommitFile?, repositoryURL: URL) async throws -> DiffContent {
        var arguments = ["show", "--format=", "--find-renames", "--find-copies", "--binary", commit.hash]
        if let file {
            try validateRelativePath(file.path)
            arguments += ["--", file.path]
        }
        let result = try await runGit(arguments, in: repositoryURL)
        return diffContent(path: file?.path ?? commit.shortHash, text: result.standardOutput)
    }

    private func runGit(_ arguments: [String], in workingDirectory: URL?, allowFailure: Bool = false) async throws -> GitCommandResult {
        let executableURL = executableURL
        let command = ["git"] + arguments
        var environment = ProcessInfo.processInfo.environment

        if let token = try? keychainStore.token(), !token.isEmpty, let askPassURL = try? ensureAskPassScript() {
            environment["GIT_ASKPASS"] = askPassURL.path
            environment["PORCELAIN_GITHUB_TOKEN"] = token
        }

        let result = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = command
            process.currentDirectoryURL = workingDirectory

            var processEnvironment = environment
            processEnvironment["GIT_TERMINAL_PROMPT"] = "0"
            processEnvironment["LC_ALL"] = "C"
            process.environment = processEnvironment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw GitError.gitMissing
            }

            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let standardOutput = String(data: outputData, encoding: .utf8) ?? ""
            let standardError = String(data: errorData, encoding: .utf8) ?? ""

            return GitCommandResult(
                command: command,
                workingDirectory: workingDirectory,
                exitCode: process.terminationStatus,
                standardOutput: standardOutput,
                standardError: standardError
            )
        }.value

        if result.exitCode != 0 && !allowFailure {
            throw GitError.commandFailed(result)
        }
        return result
    }

    private func ensureAskPassScript() throws -> URL {
        let directory = fileManager.temporaryDirectory.appendingPathComponent("Porcelain", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let scriptURL = directory.appendingPathComponent("github-askpass.sh")
        if !fileManager.fileExists(atPath: scriptURL.path) {
            let script = """
            #!/bin/sh
            case "$1" in
              *Username*) printf "%s\\n" "x-access-token" ;;
              *Password*) printf "%s\\n" "$PORCELAIN_GITHUB_TOKEN" ;;
              *) printf "\\n" ;;
            esac
            """
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        }
        return scriptURL
    }

    private func diffContent(path: String, text: String) -> DiffContent {
        let dataSize = text.data(using: .utf8)?.count ?? 0
        let binary = text.contains("Binary files") || text.contains("GIT binary patch")
        if dataSize > maxDiffBytes {
            let prefix = String(text.prefix(maxDiffBytes))
            return DiffContent(path: path, text: prefix, isBinary: binary, isLarge: true, didTruncate: true)
        }
        return DiffContent(path: path, text: text, isBinary: binary, isLarge: false, didTruncate: false)
    }

    private func syntheticDiffForUntrackedFile(_ path: String, repositoryURL: URL) throws -> DiffContent {
        try validateRelativePath(path)
        let fileURL = repositoryURL.appendingPathComponent(path)
        guard fileURL.path.hasPrefix(repositoryURL.path + "/") else {
            throw GitError.unsafePath(path)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw GitError.unreadableFile(path)
        }

        if isDirectory.boolValue {
            return syntheticDiffForUntrackedDirectory(path, fileURL: fileURL)
        }

        guard let data = try? Data(contentsOf: fileURL) else {
            throw GitError.unreadableFile(path)
        }

        if data.count > maxDiffBytes {
            return DiffContent(
                path: path,
                text: "File is too large to preview before staging (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))).",
                isBinary: isLikelyBinary(data),
                isLarge: true,
                didTruncate: false
            )
        }

        guard !isLikelyBinary(data), let text = String(data: data, encoding: .utf8) else {
            return DiffContent(path: path, text: "Binary file will be added.", isBinary: true)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let visibleLines = lines.prefix(maxSyntheticDiffLines)
        var diff = """
        diff --git a/\(path) b/\(path)
        new file mode 100644
        --- /dev/null
        +++ b/\(path)
        @@ -0,0 +1,\(lines.count) @@

        """
        diff += visibleLines.map { "+\($0)" }.joined(separator: "\n")
        if lines.count > maxSyntheticDiffLines {
            diff += "\n... preview truncated ..."
        }
        return DiffContent(path: path, text: diff, isBinary: false, isLarge: lines.count > maxSyntheticDiffLines, didTruncate: lines.count > maxSyntheticDiffLines)
    }

    private func syntheticDiffForUntrackedDirectory(_ path: String, fileURL: URL) -> DiffContent {
        let displayPath = path.hasSuffix("/") ? path : "\(path)/"
        guard let enumerator = fileManager.enumerator(
            at: fileURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return DiffContent(path: displayPath, text: "Untracked directory could not be previewed.", isBinary: false)
        }

        var files: [String] = []
        var totalBytes: Int64 = 0
        var didTruncate = false

        for case let url as URL in enumerator {
            guard files.count < maxSyntheticDiffLines else {
                didTruncate = true
                break
            }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }

            let relativePath = url.path
                .replacingOccurrences(of: fileURL.path + "/", with: "")
            files.append("\(displayPath)\(relativePath)")
            totalBytes += Int64(values?.fileSize ?? 0)
        }

        var preview = """
        Untracked directory \(displayPath)

        This directory will be added when staged.

        """

        if files.isEmpty {
            preview += "No files were found inside this directory. Git does not track empty directories."
        } else {
            preview += "\(files.count)\(didTruncate ? "+" : "") files"
            if totalBytes > 0 {
                preview += " · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))"
            }
            preview += "\n\n"
            preview += files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                .map { "+\($0)" }
                .joined(separator: "\n")
            if didTruncate {
                preview += "\n... preview truncated ..."
            }
        }

        return DiffContent(
            path: displayPath,
            text: preview,
            isBinary: false,
            isLarge: didTruncate,
            didTruncate: didTruncate
        )
    }

    private func isLikelyBinary(_ data: Data) -> Bool {
        if data.isEmpty { return false }
        let sample = data.prefix(8_192)
        if sample.contains(0) { return true }
        return String(data: sample, encoding: .utf8) == nil
    }

    private func pathArguments(base: [String], paths: [String], emptyMeansAll: Bool) throws -> [String] {
        if paths.isEmpty {
            return emptyMeansAll ? base + ["."] : base
        }
        for path in paths {
            try validateRelativePath(path)
        }
        return base + paths
    }

    private func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if path.isEmpty || path.hasPrefix("/") || path.contains("\0") || components.contains("..") {
            throw GitError.unsafePath(path)
        }
    }

    private func validateRefName(_ name: String) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty ||
            cleaned.hasPrefix("-") ||
            cleaned.contains("..") ||
            cleaned.contains(" ") ||
            cleaned.contains("~") ||
            cleaned.contains("^") ||
            cleaned.contains(":") ||
            cleaned.contains("?") ||
            cleaned.contains("*") ||
            cleaned.contains("[") ||
            cleaned.contains("\\") {
            throw GitError.parseFailure("Enter a valid branch name.")
        }
        return cleaned
    }

    private func validateRemoteName(_ name: String) throws {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || cleaned.contains("/") || cleaned.contains(" ") || cleaned.hasPrefix("-") {
            throw GitError.parseFailure("Enter a valid remote name.")
        }
    }

    private func cleanOptional(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines), !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }
}
