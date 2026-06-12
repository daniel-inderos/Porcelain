import AppKit
import Foundation
import PorcelainCore

@MainActor
final class AppViewModel: ObservableObject {
    @Published var repositories: [Repository]
    @Published var selectedRepository: Repository?
    @Published var repositoryViewModel: RepositoryViewModel?
    @Published var searchText = ""
    @Published var alert: AppAlert?
    @Published var gitVersion = "Checking Git..."
    @Published var isCloning = false
    @Published var cloneErrorMessage: String?

    private let gitService: GitServicing
    private let recentStore: RecentRepositoryStore

    init(
        gitService: GitServicing = GitService.shared,
        recentStore: RecentRepositoryStore = RecentRepositoryStore()
    ) {
        self.gitService = gitService
        self.recentStore = recentStore
        repositories = recentStore.load()
        if let first = repositories.first {
            select(first)
        }
        Task {
            await checkGit()
        }
    }

    var filteredRepositories: [Repository] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return repositories }
        return repositories.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
                $0.url.path.localizedCaseInsensitiveContains(query)
        }
    }

    func checkGit() async {
        do {
            gitVersion = try await gitService.validateGitInstalled()
        } catch {
            gitVersion = "Git unavailable"
            alert = AppAlert(error: error)
        }
    }

    func select(_ repository: Repository) {
        open(repository, remember: true)
    }

    func openWorktree(at url: URL) {
        Task {
            do {
                let root = try await gitService.repositoryRoot(for: url)
                open(Repository(url: root), remember: false)
            } catch {
                alert = AppAlert(error: error)
            }
        }
    }

    func forget(_ repository: Repository) {
        repositories = recentStore.forget(repository)
        if selectedRepository == repository {
            selectedRepository = nil
            repositoryViewModel = nil
        }
    }

    func chooseExistingRepository() {
        let panel = NSOpenPanel()
        panel.title = "Open Repository"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let root = try await gitService.repositoryRoot(for: url)
                select(Repository(url: root))
            } catch {
                alert = AppAlert(error: error)
            }
        }
    }

    func chooseFolderAndInitializeRepository() {
        let panel = NSOpenPanel()
        panel.title = "Initialize Repository"
        panel.prompt = "Initialize"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                let repository = try await gitService.initializeRepository(at: url)
                select(repository)
            } catch {
                alert = AppAlert(error: error)
            }
        }
    }

    @discardableResult
    func cloneRepository(from remoteURL: String, into parentURL: URL) async -> Bool {
        let cleanedURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedURL.isEmpty else {
            cloneErrorMessage = "Enter a repository URL."
            return false
        }

        let destination = parentURL.appendingPathComponent(Self.repositoryName(from: cleanedURL), isDirectory: true)
        isCloning = true
        cloneErrorMessage = nil
        defer { isCloning = false }

        do {
            _ = try await gitService.cloneRepository(from: cleanedURL, to: destination)
            let root = try await gitService.repositoryRoot(for: destination)
            select(Repository(url: root))
            return true
        } catch {
            cloneErrorMessage = AppAlert(error: error).message
            return false
        }
    }

    private static func repositoryName(from remoteURL: String) -> String {
        let trimmed = remoteURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let last: String
        if let url = URL(string: trimmed), let component = url.pathComponents.last, component != "/" {
            last = component
        } else {
            last = trimmed.split(separator: "/").last.map(String.init) ?? "Repository"
        }

        let withoutGit = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
        let fallback = withoutGit.isEmpty ? "Repository" : withoutGit
        return fallback.replacingOccurrences(of: ":", with: "-")
    }

    private func open(_ repository: Repository, remember: Bool) {
        selectedRepository = repository
        let viewModel = RepositoryViewModel(repository: repository, gitService: gitService)
        repositoryViewModel = viewModel
        if remember {
            repositories = recentStore.remember(repository)
        }
        viewModel.start()
    }
}
