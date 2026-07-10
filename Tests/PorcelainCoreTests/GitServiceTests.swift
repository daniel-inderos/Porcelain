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

    func testBranchNameValidationAcceptsGitCompatibleNames() throws {
        let validNames = [
            "main",
            "feature/worktree",
            "release/v1.2.3",
            "foo@bar",
            "foo#bar",
            "foo./bar",
            "refs/heads/main"
        ]

        for name in validNames {
            XCTAssertEqual(try GitRefNameValidator.validateBranchName(name), name)
        }
        XCTAssertEqual(try GitRefNameValidator.validateBranchName("  feature/worktree\n"), "feature/worktree")
    }

    func testBranchNameValidationRejectsInvalidRefSyntax() throws {
        let invalidNames = [
            "",
            "   ",
            "bad.lock",
            "feature/bad.lock",
            "feature..work",
            "-feature",
            "feature with space",
            "@",
            "HEAD",
            "feature/",
            "feature.",
            "/feature",
            "feature//work",
            "feature/.hidden",
            "feature@{upstream",
            "feature~work",
            "feature^work",
            "feature:work",
            "feature?work",
            "feature*work",
            "feature[work",
            "feature\\work",
            "feature\twork",
            "feature\u{7F}work",
            "feature\u{0}work"
        ]

        for name in invalidNames {
            do {
                _ = try GitRefNameValidator.validateBranchName(name)
                XCTFail("Expected \(name.debugDescription) to be rejected")
            } catch let error as GitError {
                XCTAssertEqual(error.errorDescription, "Enter a valid branch name.")
            } catch {
                XCTFail("Unexpected error for \(name.debugDescription): \(error)")
            }
        }
    }

    func testBranchAndWorktreeOperationsValidateBranchNamesBeforeRunningGit() async {
        let service = GitService(executableURL: URL(fileURLWithPath: "/porcelain/missing-git"))
        let repositoryURL = URL(fileURLWithPath: "/tmp/porcelain-repository")
        let worktreeURL = URL(fileURLWithPath: "/tmp/porcelain-worktree", isDirectory: true)
        let invalidName = "feature..invalid"

        await assertInvalidBranchNameRejected {
            try await service.createBranch(named: invalidName, checkout: false, in: repositoryURL)
        }
        await assertInvalidBranchNameRejected {
            try await service.createBranch(named: invalidName, checkout: true, in: repositoryURL)
        }
        await assertInvalidBranchNameRejected {
            try await service.checkoutBranch(named: invalidName, in: repositoryURL)
        }
        await assertInvalidBranchNameRejected {
            try await service.renameBranch(from: nil, to: invalidName, in: repositoryURL)
        }
        await assertInvalidBranchNameRejected {
            try await service.renameBranch(from: invalidName, to: "valid", in: repositoryURL)
        }
        await assertInvalidBranchNameRejected {
            try await service.deleteBranch(named: invalidName, in: repositoryURL)
        }
        await assertInvalidBranchNameRejected {
            try await service.mergeBranch(named: invalidName, in: repositoryURL)
        }
        await assertInvalidBranchNameRejected {
            try await service.push(in: repositoryURL, setUpstreamBranch: invalidName)
        }
        await assertInvalidBranchNameRejected {
            try await service.addWorktree(at: worktreeURL, branch: invalidName, createBranch: true, in: repositoryURL)
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

    func testCompareWorktreesIncludesVisibleWorkingTreeChangesAndExcludesGitMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let worktreeURL = directory.appendingPathComponent("feature-worktree", isDirectory: true)
        let service = GitService()
        let repository = try await service.initializeRepository(at: repositoryURL)

        try runGit(["branch", "-M", "main"], in: repository.url)
        try runGit(["config", "user.name", "Porcelain Tests"], in: repository.url)
        try runGit(["config", "user.email", "tests@example.com"], in: repository.url)

        try "ignored.log\n".write(to: repository.url.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "renamed content\n".write(to: repository.url.appendingPathComponent("old-name.txt"), atomically: true, encoding: .utf8)
        try "original\n".write(to: repository.url.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "tracked\n".write(to: repository.url.appendingPathComponent("deleted-in-feature.txt"), atomically: true, encoding: .utf8)
        _ = try await service.stage(paths: [".gitignore", "old-name.txt", "shared.txt", "deleted-in-feature.txt"], in: repository.url)
        _ = try await service.commit(summary: "Initial commit", description: "", author: nil, amend: false, in: repository.url)

        _ = try await service.addWorktree(at: worktreeURL, branch: "feature/worktree", createBranch: true, in: repository.url)

        try "current worktree\n".write(to: repository.url.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "current only\n".write(to: repository.url.appendingPathComponent("current-only.txt"), atomically: true, encoding: .utf8)
        try "ignored current\n".write(to: repository.url.appendingPathComponent("ignored.log"), atomically: true, encoding: .utf8)

        try "feature worktree\n".write(to: worktreeURL.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
        try "feature only\n".write(to: worktreeURL.appendingPathComponent("feature-only.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.moveItem(
            at: worktreeURL.appendingPathComponent("old-name.txt"),
            to: worktreeURL.appendingPathComponent("new-name.txt")
        )
        try "ignored feature\n".write(to: worktreeURL.appendingPathComponent("ignored.log"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: worktreeURL.appendingPathComponent("deleted-in-feature.txt"))

        let comparison = try await service.compareWorktrees(baseURL: repository.url, comparisonURL: worktreeURL)
        let filesByPath = Dictionary(uniqueKeysWithValues: comparison.files.map { ($0.path, $0.status) })

        XCTAssertEqual(filesByPath["shared.txt"], .modified)
        XCTAssertEqual(filesByPath["feature-only.txt"], .added)
        XCTAssertEqual(filesByPath["new-name.txt"], .renamed)
        XCTAssertEqual(filesByPath["current-only.txt"], .deleted)
        XCTAssertEqual(filesByPath["deleted-in-feature.txt"], .deleted)
        XCTAssertNil(filesByPath["ignored.log"])
        XCTAssertFalse(comparison.diff.text.contains(".git/"))
        XCTAssertFalse(comparison.diff.text.contains("ignored.log"))
        XCTAssertTrue(comparison.diff.text.contains("-current worktree"))
        XCTAssertTrue(comparison.diff.text.contains("+feature worktree"))
        XCTAssertTrue(comparison.diff.text.contains("+feature only"))
        XCTAssertTrue(comparison.diff.text.contains("-current only"))

        let sharedDiff = try await service.diffBetweenWorktrees(
            baseURL: repository.url,
            comparisonURL: worktreeURL,
            file: WorktreeComparisonFile(path: "shared.txt", status: .modified)
        )
        XCTAssertEqual(sharedDiff.path, "shared.txt")
        XCTAssertTrue(sharedDiff.text.contains("-current worktree"))
        XCTAssertTrue(sharedDiff.text.contains("+feature worktree"))
        XCTAssertFalse(sharedDiff.text.contains("feature-only.txt"))

        let renamedFile = try XCTUnwrap(comparison.files.first { $0.path == "new-name.txt" })
        XCTAssertEqual(renamedFile.oldPath, "old-name.txt")
        let renamedDiff = try await service.diffBetweenWorktrees(
            baseURL: repository.url,
            comparisonURL: worktreeURL,
            file: renamedFile
        )
        XCTAssertEqual(renamedDiff.path, "new-name.txt")
        XCTAssertTrue(renamedDiff.text.contains("rename from base/old-name.txt"))
        XCTAssertTrue(renamedDiff.text.contains("rename to comparison/new-name.txt"))
        XCTAssertFalse(renamedDiff.text.contains("new file mode"))
    }

    func testCompareWorktreesSkipsUnchangedLargeFilesAndLimitsPerFileSnapshots() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let worktreeURL = directory.appendingPathComponent("feature-worktree", isDirectory: true)
        let recording = SnapshotCopyRecording()
        let service = GitService(fileManager: RecordingFileManager(recording: recording))
        let repository = try await service.initializeRepository(at: repositoryURL)
        try configureTestRepository(repository.url)

        let largeFileName = "unchanged-large.bin"
        try Data(repeating: 0x5A, count: 4 * 1_024 * 1_024).write(
            to: repository.url.appendingPathComponent(largeFileName)
        )
        try "before\n".write(
            to: repository.url.appendingPathComponent("changed.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await service.stage(paths: [largeFileName, "changed.txt"], in: repository.url)
        _ = try await service.commit(summary: "Initial commit", description: "", author: nil, amend: false, in: repository.url)
        _ = try await service.addWorktree(at: worktreeURL, branch: "feature/worktree", createBranch: true, in: repository.url)

        try "after\n".write(
            to: worktreeURL.appendingPathComponent("changed.txt"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: worktreeURL.appendingPathComponent(largeFileName).path
        )

        recording.reset()
        let comparison = try await service.compareWorktrees(baseURL: repository.url, comparisonURL: worktreeURL)
        XCTAssertEqual(comparison.files.map(\.path), ["changed.txt"])
        XCTAssertFalse(recording.snapshotCopySourceNames.contains(largeFileName))
        XCTAssertEqual(recording.snapshotCopySourceNames.filter { $0 == "changed.txt" }.count, 2)
        assertComparisonDirectoriesWereRemoved(recording.comparisonDirectories)

        let changedFile = try XCTUnwrap(comparison.files.first)
        recording.reset()
        let diff = try await service.diffBetweenWorktrees(
            baseURL: repository.url,
            comparisonURL: worktreeURL,
            file: changedFile
        )
        XCTAssertTrue(diff.text.contains("-before"))
        XCTAssertTrue(diff.text.contains("+after"))
        XCTAssertEqual(Set(recording.snapshotCopySourceNames), ["changed.txt"])
        assertComparisonDirectoriesWereRemoved(recording.comparisonDirectories)
    }

    func testPerFileWorktreeDiffTreatsPathspecMagicSpacesAndUnicodeLiterally() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let worktreeURL = directory.appendingPathComponent("feature-worktree", isDirectory: true)
        let recording = SnapshotCopyRecording()
        let service = GitService(fileManager: RecordingFileManager(recording: recording))
        let repository = try await service.initializeRepository(at: repositoryURL)
        try configureTestRepository(repository.url)

        try "anchor\n".write(
            to: repository.url.appendingPathComponent("anchor.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await service.stage(paths: ["anchor.txt"], in: repository.url)
        _ = try await service.commit(summary: "Initial commit", description: "", author: nil, amend: false, in: repository.url)
        _ = try await service.addWorktree(at: worktreeURL, branch: "feature/worktree", createBranch: true, in: repository.url)

        let specialPath = ":(glob)literal [é].txt"
        try "before special\n".write(
            to: repository.url.appendingPathComponent(specialPath),
            atomically: true,
            encoding: .utf8
        )
        try "after special\n".write(
            to: worktreeURL.appendingPathComponent(specialPath),
            atomically: true,
            encoding: .utf8
        )

        let comparison = try await service.compareWorktrees(baseURL: repository.url, comparisonURL: worktreeURL)
        let file = try XCTUnwrap(comparison.files.first { $0.path == specialPath })
        recording.reset()
        let fileDiff = try await service.diffBetweenWorktrees(
            baseURL: repository.url,
            comparisonURL: worktreeURL,
            file: file
        )

        XCTAssertTrue(fileDiff.text.contains("-before special"))
        XCTAssertTrue(fileDiff.text.contains("+after special"))
        XCTAssertEqual(Set(recording.snapshotCopySourceNames), [specialPath])
        assertComparisonDirectoriesWereRemoved(recording.comparisonDirectories)
    }

    func testCompareWorktreesPreservesCopyDetectionFromChangedSources() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let worktreeURL = directory.appendingPathComponent("feature-worktree", isDirectory: true)
        let service = GitService()
        let repository = try await service.initializeRepository(at: repositoryURL)
        try configureTestRepository(repository.url)

        let originalContent = "copy source line one\ncopy source line two\n"
        try originalContent.write(
            to: repository.url.appendingPathComponent("source.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await service.stage(paths: ["source.txt"], in: repository.url)
        _ = try await service.commit(summary: "Initial commit", description: "", author: nil, amend: false, in: repository.url)
        _ = try await service.addWorktree(at: worktreeURL, branch: "feature/worktree", createBranch: true, in: repository.url)

        try originalContent.write(
            to: worktreeURL.appendingPathComponent("copy.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "changed source\n".write(
            to: worktreeURL.appendingPathComponent("source.txt"),
            atomically: true,
            encoding: .utf8
        )

        let comparison = try await service.compareWorktrees(baseURL: repository.url, comparisonURL: worktreeURL)
        let copiedFile = try XCTUnwrap(comparison.files.first { $0.path == "copy.txt" })
        XCTAssertEqual(copiedFile.status, .copied)
        XCTAssertEqual(copiedFile.oldPath, "source.txt")
        XCTAssertEqual(comparison.files.first { $0.path == "source.txt" }?.status, .modified)
    }

    func testCompareWorktreesDetectsExecutableBitOnlyChanges() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let worktreeURL = directory.appendingPathComponent("feature-worktree", isDirectory: true)
        let service = GitService()
        let repository = try await service.initializeRepository(at: repositoryURL)
        try configureTestRepository(repository.url)

        let scriptURL = repository.url.appendingPathComponent("script.sh")
        try "#!/bin/sh\necho porcelain\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scriptURL.path)
        _ = try await service.stage(paths: ["script.sh"], in: repository.url)
        _ = try await service.commit(summary: "Initial commit", description: "", author: nil, amend: false, in: repository.url)
        _ = try await service.addWorktree(at: worktreeURL, branch: "feature/worktree", createBranch: true, in: repository.url)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: worktreeURL.appendingPathComponent("script.sh").path
        )

        let comparison = try await service.compareWorktrees(baseURL: repository.url, comparisonURL: worktreeURL)
        let file = try XCTUnwrap(comparison.files.first { $0.path == "script.sh" })
        XCTAssertEqual(file.status, .modified)
        XCTAssertTrue(comparison.diff.text.contains("old mode 100644"))
        XCTAssertTrue(comparison.diff.text.contains("new mode 100755"))

        let fileDiff = try await service.diffBetweenWorktrees(
            baseURL: repository.url,
            comparisonURL: worktreeURL,
            file: file
        )
        XCTAssertTrue(fileDiff.text.contains("old mode 100644"))
        XCTAssertTrue(fileDiff.text.contains("new mode 100755"))
    }

    func testCompareWorktreesDetectsSymlinkTargetsAndTypeChangesWithoutFollowingLinks() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let worktreeURL = directory.appendingPathComponent("feature-worktree", isDirectory: true)
        let service = GitService()
        let repository = try await service.initializeRepository(at: repositoryURL)
        try configureTestRepository(repository.url)

        try FileManager.default.createSymbolicLink(
            atPath: repository.url.appendingPathComponent("dangling-link").path,
            withDestinationPath: "missing-one"
        )
        try FileManager.default.createDirectory(
            at: repository.url.appendingPathComponent("dir-one"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repository.url.appendingPathComponent("dir-two"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: repository.url.appendingPathComponent("directory-link").path,
            withDestinationPath: "dir-one"
        )
        try "regular\n".write(
            to: repository.url.appendingPathComponent("type-change"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await service.stage(
            paths: ["dangling-link", "directory-link", "type-change"],
            in: repository.url
        )
        _ = try await service.commit(summary: "Initial commit", description: "", author: nil, amend: false, in: repository.url)
        _ = try await service.addWorktree(at: worktreeURL, branch: "feature/worktree", createBranch: true, in: repository.url)

        try FileManager.default.createDirectory(
            at: worktreeURL.appendingPathComponent("dir-one"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: worktreeURL.appendingPathComponent("dir-two"),
            withIntermediateDirectories: true
        )
        for (path, target) in [("dangling-link", "missing-two"), ("directory-link", "dir-two")] {
            let linkURL = worktreeURL.appendingPathComponent(path)
            try FileManager.default.removeItem(at: linkURL)
            try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target)
        }
        let typeChangeURL = worktreeURL.appendingPathComponent("type-change")
        try FileManager.default.removeItem(at: typeChangeURL)
        try FileManager.default.createSymbolicLink(atPath: typeChangeURL.path, withDestinationPath: "missing-type-target")

        let comparison = try await service.compareWorktrees(baseURL: repository.url, comparisonURL: worktreeURL)
        let filesByPath = Dictionary(uniqueKeysWithValues: comparison.files.map { ($0.path, $0.status) })
        XCTAssertEqual(filesByPath["dangling-link"], .modified)
        XCTAssertEqual(filesByPath["directory-link"], .modified)
        XCTAssertEqual(filesByPath["type-change"], .typeChanged)
        XCTAssertTrue(comparison.diff.text.contains("-missing-one"))
        XCTAssertTrue(comparison.diff.text.contains("+missing-two"))
        XCTAssertTrue(comparison.diff.text.contains("-dir-one"))
        XCTAssertTrue(comparison.diff.text.contains("+dir-two"))

        let danglingFile = try XCTUnwrap(comparison.files.first { $0.path == "dangling-link" })
        let danglingDiff = try await service.diffBetweenWorktrees(
            baseURL: repository.url,
            comparisonURL: worktreeURL,
            file: danglingFile
        )
        XCTAssertTrue(danglingDiff.text.contains("-missing-one"))
        XCTAssertTrue(danglingDiff.text.contains("+missing-two"))
    }

    func testCompareWorktreesHonorsVisibilityPerSideAndCleansSnapshotsAfterFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let worktreeURL = directory.appendingPathComponent("feature-worktree", isDirectory: true)
        let recording = SnapshotCopyRecording()
        let service = GitService(fileManager: RecordingFileManager(recording: recording))
        let repository = try await service.initializeRepository(at: repositoryURL)
        try configureTestRepository(repository.url)

        try "\n".write(to: repository.url.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        _ = try await service.stage(paths: [".gitignore"], in: repository.url)
        _ = try await service.commit(summary: "Initial commit", description: "", author: nil, amend: false, in: repository.url)
        _ = try await service.addWorktree(at: worktreeURL, branch: "feature/worktree", createBranch: true, in: repository.url)

        try "comparison-visible.txt\n".write(
            to: repository.url.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "base-visible.txt\n".write(
            to: worktreeURL.appendingPathComponent(".gitignore"),
            atomically: true,
            encoding: .utf8
        )
        try "base visible\n".write(
            to: repository.url.appendingPathComponent("base-visible.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored comparison secret\n".write(
            to: worktreeURL.appendingPathComponent("base-visible.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "ignored base secret\n".write(
            to: repository.url.appendingPathComponent("comparison-visible.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "comparison visible\n".write(
            to: worktreeURL.appendingPathComponent("comparison-visible.txt"),
            atomically: true,
            encoding: .utf8
        )

        recording.reset()
        let comparison = try await service.compareWorktrees(baseURL: repository.url, comparisonURL: worktreeURL)
        let filesByPath = Dictionary(uniqueKeysWithValues: comparison.files.map { ($0.path, $0.status) })
        XCTAssertEqual(filesByPath["base-visible.txt"], .deleted)
        XCTAssertEqual(filesByPath["comparison-visible.txt"], .added)
        XCTAssertFalse(comparison.diff.text.contains("ignored comparison secret"))
        XCTAssertFalse(comparison.diff.text.contains("ignored base secret"))

        for path in ["base-visible.txt", "comparison-visible.txt"] {
            let file = try XCTUnwrap(comparison.files.first { $0.path == path })
            let fileDiff = try await service.diffBetweenWorktrees(
                baseURL: repository.url,
                comparisonURL: worktreeURL,
                file: file
            )
            XCTAssertFalse(fileDiff.text.contains("ignored comparison secret"))
            XCTAssertFalse(fileDiff.text.contains("ignored base secret"))
        }

        recording.reset()
        recording.failSnapshotCopies(named: "base-visible.txt")
        do {
            _ = try await service.compareWorktrees(baseURL: repository.url, comparisonURL: worktreeURL)
            XCTFail("Expected the injected snapshot copy failure")
        } catch {
            XCTAssertFalse(recording.comparisonDirectories.isEmpty)
            assertComparisonDirectoriesWereRemoved(recording.comparisonDirectories)
        }
    }

    func testLocalCommitHookDoesNotReceivePorcelainCredentials() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let keychainStore = KeychainStore(service: "PorcelainTests-\(UUID().uuidString)")
        try keychainStore.saveToken("local-hook-test-token")
        defer { try? keychainStore.deleteToken() }

        let service = GitService(keychainStore: keychainStore)
        let repository = try await service.initializeRepository(at: directory)
        try runGit(["config", "user.name", "Porcelain Tests"], in: repository.url)
        try runGit(["config", "user.email", "tests@example.com"], in: repository.url)
        try "content\n".write(
            to: repository.url.appendingPathComponent("credential-boundary.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await service.stage(paths: ["credential-boundary.txt"], in: repository.url)

        let hookURL = repository.url.appendingPathComponent(".git/hooks/pre-commit")
        let markerURL = repository.url.appendingPathComponent("hook-environment.txt")
        let hook = """
        #!/bin/sh
        if [ -n "${PORCELAIN_GITHUB_TOKEN+x}" ]; then printf "token-present\\n" >> hook-environment.txt; fi
        if [ -n "${PORCELAIN_FALLBACK_GIT_ASKPASS+x}" ]; then printf "fallback-present\\n" >> hook-environment.txt; fi
        case "${GIT_ASKPASS:-}" in
          */Porcelain/github-askpass.sh) printf "porcelain-askpass-present\\n" >> hook-environment.txt ;;
        esac
        exit 0
        """
        try hook.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hookURL.path)

        _ = try await service.commit(
            summary: "Credential boundary",
            description: "",
            author: nil,
            amend: false,
            in: repository.url
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    func testGitHubAskPassRejectsLookalikeHostsAndDelegatesOtherHosts() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fallbackURL = directory.appendingPathComponent("fallback-askpass.sh")
        try "#!/bin/sh\nprintf '%s\\n' fallback-ok\n".write(
            to: fallbackURL,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fallbackURL.path)

        let executableURL = directory.appendingPathComponent("fake-git.sh")
        let executable = """
        #!/bin/sh
        if [ "$2" = "ls-remote" ]; then
          [ "$4" = "--" ] || exit 8
          [ -z "${PORCELAIN_GITHUB_TOKEN+x}" ] || exit 9
          case "${GIT_ASKPASS:-}" in
            */Porcelain/github-askpass.sh) exit 9 ;;
          esac
          printf '%s\\n' "$5"
          exit 0
        fi
        helper="${GIT_ASKPASS:-}"
        [ -x "$helper" ] || exit 10
        [ -n "${PORCELAIN_GITHUB_TOKEN:-}" ] || exit 11
        username=$("$helper" "Username for 'https://github.com/example/repository':")
        [ "$username" = "x-access-token" ] || exit 12
        password=$("$helper" "Password for 'https://x-access-token@github.com/example/repository':")
        [ "$password" = "$PORCELAIN_GITHUB_TOKEN" ] || exit 13
        not_github=$("$helper" "Password for 'https://notgithub.com/example/repository':")
        [ -z "$not_github" ] || exit 14
        suffix_attack=$("$helper" "Password for 'https://github.com.evil/example/repository':")
        [ -z "$suffix_attack" ] || exit 15
        delegated=$(PORCELAIN_FALLBACK_GIT_ASKPASS="$(dirname "$0")/fallback-askpass.sh" "$helper" "Password for 'https://gitlab.com/example/repository':")
        [ "$delegated" = "fallback-ok" ] || exit 16
        printf '%s\\n' askpass-boundary-ok
        """
        try executable.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

        let keychainStore = KeychainStore(service: "PorcelainTests-\(UUID().uuidString)")
        let dummyToken = "askpass-test-token"
        try keychainStore.saveToken(dummyToken)
        defer { try? keychainStore.deleteToken() }

        let service = GitService(executableURL: executableURL, keychainStore: keychainStore)
        let result = try await service.cloneRepository(
            from: "https://github.com/example/repository.git",
            to: directory.appendingPathComponent("clone")
        )

        XCTAssertEqual(result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "askpass-boundary-ok")
        XCTAssertFalse(result.combinedOutput.contains(dummyToken))
        let helperDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Porcelain")
        let helperURL = helperDirectory.appendingPathComponent("github-askpass.sh")
        let directoryMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: helperDirectory.path)[.posixPermissions] as? NSNumber
        ).intValue
        let helperMode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: helperURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(directoryMode & 0o777, 0o700)
        XCTAssertEqual(helperMode & 0o777, 0o700)
    }

    func testCloneScopesAuthenticationAfterURLRewriteAndProtectsRemoteOperand() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let configURL = directory.appendingPathComponent("rewrite.gitconfig")
        try """
        [url "envprobe::"]
            insteadOf = https://github.com/
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let executableURL = directory.appendingPathComponent("clone-probe.sh")
        let executable = """
        #!/bin/sh
        [ "$1" = "git" ] || exit 20
        shift
        case "$1" in
          ls-remote)
            [ -z "${PORCELAIN_GITHUB_TOKEN+x}" ] || exit 21
            case "${GIT_ASKPASS:-}" in
              */Porcelain/github-askpass.sh) exit 22 ;;
            esac
            GIT_CONFIG_GLOBAL="$(dirname "$0")/rewrite.gitconfig" exec /usr/bin/git "$@"
            ;;
          clone)
            [ "$3" = "--" ] || exit 23
            [ -z "${PORCELAIN_GITHUB_TOKEN+x}" ] || exit 24
            case "${GIT_ASKPASS:-}" in
              */Porcelain/github-askpass.sh) exit 25 ;;
            esac
            printf '%s\\n' clone-scope-ok
            ;;
          *) exit 26 ;;
        esac
        """
        try executable.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

        let keychainStore = KeychainStore(service: "PorcelainTests-\(UUID().uuidString)")
        let dummyToken = "clone-scope-test-token"
        try keychainStore.saveToken(dummyToken)
        defer { try? keychainStore.deleteToken() }
        let service = GitService(executableURL: executableURL, keychainStore: keychainStore)

        let rewritten = try await service.cloneRepository(
            from: "https://github.com/example/repository.git",
            to: directory.appendingPathComponent("rewritten-clone")
        )
        let optionLike = try await service.cloneRepository(
            from: "-option-like-remote",
            to: directory.appendingPathComponent("option-clone")
        )

        XCTAssertEqual(rewritten.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "clone-scope-ok")
        XCTAssertEqual(optionLike.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines), "clone-scope-ok")
        XCTAssertFalse(rewritten.combinedOutput.contains(dummyToken))
        XCTAssertFalse(optionLike.combinedOutput.contains(dummyToken))
    }

    func testCommitHookOutputIsBoundedAndReportsTruncation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let stdoutLimit = 4_096
        let stderrLimit = 3_072
        let service = GitService(
            maxCommandOutputBytes: stdoutLimit,
            maxStandardErrorBytes: stderrLimit
        )
        let repository = try await service.initializeRepository(at: directory)
        try runGit(["config", "user.name", "Porcelain Tests"], in: repository.url)
        try runGit(["config", "user.email", "tests@example.com"], in: repository.url)
        try "content\n".write(
            to: repository.url.appendingPathComponent("noisy-hook.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await service.stage(paths: ["noisy-hook.txt"], in: repository.url)

        let hookURL = repository.url.appendingPathComponent(".git/hooks/pre-commit")
        let hook = """
        #!/bin/sh
        printf '%s' '\(String(repeating: "o", count: 100_000))'
        printf '%s' '\(String(repeating: "e", count: 100_000))' >&2
        exit 1
        """
        try hook.write(to: hookURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hookURL.path)

        do {
            _ = try await service.commit(
                summary: "Noisy hook",
                description: "",
                author: nil,
                amend: false,
                in: repository.url
            )
            XCTFail("Expected the hook to reject the commit")
        } catch GitError.commandFailed(let result) {
            XCTAssertTrue(result.standardError.contains("[Porcelain: standard error truncated]"))
            XCTAssertLessThan(result.standardOutput.utf8.count, stdoutLimit + 100)
            XCTAssertLessThan(result.standardError.utf8.count, stderrLimit + 100)
        }
    }

    func testOrdinaryCommandStdoutIsBoundedAndInvalidUTF8IsPreserved() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableURL = directory.appendingPathComponent("noisy-git.sh")
        let executable = """
        #!/bin/sh
        printf '\\377'
        printf '%s' '\(String(repeating: "x", count: 100_000))'
        """
        try executable.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

        let outputLimit = 4_096
        let service = GitService(
            executableURL: executableURL,
            maxCommandOutputBytes: outputLimit
        )
        let output = try await service.validateGitInstalled()

        XCTAssertTrue(output.contains("�"))
        XCTAssertTrue(output.contains("[Porcelain: standard output truncated]"))
        XCTAssertLessThan(output.utf8.count, outputLimit + 100)
    }

    func testParserCriticalStatusOutputBypassesOrdinaryCommandCap() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try runGit(["init", "-q"], in: directory)
        let service = GitService(maxCommandOutputBytes: 1)
        try "one\n".write(
            to: directory.appendingPathComponent("first-untracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "two\n".write(
            to: directory.appendingPathComponent("second-untracked.txt"),
            atomically: true,
            encoding: .utf8
        )

        let status = try await service.status(in: directory)

        XCTAssertEqual(Set(status.changes.map(\.path)), ["first-untracked.txt", "second-untracked.txt"])
    }

    func testNetworkAuthenticationIsScopedPerResolvedRemote() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: repositoryURL)
        try runGit(["symbolic-ref", "HEAD", "refs/heads/main"], in: repositoryURL)
        try runGit(["remote", "add", "github", "https://github.com/example/repository.git"], in: repositoryURL)
        try runGit(["remote", "add", "gitlab", "https://gitlab.com/example/repository.git"], in: repositoryURL)
        try runGit(["remote", "add", "lookalike", "https://github.com.evil/example/repository.git"], in: repositoryURL)
        try runGit(["remote", "add", "mixed", "https://github.com/example/mixed.git"], in: repositoryURL)
        try runGit(["remote", "set-url", "--add", "--push", "mixed", "https://github.com/example/mixed.git"], in: repositoryURL)
        try runGit(["remote", "set-url", "--add", "--push", "mixed", "https://gitlab.com/example/mixed.git"], in: repositoryURL)
        try runGit(["remote", "add", "origin", "https://github.com/example/origin.git"], in: repositoryURL)
        try runGit(["config", "remote.-option.url", "https://gitlab.com/example/option.git"], in: repositoryURL)
        try runGit(["config", "remote.skipped-current.url", "https://github.com/example/skipped-current.git"], in: repositoryURL)
        try runGit(["config", "remote.skipped-current.skipFetchAll", "true"], in: repositoryURL)
        try runGit(["config", "remote.skipped-deprecated.url", "https://github.com/example/skipped-deprecated.git"], in: repositoryURL)
        try runGit(["config", "remote.skipped-deprecated.skipDefaultUpdate", "true"], in: repositoryURL)
        try runGit(["config", "remote.precedence-fetched.url", "https://gitlab.com/example/precedence-fetched.git"], in: repositoryURL)
        try runGit(["config", "remote.precedence-fetched.skipFetchAll", "true"], in: repositoryURL)
        try runGit(["config", "remote.precedence-fetched.skipDefaultUpdate", "false"], in: repositoryURL)
        try runGit(["config", "remote.precedence-skipped.url", "https://github.com/example/precedence-skipped.git"], in: repositoryURL)
        try runGit(["config", "remote.precedence-skipped.skipDefaultUpdate", "false"], in: repositoryURL)
        try runGit(["config", "remote.precedence-skipped.skipFetchAll", "true"], in: repositoryURL)

        let executableURL = directory.appendingPathComponent("git-environment-probe.sh")
        let executable = """
        #!/bin/sh
        [ "$1" = "git" ] || exit 90
        shift
        command="$1"
        case "$command" in
          fetch|pull|push)
            auth=noauth
            [ -n "${PORCELAIN_GITHUB_TOKEN+x}" ] && auth=auth
            helper=nohelper
            case "${GIT_ASKPASS:-}" in
              */Porcelain/github-askpass.sh) helper=helper ;;
            esac
            separator=missing-separator
            last=""
            for argument in "$@"; do
              [ "$argument" = "--" ] && separator=separator
              last="$argument"
            done
            case "$command:$last:$separator" in
              fetch:-*:missing-separator) exit 91 ;;
            esac
            printf '%s|%s|%s|%s|%s\\n' "$command" "$last" "$auth" "$helper" "$separator" >> "$(dirname "$0")/network-environment.log"
            if [ "$command" = "fetch" ]; then
              printf '%s' '\(String(repeating: "o", count: 2_000))'
              printf '%s' '\(String(repeating: "e", count: 2_000))' >&2
            fi
            exit 0
            ;;
          *) exec /usr/bin/git "$@" ;;
        esac
        """
        try executable.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)

        let keychainStore = KeychainStore(service: "PorcelainTests-\(UUID().uuidString)")
        let dummyToken = "remote-scope-test-token"
        try keychainStore.saveToken(dummyToken)
        defer { try? keychainStore.deleteToken() }
        let service = GitService(
            executableURL: executableURL,
            keychainStore: keychainStore,
            maxCommandOutputBytes: 1_024,
            maxStandardErrorBytes: 768
        )

        let fetchResult = try await service.fetch(in: repositoryURL)
        XCTAssertTrue(fetchResult.standardOutput.contains("[Porcelain: standard output truncated]"))
        XCTAssertTrue(fetchResult.standardError.contains("[Porcelain: standard error truncated]"))
        XCTAssertLessThan(fetchResult.standardOutput.utf8.count, 1_124)
        XCTAssertLessThan(fetchResult.standardError.utf8.count, 868)

        try runGit(["config", "branch.main.remote", "github"], in: repositoryURL)
        try runGit(["config", "branch.main.merge", "refs/heads/main"], in: repositoryURL)
        _ = try await service.pull(in: repositoryURL)
        try runGit(["config", "branch.main.remote", "gitlab"], in: repositoryURL)
        _ = try await service.pull(in: repositoryURL)

        try runGit(["config", "branch.main.pushRemote", "gitlab"], in: repositoryURL)
        try runGit(["config", "remote.pushDefault", "github"], in: repositoryURL)
        _ = try await service.push(in: repositoryURL, setUpstreamBranch: nil)
        try runGit(["config", "branch.main.pushRemote", "mixed"], in: repositoryURL)
        _ = try await service.push(in: repositoryURL, setUpstreamBranch: nil)
        try runGit(["config", "--unset", "branch.main.pushRemote"], in: repositoryURL)
        _ = try await service.push(in: repositoryURL, setUpstreamBranch: nil)
        try runGit(["config", "--unset", "remote.pushDefault"], in: repositoryURL)
        try runGit(["config", "branch.main.remote", "lookalike"], in: repositoryURL)
        _ = try await service.push(in: repositoryURL, setUpstreamBranch: nil)
        try runGit(["config", "--unset", "branch.main.remote"], in: repositoryURL)
        _ = try await service.push(in: repositoryURL, setUpstreamBranch: nil)
        _ = try await service.push(in: repositoryURL, setUpstreamBranch: "main")

        let soleRemoteRepository = directory.appendingPathComponent("sole-remote-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: soleRemoteRepository, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: soleRemoteRepository)
        try runGit(["symbolic-ref", "HEAD", "refs/heads/main"], in: soleRemoteRepository)
        try runGit(["remote", "add", "github", "https://github.com/example/sole.git"], in: soleRemoteRepository)
        _ = try await service.pull(in: soleRemoteRepository)
        _ = try await service.push(in: soleRemoteRepository, setUpstreamBranch: nil)

        let ambiguousRepository = directory.appendingPathComponent("ambiguous-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: ambiguousRepository, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: ambiguousRepository)
        try runGit(["symbolic-ref", "HEAD", "refs/heads/main"], in: ambiguousRepository)
        try runGit(["remote", "add", "github", "https://github.com/example/ambiguous.git"], in: ambiguousRepository)
        try runGit(["remote", "add", "gitlab", "https://gitlab.com/example/ambiguous.git"], in: ambiguousRepository)
        _ = try await service.pull(in: ambiguousRepository)
        _ = try await service.push(in: ambiguousRepository, setUpstreamBranch: nil)

        let logURL = directory.appendingPathComponent("network-environment.log")
        let log = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(log.contains("fetch|github|auth|helper|separator"))
        XCTAssertTrue(log.contains("fetch|gitlab|noauth|nohelper|separator"))
        XCTAssertTrue(log.contains("fetch|lookalike|noauth|nohelper|separator"))
        XCTAssertTrue(log.contains("fetch|mixed|auth|helper|separator"))
        XCTAssertTrue(log.contains("fetch|-option|noauth|nohelper|separator"))
        XCTAssertTrue(log.contains("fetch|precedence-fetched|noauth|nohelper|separator"))
        XCTAssertFalse(log.contains("fetch|skipped-current"))
        XCTAssertFalse(log.contains("fetch|skipped-deprecated"))
        XCTAssertFalse(log.contains("fetch|precedence-skipped"))
        XCTAssertEqual(log.components(separatedBy: "pull|--progress|auth|helper|missing-separator").count - 1, 2)
        XCTAssertEqual(log.components(separatedBy: "pull|--progress|noauth|nohelper|missing-separator").count - 1, 2)
        XCTAssertEqual(log.components(separatedBy: "push|--progress|auth|helper|missing-separator").count - 1, 4)
        XCTAssertEqual(log.components(separatedBy: "push|--progress|noauth|nohelper|missing-separator").count - 1, 4)
        XCTAssertFalse(log.contains(dummyToken))
    }

    func testFetchTreatsOptionLikeConfiguredRemoteAsAnOperand() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let remoteURL = directory.appendingPathComponent("remote.git", isDirectory: true)
        let secondRemoteURL = directory.appendingPathComponent("second-remote.git", isDirectory: true)
        try FileManager.default.createDirectory(at: repositoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRemoteURL, withIntermediateDirectories: true)
        try runGit(["init", "-q"], in: repositoryURL)
        try runGit(["init", "--bare", "-q"], in: remoteURL)
        try runGit(["init", "--bare", "-q"], in: secondRemoteURL)
        try runGit(["config", "remote.-option.url", remoteURL.path], in: repositoryURL)
        try runGit(["remote", "add", "second", secondRemoteURL.path], in: repositoryURL)
        try runGit(["config", "user.name", "Porcelain Tests"], in: repositoryURL)
        try runGit(["config", "user.email", "tests@example.com"], in: repositoryURL)
        try "content\n".write(
            to: repositoryURL.appendingPathComponent("tracked.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "tracked.txt"], in: repositoryURL)
        try runGit(["commit", "-q", "-m", "Initial"], in: repositoryURL)
        try runGit(["push", "-q", "--", "-option", "HEAD:refs/heads/main"], in: repositoryURL)
        try runGit(["push", "-q", "second", "HEAD:refs/heads/main"], in: repositoryURL)
        try runGit(["symbolic-ref", "HEAD", "refs/heads/main"], in: remoteURL)
        try runGit(["symbolic-ref", "HEAD", "refs/heads/main"], in: secondRemoteURL)

        let service = GitService()
        let result = try await service.fetch(in: repositoryURL)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.command, ["git", "fetch", "--all", "--prune", "--progress"])
        let fetchHead = try String(
            contentsOf: repositoryURL.appendingPathComponent(".git/FETCH_HEAD"),
            encoding: .utf8
        )
        let fetchHeadLines = fetchHead.split(whereSeparator: { $0.isNewline })
        XCTAssertEqual(fetchHeadLines.count, 2)
        XCTAssertTrue(fetchHead.contains(remoteURL.deletingPathExtension().lastPathComponent))
        XCTAssertTrue(fetchHead.contains(secondRemoteURL.deletingPathExtension().lastPathComponent))
    }

    func testPullWithoutUpstreamPreservesCurrentCommit() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let repositoryURL = directory.appendingPathComponent("repository", isDirectory: true)
        let keychainStore = KeychainStore(service: "PorcelainTests-\(UUID().uuidString)")
        defer { try? keychainStore.deleteToken() }
        let service = GitService(keychainStore: keychainStore)
        let repository = try await service.initializeRepository(at: repositoryURL)
        try runGit(["config", "user.name", "Porcelain Tests"], in: repository.url)
        try runGit(["config", "user.email", "tests@example.com"], in: repository.url)
        try "initial\n".write(
            to: repository.url.appendingPathComponent("pull.txt"),
            atomically: true,
            encoding: .utf8
        )
        _ = try await service.stage(paths: ["pull.txt"], in: repository.url)
        _ = try await service.commit(summary: "Initial", description: "", author: nil, amend: false, in: repository.url)
        let historyBefore = try await service.history(in: repository.url, limit: 1)
        let headBefore = try XCTUnwrap(historyBefore.first?.hash)

        do {
            _ = try await service.pull(in: repository.url)
            XCTFail("Expected pull without an upstream to fail")
        } catch let error as GitError {
            XCTAssertNotNil(error.errorDescription)
        }

        let historyAfter = try await service.history(in: repository.url, limit: 1)
        let headAfter = try XCTUnwrap(historyAfter.first?.hash)
        XCTAssertEqual(headAfter, headBefore)
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

        let captureLimit = 4_096
        let service = GitService(maxDiffBytes: captureLimit)
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
        XCTAssertTrue(diff.isLarge)
        XCTAssertTrue(diff.didTruncate)
        XCTAssertLessThanOrEqual(diff.text.utf8.count, captureLimit)
    }

    private func configureTestRepository(_ repositoryURL: URL) throws {
        try runGit(["branch", "-M", "main"], in: repositoryURL)
        try runGit(["config", "user.name", "Porcelain Tests"], in: repositoryURL)
        try runGit(["config", "user.email", "tests@example.com"], in: repositoryURL)
    }

    private func assertComparisonDirectoriesWereRemoved(
        _ directories: [URL],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(directories.isEmpty, file: file, line: line)
        for directory in directories {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), file: file, line: line)
        }
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

    private func assertInvalidBranchNameRejected(
        _ operation: () async throws -> GitCommandResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected invalid branch name to be rejected", file: file, line: line)
        } catch let error as GitError {
            XCTAssertEqual(error.errorDescription, "Enter a valid branch name.", file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private final class SnapshotCopyRecording: @unchecked Sendable {
    private let recordingLock = NSLock()
    private var recordedSnapshotCopySourceNames: [String] = []
    private var recordedComparisonDirectories: Set<URL> = []
    private var failingSnapshotCopyName: String?

    var snapshotCopySourceNames: [String] {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        return recordedSnapshotCopySourceNames
    }

    var comparisonDirectories: [URL] {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        return recordedComparisonDirectories.sorted { $0.path < $1.path }
    }

    func reset() {
        recordingLock.lock()
        recordedSnapshotCopySourceNames = []
        recordedComparisonDirectories = []
        failingSnapshotCopyName = nil
        recordingLock.unlock()
    }

    func failSnapshotCopies(named name: String) {
        recordingLock.lock()
        failingSnapshotCopyName = name
        recordingLock.unlock()
    }

    func recordComparisonDirectory(_ url: URL) {
        recordingLock.lock()
        recordedComparisonDirectories.insert(url)
        recordingLock.unlock()
    }

    func recordSnapshotCopy(named name: String) -> Bool {
        recordingLock.lock()
        defer { recordingLock.unlock() }
        recordedSnapshotCopySourceNames.append(name)
        return failingSnapshotCopyName == name
    }
}

private final class RecordingFileManager: FileManager, @unchecked Sendable {
    private let recording: SnapshotCopyRecording

    init(recording: SnapshotCopyRecording) {
        self.recording = recording
        super.init()
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if let comparisonDirectory = Self.comparisonDirectory(containing: url) {
            recording.recordComparisonDirectory(comparisonDirectory)
        }
        try super.createDirectory(
            at: url,
            withIntermediateDirectories: createIntermediates,
            attributes: attributes
        )
    }

    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        guard Self.comparisonDirectory(containing: dstURL) != nil else {
            try super.copyItem(at: srcURL, to: dstURL)
            return
        }

        if recording.recordSnapshotCopy(named: srcURL.lastPathComponent) {
            throw CocoaError(.fileWriteUnknown)
        }
        try super.copyItem(at: srcURL, to: dstURL)
    }

    private static func comparisonDirectory(containing url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if candidate.lastPathComponent.hasPrefix("PorcelainWorktreeCompare-") {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate {
                return nil
            }
            candidate = parent
        }
        return nil
    }
}
