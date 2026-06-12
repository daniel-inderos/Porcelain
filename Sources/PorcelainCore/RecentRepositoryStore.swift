import Foundation

public final class RecentRepositoryStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key = "recentRepositories"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> [Repository] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Repository].self, from: data)) ?? []
    }

    public func save(_ repositories: [Repository]) {
        var seenPaths = Set<String>()
        let unique = repositories.filter { repository in
            seenPaths.insert(repository.url.path).inserted
        }
        guard let data = try? JSONEncoder().encode(unique) else { return }
        defaults.set(data, forKey: key)
    }

    public func remember(_ repository: Repository) -> [Repository] {
        var repositories = load().filter { $0.url != repository.url }
        repositories.insert(repository, at: 0)
        if repositories.count > 20 {
            repositories = Array(repositories.prefix(20))
        }
        save(repositories)
        return repositories
    }

    public func forget(_ repository: Repository) -> [Repository] {
        let repositories = load().filter { $0.url != repository.url }
        save(repositories)
        return repositories
    }
}
