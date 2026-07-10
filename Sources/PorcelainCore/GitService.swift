import Darwin
import Foundation

public protocol GitServicing: Sendable {
    func validateGitInstalled() async throws -> String
    func repositoryRoot(for url: URL) async throws -> URL
    func isRepository(_ url: URL) async -> Bool
    func cloneRepository(from remoteURL: String, to destinationURL: URL) async throws -> GitCommandResult
    func initializeRepository(at url: URL) async throws -> Repository
    func status(in repositoryURL: URL) async throws -> GitStatus
    func worktrees(in repositoryURL: URL) async throws -> [GitWorktree]
    func addWorktree(at destination: URL, branch: String, createBranch: Bool, in repositoryURL: URL) async throws -> GitCommandResult
    func removeWorktree(at worktreePath: URL, force: Bool, in repositoryURL: URL) async throws -> GitCommandResult
    func pruneWorktrees(in repositoryURL: URL) async throws -> GitCommandResult
    func changeSummary(forWorktreeAt worktreeURL: URL) async throws -> WorktreeChangeSummary
    func compareWorktrees(baseURL: URL, comparisonURL: URL) async throws -> WorktreeComparison
    func diffBetweenWorktrees(baseURL: URL, comparisonURL: URL, file: WorktreeComparisonFile?) async throws -> DiffContent
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

    static let spawnQueue = DispatchQueue(label: "app.porcelain.git-spawn")

    private let executableURL: URL
    private let fileManager: FileManager
    private let keychainStore: KeychainStore
    private let maxDiffBytes: Int
    private let maxSyntheticDiffLines: Int
    private let maxCommandOutputBytes: Int
    private let maxStandardErrorBytes: Int

    public init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/env"),
        fileManager: FileManager = .default,
        keychainStore: KeychainStore = KeychainStore(),
        maxDiffBytes: Int = 900_000,
        maxSyntheticDiffLines: Int = 5_000,
        maxCommandOutputBytes: Int = 2_000_000,
        maxStandardErrorBytes: Int = 256_000
    ) {
        self.executableURL = executableURL
        self.fileManager = fileManager
        self.keychainStore = keychainStore
        self.maxDiffBytes = max(1, maxDiffBytes)
        self.maxSyntheticDiffLines = maxSyntheticDiffLines
        self.maxCommandOutputBytes = max(1, maxCommandOutputBytes)
        self.maxStandardErrorBytes = max(1, maxStandardErrorBytes)
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
        let resolvedURLResult = try await runGit(
            ["ls-remote", "--get-url", "--", remoteURL],
            in: nil,
            allowFailure: true
        )
        let resolvedURL = resolvedURLResult.exitCode == 0
            ? resolvedURLResult.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return try await runGit(
            ["clone", "--progress", "--", remoteURL, destinationURL.path],
            in: nil,
            authentication: authentication(forRemoteURL: resolvedURL)
        )
    }

    public func initializeRepository(at url: URL) async throws -> Repository {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try await runGit(["init"], in: url)
        let root = try await repositoryRoot(for: url)
        return Repository(url: root)
    }

    public func status(in repositoryURL: URL) async throws -> GitStatus {
        let result = try await runGit(
            ["status", "--porcelain=v1", "-z", "--branch"],
            in: repositoryURL,
            preserveFullOutput: true
        )
        return GitParsers.parseStatus(result.standardOutput)
    }

    public func worktrees(in repositoryURL: URL) async throws -> [GitWorktree] {
        let result = try await runGit(
            ["worktree", "list", "--porcelain", "-z"],
            in: repositoryURL,
            preserveFullOutput: true
        )
        return GitParsers.parseWorktrees(result.standardOutput)
    }

    public func addWorktree(at destination: URL, branch: String, createBranch: Bool, in repositoryURL: URL) async throws -> GitCommandResult {
        let branch = try validateRefName(branch)
        var arguments = ["worktree", "add"]
        if createBranch {
            arguments += ["-b", branch]
        }
        // Record the real path; a symlinked destination (e.g. under /tmp)
        // confuses later git commands run inside the worktree.
        arguments.append(Self.realResolvedURL(destination).path)
        if !createBranch {
            arguments.append(branch)
        }
        return try await runGit(arguments, in: repositoryURL)
    }

    public func removeWorktree(at worktreePath: URL, force: Bool, in repositoryURL: URL) async throws -> GitCommandResult {
        var arguments = ["worktree", "remove"]
        if force {
            arguments.append("--force")
        }
        arguments.append(worktreePath.path)
        return try await runGit(arguments, in: repositoryURL)
    }

    public func pruneWorktrees(in repositoryURL: URL) async throws -> GitCommandResult {
        try await runGit(["worktree", "prune"], in: repositoryURL)
    }

    public func changeSummary(forWorktreeAt worktreeURL: URL) async throws -> WorktreeChangeSummary {
        async let statusValue = status(in: worktreeURL)
        async let shortstatValue = shortstat(in: worktreeURL)
        async let commitsValue = history(in: worktreeURL, limit: 1)

        let currentStatus = try await statusValue
        let shortstat = try await shortstatValue
        let commits = try await commitsValue

        return WorktreeChangeSummary(
            total: currentStatus.changes.count,
            staged: currentStatus.changes.filter(\.isStaged).count,
            untracked: currentStatus.changes.filter(\.isUntracked).count,
            conflicted: currentStatus.conflicts.count,
            insertions: shortstat.insertions,
            deletions: shortstat.deletions,
            ahead: currentStatus.ahead,
            behind: currentStatus.behind,
            branchName: currentStatus.branchName,
            lastCommit: commits.first
        )
    }

    public func compareWorktrees(baseURL: URL, comparisonURL: URL) async throws -> WorktreeComparison {
        let baseURL = Self.realResolvedURL(baseURL)
        let comparisonURL = Self.realResolvedURL(comparisonURL)
        return try await withWorktreeSnapshots(baseURL: baseURL, comparisonURL: comparisonURL, limitedTo: nil) { snapshot in
            let files = try await changedFiles(in: snapshot)
            let diff = try await diffBetweenSnapshot(
                snapshot,
                file: nil,
                title: "\(baseURL.lastPathComponent) vs \(comparisonURL.lastPathComponent)"
            )
            return WorktreeComparison(baseURL: baseURL, comparisonURL: comparisonURL, files: files, diff: diff)
        }
    }

    public func diffBetweenWorktrees(baseURL: URL, comparisonURL: URL, file: WorktreeComparisonFile?) async throws -> DiffContent {
        if let path = file?.path {
            try validateRelativePath(path)
        }
        if let oldPath = file?.oldPath {
            try validateRelativePath(oldPath)
        }

        let baseURL = Self.realResolvedURL(baseURL)
        let comparisonURL = Self.realResolvedURL(comparisonURL)
        return try await withWorktreeSnapshots(baseURL: baseURL, comparisonURL: comparisonURL, limitedTo: file?.snapshotPaths) { snapshot in
            try await diffBetweenSnapshot(
                snapshot,
                file: file,
                title: file?.path ?? "\(baseURL.lastPathComponent) vs \(comparisonURL.lastPathComponent)"
            )
        }
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

        let execution = try await runGitExecution(
            arguments,
            in: repositoryURL,
            standardOutputLimit: maxDiffBytes,
            includeStandardOutputTruncationNotice: false
        )
        return diffContent(
            path: change.path,
            text: execution.result.standardOutput,
            collectorDidTruncate: execution.standardOutputDidTruncate
        )
    }

    public func stage(paths: [String], in repositoryURL: URL) async throws -> GitCommandResult {
        let arguments = try pathArguments(base: ["add", "--"], paths: paths, emptyMeansAll: true)
        return try await runGit(arguments, in: repositoryURL)
    }

    public func unstage(paths: [String], in repositoryURL: URL) async throws -> GitCommandResult {
        // `restore --staged` needs HEAD; on a repository with no commits yet,
        // drop the paths from the index instead.
        let headProbe = try await runGit(["rev-parse", "--verify", "--quiet", "HEAD"], in: repositoryURL, allowFailure: true)
        guard headProbe.exitCode == 0 else {
            let arguments = try pathArguments(base: ["rm", "--cached", "--ignore-unmatch", "-r", "--"], paths: paths, emptyMeansAll: true)
            return try await runGit(arguments, in: repositoryURL)
        }
        let arguments = try pathArguments(base: ["restore", "--staged", "--"], paths: paths, emptyMeansAll: true)
        return try await runGit(arguments, in: repositoryURL)
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
        let result = try await runGit(
            ["branch", "--format=%(HEAD)%09%(refname:short)%09%(upstream:short)%09%(upstream:track)"],
            in: repositoryURL,
            preserveFullOutput: true
        )
        return GitParsers.parseBranches(result.standardOutput)
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
        let result = try await runGit(["remote", "-v"], in: repositoryURL, preserveFullOutput: true)
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
        let remotesResult = try await runGit(
            ["remote"],
            in: repositoryURL,
            preserveFullOutput: true
        )
        let remoteNames = remotesResult.standardOutput
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
        guard !remoteNames.isEmpty else {
            return try await runGit(["fetch", "--all", "--prune", "--progress"], in: repositoryURL)
        }
        let skippedRemotes = try await remotesSkippedByFetchAll(in: repositoryURL)

        // `fetch --all` cannot give different environments to mixed-host
        // remotes. Fetch sequentially so only exact GitHub HTTPS remotes see
        // Porcelain's credential helper. This intentionally trades Git's
        // optional parallel fetching for a strict credential boundary.
        var aggregate = NetworkResultAccumulator(
            standardOutputLimit: maxCommandOutputBytes,
            standardErrorLimit: maxStandardErrorBytes
        )
        var hasAttemptedFetch = false
        for remote in remoteNames {
            if skippedRemotes.contains(remote) {
                continue
            }
            let authentication = await authentication(forRemoteNamed: remote, push: false, in: repositoryURL)
            var arguments = ["fetch", "--prune", "--progress"]
            if hasAttemptedFetch {
                // Separate fetch processes otherwise replace FETCH_HEAD. Git's
                // native --all behavior retains entries from every remote.
                arguments.append("--append")
            }
            arguments += ["--", remote]
            let result = try await runGit(
                arguments,
                in: repositoryURL,
                allowFailure: true,
                authentication: authentication
            )
            aggregate.append(result)
            hasAttemptedFetch = true
        }

        let aggregateResult = aggregate.result(
            command: ["git", "fetch", "--all", "--prune", "--progress"],
            workingDirectory: repositoryURL
        )
        if aggregateResult.exitCode != 0 {
            throw GitError.commandFailed(aggregateResult)
        }
        return aggregateResult
    }

    public func pull(in repositoryURL: URL) async throws -> GitCommandResult {
        let authentication = await authenticationForPull(in: repositoryURL)
        return try await runGit(
            ["pull", "--ff-only", "--progress"],
            in: repositoryURL,
            authentication: authentication
        )
    }

    public func push(in repositoryURL: URL, setUpstreamBranch: String? = nil) async throws -> GitCommandResult {
        if let branch = setUpstreamBranch, !branch.isEmpty {
            let authentication = await authentication(forRemoteNamed: "origin", push: true, in: repositoryURL)
            return try await runGit(
                ["push", "--set-upstream", "origin", try validateRefName(branch), "--progress"],
                in: repositoryURL,
                authentication: authentication
            )
        }
        let authentication = await authenticationForPush(in: repositoryURL)
        return try await runGit(
            ["push", "--progress"],
            in: repositoryURL,
            authentication: authentication
        )
    }

    public func history(in repositoryURL: URL, limit: Int = 200) async throws -> [GitCommit] {
        let result = try await runGit([
            "log",
            "--date=iso-strict",
            "--pretty=format:%H%x1f%h%x1f%an%x1f%ae%x1f%ad%x1f%s%x1e",
            "--max-count=\(max(1, min(limit, 1_000)))"
        ], in: repositoryURL, allowFailure: true, preserveFullOutput: true)

        if result.exitCode != 0 {
            return []
        }

        return GitParsers.parseCommits(result.standardOutput)
    }

    public func filesChanged(in commit: GitCommit, repositoryURL: URL) async throws -> [GitCommitFile] {
        let result = try await runGit(
            ["diff-tree", "--no-commit-id", "--name-status", "-r", "-M", "-z", commit.hash],
            in: repositoryURL,
            preserveFullOutput: true
        )
        return GitParsers.parseCommitFiles(result.standardOutput)
    }

    public func diff(for commit: GitCommit, file: GitCommitFile?, repositoryURL: URL) async throws -> DiffContent {
        var arguments = ["show", "--format=", "--find-renames", "--find-copies", "--binary", commit.hash]
        if let file {
            try validateRelativePath(file.path)
            arguments += ["--", file.path]
        }
        let execution = try await runGitExecution(
            arguments,
            in: repositoryURL,
            standardOutputLimit: maxDiffBytes,
            includeStandardOutputTruncationNotice: false
        )
        return diffContent(
            path: file?.path ?? commit.shortHash,
            text: execution.result.standardOutput,
            collectorDidTruncate: execution.standardOutputDidTruncate
        )
    }

    private func changedFiles(in snapshot: WorktreeSnapshot) async throws -> [WorktreeComparisonFile] {
        let result = try await runGit(
            ["diff", "--no-index", "--name-status", "-z", "-M", "-C", "--", snapshot.baseName, snapshot.comparisonName],
            in: snapshot.parentURL,
            allowFailure: true,
            preserveFullOutput: true
        )
        try validateNoIndexDiffResult(result)
        return try parseNoIndexNameStatus(
            result.standardOutput,
            baseName: snapshot.baseName,
            comparisonName: snapshot.comparisonName
        )
    }

    private func diffBetweenSnapshot(_ snapshot: WorktreeSnapshot, file: WorktreeComparisonFile?, title: String) async throws -> DiffContent {
        var arguments = ["diff", "--no-index", "--find-renames", "--find-copies", "--binary"]
        if let file {
            let basePath = file.oldPath ?? file.path
            let comparisonPath = file.path
            if basePath != comparisonPath {
                arguments += ["--", snapshot.baseName, snapshot.comparisonName]
            } else {
                arguments += ["--"]
                switch snapshot.existence(basePath: basePath, comparisonPath: comparisonPath) {
                case (true, true):
                    arguments += ["\(snapshot.baseName)/\(basePath)", "\(snapshot.comparisonName)/\(comparisonPath)"]
                case (false, true):
                    arguments += ["/dev/null", "\(snapshot.comparisonName)/\(comparisonPath)"]
                case (true, false):
                    arguments += ["\(snapshot.baseName)/\(basePath)", "/dev/null"]
                case (false, false):
                    arguments += ["\(snapshot.baseName)/\(basePath)", "\(snapshot.comparisonName)/\(comparisonPath)"]
                }
            }
        } else {
            arguments += ["--", snapshot.baseName, snapshot.comparisonName]
        }

        let execution = try await runGitExecution(
            arguments,
            in: snapshot.parentURL,
            allowFailure: true,
            standardOutputLimit: maxDiffBytes,
            includeStandardOutputTruncationNotice: false
        )
        try validateNoIndexDiffResult(execution.result)
        return diffContent(
            path: title,
            text: execution.result.standardOutput,
            collectorDidTruncate: execution.standardOutputDidTruncate
        )
    }

    private func withWorktreeSnapshots<Value>(
        baseURL: URL,
        comparisonURL: URL,
        limitedTo paths: Set<String>?,
        operation: (WorktreeSnapshot) async throws -> Value
    ) async throws -> Value {
        if let paths {
            for path in paths {
                try validateRelativePath(path)
            }
        }

        let parentURL = fileManager.temporaryDirectory
            .appendingPathComponent("PorcelainWorktreeCompare-\(UUID().uuidString)", isDirectory: true)
        let snapshot = WorktreeSnapshot(
            parentURL: parentURL,
            baseName: "base",
            comparisonName: "comparison"
        )

        defer {
            try? fileManager.removeItem(at: parentURL)
        }
        try fileManager.createDirectory(at: snapshot.baseURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: snapshot.comparisonURL, withIntermediateDirectories: true)

        async let baseVisiblePathsValue = visibleWorktreeFilePaths(in: baseURL, limitedTo: paths)
        async let comparisonVisiblePathsValue = visibleWorktreeFilePaths(in: comparisonURL, limitedTo: paths)
        let (baseVisiblePaths, comparisonVisiblePaths) = try await (
            Set(baseVisiblePathsValue),
            Set(comparisonVisiblePathsValue)
        )

        let requestedPaths = paths ?? baseVisiblePaths.union(comparisonVisiblePaths)
        let baseEntries = try snapshotEntries(
            for: requestedPaths.intersection(baseVisiblePaths),
            in: baseURL
        )
        let comparisonEntries = try snapshotEntries(
            for: requestedPaths.intersection(comparisonVisiblePaths),
            in: comparisonURL
        )

        let snapshotPaths: Set<String>
        if paths == nil {
            snapshotPaths = try changedSnapshotPaths(
                requestedPaths,
                baseURL: baseURL,
                baseEntries: baseEntries,
                comparisonURL: comparisonURL,
                comparisonEntries: comparisonEntries
            )
        } else {
            snapshotPaths = requestedPaths
        }

        try snapshotWorktree(
            at: baseURL,
            to: snapshot.baseURL,
            paths: snapshotPaths,
            entries: baseEntries
        )
        try snapshotWorktree(
            at: comparisonURL,
            to: snapshot.comparisonURL,
            paths: snapshotPaths,
            entries: comparisonEntries
        )

        return try await operation(snapshot)
    }

    private func snapshotEntries(
        for paths: Set<String>,
        in worktreeURL: URL
    ) throws -> [String: SnapshotFileEntry] {
        var entries: [String: SnapshotFileEntry] = [:]
        entries.reserveCapacity(paths.count)
        for path in paths {
            try validateRelativePath(path)
            let entry = try snapshotFileEntry(at: worktreeURL.appendingPathComponent(path))
            if entry != .absent {
                entries[path] = entry
            }
        }
        return entries
    }

    private func changedSnapshotPaths(
        _ paths: Set<String>,
        baseURL: URL,
        baseEntries: [String: SnapshotFileEntry],
        comparisonURL: URL,
        comparisonEntries: [String: SnapshotFileEntry]
    ) throws -> Set<String> {
        var changedPaths: Set<String> = []
        changedPaths.reserveCapacity(paths.count)

        for path in paths {
            let baseEntry = baseEntries[path] ?? .absent
            let comparisonEntry = comparisonEntries[path] ?? .absent
            if try snapshotEntriesDiffer(
                baseEntry,
                at: baseURL.appendingPathComponent(path),
                comparisonEntry,
                at: comparisonURL.appendingPathComponent(path)
            ) {
                changedPaths.insert(path)
            }
        }
        return changedPaths
    }

    private func snapshotEntriesDiffer(
        _ baseEntry: SnapshotFileEntry,
        at baseURL: URL,
        _ comparisonEntry: SnapshotFileEntry,
        at comparisonURL: URL
    ) throws -> Bool {
        switch (baseEntry, comparisonEntry) {
        case (.absent, .absent):
            return false
        case let (.regular(baseSize, baseIsExecutable), .regular(comparisonSize, comparisonIsExecutable)):
            guard baseSize == comparisonSize, baseIsExecutable == comparisonIsExecutable else {
                return true
            }
            return try !regularFilesAreEqual(baseURL, comparisonURL)
        case let (.symbolicLink(baseTarget), .symbolicLink(comparisonTarget)):
            return baseTarget != comparisonTarget
        case let (
            .other(baseType, baseSize, basePermissions),
            .other(comparisonType, comparisonSize, comparisonPermissions)
        ):
            return baseType != comparisonType ||
                baseSize != comparisonSize ||
                basePermissions != comparisonPermissions
        default:
            return true
        }
    }

    private func snapshotWorktree(
        at worktreeURL: URL,
        to snapshotURL: URL,
        paths: Set<String>,
        entries: [String: SnapshotFileEntry]
    ) throws {
        let orderedPaths = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        for path in orderedPaths where entries[path] != nil {
            try copySnapshotFile(path, from: worktreeURL, to: snapshotURL)
        }
    }

    private func visibleWorktreeFilePaths(
        in worktreeURL: URL,
        limitedTo paths: Set<String>? = nil
    ) async throws -> [String] {
        var arguments = ["ls-files", "-co", "--exclude-standard", "-z"]
        if let paths {
            let orderedPaths = paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            for path in orderedPaths {
                try validateRelativePath(path)
            }
            arguments += ["--"] + orderedPaths.map { ":(literal)\($0)" }
        }
        let result = try await runGit(
            arguments,
            in: worktreeURL,
            preserveFullOutput: true
        )
        let paths = result.standardOutput
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)

        var uniquePaths: Set<String> = []
        for path in paths {
            try validateRelativePath(path)
            uniquePaths.insert(path)
        }
        return uniquePaths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func copySnapshotFile(_ path: String, from worktreeURL: URL, to snapshotURL: URL) throws {
        try validateRelativePath(path)

        let sourceURL = worktreeURL.appendingPathComponent(path)
        guard sourceURL.path.hasPrefix(worktreeURL.path + "/") else {
            throw GitError.unsafePath(path)
        }

        let sourceEntry = try snapshotFileEntry(at: sourceURL)
        guard sourceEntry.isSnapshotFile else {
            return
        }

        let destinationURL = snapshotURL.appendingPathComponent(path)
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileSystemEntryExists(at: destinationURL) {
            try fileManager.removeItem(at: destinationURL)
        }

        switch sourceEntry {
        case let .symbolicLink(target):
            try createSymbolicLink(at: destinationURL, target: target)
        case .regular:
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        case .absent, .other:
            return
        }
    }

    private func snapshotFileEntry(at url: URL) throws -> SnapshotFileEntry {
        var information = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &information)
        }
        if result != 0 {
            let code = errno
            if code == ENOENT || code == ENOTDIR {
                return .absent
            }
            throw posixFileError(code, at: url)
        }

        let mode = UInt32(information.st_mode)
        let fileType = mode & UInt32(S_IFMT)
        let permissions = mode & 0o7777
        let isExecutable = (mode & 0o111) != 0
        let size = UInt64(max(0, information.st_size))

        switch fileType {
        case UInt32(S_IFREG):
            return .regular(size: size, isExecutable: isExecutable)
        case UInt32(S_IFLNK):
            return .symbolicLink(target: try symbolicLinkTarget(at: url, expectedSize: size))
        default:
            return .other(fileType: fileType, size: size, permissions: permissions)
        }
    }

    private func symbolicLinkTarget(at url: URL, expectedSize: UInt64) throws -> Data {
        var capacity = max(256, min(Int(expectedSize) + 1, 1_048_576))
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let count = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return -1 }
                return buffer.withUnsafeMutableBufferPointer { bytes in
                    Darwin.readlink(path, bytes.baseAddress, bytes.count)
                }
            }
            if count < 0 {
                throw posixFileError(errno, at: url)
            }
            if count < buffer.count {
                return buffer.withUnsafeBytes { bytes in
                    Data(bytes.prefix(count))
                }
            }
            guard capacity < 1_048_576 else {
                throw GitError.unreadableFile(url.lastPathComponent)
            }
            capacity = min(capacity * 2, 1_048_576)
        }
    }

    private func createSymbolicLink(at url: URL, target: Data) throws {
        var bytes = target.map { CChar(bitPattern: $0) }
        bytes.append(0)
        let result: Int32 = url.withUnsafeFileSystemRepresentation { destinationPath in
            guard let destinationPath else { return Int32(-1) }
            return bytes.withUnsafeBufferPointer { targetPath in
                Darwin.symlink(targetPath.baseAddress, destinationPath)
            }
        }
        if result != 0 {
            throw posixFileError(errno, at: url)
        }
    }

    private func regularFilesAreEqual(_ firstURL: URL, _ secondURL: URL) throws -> Bool {
        let firstDescriptor = try openRegularFile(at: firstURL)
        defer { Darwin.close(firstDescriptor) }
        let secondDescriptor = try openRegularFile(at: secondURL)
        defer { Darwin.close(secondDescriptor) }

        let chunkSize = 256 * 1_024
        var firstBuffer = [UInt8](repeating: 0, count: chunkSize)
        var secondBuffer = [UInt8](repeating: 0, count: chunkSize)

        while true {
            let firstCount = try readChunk(from: firstDescriptor, into: &firstBuffer)
            let secondCount = try readChunk(from: secondDescriptor, into: &secondBuffer)
            guard firstCount == secondCount else { return false }
            guard firstCount > 0 else { return true }
            guard firstBuffer[..<firstCount].elementsEqual(secondBuffer[..<secondCount]) else {
                return false
            }
        }
    }

    private func openRegularFile(at url: URL) throws -> Int32 {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        if descriptor < 0 {
            throw posixFileError(errno, at: url)
        }
        return descriptor
    }

    private func readChunk(from descriptor: Int32, into buffer: inout [UInt8]) throws -> Int {
        var total = 0
        while total < buffer.count {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(
                    descriptor,
                    baseAddress.advanced(by: total),
                    bytes.count - total
                )
            }
            if count > 0 {
                total += count
                continue
            }
            if count == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw posixFileError(errno, at: nil)
        }
        return total
    }

    private func validateNoIndexDiffResult(_ result: GitCommandResult) throws {
        if result.exitCode == 0 {
            return
        }
        if result.exitCode == 1 && !result.standardOutput.isEmpty {
            return
        }
        throw GitError.commandFailed(result)
    }

    private func parseNoIndexNameStatus(
        _ output: String,
        baseName: String,
        comparisonName: String
    ) throws -> [WorktreeComparisonFile] {
        let fields = output
            .split(separator: "\0", omittingEmptySubsequences: true)
            .map(String.init)

        var files: [WorktreeComparisonFile] = []
        var index = 0
        while index < fields.count {
            let status = fields[index]
            index += 1
            guard let state = comparisonState(forNameStatus: status), index < fields.count else {
                throw GitError.parseFailure("Could not parse worktree comparison output.")
            }

            if state == .renamed || state == .copied {
                guard index + 1 < fields.count else {
                    throw GitError.parseFailure("Could not parse worktree comparison output.")
                }
                let oldPath = snapshotRelativePath(fields[index], baseName: baseName, comparisonName: comparisonName)
                let newPath = snapshotRelativePath(fields[index + 1], baseName: baseName, comparisonName: comparisonName)
                files.append(WorktreeComparisonFile(path: newPath, oldPath: oldPath, status: state))
                index += 2
            } else {
                let path = snapshotRelativePath(fields[index], baseName: baseName, comparisonName: comparisonName)
                files.append(WorktreeComparisonFile(path: path, status: state))
                index += 1
            }
        }

        return files.sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    private func comparisonState(forNameStatus status: String) -> GitFileState? {
        switch status.first {
        case "A":
            return .added
        case "D":
            return .deleted
        case "R":
            return .renamed
        case "C":
            return .copied
        case "T":
            return .typeChanged
        case "M":
            return .modified
        default:
            return nil
        }
    }

    private func snapshotRelativePath(_ path: String, baseName: String, comparisonName: String) -> String {
        for prefix in ["\(baseName)/", "\(comparisonName)/"] where path.hasPrefix(prefix) {
            return String(path.dropFirst(prefix.count))
        }
        return path
    }

    private func shortstat(in repositoryURL: URL) async throws -> (filesChanged: Int, insertions: Int, deletions: Int) {
        let headProbe = try await runGit(["rev-parse", "--verify", "--quiet", "HEAD"], in: repositoryURL, allowFailure: true)
        guard headProbe.exitCode == 0 else {
            return (0, 0, 0)
        }

        let result = try await runGit(["diff", "--shortstat", "HEAD"], in: repositoryURL)
        return GitParsers.parseShortstat(result.standardOutput)
    }

    private func authentication(forRemoteURL remoteURL: String?) -> GitAuthentication {
        guard let remoteURL,
              let components = URLComponents(string: remoteURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "https",
              components.host?.lowercased() == "github.com" else {
            return .none
        }
        return .githubKeychainToken
    }

    private func authentication(
        forRemoteNamed remote: String,
        push: Bool,
        in repositoryURL: URL
    ) async -> GitAuthentication {
        guard remote != "." else { return .none }
        var arguments = ["remote", "get-url"]
        if push {
            arguments += ["--push", "--all"]
        }
        // `--` prevents a remote name from being interpreted as an option,
        // including names introduced by hand-editing Git configuration.
        arguments += ["--", remote]
        guard let result = try? await runGit(arguments, in: repositoryURL, allowFailure: true),
              result.exitCode == 0 else {
            return .none
        }
        let remoteURLs = result.standardOutput
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
        guard !remoteURLs.isEmpty else { return .none }
        if push {
            // Git pushes to every configured pushurl. A mixed-host set cannot
            // safely share one process environment, so withhold Porcelain's
            // token unless every destination is exact HTTPS github.com.
            return remoteURLs.allSatisfy { authentication(forRemoteURL: $0) == .githubKeychainToken }
                ? .githubKeychainToken
                : .none
        }
        // Git fetches from the first configured fetch URL.
        return authentication(forRemoteURL: remoteURLs[0])
    }

    private func authenticationForPull(in repositoryURL: URL) async -> GitAuthentication {
        let remote: String
        if let branch = await currentBranch(in: repositoryURL),
           let branchRemote = await configValue("branch.\(branch).remote", in: repositoryURL) {
            remote = branchRemote
        } else if let fallbackRemote = await fallbackRemote(in: repositoryURL) {
            remote = fallbackRemote
        } else {
            return .none
        }
        return await authentication(forRemoteNamed: remote, push: false, in: repositoryURL)
    }

    private func authenticationForPush(in repositoryURL: URL) async -> GitAuthentication {
        let branch = await currentBranch(in: repositoryURL)
        let remote: String?
        if let branch,
           let branchPushRemote = await configValue("branch.\(branch).pushRemote", in: repositoryURL) {
            remote = branchPushRemote
        } else if let defaultRemote = await configValue("remote.pushDefault", in: repositoryURL) {
            remote = defaultRemote
        } else if let branch,
                  let branchRemote = await configValue("branch.\(branch).remote", in: repositoryURL) {
            remote = branchRemote
        } else {
            remote = await fallbackRemote(in: repositoryURL)
        }
        guard let remote else { return .none }
        return await authentication(forRemoteNamed: remote, push: true, in: repositoryURL)
    }

    private func fallbackRemote(in repositoryURL: URL) async -> String? {
        guard let result = try? await runGit(
            ["remote"],
            in: repositoryURL,
            preserveFullOutput: true
        ) else {
            return nil
        }
        let remotes = result.standardOutput
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
        if remotes.contains("origin") {
            return "origin"
        }
        return remotes.count == 1 ? remotes[0] : nil
    }

    private func currentBranch(in repositoryURL: URL) async -> String? {
        guard let result = try? await runGit(
            ["symbolic-ref", "--quiet", "--short", "HEAD"],
            in: repositoryURL,
            allowFailure: true
        ), result.exitCode == 0 else {
            return nil
        }
        let branch = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return branch.isEmpty ? nil : branch
    }

    private func configValue(_ key: String, in repositoryURL: URL) async -> String? {
        guard let result = try? await runGit(
            ["config", "--get", key],
            in: repositoryURL,
            allowFailure: true
        ), result.exitCode == 0 else {
            return nil
        }
        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func remotesSkippedByFetchAll(in repositoryURL: URL) async throws -> Set<String> {
        let result = try await runGit(
            [
                "config",
                "--type=bool",
                "--null",
                "--get-regexp",
                "^remote\\..*\\.(skipFetchAll|skipDefaultUpdate)$"
            ],
            in: repositoryURL,
            allowFailure: true,
            preserveFullOutput: true
        )
        if result.exitCode == 1 {
            return []
        }
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(result)
        }

        var effectiveValues: [String: Bool] = [:]
        for record in result.standardOutput.split(separator: "\0", omittingEmptySubsequences: true) {
            guard let separator = record.firstIndex(of: "\n") else { continue }
            let key = String(record[..<separator])
            let value = record[record.index(after: separator)...]
            let lowercaseKey = key.lowercased()
            let suffix: String
            if lowercaseKey.hasSuffix(".skipfetchall") {
                suffix = ".skipfetchall"
            } else if lowercaseKey.hasSuffix(".skipdefaultupdate") {
                suffix = ".skipdefaultupdate"
            } else {
                continue
            }
            guard lowercaseKey.hasPrefix("remote."), key.count > "remote.".count + suffix.count else {
                continue
            }
            let nameStart = key.index(key.startIndex, offsetBy: "remote.".count)
            let nameEnd = key.index(key.endIndex, offsetBy: -suffix.count)
            let remote = String(key[nameStart..<nameEnd])
            // The config result preserves Git's effective read order. Both
            // names feed the same setting internally, so the last one wins.
            effectiveValues[remote] = value == "true"
        }
        return Set(effectiveValues.compactMap { $0.value ? $0.key : nil })
    }

    private func runGit(
        _ arguments: [String],
        in workingDirectory: URL?,
        allowFailure: Bool = false,
        authentication: GitAuthentication = .none,
        preserveFullOutput: Bool = false
    ) async throws -> GitCommandResult {
        try await runGitExecution(
            arguments,
            in: workingDirectory,
            allowFailure: allowFailure,
            authentication: authentication,
            standardOutputLimit: preserveFullOutput ? nil : maxCommandOutputBytes
        ).result
    }

    private func runGitExecution(
        _ arguments: [String],
        in workingDirectory: URL?,
        allowFailure: Bool = false,
        authentication: GitAuthentication = .none,
        standardOutputLimit: Int? = nil,
        standardErrorLimit: Int? = nil,
        includeStandardOutputTruncationNotice: Bool = true
    ) async throws -> GitExecutionResult {
        let executableURL = executableURL
        let command = ["git"] + arguments
        var environment = ProcessInfo.processInfo.environment

        // Never propagate Porcelain's legacy plaintext-token variable. A user
        // supplied GIT_ASKPASS remains untouched for non-authenticated calls;
        // Porcelain only installs its own helper for explicit network commands.
        environment.removeValue(forKey: "PORCELAIN_GITHUB_TOKEN")
        environment.removeValue(forKey: "PORCELAIN_FALLBACK_GIT_ASKPASS")

        // Git intentionally runs network-related repository hooks (including
        // pre-push and reference-transaction) in this environment. Porcelain
        // treats installed hooks as trusted local code and does not disable or
        // replay them, which would change native Git behavior.
        if authentication == .githubKeychainToken,
           let token = try? keychainStore.token(),
           !token.isEmpty,
           let askPassURL = try? ensureAskPassScript() {
            if let existingAskPass = environment["GIT_ASKPASS"], existingAskPass != askPassURL.path {
                environment["PORCELAIN_FALLBACK_GIT_ASKPASS"] = existingAskPass
            }
            environment["GIT_ASKPASS"] = askPassURL.path
            environment["PORCELAIN_GITHUB_TOKEN"] = token
        }

        // Git resolves where it is partly from the recorded worktree path and
        // the PWD variable; a symlinked working directory (such as anything
        // under /tmp or /var/folders on macOS) or a stale inherited PWD can
        // make commands inside a linked worktree silently act on nothing.
        // URL.resolvingSymlinksInPath() leaves /var and /tmp untouched, so
        // resolution goes through realpath(3) instead.
        let resolvedWorkingDirectory = workingDirectory.map(Self.realResolvedURL)

        let process = Process()
        process.executableURL = executableURL
        process.arguments = command
        process.currentDirectoryURL = resolvedWorkingDirectory

        var processEnvironment = environment
        processEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        processEnvironment["LC_ALL"] = "C"
        if let resolvedWorkingDirectory {
            processEnvironment["PWD"] = resolvedWorkingDirectory.path
        } else {
            processEnvironment.removeValue(forKey: "PWD")
        }
        process.environment = processEnvironment

        // Everything below is handler-driven: no thread blocks on the child
        // or its pipes. Dedicated blocked reader threads starve on small-core
        // machines — GCD can take seconds to spin up overcommit threads, and
        // the readers then miss output that git wrote within milliseconds.
        let eofGroup = DispatchGroup()
        let exitWaiter = ExitWaiter()
        process.terminationHandler = { finished in
            exitWaiter.finished(status: finished.terminationStatus)
        }

        // Pipe setup and launch are serialized process-wide: concurrent
        // pipe()/spawn pairs race on file-descriptor reuse in the shared
        // descriptor table, which can cross-wire or orphan child output.
        let (outputCollector, errorCollector) = try GitService.spawnQueue.sync {
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let output = PipeCollector(
                handle: outputPipe.fileHandleForReading,
                eofGroup: eofGroup,
                retentionLimit: standardOutputLimit
            )
            let error = PipeCollector(
                handle: errorPipe.fileHandleForReading,
                eofGroup: eofGroup,
                retentionLimit: standardErrorLimit ?? maxStandardErrorBytes
            )

            do {
                try process.run()
            } catch {
                throw GitError.gitMissing
            }

            return (output, error)
        }

        let exitCode = await exitWaiter.wait()

        // Git can hand its pipes to a detached helper (auto maintenance,
        // fsmonitor) that outlives the command, so EOF may never arrive even
        // though the command finished; wait briefly for the pipes to drain
        // instead of forever.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeOnce = ResumeOnce(continuation)
            eofGroup.notify(queue: .global()) {
                resumeOnce.resume()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                resumeOnce.resume()
            }
        }

        outputCollector.stop()
        errorCollector.stop()

        let outputSnapshot = outputCollector.snapshot()
        let errorSnapshot = errorCollector.snapshot()
        var standardError = String(decoding: errorSnapshot.data, as: UTF8.self)
        if errorSnapshot.didTruncate {
            standardError += "\n[Porcelain: standard error truncated]\n"
        }
        var standardOutput = String(decoding: outputSnapshot.data, as: UTF8.self)
        if outputSnapshot.didTruncate, includeStandardOutputTruncationNotice {
            standardOutput += "\n[Porcelain: standard output truncated]\n"
        }
        let result = GitCommandResult(
            command: command,
            workingDirectory: workingDirectory,
            exitCode: exitCode,
            standardOutput: standardOutput,
            standardError: standardError
        )

        if result.exitCode != 0 && !allowFailure {
            throw GitError.commandFailed(result)
        }
        return GitExecutionResult(
            result: result,
            standardOutputDidTruncate: outputSnapshot.didTruncate,
            standardErrorDidTruncate: errorSnapshot.didTruncate
        )
    }

    /// realpath(3)-based resolution; URL.resolvingSymlinksInPath() skips
    /// /var and /tmp on macOS. Falls back to resolving the parent when the
    /// path itself does not exist yet (e.g. a new worktree destination).
    nonisolated private static func realResolvedURL(_ url: URL) -> URL {
        func resolve(_ path: String) -> String? {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            guard realpath(path, &buffer) != nil else { return nil }
            return String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        if let resolved = resolve(url.path) {
            return URL(fileURLWithPath: resolved, isDirectory: true)
        }
        if let parent = resolve(url.deletingLastPathComponent().path) {
            return URL(fileURLWithPath: parent, isDirectory: true)
                .appendingPathComponent(url.lastPathComponent, isDirectory: true)
        }
        return url
    }

    private func ensureAskPassScript() throws -> URL {
        let directory = fileManager.temporaryDirectory.appendingPathComponent("Porcelain", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let scriptURL = directory.appendingPathComponent("github-askpass.sh")
        let script = """
        #!/bin/sh
        prompt=$(printf "%s" "$1" | tr "[:upper:]" "[:lower:]")
        case "$prompt" in
          *"https://github.com/"*|*"https://github.com'"*|*"https://github.com:"*|*"@github.com/"*|*"@github.com'"*|*"@github.com:"*) ;;
          *)
            if [ -n "$PORCELAIN_FALLBACK_GIT_ASKPASS" ]; then
              exec "$PORCELAIN_FALLBACK_GIT_ASKPASS" "$1"
            fi
            printf "\\n"
            exit 0
            ;;
        esac
        case "$prompt" in
          *username*) printf "%s\\n" "x-access-token" ;;
          *password*) printf "%s\\n" "$PORCELAIN_GITHUB_TOKEN" ;;
          *) printf "\\n" ;;
        esac
        """
        // Rewrite on every use so upgrades cannot leave the legacy,
        // host-agnostic helper installed in the shared temporary location.
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private func diffContent(path: String, text: String, collectorDidTruncate: Bool = false) -> DiffContent {
        let dataSize = text.data(using: .utf8)?.count ?? 0
        let binary = text.contains("Binary files") || text.contains("GIT binary patch")
        if collectorDidTruncate {
            return DiffContent(path: path, text: text, isBinary: binary, isLarge: true, didTruncate: true)
        }
        if dataSize > maxDiffBytes, let data = text.data(using: .utf8) {
            let prefix = String(decoding: data.prefix(maxDiffBytes), as: UTF8.self)
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
        try GitRefNameValidator.validateBranchName(name)
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

private enum GitAuthentication {
    case none
    case githubKeychainToken
}

private struct GitExecutionResult {
    let result: GitCommandResult
    let standardOutputDidTruncate: Bool
    let standardErrorDidTruncate: Bool
}

private struct NetworkResultAccumulator {
    private var standardOutput: BoundedTextAccumulator
    private var standardError: BoundedTextAccumulator
    private var firstFailureCode: Int32?

    init(standardOutputLimit: Int, standardErrorLimit: Int) {
        standardOutput = BoundedTextAccumulator(
            limit: standardOutputLimit,
            truncationNotice: "[Porcelain: standard output truncated]"
        )
        standardError = BoundedTextAccumulator(
            limit: standardErrorLimit,
            truncationNotice: "[Porcelain: standard error truncated]"
        )
    }

    mutating func append(_ result: GitCommandResult) {
        standardOutput.append(result.standardOutput)
        standardError.append(result.standardError)
        if firstFailureCode == nil, result.exitCode != 0 {
            firstFailureCode = result.exitCode
        }
    }

    func result(command: [String], workingDirectory: URL) -> GitCommandResult {
        GitCommandResult(
            command: command,
            workingDirectory: workingDirectory,
            exitCode: firstFailureCode ?? 0,
            standardOutput: standardOutput.value,
            standardError: standardError.value
        )
    }
}

private struct BoundedTextAccumulator {
    private let limit: Int
    private let truncationNotice: String
    private var retained = Data()
    private var didTruncate = false

    init(limit: Int, truncationNotice: String) {
        self.limit = max(0, limit)
        self.truncationNotice = truncationNotice
    }

    mutating func append(_ value: String) {
        guard !value.isEmpty, !didTruncate else { return }
        let piece = (retained.isEmpty ? "" : "\n") + value
        let data = Data(piece.utf8)
        let remaining = max(0, limit - retained.count)
        if remaining > 0 {
            retained.append(data.prefix(remaining))
        }
        if data.count > remaining {
            didTruncate = true
        }
    }

    var value: String {
        var output = String(decoding: retained, as: UTF8.self)
        if didTruncate {
            output += "\n\(truncationNotice)\n"
        }
        return output
    }
}

private enum SnapshotFileEntry: Equatable {
    case absent
    case regular(size: UInt64, isExecutable: Bool)
    case symbolicLink(target: Data)
    case other(fileType: UInt32, size: UInt64, permissions: UInt32)

    var isSnapshotFile: Bool {
        switch self {
        case .regular, .symbolicLink:
            true
        case .absent, .other:
            false
        }
    }
}

private func fileSystemEntryExists(at url: URL) -> Bool {
    var information = stat()
    return url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return false }
        return Darwin.lstat(path, &information) == 0
    }
}

private func posixFileError(_ code: Int32, at url: URL?) -> NSError {
    var userInfo: [String: Any] = [:]
    if let url {
        userInfo[NSFilePathErrorKey] = url.path
    }
    return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: userInfo)
}

private struct WorktreeSnapshot {
    let parentURL: URL
    let baseName: String
    let comparisonName: String

    var baseURL: URL {
        parentURL.appendingPathComponent(baseName, isDirectory: true)
    }

    var comparisonURL: URL {
        parentURL.appendingPathComponent(comparisonName, isDirectory: true)
    }

    func existence(basePath: String, comparisonPath: String) -> (base: Bool, comparison: Bool) {
        return (
            fileSystemEntryExists(at: baseURL.appendingPathComponent(basePath)),
            fileSystemEntryExists(at: comparisonURL.appendingPathComponent(comparisonPath))
        )
    }
}

/// Accumulates a pipe's output via its readability handler so the producing
/// process never blocks on a full pipe buffer. Handler-driven on purpose:
/// no thread is held hostage per pipe.
private final class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let eofGroup: DispatchGroup
    private let retentionLimit: Int?
    private let lock = NSLock()
    private var data = Data()
    private var didTruncate = false
    private var finished = false

    init(handle: FileHandle, eofGroup: DispatchGroup, retentionLimit: Int?) {
        self.handle = handle
        self.eofGroup = eofGroup
        self.retentionLimit = retentionLimit.map { max(0, $0) }
        eofGroup.enter()
        handle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            self.lock.lock()
            if chunk.isEmpty {
                let alreadyFinished = self.finished
                self.finished = true
                self.lock.unlock()
                handle.readabilityHandler = nil
                if !alreadyFinished {
                    self.eofGroup.leave()
                }
            } else {
                if let retentionLimit = self.retentionLimit {
                    let remaining = max(0, retentionLimit - self.data.count)
                    if remaining > 0 {
                        self.data.append(chunk.prefix(remaining))
                    }
                    if chunk.count > remaining {
                        self.didTruncate = true
                    }
                } else {
                    self.data.append(chunk)
                }
                self.lock.unlock()
            }
        }
    }

    /// Detaches the handler once the caller stops caring (EOF or grace
    /// timeout) and balances the group entry if EOF never arrived.
    func stop() {
        lock.lock()
        let needsDetach = !finished
        finished = true
        lock.unlock()
        if needsDetach {
            handle.readabilityHandler = nil
            eofGroup.leave()
        }
    }

    func snapshot() -> PipeCaptureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return PipeCaptureSnapshot(data: data, didTruncate: didTruncate)
    }
}

private struct PipeCaptureSnapshot {
    let data: Data
    let didTruncate: Bool
}

/// Bridges Process.terminationHandler to async without losing a termination
/// that fires before anyone awaits.
private final class ExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finished(status: Int32) {
        lock.lock()
        self.status = status
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: status)
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// Funnels multiple completion signals into a single continuation resume.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    func resume() {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}
