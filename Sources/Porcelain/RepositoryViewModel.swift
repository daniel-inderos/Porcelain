import AppKit
import Foundation
import PorcelainCore

@MainActor
final class RepositoryViewModel: ObservableObject, Identifiable {
    let id = UUID()
    let repository: Repository

    @Published var selectedTab: PorcelainTab = .changes {
        didSet {
            guard selectedTab == .worktrees, oldValue != .worktrees else { return }
            refreshWorktrees()
        }
    }
    @Published var status = GitStatus(branchName: nil, upstreamName: nil, ahead: 0, behind: 0, detachedHead: nil, changes: [])
    @Published var identity = GitIdentity(name: nil, email: nil)
    @Published var branches: [GitBranch] = []
    @Published var remotes: [GitRemote] = []
    @Published var worktreeInfos: [WorktreeInfo] = []
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
    private var isWorktreeRefreshInFlight = false
    var onSuccessfulOperation: (@MainActor () -> Void)?

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

    func refreshWorktrees() {
        guard !isWorktreeRefreshInFlight else { return }
        isWorktreeRefreshInFlight = true
        Task {
            defer { isWorktreeRefreshInFlight = false }
            await loadWorktreeInfos()
        }
    }

    func makeWorktreeReviewViewModel(
        for worktree: GitWorktree,
        onSuccessfulOperation: (@MainActor () -> Void)? = nil
    ) -> RepositoryViewModel {
        let viewModel = RepositoryViewModel(
            repository: Repository(url: worktree.path),
            gitService: gitService,
            keychainStore: keychainStore
        )
        viewModel.onSuccessfulOperation = onSuccessfulOperation
        return viewModel
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
            async let worktreesValue = gitService.worktrees(in: repository.url)

            status = try await statusValue
            identity = try await identityValue
            branches = try await branchesValue
            remotes = try await remotesValue
            commits = try await commitsValue
            worktreeInfos = await Self.worktreeInfos(
                for: try await worktreesValue,
                currentRepositoryURL: repository.url,
                gitService: gitService
            )

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

    private func loadWorktreeInfos() async {
        do {
            let worktrees = try await gitService.worktrees(in: repository.url)
            worktreeInfos = await Self.worktreeInfos(
                for: worktrees,
                currentRepositoryURL: repository.url,
                gitService: gitService
            )
        } catch {
            alert = AppAlert(error: error)
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

    func addWorktree(
        branch: String,
        createBranch: Bool,
        at destination: URL,
        completion: (@MainActor (Bool, AppAlert?) -> Void)? = nil
    ) {
        perform("Adding worktree", presentsAlert: completion == nil) {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return try await self.gitService.addWorktree(
                at: destination,
                branch: branch,
                createBranch: createBranch,
                in: self.repository.url
            )
        } completion: { succeeded, alert in
            completion?(succeeded, alert)
        }
    }

    func removeWorktree(_ worktree: GitWorktree, force: Bool) {
        perform("Removing worktree") {
            try await self.gitService.removeWorktree(at: worktree.path, force: force, in: self.repository.url)
        }
    }

    func pruneWorktrees() {
        perform("Pruning worktrees") {
            try await self.gitService.pruneWorktrees(in: self.repository.url)
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

    func revealWorktreeInFinder(_ worktree: GitWorktree) {
        NSWorkspace.shared.activateFileViewerSelecting([worktree.path])
    }

    func openWorktreeInTerminal(_ worktree: GitWorktree) {
        guard let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            alert = AppAlert(title: "Terminal", message: "Terminal.app could not be found on this Mac.")
            return
        }
        NSWorkspace.shared.open(
            [worktree.path],
            withApplicationAt: terminalURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
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

    private func perform(
        _ message: String,
        presentsAlert: Bool = true,
        operation: @escaping @MainActor () async throws -> GitCommandResult,
        completion: (@MainActor (Bool, AppAlert?) -> Void)? = nil
    ) {
        Task {
            let outcome = await withActivity(message, presentsAlert: presentsAlert) {
                let result = try await operation()
                rawGitOutput = result.combinedOutput
                await loadRepositoryState()
                return result
            }
            if outcome.alert == nil {
                onSuccessfulOperation?()
            }
            completion?(outcome.alert == nil, outcome.alert)
        }
    }

    @discardableResult
    private func withActivity<Value>(
        _ message: String,
        presentsAlert: Bool = true,
        operation: () async throws -> Value
    ) async -> (value: Value?, alert: AppAlert?) {
        activityMessage = message
        defer { activityMessage = nil }
        do {
            return (try await operation(), nil)
        } catch {
            let appAlert: AppAlert
            if case GitError.commandFailed(let result) = error {
                rawGitOutput = result.combinedOutput
                appAlert = AppAlert(error: error, rawOutput: result.combinedOutput)
            } else {
                appAlert = AppAlert(error: error)
            }
            if presentsAlert {
                alert = appAlert
            }
            return (nil, appAlert)
        }
    }

    private static func worktreeInfos(
        for worktrees: [GitWorktree],
        currentRepositoryURL: URL,
        gitService: GitServicing
    ) async -> [WorktreeInfo] {
        let infos = await withTaskGroup(of: WorktreeInfo.self) { group in
            for worktree in worktrees {
                group.addTask {
                    guard !worktree.isBare, !worktree.isPrunable else {
                        return WorktreeInfo(worktree: worktree, summary: nil)
                    }
                    let summary = try? await gitService.changeSummary(forWorktreeAt: worktree.path)
                    return WorktreeInfo(worktree: worktree, summary: summary)
                }
            }

            var infos: [WorktreeInfo] = []
            for await info in group {
                infos.append(info)
            }
            return infos
        }

        return infos.sorted { lhs, rhs in
            let lhsIsCurrent = lhs.worktree.isCurrent(for: currentRepositoryURL)
            let rhsIsCurrent = rhs.worktree.isCurrent(for: currentRepositoryURL)
            if lhsIsCurrent != rhsIsCurrent {
                return lhsIsCurrent
            }

            switch (lhs.summary?.lastCommit?.date, rhs.summary?.lastCommit?.date) {
            case (let lhsDate?, let rhsDate?):
                if lhsDate != rhsDate {
                    return lhsDate > rhsDate
                }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }

            return lhs.worktree.path.path.localizedStandardCompare(rhs.worktree.path.path) == .orderedAscending
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
