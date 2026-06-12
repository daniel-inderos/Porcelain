import Foundation

public struct GitHubRepositoryReference: Equatable, Sendable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public var webURL: URL {
        URL(string: "https://github.com/\(owner)/\(name)")!
    }
}

public enum GitHubLinks {
    public static func repositoryReference(from remoteURL: String) -> GitHubRepositoryReference? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)

        if let url = URL(string: trimmed), let host = url.host?.lowercased(), host == "github.com" {
            let components = url.path
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                .split(separator: "/")
                .map(String.init)
            guard components.count >= 2 else { return nil }
            return GitHubRepositoryReference(owner: components[0], name: stripGitSuffix(components[1]))
        }

        if trimmed.hasPrefix("git@github.com:") {
            let path = String(trimmed.dropFirst("git@github.com:".count))
            let components = path.split(separator: "/").map(String.init)
            guard components.count >= 2 else { return nil }
            return GitHubRepositoryReference(owner: components[0], name: stripGitSuffix(components[1]))
        }

        if trimmed.hasPrefix("ssh://git@github.com/") {
            let path = String(trimmed.dropFirst("ssh://git@github.com/".count))
            let components = path.split(separator: "/").map(String.init)
            guard components.count >= 2 else { return nil }
            return GitHubRepositoryReference(owner: components[0], name: stripGitSuffix(components[1]))
        }

        return nil
    }

    public static func repositoryURL(remotes: [GitRemote]) -> URL? {
        remotes.lazy.compactMap { repositoryReference(from: $0.fetchURL ?? $0.pushURL ?? "")?.webURL }.first
    }

    public static func branchURL(remotes: [GitRemote], branch: String) -> URL? {
        guard let reference = remotes.lazy.compactMap({ repositoryReference(from: $0.fetchURL ?? $0.pushURL ?? "") }).first else {
            return nil
        }
        return URL(string: "https://github.com/\(reference.owner)/\(reference.name)/tree/\(urlComponent(branch))")
    }

    public static func commitURL(remotes: [GitRemote], hash: String) -> URL? {
        guard let reference = remotes.lazy.compactMap({ repositoryReference(from: $0.fetchURL ?? $0.pushURL ?? "") }).first else {
            return nil
        }
        return URL(string: "https://github.com/\(reference.owner)/\(reference.name)/commit/\(hash)")
    }

    public static func compareURL(remotes: [GitRemote], branch: String) -> URL? {
        guard let reference = remotes.lazy.compactMap({ repositoryReference(from: $0.fetchURL ?? $0.pushURL ?? "") }).first else {
            return nil
        }
        return URL(string: "https://github.com/\(reference.owner)/\(reference.name)/compare/\(urlComponent(branch))")
    }

    public static func newPullRequestURL(remotes: [GitRemote], branch: String) -> URL? {
        guard let reference = remotes.lazy.compactMap({ repositoryReference(from: $0.fetchURL ?? $0.pushURL ?? "") }).first else {
            return nil
        }
        return URL(string: "https://github.com/\(reference.owner)/\(reference.name)/pull/new/\(urlComponent(branch))")
    }

    private static func stripGitSuffix(_ value: String) -> String {
        value.hasSuffix(".git") ? String(value.dropLast(4)) : value
    }

    private static func urlComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

