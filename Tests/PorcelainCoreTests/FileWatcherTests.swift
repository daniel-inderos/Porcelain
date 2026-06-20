import XCTest
@testable import PorcelainCore

final class FileWatcherTests: XCTestCase {
    func testWatchedURLsMatchExactAndNestedChanges() {
        let main = URL(fileURLWithPath: "/tmp/project")
        let feature = URL(fileURLWithPath: "/tmp/project-feature")
        let changedURLs = [
            URL(fileURLWithPath: "/tmp/project"),
            URL(fileURLWithPath: "/tmp/project-feature/Sources/App.swift")
        ]

        let matches = FileWatchPathMatcher.watchedURLs(matching: changedURLs, in: [main, feature])

        XCTAssertEqual(matches, Set([main, feature]))
    }

    func testWatchedURLsDoNotMatchSiblingPrefixes() {
        let project = URL(fileURLWithPath: "/tmp/project")
        let projectFeature = URL(fileURLWithPath: "/tmp/project-feature")
        let changedURLs = [
            URL(fileURLWithPath: "/tmp/project-feature/Sources/App.swift")
        ]

        let matches = FileWatchPathMatcher.watchedURLs(matching: changedURLs, in: [project, projectFeature])

        XCTAssertEqual(matches, Set([projectFeature]))
    }

    func testWatchedURLsDeduplicateNormalizedWatchedPaths() {
        let canonical = URL(fileURLWithPath: "/tmp/project")
        let duplicate = URL(fileURLWithPath: "/tmp/project/./")
        let changedURLs = [
            URL(fileURLWithPath: "/tmp/project/Sources/App.swift")
        ]

        let matches = FileWatchPathMatcher.watchedURLs(matching: changedURLs, in: [canonical, duplicate])

        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.standardizedFileURL.path, canonical.path)
    }
}
