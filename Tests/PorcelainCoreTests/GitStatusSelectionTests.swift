import XCTest
@testable import PorcelainCore

final class GitStatusSelectionTests: XCTestCase {
    func testPreservingSelectionMatchesSamePathWhenStateChangesToStagedOnly() throws {
        let selected = GitChange(path: "Sources/App.swift", indexState: .unmodified, workTreeState: .modified)
        let refreshed = GitChange(path: "Sources/App.swift", indexState: .modified, workTreeState: .unmodified)
        let status = makeStatus(changes: [refreshed])

        let selection = try XCTUnwrap(status.preservingSelection(for: selected, staged: false))

        XCTAssertEqual(selection.change, refreshed)
        XCTAssertTrue(selection.isStaged)
    }

    func testPreservingSelectionKeepsUnstagedPaneForPartiallyStagedChange() throws {
        let selected = GitChange(path: "Sources/App.swift", indexState: .modified, workTreeState: .modified)
        let status = makeStatus(changes: [selected])

        let selection = try XCTUnwrap(status.preservingSelection(for: selected, staged: false))

        XCTAssertEqual(selection.change, selected)
        XCTAssertFalse(selection.isStaged)
    }

    func testPreservingSelectionFallsBackToUnstagedWhenStagedStateDisappears() throws {
        let selected = GitChange(path: "Sources/App.swift", indexState: .modified, workTreeState: .unmodified)
        let refreshed = GitChange(path: "Sources/App.swift", indexState: .unmodified, workTreeState: .modified)
        let status = makeStatus(changes: [refreshed])

        let selection = try XCTUnwrap(status.preservingSelection(for: selected, staged: true))

        XCTAssertEqual(selection.change, refreshed)
        XCTAssertFalse(selection.isStaged)
    }

    func testPreservingSelectionReturnsNilWhenPathNoLongerExists() {
        let selected = GitChange(path: "Sources/App.swift", indexState: .modified, workTreeState: .unmodified)
        let status = makeStatus(changes: [
            GitChange(path: "Sources/Other.swift", indexState: .modified, workTreeState: .unmodified)
        ])

        XCTAssertNil(status.preservingSelection(for: selected, staged: true))
    }

    private func makeStatus(changes: [GitChange]) -> GitStatus {
        GitStatus(
            branchName: "main",
            upstreamName: nil,
            ahead: 0,
            behind: 0,
            detachedHead: nil,
            changes: changes
        )
    }
}
