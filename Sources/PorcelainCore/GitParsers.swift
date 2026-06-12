import Foundation

public enum GitParsers {
    public static func parseStatus(_ output: String) -> GitStatus {
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var branchName: String?
        var upstreamName: String?
        var detachedHead: String?
        var ahead = 0
        var behind = 0
        var changes: [GitChange] = []
        var index = 0

        while index < entries.count {
            let entry = entries[index]
            if entry.hasPrefix("## ") {
                let header = String(entry.dropFirst(3))
                let branch = parseBranchHeader(header)
                branchName = branch.branchName
                upstreamName = branch.upstreamName
                detachedHead = branch.detachedHead
                ahead = branch.ahead
                behind = branch.behind
                index += 1
                continue
            }

            guard entry.count >= 3 else {
                index += 1
                continue
            }

            let indexCode = entry[entry.startIndex]
            let workTreeCode = entry[entry.index(after: entry.startIndex)]
            let pathStart = entry.index(entry.startIndex, offsetBy: 3)
            let path = String(entry[pathStart...])
            var originalPath: String?

            let indexState = state(for: indexCode, pairedWith: workTreeCode)
            let workTreeState = state(for: workTreeCode, pairedWith: indexCode)

            if indexCode == "R" || indexCode == "C" {
                let next = index + 1
                if next < entries.count {
                    originalPath = path
                    let renamedPath = entries[next]
                    changes.append(GitChange(path: renamedPath, originalPath: originalPath, indexState: indexState, workTreeState: workTreeState))
                    index += 2
                    continue
                }
            }

            changes.append(GitChange(path: path, originalPath: originalPath, indexState: indexState, workTreeState: workTreeState))
            index += 1
        }

        return GitStatus(
            branchName: branchName,
            upstreamName: upstreamName,
            ahead: ahead,
            behind: behind,
            detachedHead: detachedHead,
            changes: changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        )
    }

    public static func parseBranches(_ output: String, divergence: @Sendable (String, String) -> (Int, Int)) -> [GitBranch] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> GitBranch? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 3 else { return nil }
                let current = parts[0] == "*"
                let name = parts[1]
                let upstream = parts[2].isEmpty ? nil : parts[2]
                let counts = upstream.map { divergence(name, $0) } ?? (0, 0)
                return GitBranch(name: name, isCurrent: current, upstream: upstream, ahead: counts.0, behind: counts.1)
            }
            .sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    public static func parseDivergence(_ output: String) -> (ahead: Int, behind: Int) {
        let parts = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard parts.count >= 2 else { return (0, 0) }
        return (parts[0], parts[1])
    }

    public static func parseRemotes(_ output: String) -> [GitRemote] {
        var remotes: [String: (fetch: String?, push: String?)] = [:]

        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 3 else { continue }
            let name = parts[0]
            let url = parts[1]
            let kind = parts[2]
            var remote = remotes[name] ?? (nil, nil)
            if kind == "(fetch)" {
                remote.fetch = url
            } else if kind == "(push)" {
                remote.push = url
            }
            remotes[name] = remote
        }

        return remotes
            .map { GitRemote(name: $0.key, fetchURL: $0.value.fetch, pushURL: $0.value.push) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func parseCommits(_ output: String) -> [GitCommit] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]

        return output
            .split(separator: "\u{1e}", omittingEmptySubsequences: true)
            .compactMap { record -> GitCommit? in
                let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 6 else { return nil }
                let date = formatter.date(from: fields[4]) ?? fallbackFormatter.date(from: fields[4])
                return GitCommit(
                    hash: fields[0].trimmingCharacters(in: .whitespacesAndNewlines),
                    shortHash: fields[1],
                    authorName: fields[2],
                    authorEmail: fields[3],
                    date: date,
                    subject: fields[5].trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
    }

    public static func parseCommitFiles(_ output: String) -> [GitCommitFile] {
        let entries = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var files: [GitCommitFile] = []
        var index = 0

        while index < entries.count {
            let statusCode = entries[index]
            let status = fileState(forNameStatusCode: statusCode.first ?? " ")
            if statusCode.first == "R" || statusCode.first == "C" {
                guard index + 2 < entries.count else { break }
                let oldPath = entries[index + 1]
                let newPath = entries[index + 2]
                files.append(GitCommitFile(path: newPath, oldPath: oldPath, status: status))
                index += 3
            } else {
                guard index + 1 < entries.count else { break }
                files.append(GitCommitFile(path: entries[index + 1], oldPath: nil, status: status))
                index += 2
            }
        }

        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private static func parseBranchHeader(_ header: String) -> (branchName: String?, upstreamName: String?, detachedHead: String?, ahead: Int, behind: Int) {
        if header.hasPrefix("HEAD (no branch)") {
            return (nil, nil, nil, 0, 0)
        }

        if header.hasPrefix("HEAD detached at ") {
            return (nil, nil, String(header.dropFirst("HEAD detached at ".count)), 0, 0)
        }

        if header.hasPrefix("HEAD detached from ") {
            return (nil, nil, String(header.dropFirst("HEAD detached from ".count)), 0, 0)
        }

        let pieces = header.split(separator: "...", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let branchName = pieces.first?.isEmpty == false ? pieces.first : nil
        guard pieces.count > 1 else {
            return (branchName, nil, nil, 0, 0)
        }

        let tracking = pieces[1]
        if let bracketRange = tracking.range(of: " [") {
            let upstream = String(tracking[..<bracketRange.lowerBound])
            let bracket = String(tracking[bracketRange.upperBound...].dropLast())
            var ahead = 0
            var behind = 0
            for part in bracket.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                if part.hasPrefix("ahead ") {
                    ahead = Int(part.dropFirst("ahead ".count)) ?? 0
                } else if part.hasPrefix("behind ") {
                    behind = Int(part.dropFirst("behind ".count)) ?? 0
                }
            }
            return (branchName, upstream.isEmpty ? nil : upstream, nil, ahead, behind)
        }

        return (branchName, tracking.isEmpty ? nil : tracking, nil, 0, 0)
    }

    private static func state(for code: Character, pairedWith other: Character) -> GitFileState {
        if code == "U" || other == "U" || (code == "A" && other == "A") || (code == "D" && other == "D") {
            return .unmerged
        }

        switch code {
        case " ":
            return .unmodified
        case "M":
            return .modified
        case "A":
            return .added
        case "D":
            return .deleted
        case "R":
            return .renamed
        case "C":
            return .copied
        case "?":
            return .untracked
        case "!":
            return .ignored
        case "T":
            return .typeChanged
        default:
            return .unknown
        }
    }

    private static func fileState(forNameStatusCode code: Character) -> GitFileState {
        switch code {
        case "M": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .unmerged
        default: .unknown
        }
    }
}

