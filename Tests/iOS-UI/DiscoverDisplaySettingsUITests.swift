import XCTest

/// The discover page's display settings and 封面並發數 (Phase 5 plan, decision 31; 5h-3): back
/// from 5d-1b, 顯示設定 behind a source's 發現頁設定 and 封面並發數 in 網路設定.
///
/// The library is a one-source fixture in a scratch directory handed to the app with
/// `-book-source-store-dir`, so the simulator's own sources are never touched. Its discover
/// page asks a host that does not exist; the settings do not need it to answer.
final class DiscoverDisplaySettingsUITests: XCTestCase {
    private var storeDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiscoverDisplaySettingsUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let sources: [[String: Any]] = [[
            "bookSourceName": "顯示設定測試來源",
            "bookSourceUrl": "https://discover-display-ui-test.example",
            "exploreUrl": "熱門::https://discover-display-ui-test.example/hot",
            "enabled": true,
            "enabledExplore": true,
        ]]
        try JSONSerialization.data(withJSONObject: sources)
            .write(to: storeDirectory.appendingPathComponent("book_sources.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", storeDirectory.path,
                               // Magazine, so its chart and shelf settings show; the page's own
                               // writes are not checked here.
                               "-explore.sourcePageLayout", "magazine"]
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

    @MainActor
    func testDisplaySettingsFromTheSourcePage() {
        let app = launch()
        let tab = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
        let all = app.buttons["library.sources.all"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10), app.debugDescription)
        all.tap()
        let source = app.buttons["library.source.顯示設定測試來源"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5), app.debugDescription)
        source.tap()

        let gear = app.navigationBars.buttons["發現頁設定"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), app.debugDescription)
        gear.tap()
        let display = app.buttons["discover.displaySettings"].firstMatch
        XCTAssertTrue(display.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(display.label, "顯示設定")
        display.tap()

        XCTAssertTrue(app.navigationBars["顯示設定"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["discover.display.layout"].firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["豎排榜單關鍵詞"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["榜"].exists, "the default chart keywords list")
        attach(app, "discover-display-settings")
        // Below the twelve default keywords: the form builds its rows only near the screen.
        let preload = app.staticTexts["預加載"].firstMatch
        var swipes = 0
        while !preload.exists, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(preload.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["榜單展示數量"].exists, app.debugDescription)
        attach(app, "discover-display-settings-lower")
    }

    @MainActor
    func testCoverDownloadLimitInNetworkSettings() {
        let app = launch()
        let tab = app.tabBars.buttons["設定"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
        let network = app.buttons["網路設定"].firstMatch
        var swipes = 0
        while !network.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        network.tap()
        let limit = app.buttons["network.coverDownloadLimit"].firstMatch
        XCTAssertTrue(limit.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["封面並發數"].exists || limit.label.contains("封面並發數"), app.debugDescription)
        attach(app, "network-cover-limit")
    }
}
