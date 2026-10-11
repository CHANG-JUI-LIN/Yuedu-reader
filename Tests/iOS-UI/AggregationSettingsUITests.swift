import XCTest

/// Unified library 5d-3d and 5d-3e: 設定 → 聚合設定 (Phase 5 plan, decision 21). 偏好閱讀語言
/// starts as the interface language; a language added there leads Gutenberg's categories once
/// moved first, and the choice survives a relaunch. 書庫順序 orders 範圍 and 瀏覽書庫.
final class AggregationSettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// `fresh` starts from no saved settings, as a new install (`-reset-explore-home`).
    @MainActor
    private func application(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES"]
        if fresh { app.launchArguments += ["-reset-explore-home"] }
        return app
    }

    @MainActor
    private func openAggregationSettings(_ app: XCUIApplication) {
        let settingsTab = app.tabBars.buttons["設定"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 30))
        settingsTab.tap()
        let row = app.buttons["settings_aggregation"].firstMatch
        for _ in 0..<4 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "聚合設定 sits in 來源配置管理")
        row.tap()
        XCTAssertTrue(app.navigationBars["聚合設定"].waitForExistence(timeout: 8), app.debugDescription)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testReadingLanguages() {
        let app = application(fresh: true)
        app.launch()
        openAggregationSettings(app)

        let chinese = app.staticTexts["aggregation.language.zh"].firstMatch
        XCTAssertTrue(chinese.waitForExistence(timeout: 5), "the interface language to start with")
        XCTAssertEqual(chinese.value as? String, "第 1 優先")
        XCTAssertTrue(app.buttons["優先推薦偏好語言"].firstMatch.isSelected)

        // 新增語言 adds 日本語 last; dragging it above 中文 moves it first.
        app.buttons["aggregation.addLanguage"].firstMatch.tap()
        let offer = app.buttons["aggregation.offer.ja"].firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 5), app.debugDescription)
        offer.tap()
        let japanese = app.staticTexts["aggregation.language.ja"].firstMatch
        XCTAssertTrue(japanese.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(japanese.value as? String, "第 2 優先")
        japanese.press(forDuration: 1.0, thenDragTo: chinese)
        XCTAssertEqual(app.staticTexts["aggregation.language.ja"].firstMatch.value as? String, "第 1 優先")

        app.buttons["只推薦偏好語言"].firstMatch.tap()
        XCTAssertTrue(app.buttons["只推薦偏好語言"].firstMatch.isSelected)
        attach(app, "aggregation-settings")

        // Saved: a relaunch without the reset reads it back.
        app.terminate()
        let relaunched = application(fresh: false)
        relaunched.launch()
        openAggregationSettings(relaunched)
        XCTAssertEqual(relaunched.staticTexts["aggregation.language.ja"].firstMatch.value as? String, "第 1 優先")
        XCTAssertTrue(relaunched.buttons["只推薦偏好語言"].firstMatch.isSelected)
        relaunched.terminate()
        // Leave the simulator as a new install has it, for the Explore tests after this one.
        application(fresh: true).launch()
    }

    /// The vertical order of elements on screen, top first.
    @MainActor
    private func isAbove(_ upper: XCUIElement, _ lower: XCUIElement) -> Bool {
        upper.frame.minY < lower.frame.minY
    }

    @MainActor
    func testLibraryOrder() {
        let app = application(fresh: true)
        app.launch()
        openAggregationSettings(app)

        // A new install: Gutenberg, then 青空文庫. Dragging 青空文庫 up puts it first.
        let gutenberg = app.descendants(matching: .any)["aggregation.library.gutenberg.builtin.gutenberg"].firstMatch
        let aozora = app.descendants(matching: .any)["aggregation.library.aozora.builtin.aozora"].firstMatch
        XCTAssertTrue(aozora.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(isAbove(gutenberg, aozora))
        XCTAssertEqual(aozora.value as? String, "第 2 個")
        aozora.press(forDuration: 1.0, thenDragTo: gutenberg)
        XCTAssertEqual(aozora.value as? String, "第 1 個")
        XCTAssertTrue(isAbove(aozora, gutenberg))
        attach(app, "aggregation-library-order")

        // 瀏覽書庫 lists them in that order. The tab bar shows on 設定's root only.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let exploreTab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(exploreTab.waitForExistence(timeout: 5), app.debugDescription)
        exploreTab.tap()
        let libraries = app.buttons["home.libraries"].firstMatch
        XCTAssertTrue(libraries.waitForExistence(timeout: 15), app.debugDescription)
        libraries.tap()
        let aozoraLink = app.buttons["home.libraries.aozora.builtin.aozora"].firstMatch
        let gutenbergLink = app.buttons["home.libraries.gutenberg.builtin.gutenberg"].firstMatch
        XCTAssertTrue(aozoraLink.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(isAbove(aozoraLink, gutenbergLink))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // So does 範圍.
        let menu = app.buttons["explore.scopeMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.tap()
        let aozoraOption = app.buttons["青空文庫"].firstMatch
        XCTAssertTrue(aozoraOption.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(isAbove(aozoraOption, app.buttons["Project Gutenberg"].firstMatch))
        attach(app, "scope-menu-library-order")

        app.terminate()
        // Leave the simulator as a new install has it, for the Explore tests after this one.
        application(fresh: true).launch()
    }
}
