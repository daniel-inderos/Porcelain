import Foundation

enum GitRefNameValidator {
    private static let invalidBranchNameMessage = "Enter a valid branch name."

    static func validateBranchName(_ name: String) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidBranchName(cleaned) else {
            throw GitError.parseFailure(invalidBranchNameMessage)
        }
        return cleaned
    }

    private static func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        guard !name.hasPrefix("-") else { return false }
        guard !name.hasPrefix("/") && !name.hasSuffix("/") else { return false }
        guard !name.hasSuffix(".") else { return false }
        guard !name.contains("..") else { return false }
        guard !name.contains("//") else { return false }
        guard !name.contains("@{") else { return false }
        guard name != "@" else { return false }
        guard name != "HEAD" else { return false }
        guard !containsInvalidRefCharacter(name) else { return false }

        let components = name.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { component in
            guard !component.isEmpty else { return false }
            guard component.first != "." else { return false }
            guard !component.hasSuffix(".lock") else { return false }
            return true
        }
    }

    private static func containsInvalidRefCharacter(_ name: String) -> Bool {
        for scalar in name.unicodeScalars {
            if scalar.value <= 0x20 || scalar.value == 0x7F {
                return true
            }
            switch scalar {
            case "~", "^", ":", "?", "*", "[", "\\":
                return true
            default:
                continue
            }
        }
        return false
    }
}
