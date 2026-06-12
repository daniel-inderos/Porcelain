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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PorcelainTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
