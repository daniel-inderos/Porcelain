import XCTest
import PorcelainCore
@testable import Porcelain

@MainActor
final class RepositoryViewModelConcurrencyTests: XCTestCase {
    func testStaleSuccessfulChangeDiffCannotOverwriteNewerDiff() async {
        let service = ControllableGitService()
        let viewModel = makeViewModel(service: service)
        let first = GitChange(path: "first.swift", indexState: .unmodified, workTreeState: .modified)
        let second = GitChange(path: "second.swift", indexState: .unmodified, workTreeState: .modified)

        viewModel.selectChange(first, staged: false)
        await waitUntil("first change diff request") {
            await service.hasChangeDiffRequest(path: first.path)
        }
        viewModel.selectChange(second, staged: false)
        XCTAssertEqual(viewModel.selectedChange, second)
        XCTAssertEqual(viewModel.diff, DiffContent(path: second.path, text: ""))
        await waitUntil("second change diff request") {
            await service.hasChangeDiffRequest(path: second.path)
        }

        await service.resolveChangeDiff(
            path: second.path,
            with: DiffContent(path: second.path, text: "newer successful diff")
        )
        await waitUntil("newer change diff applied") {
            viewModel.diff.text == "newer successful diff"
        }
        await service.resolveChangeDiff(
            path: first.path,
            with: DiffContent(path: first.path, text: "stale successful diff")
        )
        await drainTasks()

        XCTAssertEqual(viewModel.selectedChange, second)
        XCTAssertEqual(viewModel.diff, DiffContent(path: second.path, text: "newer successful diff"))
    }

    func testLatestChangeSelectionWinsWhenEarlierDiffFinishesLast() async {
        let service = ControllableGitService()
        let viewModel = makeViewModel(service: service)
        let first = GitChange(path: "first.swift", indexState: .unmodified, workTreeState: .modified)
        let second = GitChange(path: "second.swift", indexState: .unmodified, workTreeState: .modified)

        viewModel.selectChange(first, staged: false)
        await waitUntil("first change diff request") {
            await service.hasChangeDiffRequest(path: first.path)
        }
        viewModel.selectChange(second, staged: false)
        await waitUntil("second change diff request") {
            await service.hasChangeDiffRequest(path: second.path)
        }

        await service.resolveChangeDiff(
            path: second.path,
            with: DiffContent(path: second.path, text: "second diff")
        )
        await waitUntil("second change diff applied") {
            viewModel.diff.text == "second diff"
        }
        await service.failChangeDiff(path: first.path, with: .parseFailure("stale change error"))
        await drainTasks()

        XCTAssertEqual(viewModel.selectedChange, second)
        XCTAssertEqual(viewModel.diff, DiffContent(path: second.path, text: "second diff"))
        XCTAssertNil(viewModel.alert)
    }

    func testLatestCommitSelectionWinsWhenEarlierFileListFinishesLast() async {
        let service = ControllableGitService()
        let viewModel = makeViewModel(service: service)
        let firstCommit = commit(hash: "1111111", subject: "First")
        let secondCommit = commit(hash: "2222222", subject: "Second")
        let secondFile = GitCommitFile(path: "second.swift", oldPath: nil, status: .modified)

        viewModel.selectCommit(firstCommit)
        await waitUntil("first commit file request") {
            await service.hasCommitFilesRequest(hash: firstCommit.hash)
        }
        viewModel.selectCommit(secondCommit)
        await waitUntil("second commit file request") {
            await service.hasCommitFilesRequest(hash: secondCommit.hash)
        }

        await service.resolveCommitFiles(hash: secondCommit.hash, with: [secondFile])
        await waitUntil("second commit diff request") {
            await service.hasCommitDiffRequest(hash: secondCommit.hash, path: secondFile.path)
        }
        await service.resolveCommitDiff(
            hash: secondCommit.hash,
            path: secondFile.path,
            with: DiffContent(path: secondFile.path, text: "second commit diff")
        )
        await waitUntil("second commit diff applied") {
            viewModel.commitDiff.text == "second commit diff"
        }

        await service.failCommitFiles(hash: firstCommit.hash, with: .parseFailure("stale commit error"))
        await drainTasks()

        XCTAssertEqual(viewModel.selectedCommit, secondCommit)
        XCTAssertEqual(viewModel.commitFiles, [secondFile])
        XCTAssertEqual(viewModel.selectedCommitFile, secondFile)
        XCTAssertEqual(viewModel.commitDiff, DiffContent(path: secondFile.path, text: "second commit diff"))
        let staleDiffWasRequested = await service.hasCommitDiffRequest(hash: firstCommit.hash, path: "stale.swift")
        XCTAssertFalse(staleDiffWasRequested)
        XCTAssertNil(viewModel.alert)
    }

    func testLatestCommitFileSelectionWinsWhenDefaultDiffFinishesLast() async {
        let service = ControllableGitService()
        let viewModel = makeViewModel(service: service)
        let selectedCommit = commit(hash: "3333333", subject: "Files")
        let firstFile = GitCommitFile(path: "first.swift", oldPath: nil, status: .modified)
        let secondFile = GitCommitFile(path: "second.swift", oldPath: nil, status: .modified)

        viewModel.selectCommit(selectedCommit)
        await waitUntil("commit file request") {
            await service.hasCommitFilesRequest(hash: selectedCommit.hash)
        }
        await service.resolveCommitFiles(hash: selectedCommit.hash, with: [firstFile, secondFile])
        await waitUntil("default commit diff request") {
            await service.hasCommitDiffRequest(hash: selectedCommit.hash, path: firstFile.path)
        }

        viewModel.selectCommitFile(secondFile)
        await waitUntil("selected commit-file diff request") {
            await service.hasCommitDiffRequest(hash: selectedCommit.hash, path: secondFile.path)
        }
        await service.resolveCommitDiff(
            hash: selectedCommit.hash,
            path: secondFile.path,
            with: DiffContent(path: secondFile.path, text: "selected file diff")
        )
        await waitUntil("selected commit-file diff applied") {
            viewModel.commitDiff.text == "selected file diff"
        }
        await service.failCommitDiff(
            hash: selectedCommit.hash,
            path: firstFile.path,
            with: .parseFailure("stale commit-file error")
        )
        await drainTasks()

        XCTAssertEqual(viewModel.selectedCommitFile, secondFile)
        XCTAssertEqual(viewModel.commitDiff, DiffContent(path: secondFile.path, text: "selected file diff"))
        XCTAssertNil(viewModel.alert)
    }

    func testLatestStatusRefreshWinsWhenEarlierStatusFinishesLast() async {
        let service = ControllableGitService()
        let viewModel = makeViewModel(service: service)

        viewModel.refreshStatusOnly()
        await waitUntil("first status request") { await service.hasStatusRequest(1) }
        viewModel.refreshStatusOnly()
        await waitUntil("second status request") { await service.hasStatusRequest(2) }

        await service.resolveStatus(2, with: status(branch: "newer"))
        await waitUntil("newer status applied") { viewModel.status.branchName == "newer" }
        await service.failStatus(1, with: .parseFailure("stale status error"))
        await drainTasks()

        XCTAssertEqual(viewModel.status.branchName, "newer")
        XCTAssertNil(viewModel.alert)
    }

    func testLatestFullRefreshWinsWhenEarlierSnapshotFinishesLast() async {
        let service = ControllableGitService()
        await service.configureRepositoryResponses(
            identities: [
                GitIdentity(name: "Stale", email: "stale@example.com"),
                GitIdentity(name: "Newer", email: "newer@example.com")
            ],
            branches: [
                [GitBranch(name: "stale", isCurrent: true, upstream: nil, ahead: 0, behind: 0)],
                [GitBranch(name: "newer", isCurrent: true, upstream: nil, ahead: 0, behind: 0)]
            ],
            remotes: [[], []],
            histories: [[], []]
        )

        let viewModel = makeViewModel(service: service)
        viewModel.refresh()
        await waitUntil("first full-refresh requests") {
            let hasStatus = await service.hasStatusRequest(1)
            let metadataCallCount = await service.repositoryMetadataCallCount()
            return hasStatus && metadataCallCount >= 1
        }
        viewModel.refresh()
        await waitUntil("second full-refresh requests") {
            let hasStatus = await service.hasStatusRequest(2)
            let metadataCallCount = await service.repositoryMetadataCallCount()
            return hasStatus && metadataCallCount >= 2
        }

        await service.resolveStatus(2, with: status(branch: "newer"))
        await waitUntil("newer snapshot applied") {
            viewModel.status.branchName == "newer" && viewModel.identity.name == "Newer"
        }
        await service.failStatus(1, with: .parseFailure("stale full-refresh error"))
        await drainTasks()

        XCTAssertEqual(viewModel.status.branchName, "newer")
        XCTAssertEqual(viewModel.identity, GitIdentity(name: "Newer", email: "newer@example.com"))
        XCTAssertEqual(viewModel.branches.map(\.name), ["newer"])
        XCTAssertNil(viewModel.activityMessage)
        XCTAssertNil(viewModel.alert)
    }

    func testNewerStatusRefreshSupersedesStatusFromOlderFullRefresh() async {
        let service = ControllableGitService()
        let viewModel = makeViewModel(service: service)

        viewModel.refresh()
        await waitUntil("full-refresh status request") {
            let hasStatus = await service.hasStatusRequest(1)
            let metadataCallCount = await service.repositoryMetadataCallCount()
            return hasStatus && metadataCallCount >= 1
        }
        viewModel.refreshStatusOnly()
        await waitUntil("newer status-only request") { await service.hasStatusRequest(2) }

        await service.failStatus(1, with: .parseFailure("stale full-refresh status error"))
        await drainTasks()
        XCTAssertNotEqual(viewModel.status.branchName, "stale-full")
        XCTAssertNil(viewModel.alert)

        await service.resolveStatus(2, with: status(branch: "newer-status"))
        await waitUntil("newer status-only response applied") {
            viewModel.status.branchName == "newer-status"
        }
        XCTAssertEqual(viewModel.status.branchName, "newer-status")
    }

    func testOlderActivityCannotClearNewerActivityMessage() async {
        let service = ControllableGitService()
        let viewModel = makeViewModel(service: service)
        let baseURL = URL(fileURLWithPath: "/tmp/base")
        let comparisonURL = URL(fileURLWithPath: "/tmp/comparison")

        let olderTask = Task {
            await viewModel.compareWorktrees(baseURL: baseURL, comparisonURL: comparisonURL)
        }
        await waitUntil("comparison request") { await service.hasComparisonRequest() }
        XCTAssertEqual(viewModel.activityMessage, "Comparing worktrees")

        let newerTask = Task {
            await viewModel.diffBetweenWorktrees(baseURL: baseURL, comparisonURL: comparisonURL, file: nil)
        }
        await waitUntil("worktree diff request") { await service.hasWorktreeDiffRequest() }
        XCTAssertEqual(viewModel.activityMessage, "Loading diff")

        await service.resolveComparison(
            with: WorktreeComparison(
                baseURL: baseURL,
                comparisonURL: comparisonURL,
                files: [],
                diff: DiffContent(path: "", text: "")
            )
        )
        _ = await olderTask.value
        XCTAssertEqual(viewModel.activityMessage, "Loading diff")

        await service.resolveWorktreeDiff(with: DiffContent(path: "", text: "worktree diff"))
        _ = await newerTask.value
        XCTAssertNil(viewModel.activityMessage)
    }

    func testFullRefreshCommandFailurePreservesRawGitDiagnostics() async {
        let service = ControllableGitService()
        let viewModel = makeViewModel(service: service)
        let result = GitCommandResult(
            command: ["git", "status"],
            workingDirectory: viewModel.repository.url,
            exitCode: 128,
            standardOutput: "",
            standardError: "fatal: test failure"
        )

        viewModel.refresh()
        await waitUntil("full-refresh status request") { await service.hasStatusRequest(1) }
        await service.failStatus(1, with: GitError.commandFailed(result))
        await waitUntil("full-refresh alert") { viewModel.alert != nil }

        XCTAssertEqual(viewModel.rawGitOutput, "fatal: test failure")
        XCTAssertEqual(viewModel.alert?.rawOutput, "fatal: test failure")
        XCTAssertNil(viewModel.activityMessage)
    }

    private func makeViewModel(service: ControllableGitService) -> RepositoryViewModel {
        RepositoryViewModel(
            repository: Repository(url: URL(fileURLWithPath: "/tmp/porcelain-concurrency-tests")),
            gitService: service
        )
    }

    private func commit(hash: String, subject: String) -> GitCommit {
        GitCommit(
            hash: hash,
            shortHash: hash,
            authorName: "Test",
            authorEmail: "test@example.com",
            date: nil,
            subject: subject
        )
    }

    private func status(branch: String) -> GitStatus {
        GitStatus(
            branchName: branch,
            upstreamName: nil,
            ahead: 0,
            behind: 0,
            detachedHead: nil,
            changes: []
        )
    }

    private func waitUntil(
        _ description: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: () async -> Bool
    ) async {
        for _ in 0..<2_000 {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }

    private func drainTasks() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
}
