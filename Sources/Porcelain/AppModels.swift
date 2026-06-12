import Foundation
import PorcelainCore

enum PorcelainTab: String, CaseIterable, Identifiable {
    case changes = "Changes"
    case history = "History"
    case branches = "Branches"
    case remotes = "Remotes"
    case settings = "Settings"

    var id: String { rawValue }
}

enum DiffMode: String, CaseIterable, Identifiable {
    case unified = "Unified"
    case sideBySide = "Side by Side"

    var id: String { rawValue }
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let rawOutput: String?

    init(title: String, message: String, rawOutput: String? = nil) {
        self.title = title
        self.message = message
        self.rawOutput = rawOutput
    }

    init(error: Error, rawOutput: String? = nil) {
        title = "Porcelain"
        if let localized = error as? LocalizedError {
            let description = localized.errorDescription ?? String(describing: error)
            if let recovery = localized.recoverySuggestion, !recovery.isEmpty {
                message = "\(description)\n\n\(recovery)"
            } else {
                message = description
            }
        } else {
            message = String(describing: error)
        }
        self.rawOutput = rawOutput
    }
}

extension GitFileState {
    var shortLabel: String {
        switch self {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "?"
        case .ignored: "!"
        case .typeChanged: "T"
        case .unmerged: "!"
        case .unknown: "?"
        case .unmodified: ""
        }
    }
}

