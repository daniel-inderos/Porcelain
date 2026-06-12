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

    func testParseWorktreesPorcelain() {
        let output = [
            "worktree /repo",
            "HEAD 1111111111111111111111111111111111111111",
            "branch refs/heads/main",
            "",
            "worktree /repo-feature",
            "HEAD 2222222222222222222222222222222222222222",
            "branch refs/heads/feature/work",
            "locked indexing",
            "",
            "worktree /repo-detached",
            "HEAD 3333333333333333333333333333333333333333",
            "detached",
            "prunable gitdir file points to non-existent location",
            "",
            "worktree /repo-locked",
            "HEAD 4444444444444444444444444444444444444444",
            "locked",
            "",
            "worktree /repo-bare",
            "bare",
            "unknown attribute"
        ].joined(separator: "\0")

        let worktrees = GitParsers.parseWorktrees(output)

        XCTAssertEqual(worktrees.count, 5)
        XCTAssertEqual(worktrees[0].path.path, "/repo")
        XCTAssertEqual(worktrees[0].branch, "main")
        XCTAssertTrue(worktrees[0].isMain)
        XCTAssertEqual(worktrees[0].displayName, "main")
        XCTAssertEqual(worktrees[1].branch, "feature/work")
        XCTAssertTrue(worktrees[1].isLocked)
        XCTAssertEqual(worktrees[1].lockReason, "indexing")
        XCTAssertFalse(worktrees[1].isMain)
        XCTAssertTrue(worktrees[2].isDetached)
        XCTAssertTrue(worktrees[2].isPrunable)
        XCTAssertEqual(worktrees[2].displayName, "3333333")
        XCTAssertTrue(worktrees[3].isLocked)
        XCTAssertNil(worktrees[3].lockReason)
        XCTAssertTrue(worktrees[4].isBare)
    }

    func testParseShortstatVariants() {
        var shortstat = GitParsers.parseShortstat("1 file changed, 2 insertions(+)\n")
        XCTAssertEqual(shortstat.filesChanged, 1)
        XCTAssertEqual(shortstat.insertions, 2)
        XCTAssertEqual(shortstat.deletions, 0)

        shortstat = GitParsers.parseShortstat("1 file changed, 3 deletions(-)\n")
        XCTAssertEqual(shortstat.filesChanged, 1)
        XCTAssertEqual(shortstat.insertions, 0)
        XCTAssertEqual(shortstat.deletions, 3)

        shortstat = GitParsers.parseShortstat("2 files changed, 10 insertions(+), 4 deletions(-)\n")
        XCTAssertEqual(shortstat.filesChanged, 2)
        XCTAssertEqual(shortstat.insertions, 10)
        XCTAssertEqual(shortstat.deletions, 4)

        shortstat = GitParsers.parseShortstat("")
        XCTAssertEqual(shortstat.filesChanged, 0)
        XCTAssertEqual(shortstat.insertions, 0)
        XCTAssertEqual(shortstat.deletions, 0)
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
