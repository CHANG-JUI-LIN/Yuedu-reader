import XCTest

/// The in-app browser, full screen over 探索 and over 資源庫, keeps what is presented over it.
/// On iOS 26.4.x a cover on a navigation stack's root had its content built again whenever
/// anything was presented over it, and 新增欄目 fell back to its first page (#51). The browser's
/// covers sat on their stacks' roots too, and its 書籤 sheet closed as it opened: over 探索 on
/// the iOS 26.4.1 simulator, over 資源庫 on 26.5 as well. Its 書籤 sheet and its ••• menu must
/// stay up.
final class BrowserCoverUITests: XCTestCase {
    private static let sourceName = "瀏覽器測試書源"
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrowserCoverUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A category that is a web page (`java.startBrowser`): 資源庫 opens it in the browser.
        let source: [String: Any] = [
            "bookSourceName": Self.sourceName,
            "bookSourceUrl": "https://ui-test-browser.example",
            "exploreUrl": #"[{"title":"官網","url":"java.startBrowser('https://ui-test-browser.example/','官網')"},{"title":"排行榜","url":"https://ui-test-browser.example/hot"}]"#,
            "enabled": true,
            "enabledExplore": true,
        ]
        try JSONSerialization.data(withJSONObject: [source]).write(to: directory.appendingPathComponent("book_sources.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.path,
                               "-reset-public-library-explore", "-reset-explore-home"]
        app.launch()
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 書籤's sheet and the ••• menu, each opened over the browser, stay up.
    @MainActor
    private func presentOverBrowser(_ app: XCUIApplication, _ name: String) {
        let address = app.textFields["輸入網址或搜尋"].firstMatch
        XCTAssertTrue(address.waitForExistence(timeout: 10), app.debugDescription)

        app.buttons["書籤"].firstMatch.tap()
        let sheet = app.navigationBars["書籤"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), app.debugDescription)
        // On iOS 26.4.1 the cover's rebuild took 新增欄目's sheet down within half a second.
        XCTAssertFalse(sheet.waitForNonExistence(timeout: 3), "書籤 closed by itself\n\(app.debugDescription)")
        attach(app, "\(name)-bookmarks")
        sheet.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5), app.debugDescription)

        app.buttons["更多"].firstMatch.tap()
        // A toggle in a menu: a button or a switch, by version.
        let desktop = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "電腦版網頁")).firstMatch
        XCTAssertTrue(desktop.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(desktop.waitForNonExistence(timeout: 3), "••• closed by itself\n\(app.debugDescription)")
        attach(app, "\(name)-more")
    }

    @MainActor
    func testExploreBrowserKeepsWhatIsPresentedOverIt() {
        let app = launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
        let more = app.buttons["explore.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 15), app.debugDescription)
        more.tap()
        // A menu item carries no identifier into the accessibility tree: found by its label.
        let browser = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "瀏覽器", "瀏覽器,")).firstMatch
        XCTAssertTrue(browser.waitForExistence(timeout: 5), app.debugDescription)
        browser.tap()
        presentOverBrowser(app, "explore-browser")
    }

    @MainActor
    func testLibraryBrowserKeepsWhatIsPresentedOverIt() {
        let app = launch()
        let tab = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
        let all = app.buttons["library.sources.all"].firstMatch
        for _ in 0..<6 where !all.exists { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(all.waitForExistence(timeout: 10), app.debugDescription)
        all.tap()
        let source = app.buttons["library.source.\(Self.sourceName)"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        source.tap()
        let page = app.buttons["官網"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 15), app.debugDescription)
        page.tap()
        presentOverBrowser(app, "library-browser")
    }
}
