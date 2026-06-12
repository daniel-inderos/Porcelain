import Foundation

public struct Repository: Identifiable, Codable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public var name: String { url.lastPathComponent }

    public init(url: URL) {
        self.url = url
    }
}

public struct GitWorktree: Identifiable, Hashable, Sendable {
    public var id: String { path.path }
    public let path: URL
    public let headHash: String?
    public let branch: String?
    public let isDetached: Bool
    public let isBare: Bool
    public let isLocked: Bool
    public let lockReason: String?
    public let isPrunable: Bool
    public let isMain: Bool

    public init(
        path: URL,
        headHash: String?,
        branch: String?,
        isDetached: Bool,
        isBare: Bool,
        isLocked: Bool,
        lockReason: String?,
        isPrunable: Bool,
        isMain: Bool
    ) {
        self.path = path
        self.headHash = headHash
        self.branch = branch
        self.isDetached = isDetached
        self.isBare = isBare
        self.isLocked = isLocked
        self.lockReason = lockReason
        self.isPrunable = isPrunable
        self.isMain = isMain
    }

    public var displayName: String {
        branch ?? headHash.map { String($0.prefix(7)) } ?? (path.lastPathComponent.isEmpty ? path.path : path.lastPathComponent)
    }
}

public enum GitFileState: String, Codable, CaseIterable, Sendable {
    case unmodified
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case ignored
    case typeChanged
    case unmerged
    case unknown

    public var label: String {
        switch self {
        case .unmodified: "Unmodified"
        case .modified: "Modified"
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .untracked: "Untracked"
        case .ignored: "Ignored"
        case .typeChanged: "Type Changed"
        case .unmerged: "Conflict"
        case .unknown: "Unknown"
        }
    }
}

public struct GitChange: Identifiable, Codable, Hashable, Sendable {
    public var id: String { "\(path)|\(originalPath ?? "")|\(indexState.rawValue)|\(workTreeState.rawValue)" }
    public let path: String
    public let originalPath: String?
    public let indexState: GitFileState
    public let workTreeState: GitFileState

    public init(path: String, originalPath: String? = nil, indexState: GitFileState, workTreeState: GitFileState) {
        self.path = path
        self.originalPath = originalPath
        self.indexState = indexState
        self.workTreeState = workTreeState
    }

    public var isStaged: Bool {
        indexState != .unmodified &&
            indexState != .unknown &&
            indexState != .untracked &&
            indexState != .ignored
    }

    public var hasUnstagedChanges: Bool {
        workTreeState != .unmodified && workTreeState != .unknown
    }

    public var isUntracked: Bool {
        indexState == .untracked || workTreeState == .untracked
    }

    public var isConflict: Bool {
        indexState == .unmerged || workTreeState == .unmerged
    }

    public var displayState: GitFileState {
        if isConflict { return .unmerged }
        if isUntracked { return .untracked }
        if isStaged { return indexState }
        return workTreeState
    }
}

public struct GitStatus: Equatable, Sendable {
    public let branchName: String?
    public let upstreamName: String?
    public let ahead: Int
    public let behind: Int
    public let detachedHead: String?
    public let changes: [GitChange]
    public let conflicts: [GitChange]

    public init(
        branchName: String?,
        upstreamName: String?,
        ahead: Int,
        behind: Int,
        detachedHead: String?,
        changes: [GitChange]
    ) {
        self.branchName = branchName
        self.upstreamName = upstreamName
        self.ahead = ahead
        self.behind = behind
        self.detachedHead = detachedHead
        self.changes = changes
        self.conflicts = changes.filter(\.isConflict)
    }

    public var isClean: Bool { changes.isEmpty }
    public var branchDisplayName: String { branchName ?? detachedHead.map { "Detached \($0)" } ?? "Unknown" }
}

public struct GitBranch: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let isCurrent: Bool
    public let upstream: String?
    public let ahead: Int
    public let behind: Int

    public init(name: String, isCurrent: Bool, upstream: String?, ahead: Int, behind: Int) {
        self.name = name
        self.isCurrent = isCurrent
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
    }

    public var trackingSummary: String {
        switch (ahead, behind) {
        case (0, 0):
            upstream == nil ? "No upstream" : "Up to date"
        case (let ahead, 0):
            "\(ahead) ahead"
        case (0, let behind):
            "\(behind) behind"
        case (let ahead, let behind):
            "\(ahead) ahead, \(behind) behind"
        }
    }
}

public struct GitRemote: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let fetchURL: String?
    public let pushURL: String?

    public init(name: String, fetchURL: String?, pushURL: String?) {
        self.name = name
        self.fetchURL = fetchURL
        self.pushURL = pushURL
    }

    public var displayURL: String {
        fetchURL ?? pushURL ?? ""
    }
}

public struct GitCommit: Identifiable, Hashable, Sendable {
    public var id: String { hash }
    public let hash: String
    public let shortHash: String
    public let authorName: String
    public let authorEmail: String
    public let date: Date?
    public let subject: String

    public init(hash: String, shortHash: String, authorName: String, authorEmail: String, date: Date?, subject: String) {
        self.hash = hash
        self.shortHash = shortHash
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.date = date
        self.subject = subject
    }
}

public struct WorktreeChangeSummary: Equatable, Sendable {
    public let total: Int
    public let staged: Int
    public let untracked: Int
    public let conflicted: Int
    public let insertions: Int
    public let deletions: Int
    public let ahead: Int
    public let behind: Int
    public let branchName: String?
    public let lastCommit: GitCommit?

    public init(
        total: Int,
        staged: Int,
        untracked: Int,
        conflicted: Int,
        insertions: Int,
        deletions: Int,
        ahead: Int,
        behind: Int,
        branchName: String?,
        lastCommit: GitCommit?
    ) {
        self.total = total
        self.staged = staged
        self.untracked = untracked
        self.conflicted = conflicted
        self.insertions = insertions
        self.deletions = deletions
        self.ahead = ahead
        self.behind = behind
        self.branchName = branchName
        self.lastCommit = lastCommit
    }

    public var isClean: Bool { total == 0 }
}

public struct GitCommitFile: Identifiable, Hashable, Sendable {
    public var id: String { "\(status.rawValue)|\(path)|\(oldPath ?? "")" }
    public let path: String
    public let oldPath: String?
    public let status: GitFileState

    public init(path: String, oldPath: String?, status: GitFileState) {
        self.path = path
        self.oldPath = oldPath
        self.status = status
    }
}

public struct DiffContent: Equatable, Sendable {
    public let path: String
    public let text: String
    public let isBinary: Bool
    public let isLarge: Bool
    public let didTruncate: Bool

    public init(path: String, text: String, isBinary: Bool = false, isLarge: Bool = false, didTruncate: Bool = false) {
        self.path = path
        self.text = text
        self.isBinary = isBinary
        self.isLarge = isLarge
        self.didTruncate = didTruncate
    }
}

public struct GitIdentity: Equatable, Sendable {
    public let name: String?
    public let email: String?

    public init(name: String?, email: String?) {
        self.name = name
        self.email = email
    }

    public var displayName: String {
        switch (name?.isEmpty == false ? name : nil, email?.isEmpty == false ? email : nil) {
        case (let name?, let email?):
            "\(name) <\(email)>"
        case (let name?, nil):
            name
        case (nil, let email?):
            email
        case (nil, nil):
            "Git default"
        }
    }
}

public struct GitCommandResult: Equatable, Sendable {
    public let command: [String]
    public let workingDirectory: URL?
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(command: [String], workingDirectory: URL?, exitCode: Int32, standardOutput: String, standardError: String) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    public var combinedOutput: String {
        [standardOutput, standardError]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }
}

public enum GitError: Error, LocalizedError, Sendable {
    case gitMissing
    case invalidRepository(URL)
    case commandFailed(GitCommandResult)
    case emptyCommitSummary
    case unsafePath(String)
    case unreadableFile(String)
    case parseFailure(String)

    public var errorDescription: String? {
        switch self {
        case .gitMissing:
            "Git is not installed or could not be found on this Mac."
        case .invalidRepository(let url):
            "\(url.path) is not a Git repository."
        case .commandFailed(let result):
            GitError.friendlyMessage(for: result)
        case .emptyCommitSummary:
            "Enter a commit summary before committing."
        case .unsafePath(let path):
            "The path \(path) is not safe to modify."
        case .unreadableFile(let path):
            "Could not read \(path)."
        case .parseFailure(let message):
            message
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .gitMissing:
            return "Install Xcode Command Line Tools or Git, then relaunch Porcelain."
        case .invalidRepository:
            return "Choose a folder that contains a .git directory, or initialize a new repository."
        case .commandFailed(let result):
            let raw = result.combinedOutput.lowercased()
            if raw.contains("authentication failed") || raw.contains("could not read username") {
                return "Check your remote credentials or sign in with a token in Settings."
            }
            if raw.contains("merge conflict") || raw.contains("unmerged") {
                return "Resolve conflicts in the working tree, then refresh Porcelain."
            }
            if raw.contains("non-fast-forward") || raw.contains("fetch first") {
                return "Pull the latest changes before pushing again."
            }
            // Avoid repeating the raw output when the error description already is the raw output.
            let output = result.combinedOutput
            if output.isEmpty || GitError.friendlyMessage(for: result) == output {
                return nil
            }
            return output
        case .emptyCommitSummary:
            return "A short summary helps identify the change in history."
        case .unsafePath:
            return "Porcelain only modifies paths reported by Git inside the selected repository."
        case .unreadableFile:
            return "The file may have been deleted or may require permission changes."
        case .parseFailure:
            return nil
        }
    }

    private static func friendlyMessage(for result: GitCommandResult) -> String {
        let output = result.combinedOutput
        let lowercased = output.lowercased()
        if lowercased.contains("not a git repository") {
            return "This folder is not a Git repository."
        }
        if lowercased.contains("authentication failed") || lowercased.contains("could not read username") {
            return "Git could not authenticate with the remote."
        }
        if lowercased.contains("merge conflict") || lowercased.contains("automatic merge failed") {
            return "Git stopped because the merge has conflicts."
        }
        if lowercased.contains("nothing to commit") {
            return "There is nothing staged to commit."
        }
        if lowercased.contains("is already checked out") {
            return "That branch is already checked out in another worktree."
        }
        if lowercased.contains("contains modified or untracked files") || lowercased.contains("use --force") {
            return "This worktree has local changes. Use force to remove it."
        }
        if lowercased.contains("already exists") && !lowercased.contains("branch named") {
            return "That folder already exists and must be empty before adding a worktree."
        }
        if lowercased.contains("would be overwritten") {
            return "Git stopped to protect local changes."
        }
        return output.isEmpty ? "Git command failed with exit code \(result.exitCode)." : output
    }
}
