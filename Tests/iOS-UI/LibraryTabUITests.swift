import XCTest

/// 資源庫 (Phase 5 plan, decisions 30 and 31; 5h): the tab between 探索 and 搜尋, its card saying
/// what moved there, and each of its rows opening the page it names.
final class LibraryTabUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               // The card shows until it is closed: shown again for this run.
                               "-reset-library-notice"]
        app.launch()
        let tab = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor
    func testTabsAndRows() {
        let app = launch()
        // 書架・探索・資源庫・搜尋・設定, and no RSS tab (decision 30).
        let names = app.tabBars.buttons.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(names, ["書架", "探索", "資源庫", "搜尋", "設定"])

        let close = app.buttons["library.noticeClose"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(close.label, "關閉")
        XCTAssertTrue(app.staticTexts["所有來源都在這裡"].exists)
        attach(app, "library-tab")
        close.tap()
        XCTAssertFalse(app.staticTexts["所有來源都在這裡"].waitForExistence(timeout: 2))

        // A public library opens its own page, titled by its name.
        let gutenberg = app.buttons["library.public.builtin.gutenberg"].firstMatch
        XCTAssertTrue(gutenberg.waitForExistence(timeout: 5), app.debugDescription)
        gutenberg.tap()
        XCTAssertTrue(app.navigationBars["Project Gutenberg"].waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "library-gutenberg")
        back(app)

        let rss = app.buttons["library.rss"].firstMatch
        XCTAssertTrue(rss.waitForExistence(timeout: 5), app.debugDescription)
        rss.tap()
        XCTAssertTrue(app.navigationBars["RSS 訂閱"].waitForExistence(timeout: 5), app.debugDescription)
        back(app)

        let sources = app.buttons["library.sources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 5), app.debugDescription)
        sources.tap()
        XCTAssertTrue(app.navigationBars["來源配置管理"].waitForExistence(timeout: 5), app.debugDescription)
        back(app)

        let remote = app.buttons["library.manageRemote"].firstMatch
        XCTAssertTrue(remote.waitForExistence(timeout: 5), app.debugDescription)
        remote.tap()
        XCTAssertTrue(app.navigationBars["遠端書庫"].waitForExistence(timeout: 5), app.debugDescription)
        back(app)

        // 設定 no longer has them.
        app.tabBars.buttons["設定"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings_remote_libraries"].exists)
        XCTAssertFalse(app.buttons["管理來源配置"].exists)
    }
}
