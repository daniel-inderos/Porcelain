import XCTest
@testable import PorcelainCore

final class GitServiceTests: XCTestCase {
    func testRepositoryLifecycleStatusStageUnstageAndDiscard() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = GitService()
        let repository = try await service.initializeRepository(at: directory)
        let isRepository = await service.isRepository(repository.url)
        XCTAssertTrue(isRepository)

        let fileURL = repository.url.appendingPathComponent("hello.txt")
        try "hello\n".write(to: fileURL, atomically: true, encoding: .utf8)

        var status = try await service.status(in: repository.url)
        XCTAssertEqual(status.changes.first?.path, "hello.txt")
        XCTAssertEqual(status.changes.first?.displayState, .untracked)

        let untrackedDiff = try await service.diff(for: status.changes[0], in: repository.url, staged: false)
        XCTAssertFalse(untrackedDiff.isBinary)
        XCTAssertTrue(untrackedDiff.text.contains("+hello"))

        _ = try await service.stage(paths: ["hello.txt"], in: repository.url)
        status = try await service.status(in: repository.url)
        XCTAssertEqual(status.changes.first?.indexState, .added)

        _ = try await service.unstage(paths: ["hello.txt"], in: repository.url)
        status = try await service.status(in: repository.url)
        XCTAssertEqual(status.changes.first?.displayState, .untracked)

        _ = try await service.discard(paths: ["hello.txt"], in: repository.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        status = try await service.status(in: repository.url)
        XCTAssertTrue(status.isClean)
    }

    func testInvalidRepositoryIsReported() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = GitService()
        let isRepository = await service.isRepository(directory)

        XCTAssertFalse(isRepository)
        do {
            _ = try await service.repositoryRoot(for: directory)
            XCTFail("Expected invalid repository error")
        } catch {
            XCTAssertNotNil(error as? GitError)
        }
    }

    func testCommitRejectsEmptySummary() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = GitService()
        let repository = try await service.initializeRepository(at: directory)

        do {
            _ = try await service.commit(summary: "  ", description: "", author: nil, amend: false, in: repository.url)
            XCTFail("Expected empty commit summary to throw")
        } catch GitError.emptyCommitSummary {
            XCTAssertTrue(true)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUntrackedDirectoryDiffShowsDirectoryPreview() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = GitService()
        let repository = try await service.initializeRepository(at: directory)
        let exportsDirectory = repository.url.appendingPathComponent("prompt-exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        try "hello\n".write(
            to: exportsDirectory.appendingPathComponent("export.txt"),
            atomically: true,
            encoding: .utf8
        )

        let change = GitChange(path: "prompt-exports/", indexState: .untracked, workTreeState: .untracked)
        XCTAssertFalse(change.isStaged)
        XCTAssertTrue(change.hasUnstagedChanges)

        let diff = try await service.diff(for: change, in: repository.url, staged: false)

        XCTAssertFalse(diff.isBinary)
        XCTAssertTrue(diff.text.contains("Untracked directory prompt-exports/"))
        XCTAssertTrue(diff.text.contains("+prompt-exports/export.txt"))
    }

    func testWorktreeLifecycleAndChangeSummary() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let worktreeURL = directory.appendingPathComponent("feature-worktree", isDirectory: true)
        let service = GitService()
        let repository = try await service.initializeRepository(at: repositoryURL)

        try runGit(["branch", "-M", "main"], in: repository.url)
        try runGit(["config", "user.name", "Porcelain Tests"], in: repository.url)
        try runGit(["config", "user.email", "tests@example.com"], in: repository.url)

        let fileURL = repository.url.appendingPathComponent("hello.txt")
        try "hello\n".write(to: fileURL, atomically: true, encoding: .utf8)
        _ = try await service.stage(paths: ["hello.txt"], in: repository.url)
        _ = try await service.commit(summary: "Initial commit", description: "", author: nil, amend: false, in: repository.url)

        _ = try await service.addWorktree(at: worktreeURL, branch: "feature/worktree", createBranch: true, in: repository.url)

        let worktrees = try await service.worktrees(in: repository.url)
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertEqual(worktrees[0].path.path, repository.url.path)
        XCTAssertEqual(worktrees[0].branch, "main")
        XCTAssertTrue(worktrees[0].isMain)

        let resolvedWorktreePath = worktreeURL.resolvingSymlinksInPath().path
        let linkedWorktree = try XCTUnwrap(worktrees.first { $0.path.resolvingSymlinksInPath().path == resolvedWorktreePath })
        XCTAssertEqual(linkedWorktree.branch, "feature/worktree")
        XCTAssertFalse(linkedWorktree.isMain)

        let linkedFileURL = worktreeURL.appendingPathComponent("hello.txt")
        try "hello\nfrom linked worktree\n".write(to: linkedFileURL, atomically: true, encoding: .utf8)

        let summary = try await service.changeSummary(forWorktreeAt: worktreeURL)
        XCTAssertFalse(summary.isClean)
        XCTAssertEqual(summary.total, 1)
        XCTAssertEqual(summary.staged, 0)
        XCTAssertEqual(summary.untracked, 0)
        XCTAssertEqual(summary.conflicted, 0)
        XCTAssertEqual(summary.insertions, 1)
        XCTAssertEqual(summary.deletions, 0)
        XCTAssertEqual(summary.branchName, "feature/worktree")
        XCTAssertEqual(summary.lastCommit?.subject, "Initial commit")

        do {
            _ = try await service.removeWorktree(at: worktreeURL, force: false, in: repository.url)
            XCTFail("Expected dirty worktree removal to require force")
        } catch let error as GitError {
            XCTAssertEqual(error.errorDescription, "This worktree has local changes. Use force to remove it.")
        }

        _ = try await service.removeWorktree(at: worktreeURL, force: true, in: repository.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktreeURL.path))
        let remainingWorktrees = try await service.worktrees(in: repository.url)
        XCTAssertEqual(remainingWorktrees.count, 1)
    }

    func testRecentRepositoryStoreDeduplicates() {
        let suiteName = "PorcelainTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = RecentRepositoryStore(defaults: defaults)
        let first = Repository(url: URL(fileURLWithPath: "/tmp/one"))
        let second = Repository(url: URL(fileURLWithPath: "/tmp/two"))

        _ = store.remember(first)
        _ = store.remember(second)
        let repositories = store.remember(first)

        XCTAssertEqual(repositories.map(\.url.path), ["/tmp/one", "/tmp/two"])
        XCTAssertEqual(store.load().map(\.url.path), ["/tmp/one", "/tmp/two"])
    }

    func testLargeCommitDiffDoesNotBlockOnPipeBuffer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = GitService()
        let repository = try await service.initializeRepository(at: directory)
        try runGit(["config", "user.name", "Porcelain Tests"], in: repository.url)
        try runGit(["config", "user.email", "tests@example.com"], in: repository.url)

        // Well past the 64 KB pipe buffer that used to deadlock runGit.
        let largeContent = (0..<20_000).map { "line \($0) of a reasonably long test fixture" }.joined(separator: "\n")
        try largeContent.write(to: repository.url.appendingPathComponent("big.txt"), atomically: true, encoding: .utf8)

        _ = try await service.stage(paths: ["big.txt"], in: repository.url)
        _ = try await service.commit(summary: "Add big file", description: "", author: nil, amend: false, in: repository.url)

        let commits = try await service.history(in: repository.url, limit: 10)
        XCTAssertEqual(commits.count, 1)

        let diff = try await service.diff(for: commits[0], file: nil, repositoryURL: repository.url)
        XCTAssertTrue(diff.text.contains("+line 0 of a reasonably long test fixture"))
        XCTAssertFalse(diff.isBinary)
    }

    private func runGit(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PorcelainTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
