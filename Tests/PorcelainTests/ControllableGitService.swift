import Foundation
import PorcelainCore

actor ControllableGitService: GitServicing {
    private var nextStatusRequestID = 1
    private var statusContinuations: [Int: CheckedContinuation<GitStatus, Error>] = [:]
    private var changeDiffContinuations: [String: CheckedContinuation<DiffContent, Error>] = [:]
    private var commitFilesContinuations: [String: CheckedContinuation<[GitCommitFile], Error>] = [:]
    private var commitDiffContinuations: [String: CheckedContinuation<DiffContent, Error>] = [:]
    private var comparisonContinuation: CheckedContinuation<WorktreeComparison, Error>?
    private var worktreeDiffContinuation: CheckedContinuation<DiffContent, Error>?

    private var identityResponses = [GitIdentity(name: nil, email: nil)]
    private var branchesResponses: [[GitBranch]] = [[]]
    private var remotesResponses: [[GitRemote]] = [[]]
    private var historyResponses: [[GitCommit]] = [[]]
    private var identityCallCount = 0
    private var branchesCallCount = 0
    private var remotesCallCount = 0
    private var historyCallCount = 0

    func configureRepositoryResponses(
        identities: [GitIdentity],
        branches: [[GitBranch]],
        remotes: [[GitRemote]],
        histories: [[GitCommit]]
    ) {
        precondition(!identities.isEmpty)
        precondition(!branches.isEmpty)
        precondition(!remotes.isEmpty)
        precondition(!histories.isEmpty)
        identityResponses = identities
        branchesResponses = branches
        remotesResponses = remotes
        historyResponses = histories
    }

    func hasStatusRequest(_ id: Int) -> Bool {
        statusContinuations[id] != nil
    }

    func repositoryMetadataCallCount() -> Int {
        min(identityCallCount, branchesCallCount, remotesCallCount, historyCallCount)
    }

    func resolveStatus(_ id: Int, with status: GitStatus) {
        statusContinuations.removeValue(forKey: id)?.resume(returning: status)
    }

    func failStatus(_ id: Int, with error: GitError) {
        statusContinuations.removeValue(forKey: id)?.resume(throwing: error)
    }

    func hasChangeDiffRequest(path: String) -> Bool {
        changeDiffContinuations[path] != nil
    }

    func resolveChangeDiff(path: String, with diff: DiffContent) {
        changeDiffContinuations.removeValue(forKey: path)?.resume(returning: diff)
    }

    func failChangeDiff(path: String, with error: GitError) {
        changeDiffContinuations.removeValue(forKey: path)?.resume(throwing: error)
    }

    func hasCommitFilesRequest(hash: String) -> Bool {
        commitFilesContinuations[hash] != nil
    }

    func resolveCommitFiles(hash: String, with files: [GitCommitFile]) {
        commitFilesContinuations.removeValue(forKey: hash)?.resume(returning: files)
    }

    func failCommitFiles(hash: String, with error: GitError) {
        commitFilesContinuations.removeValue(forKey: hash)?.resume(throwing: error)
    }

    func hasCommitDiffRequest(hash: String, path: String?) -> Bool {
        commitDiffContinuations[commitDiffKey(hash: hash, path: path)] != nil
    }

    func resolveCommitDiff(hash: String, path: String?, with diff: DiffContent) {
        commitDiffContinuations.removeValue(forKey: commitDiffKey(hash: hash, path: path))?.resume(returning: diff)
    }

    func failCommitDiff(hash: String, path: String?, with error: GitError) {
        commitDiffContinuations.removeValue(forKey: commitDiffKey(hash: hash, path: path))?.resume(throwing: error)
    }

    func hasComparisonRequest() -> Bool {
        comparisonContinuation != nil
    }

    func resolveComparison(with comparison: WorktreeComparison) {
        comparisonContinuation?.resume(returning: comparison)
        comparisonContinuation = nil
    }

    func hasWorktreeDiffRequest() -> Bool {
        worktreeDiffContinuation != nil
    }

    func resolveWorktreeDiff(with diff: DiffContent) {
        worktreeDiffContinuation?.resume(returning: diff)
        worktreeDiffContinuation = nil
    }

    func validateGitInstalled() async throws -> String { "git version test" }

    func repositoryRoot(for url: URL) async throws -> URL { url }

    func isRepository(_ url: URL) async -> Bool { true }

    func cloneRepository(from remoteURL: String, to destinationURL: URL) async throws -> GitCommandResult {
        commandResult()
    }

    func initializeRepository(at url: URL) async throws -> Repository { Repository(url: url) }

    func status(in repositoryURL: URL) async throws -> GitStatus {
        let requestID = nextStatusRequestID
        nextStatusRequestID += 1
        return try await withCheckedThrowingContinuation { continuation in
            statusContinuations[requestID] = continuation
        }
    }

    func worktrees(in repositoryURL: URL) async throws -> [GitWorktree] { [] }

    func addWorktree(
        at destination: URL,
        branch: String,
        createBranch: Bool,
        in repositoryURL: URL
    ) async throws -> GitCommandResult {
        commandResult()
    }

    func removeWorktree(
        at worktreePath: URL,
        force: Bool,
        in repositoryURL: URL
    ) async throws -> GitCommandResult {
        commandResult()
    }

    func pruneWorktrees(in repositoryURL: URL) async throws -> GitCommandResult { commandResult() }

    func changeSummary(forWorktreeAt worktreeURL: URL) async throws -> WorktreeChangeSummary {
        WorktreeChangeSummary(
            total: 0,
            staged: 0,
            untracked: 0,
            conflicted: 0,
            insertions: 0,
            deletions: 0,
            ahead: 0,
            behind: 0,
            branchName: nil,
            lastCommit: nil
        )
    }

    func compareWorktrees(baseURL: URL, comparisonURL: URL) async throws -> WorktreeComparison {
        try await withCheckedThrowingContinuation { continuation in
            comparisonContinuation = continuation
        }
    }

    func diffBetweenWorktrees(
        baseURL: URL,
        comparisonURL: URL,
        file: WorktreeComparisonFile?
    ) async throws -> DiffContent {
        try await withCheckedThrowingContinuation { continuation in
            worktreeDiffContinuation = continuation
        }
    }

    func identity(in repositoryURL: URL) async throws -> GitIdentity {
        defer { identityCallCount += 1 }
        return identityResponses[min(identityCallCount, identityResponses.count - 1)]
    }

    func diff(for change: GitChange, in repositoryURL: URL, staged: Bool) async throws -> DiffContent {
        try await withCheckedThrowingContinuation { continuation in
            precondition(changeDiffContinuations[change.path] == nil)
            changeDiffContinuations[change.path] = continuation
        }
    }

    func stage(paths: [String], in repositoryURL: URL) async throws -> GitCommandResult { commandResult() }

    func unstage(paths: [String], in repositoryURL: URL) async throws -> GitCommandResult { commandResult() }

    func discard(paths: [String], in repositoryURL: URL) async throws -> GitCommandResult { commandResult() }

    func commit(
        summary: String,
        description: String,
        author: GitIdentity?,
        amend: Bool,
        in repositoryURL: URL
    ) async throws -> GitCommandResult {
        commandResult()
    }

    func branches(in repositoryURL: URL) async throws -> [GitBranch] {
        defer { branchesCallCount += 1 }
        return branchesResponses[min(branchesCallCount, branchesResponses.count - 1)]
    }

    func createBranch(
        named name: String,
        checkout: Bool,
        in repositoryURL: URL
    ) async throws -> GitCommandResult {
        commandResult()
    }

    func checkoutBranch(named name: String, in repositoryURL: URL) async throws -> GitCommandResult { commandResult() }

    func renameBranch(
        from oldName: String?,
        to newName: String,
        in repositoryURL: URL
    ) async throws -> GitCommandResult {
        commandResult()
    }

    func deleteBranch(
        named name: String,
        force: Bool,
        in repositoryURL: URL
    ) async throws -> GitCommandResult {
        commandResult()
    }

    func mergeBranch(named name: String, in repositoryURL: URL) async throws -> GitCommandResult { commandResult() }

    func remotes(in repositoryURL: URL) async throws -> [GitRemote] {
        defer { remotesCallCount += 1 }
        return remotesResponses[min(remotesCallCount, remotesResponses.count - 1)]
    }

    func addRemote(named name: String, url: String, in repositoryURL: URL) async throws -> GitCommandResult {
        commandResult()
    }

    func setRemote(named name: String, url: String, in repositoryURL: URL) async throws -> GitCommandResult {
        commandResult()
    }

    func removeRemote(named name: String, in repositoryURL: URL) async throws -> GitCommandResult { commandResult() }

    func fetch(in repositoryURL: URL) async throws -> GitCommandResult { commandResult() }

    func pull(in repositoryURL: URL) async throws -> GitCommandResult { commandResult() }

    func push(in repositoryURL: URL, setUpstreamBranch: String?) async throws -> GitCommandResult { commandResult() }

    func history(in repositoryURL: URL, limit: Int) async throws -> [GitCommit] {
        defer { historyCallCount += 1 }
        return historyResponses[min(historyCallCount, historyResponses.count - 1)]
    }

    func filesChanged(in commit: GitCommit, repositoryURL: URL) async throws -> [GitCommitFile] {
        try await withCheckedThrowingContinuation { continuation in
            precondition(commitFilesContinuations[commit.hash] == nil)
            commitFilesContinuations[commit.hash] = continuation
        }
    }

    func diff(for commit: GitCommit, file: GitCommitFile?, repositoryURL: URL) async throws -> DiffContent {
        try await withCheckedThrowingContinuation { continuation in
            let key = commitDiffKey(hash: commit.hash, path: file?.path)
            precondition(commitDiffContinuations[key] == nil)
            commitDiffContinuations[key] = continuation
        }
    }

    private func commitDiffKey(hash: String, path: String?) -> String {
        "\(hash)|\(path ?? "<full>")"
    }

    private func commandResult() -> GitCommandResult {
        GitCommandResult(
            command: ["git"],
            workingDirectory: nil,
            exitCode: 0,
            standardOutput: "",
            standardError: ""
        )
    }
}
