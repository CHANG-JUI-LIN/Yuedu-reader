import StoreKitTest
import XCTest

/// The first switch to 資源庫 with a reader's 2,611 sources (FB-167: the tab bar moved at once,
/// the bookshelf stayed on screen ~6 s). A driver for measuring, not a pass/fail check: the app
/// logs `⏱ library.tab.appear` and `⏱ library.tab.firstFrame` from the tap
/// (`LibraryTabTiming`), and this prints the tap to the first card being reachable.
/// Opt-in: `TEST_RUNNER_YUEDU_PROFILE_LIBRARY_TAB=1`; `TEST_RUNNER_YUEDU_PROFILE_LIBRARY_TAB_GROUPS`
/// sets how many groups the sources fall in (default 1), `…_COUNT` how many (default 2,611).
final class LibraryTabSwitchProfilingUITests: XCTestCase {
    private var storeKitSession: SKTestSession?

    private func sourceDirectory(count: Int, groups: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTabSwitchProfiling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sources: [[String: Any]] = (0..<count).map { index in
            [
                "bookSourceName": "來源\(index)",
                "bookSourceGroup": "分組\(index % groups)",
                "bookSourceUrl": "https://library-tab-\(index).example",
                "enabled": true,
                "exploreUrl": "熱門::https://library-tab-\(index).example/hot",
                "enabledExplore": true,
            ]
        }
        try JSONSerialization.data(withJSONObject: sources)
            .write(to: directory.appendingPathComponent("book_sources.json"))
        return directory
    }

    /// `count` sources copied round-robin from a real pack (`TEST_RUNNER_YUEDU_PROFILE_LIBRARY_TAB_PACK`,
    /// a Legado JSON array): their rules are kilobytes each, as a reader's are. Each copy gets its
    /// own URL; all but the first lose their group, as the reader's showed one group of one.
    private func packDirectory(pack: URL, count: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTabSwitchProfiling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let real = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pack)) as? [[String: Any]])
        let sources: [[String: Any]] = (0..<count).map { index in
            var source = real[index % real.count]
            source["bookSourceUrl"] = "\(source["bookSourceUrl"] as? String ?? "https://pack.example")#\(index)"
            source["bookSourceName"] = "\(source["bookSourceName"] as? String ?? "來源")\(index)"
            source["bookSourceGroup"] = index == 0 ? "分組0" : ""
            source["enabled"] = true
            return source
        }
        try JSONSerialization.data(withJSONObject: sources)
            .write(to: directory.appendingPathComponent("book_sources.json"))
        return directory
    }

    @MainActor
    func testFirstSwitchToLibrary() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["YUEDU_PROFILE_LIBRARY_TAB"] == "1", "Library tab profiling is opt-in")
        let groups = Int(environment["YUEDU_PROFILE_LIBRARY_TAB_GROUPS"] ?? "") ?? 1
        let count = Int(environment["YUEDU_PROFILE_LIBRARY_TAB_COUNT"] ?? "") ?? 2611
        let pack = environment["YUEDU_PROFILE_LIBRARY_TAB_PACK"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let directory = try pack.map { try packDirectory(pack: $0, count: count) }
            ?? sourceDirectory(count: count, groups: groups)
        // The reader's page: the official modules on and the first-launch notice still open.
        let asReader = environment["YUEDU_PROFILE_LIBRARY_TAB_AS_READER"] == "1"
        defer { try? FileManager.default.removeItem(at: directory) }
        storeKitSession = try StoreKitTestSessions.fresh(StoreKitTestSessions.yueduPro())
        let app = XCUIApplication()
        app.launchArguments = (asReader ? [] : ["-no-official-modules", "-library.tabNoticeDismissed", "YES"])
            + ["-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hans)",
               "-AppleLocale", "zh_CN", "-yd_source_disclaimer_accepted", "YES",
               "-book-source-store-dir", directory.path]
        app.launch()
        let shelf = app.tabBars.buttons.element(boundBy: 0)
        XCTAssertTrue(shelf.waitForExistence(timeout: 30), app.debugDescription)
        shelf.tap()
        // Let launch settle so the switch is measured on its own.
        _ = app.otherElements["never"].waitForExistence(timeout: 8)
        let tab = app.tabBars.buttons["资源库"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10), app.debugDescription)
        let start = Date()
        tab.tap()
        XCTAssertTrue(app.buttons["library.sources.all"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        let ms = Date().timeIntervalSince(start) * 1000
        print("⏱ FB167 tap→sources.all \(Int(ms))ms sources=\(count) groups=\(groups) pack=\(pack != nil) asReader=\(asReader)")
    }
}
