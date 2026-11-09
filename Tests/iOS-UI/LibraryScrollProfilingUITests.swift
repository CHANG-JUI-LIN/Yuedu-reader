import StoreKitTest
import XCTest

/// 資源庫 scrolling with a reader's large source library (FB-165: 1500 sources, 700 with a
/// discover page, a card for each of their groups), flung down and back for about 30 s. A driver
/// for measuring, not a pass/fail check: sample the app's main thread while it scrolls.
/// Opt-in, it takes minutes: `TEST_RUNNER_YUEDU_PROFILE_LIBRARY_SCROLL=1 xcodebuild test …`.
final class LibraryScrollProfilingUITests: XCTestCase {
    private var storeKitSession: SKTestSession?

    /// 1500 sources in a scratch directory for `-book-source-store-dir`: 700 with a discover page,
    /// spread over 150 groups, a fifth of them in two groups as packs often put them.
    private func largeSourceDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryScrollProfiling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let groupCount = 150
        let sources: [[String: Any]] = (0..<1500).map { index in
            var group = "分組\(index % groupCount)"
            if index % 5 == 0 { group += ",分組\((index / 5) % groupCount)" }
            var source: [String: Any] = [
                "bookSourceName": "來源\(index)",
                "bookSourceGroup": group,
                "bookSourceUrl": "https://library-scroll-\(index).example",
                "enabled": true,
            ]
            if index < 700 {
                source["exploreUrl"] = "熱門::https://library-scroll-\(index).example/hot"
                source["enabledExplore"] = true
            }
            return source
        }
        try JSONSerialization.data(withJSONObject: sources)
            .write(to: directory.appendingPathComponent("book_sources.json"))
        return directory
    }

    @MainActor
    func testScrollingWithManyGroups() throws {
        try measureScrolling()
    }

    @MainActor
    private func measureScrolling() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["YUEDU_PROFILE_LIBRARY_SCROLL"] == "1",
                          "Library scroll profiling is opt-in")
        let directory = try largeSourceDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        storeKitSession = try StoreKitTestSessions.fresh(StoreKitTestSessions.yueduPro())
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)",
                               "-AppleLocale", "zh_TW", "-yd_source_disclaimer_accepted", "YES",
                               "-library.tabNoticeDismissed", "YES",
                               "-book-source-store-dir", directory.path,
                               "-explore.showsGrid", "YES", "-explore.gridColumnCount", "3"]
        app.launch()
        let tab = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
        XCTAssertTrue(app.buttons["library.sources.all"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        // Drags by coordinate, not by element: an element query snapshots the accessibility
        // tree, which with every card alive costs the app ~95 ms a time and would swamp what is
        // measured. Sample the app (`sample <pid>`) while this runs; it scrolls for about 30 s.
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        for _ in 0..<6 {
            for _ in 0..<3 { bottom.press(forDuration: 0.05, thenDragTo: top, withVelocity: .fast, thenHoldForDuration: 0) }
            for _ in 0..<3 { top.press(forDuration: 0.05, thenDragTo: bottom, withVelocity: .fast, thenHoldForDuration: 0) }
        }
    }
}
