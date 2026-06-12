import AppKit
import Foundation
import PorcelainCore

@MainActor
final class RepositoryViewModel: ObservableObject, Identifiable {
    let id = UUID()
    let repository: Repository

    @Published var selectedTab: PorcelainTab = .changes
    @Published var status = GitStatus(branchName: nil, upstreamName: nil, ahead: 0, behind: 0, detachedHead: nil, changes: [])
    @Published var identity = GitIdentity(name: nil, email: nil)
    @Published var branches: [GitBranch] = []
    @Published var remotes: [GitRemote] = []
    @Published var commits: [GitCommit] = []
    @Published var commitFiles: [GitCommitFile] = []
    @Published var selectedChange: GitChange?
    @Published var selectedChangeIsStaged = false
    @Published var selectedCommit: GitCommit?
    @Published var selectedCommitFile: GitCommitFile?
    @Published var diff = DiffContent(path: "", text: "")
    @Published var commitSummary = ""
    @Published var commitDescription = ""
    @Published var amendCommit = false
    @Published var activityMessage: String?
    @Published var rawGitOutput = ""
    @Published var alert: AppAlert?
    @Published var githubToken = ""
    @Published var hasGitHubToken = false

    private let gitService: GitServicing
    private let keychainStore: KeychainStore
    private let fileWatcher = RepositoryFileWatcher()

    init(
        repository: Repository,
        gitService: GitServicing,
        keychainStore: KeychainStore = KeychainStore()
    ) {
        self.repository = repository
        self.gitService = gitService
        self.keychainStore = keychainStore
    }

    var isBusy: Bool { activityMessage != nil }
    var stagedChanges: [GitChange] { status.changes.filter(\.isStaged) }
    var unstagedChanges: [GitChange] { status.changes.filter { $0.hasUnstagedChanges || $0.isUntracked } }
    var currentBranchName: String? { status.branchName }
    var hasConflicts: Bool { !status.conflicts.isEmpty }
    var hasGitHubRemote: Bool { GitHubLinks.repositoryURL(remotes: remotes) != nil }

    var syncSummary: String {
        if status.upstreamName == nil {
            return "No upstream"
        }
        switch (status.ahead, status.behind) {
        case (0, 0):
            return "Up to date"
        case (let ahead, 0):
            return "\(ahead) ahead"
        case (0, let behind):
            return "\(behind) behind"
        case (let ahead, let behind):
            return "\(ahead) ahead, \(behind) behind"
        }
    }

    func start() {
        refresh()
        loadTokenState()
        fileWatcher.startWatching(repositoryURL: repository.url) { [weak self] in
            Task { @MainActor in
                self?.refreshStatusOnly()
            }
        }
    }

    deinit {
        fileWatcher.stop()
    }

    func refresh() {
        Task {
            await loadRepositoryState()
        }
    }

    func refreshStatusOnly() {
        Task {
            do {
                status = try await gitService.status(in: repository.url)
                if let selectedChange {
                    selectedChangeIsStaged = selectedChange.isStaged
                    await selectChange(selectedChange, staged: selectedChangeIsStaged)
                }
            } catch {
                alert = AppAlert(error: error)
            }
        }
    }

    func loadRepositoryState() async {
        await withActivity("Refreshing") {
            async let statusValue = gitService.status(in: repository.url)
            async let identityValue = gitService.identity(in: repository.url)
            async let branchesValue = gitService.branches(in: repository.url)
            async let remotesValue = gitService.remotes(in: repository.url)
            async let commitsValue = gitService.history(in: repository.url, limit: 200)

            status = try await statusValue
            identity = try await identityValue
            branches = try await branchesValue
            remotes = try await remotesValue
            commits = try await commitsValue

            if selectedChange == nil, let first = unstagedChanges.first ?? stagedChanges.first {
                await selectChange(first, staged: first.isStaged && !first.hasUnstagedChanges)
            } else if let selectedChange {
                await selectChange(selectedChange, staged: selectedChangeIsStaged)
            }

            if selectedCommit == nil, let firstCommit = commits.first {
                await selectCommit(firstCommit)
            }
        }
    }

    func selectChange(_ change: GitChange, staged: Bool) async {
        selectedChange = change
        selectedChangeIsStaged = staged
        do {
            diff = try await gitService.diff(for: change, in: repository.url, staged: staged)
        } catch {
            diff = DiffContent(path: change.path, text: "")
            alert = AppAlert(error: error)
        }
    }

    func selectCommit(_ commit: GitCommit) async {
        selectedCommit = commit
        do {
            commitFiles = try await gitService.filesChanged(in: commit, repositoryURL: repository.url)
            selectedCommitFile = commitFiles.first
            diff = try await gitService.diff(for: commit, file: selectedCommitFile, repositoryURL: repository.url)
        } catch {
            commitFiles = []
            selectedCommitFile = nil
            diff = DiffContent(path: commit.shortHash, text: "")
            alert = AppAlert(error: error)
        }
    }

    func selectCommitFile(_ file: GitCommitFile?) async {
        selectedCommitFile = file
        guard let selectedCommit else { return }
        do {
            diff = try await gitService.diff(for: selectedCommit, file: file, repositoryURL: repository.url)
        } catch {
            alert = AppAlert(error: error)
        }
    }

    func stage(_ change: GitChange) {
        perform("Staging") {
            try await self.gitService.stage(paths: [change.path], in: self.repository.url)
        }
    }

    func stageAll() {
        perform("Staging all") {
            try await self.gitService.stage(paths: [], in: self.repository.url)
        }
    }

    func unstage(_ change: GitChange) {
        perform("Unstaging") {
            try await self.gitService.unstage(paths: [change.path], in: self.repository.url)
        }
    }

    func unstageAll() {
        perform("Unstaging all") {
            try await self.gitService.unstage(paths: [], in: self.repository.url)
        }
    }

    func discard(_ change: GitChange) {
        perform("Discarding") {
            try await self.gitService.discard(paths: [change.path], in: self.repository.url)
        }
    }

    func commit() {
        perform("Committing") {
            let result = try await self.gitService.commit(
                summary: self.commitSummary,
                description: self.commitDescription,
                author: self.identity,
                amend: self.amendCommit,
                in: self.repository.url
            )
            self.commitSummary = ""
            self.commitDescription = ""
            self.amendCommit = false
            return result
        }
    }

    func fetch() {
        perform("Fetching") {
            try await self.gitService.fetch(in: self.repository.url)
        }
    }

    func pull() {
        perform("Pulling") {
            try await self.gitService.pull(in: self.repository.url)
        }
    }

    func push() {
        let upstreamBranch = status.upstreamName == nil ? status.branchName : nil
        perform("Pushing") {
            try await self.gitService.push(in: self.repository.url, setUpstreamBranch: upstreamBranch)
        }
    }

    func pushAndSetUpstream() {
        perform("Pushing") {
            try await self.gitService.push(in: self.repository.url, setUpstreamBranch: self.status.branchName)
        }
    }

    func createBranch(named name: String, checkout: Bool) {
        perform("Creating branch") {
            try await self.gitService.createBranch(named: name, checkout: checkout, in: self.repository.url)
        }
    }

    func checkoutBranch(named name: String) {
        guard name != status.branchName else { return }
        perform("Checking out branch") {
            try await self.gitService.checkoutBranch(named: name, in: self.repository.url)
        }
    }

    func renameBranch(from oldName: String?, to newName: String) {
        perform("Renaming branch") {
            try await self.gitService.renameBranch(from: oldName, to: newName, in: self.repository.url)
        }
    }

    func deleteBranch(named name: String, force: Bool = false) {
        perform("Deleting branch") {
            try await self.gitService.deleteBranch(named: name, force: force, in: self.repository.url)
        }
    }

    func mergeBranch(named name: String) {
        perform("Merging branch") {
            try await self.gitService.mergeBranch(named: name, in: self.repository.url)
        }
    }

    func addRemote(named name: String, url: String) {
        perform("Adding remote") {
            try await self.gitService.addRemote(named: name, url: url, in: self.repository.url)
        }
    }

    func setRemote(named name: String, url: String) {
        perform("Updating remote") {
            try await self.gitService.setRemote(named: name, url: url, in: self.repository.url)
        }
    }

    func removeRemote(named name: String) {
        perform("Removing remote") {
            try await self.gitService.removeRemote(named: name, in: self.repository.url)
        }
    }

    func openFile(_ change: GitChange) {
        NSWorkspace.shared.open(repository.url.appendingPathComponent(change.path))
    }

    func revealInFinder(_ change: GitChange) {
        NSWorkspace.shared.activateFileViewerSelecting([repository.url.appendingPathComponent(change.path)])
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func copyCommitHash(_ commit: GitCommit) {
        copyPath(commit.hash)
    }

    func openRepositoryOnRemote() {
        open(GitHubLinks.repositoryURL(remotes: remotes))
    }

    func openBranchOnRemote() {
        guard let branch = status.branchName else { return }
        open(GitHubLinks.branchURL(remotes: remotes, branch: branch))
    }

    func openCommitOnRemote(_ commit: GitCommit) {
        open(GitHubLinks.commitURL(remotes: remotes, hash: commit.hash))
    }

    func openCompareOnRemote() {
        guard let branch = status.branchName else { return }
        open(GitHubLinks.compareURL(remotes: remotes, branch: branch))
    }

    func openNewPullRequest() {
        guard let branch = status.branchName else { return }
        open(GitHubLinks.newPullRequestURL(remotes: remotes, branch: branch))
    }

    func saveGitHubToken() {
        do {
            try keychainStore.saveToken(githubToken)
            githubToken = ""
            hasGitHubToken = true
        } catch {
            alert = AppAlert(error: error)
        }
    }

    func deleteGitHubToken() {
        do {
            try keychainStore.deleteToken()
            githubToken = ""
            hasGitHubToken = false
        } catch {
            alert = AppAlert(error: error)
        }
    }

    private func loadTokenState() {
        do {
            hasGitHubToken = try keychainStore.token() != nil
        } catch {
            hasGitHubToken = false
        }
    }

    private func perform(_ message: String, operation: @escaping @MainActor () async throws -> GitCommandResult) {
        Task {
            await withActivity(message) {
                let result = try await operation()
                rawGitOutput = result.combinedOutput
                await loadRepositoryState()
            }
        }
    }

    private func withActivity(_ message: String, operation: () async throws -> Void) async {
        activityMessage = message
        defer { activityMessage = nil }
        do {
            try await operation()
        } catch {
            if case GitError.commandFailed(let result) = error {
                rawGitOutput = result.combinedOutput
                alert = AppAlert(error: error, rawOutput: result.combinedOutput)
            } else {
                alert = AppAlert(error: error)
            }
        }
    }

    private func open(_ url: URL?) {
        guard let url else {
            alert = AppAlert(title: "Remote Link", message: "No GitHub remote could be detected for this repository.")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
