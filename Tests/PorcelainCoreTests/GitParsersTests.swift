import XCTest
@testable import PorcelainCore

final class GitParsersTests: XCTestCase {
    func testParsePorcelainStatusWithBranchRenameAndConflicts() {
        let output = [
            "## main...origin/main [ahead 2, behind 1]",
            " M Sources/App.swift",
            "A  Sources/NewFile.swift",
            "?? Notes.md",
            "R  Old.swift",
            "New.swift",
            "UU Sources/Conflict.swift"
        ].joined(separator: "\0") + "\0"

        let status = GitParsers.parseStatus(output)

        XCTAssertEqual(status.branchName, "main")
        XCTAssertEqual(status.upstreamName, "origin/main")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 1)
        XCTAssertEqual(status.changes.count, 5)
        XCTAssertEqual(status.conflicts.map(\.path), ["Sources/Conflict.swift"])
        XCTAssertTrue(status.changes.contains { $0.path == "Notes.md" && $0.isUntracked })
        XCTAssertTrue(status.changes.contains { $0.path == "Notes.md" && !$0.isStaged && $0.hasUnstagedChanges })
        XCTAssertTrue(status.changes.contains { $0.path == "Sources/NewFile.swift" && $0.isStaged })

        let renamed = status.changes.first { $0.path == "New.swift" }
        XCTAssertEqual(renamed?.originalPath, "Old.swift")
        XCTAssertEqual(renamed?.indexState, .renamed)
    }

    func testParseDetachedHeadStatus() {
        let status = GitParsers.parseStatus("## HEAD detached at abc1234\0 M file.txt\0")

        XCTAssertNil(status.branchName)
        XCTAssertEqual(status.detachedHead, "abc1234")
        XCTAssertEqual(status.branchDisplayName, "Detached abc1234")
    }

    func testParseBranchesWithTrackingInfo() {
        let output = [
            "*\tmain\torigin/main\t[ahead 2, behind 1]",
            " \tfeature/idea\torigin/feature/idea\t",
            " \tlocal-only\t\t",
            " \tstale\torigin/stale\t[gone]"
        ].joined(separator: "\n")

        let branches = GitParsers.parseBranches(output)

        XCTAssertEqual(branches.map(\.name), ["main", "feature/idea", "local-only", "stale"])
        XCTAssertEqual(branches.first?.isCurrent, true)
        XCTAssertEqual(branches.first?.ahead, 2)
        XCTAssertEqual(branches.first?.behind, 1)
        XCTAssertEqual(branches.first?.upstream, "origin/main")
        XCTAssertEqual(branches.first { $0.name == "feature/idea" }?.ahead, 0)
        XCTAssertNil(branches.first { $0.name == "local-only" }?.upstream)
        XCTAssertEqual(branches.first { $0.name == "stale" }?.ahead, 0)
    }

    func testParseTrack() {
        XCTAssertEqual(GitParsers.parseTrack("[ahead 3, behind 7]").ahead, 3)
        XCTAssertEqual(GitParsers.parseTrack("[ahead 3, behind 7]").behind, 7)
        XCTAssertEqual(GitParsers.parseTrack("[behind 4]").behind, 4)
        XCTAssertEqual(GitParsers.parseTrack("[gone]").ahead, 0)
        XCTAssertEqual(GitParsers.parseTrack("").ahead, 0)
    }

    func testParseRemotes() {
        let output = """
        origin\thttps://github.com/example/porcelain.git (fetch)
        origin\thttps://github.com/example/porcelain.git (push)
        upstream\tgit@github.com:open/source.git (fetch)
        upstream\tgit@github.com:open/source.git (push)

        """

        let remotes = GitParsers.parseRemotes(output)

        XCTAssertEqual(remotes.count, 2)
        XCTAssertEqual(remotes.first?.name, "origin")
        XCTAssertEqual(remotes.first?.fetchURL, "https://github.com/example/porcelain.git")
        XCTAssertEqual(remotes.last?.name, "upstream")
    }

    func testParseCommits() {
        let output = "abcdef123\u{1f}abcdef1\u{1f}Dana\u{1f}dana@example.com\u{1f}2026-06-11T16:20:30+00:00\u{1f}Initial commit\u{1e}"

        let commits = GitParsers.parseCommits(output)

        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits[0].hash, "abcdef123")
        XCTAssertEqual(commits[0].shortHash, "abcdef1")
        XCTAssertEqual(commits[0].authorName, "Dana")
        XCTAssertEqual(commits[0].subject, "Initial commit")
        XCTAssertNotNil(commits[0].date)
    }

    func testParseCommitFilesWithRenameAndDeletion() {
        let output = "M\0Sources/App.swift\0R100\0Old.swift\0New.swift\0D\0Removed.swift\0"

        let files = GitParsers.parseCommitFiles(output)

        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.first { $0.path == "New.swift" }?.oldPath, "Old.swift")
        XCTAssertEqual(files.first { $0.path == "New.swift" }?.status, .renamed)
        XCTAssertEqual(files.first { $0.path == "Removed.swift" }?.status, .deleted)
        XCTAssertEqual(files.first { $0.path == "Sources/App.swift" }?.status, .modified)
    }

    func testGitHubLinks() {
        XCTAssertEqual(
            GitHubLinks.repositoryReference(from: "https://github.com/example/porcelain.git"),
            GitHubRepositoryReference(owner: "example", name: "porcelain")
        )
        XCTAssertEqual(
            GitHubLinks.repositoryReference(from: "git@github.com:example/porcelain.git"),
            GitHubRepositoryReference(owner: "example", name: "porcelain")
        )
        XCTAssertEqual(
            GitHubLinks.repositoryReference(from: "ssh://git@github.com/example/porcelain.git"),
            GitHubRepositoryReference(owner: "example", name: "porcelain")
        )

        let remotes = [GitRemote(name: "origin", fetchURL: "git@github.com:example/porcelain.git", pushURL: nil)]
        XCTAssertEqual(
            GitHubLinks.newPullRequestURL(remotes: remotes, branch: "feature/native ui")?.absoluteString,
            "https://github.com/example/porcelain/pull/new/feature/native%20ui"
        )
    }
}
