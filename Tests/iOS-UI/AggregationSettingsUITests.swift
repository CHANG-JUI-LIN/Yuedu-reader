import XCTest

/// Unified library 5d-3d and 5d-3e: 設定 → 聚合設定 (Phase 5 plan, decision 21), laid out as
/// Emby's Home Screen page since decision 36. 中繼資料語言偏好推薦 (2026-10-21) is one menu that
/// starts at 跟隨 App 語言; the language picked there survives a relaunch. 書庫順序 is gone (2026-10-25). 隱藏已讀, one switch, starts on. 數據來源
/// (search 9d) lists each purpose's places with how many are checked.
final class AggregationSettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    /// `fresh` starts from no saved settings, as a new install (`-reset-explore-home`).
    @MainActor
    private func application(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-no-official-modules", "-onboarding.completed", "YES",
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

    /// Scrolls the page until `element` can be touched: the page's sections are built as they
    /// come on screen.
    @MainActor
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<4 where !element.isHittable { app.swipeUp() }
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// What a menu row reads: its title and its choice.
    @MainActor
    private func spoken(_ element: XCUIElement) -> String {
        [element.label, element.value as? String ?? ""].joined(separator: " ")
    }

    @MainActor
    func testMetadataLanguage() {
        let app = application(fresh: true)
        app.launch()
        openAggregationSettings(app)

        // One menu, at 跟隨 App 語言 until the reader picks another.
        let menu = app.descendants(matching: .any)["aggregation.metadataLanguage"].firstMatch
        reveal(menu, in: app)
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(spoken(menu).contains("跟隨 App 語言"), spoken(menu))
        menu.tap()
        XCTAssertTrue(app.buttons["繁體中文"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["简体中文"].firstMatch.exists, "Chinese in each script")
        let japanese = app.buttons["日本語"].firstMatch
        XCTAssertTrue(japanese.exists, app.debugDescription)
        japanese.tap()
        XCTAssertTrue(spoken(menu).contains("日本語"), spoken(menu))
        attach(app, "aggregation-metadata-language")

        // Saved: a relaunch without the reset reads it back.
        app.terminate()
        let relaunched = application(fresh: false)
        relaunched.launch()
        openAggregationSettings(relaunched)
        let reread = relaunched.descendants(matching: .any)["aggregation.metadataLanguage"].firstMatch
        reveal(reread, in: relaunched)
        XCTAssertTrue(reread.waitForExistence(timeout: 5), relaunched.debugDescription)
        XCTAssertTrue(spoken(reread).contains("日本語"), spoken(reread))
        relaunched.terminate()
        // Leave the simulator as a new install has it, for the Explore tests after this one.
        application(fresh: true).launch()
    }

    /// The vertical order of elements on screen, top first.
    @MainActor
    private func isAbove(_ upper: XCUIElement, _ lower: XCUIElement) -> Bool {
        upper.frame.minY < lower.frame.minY
    }

    /// Decision 36: one 隱藏已讀 for the whole home, at the bottom of the page, under the
    /// languages; 書庫順序, which was between them, is gone (2026-10-25).
    @MainActor
    func testHideReadSwitch() {
        let app = application(fresh: true)
        app.launch()
        openAggregationSettings(app)
        let language = app.descendants(matching: .any)["aggregation.metadataLanguage"].firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 5), app.debugDescription)
        let hideRead = app.switches["aggregation.hideRead"].firstMatch
        reveal(hideRead, in: app)
        XCTAssertTrue(hideRead.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(isAbove(language, hideRead), "隱藏已讀 is last")
        XCTAssertFalse(app.staticTexts["書庫順序"].exists, "書庫順序 is gone")
        XCTAssertFalse(app.descendants(matching: .any)["aggregation.library.gutenberg.builtin.gutenberg"].exists)
        XCTAssertFalse(app.switches["aggregation.hideRead.latest"].exists, "the two switches are one")
        XCTAssertFalse(app.staticTexts["顯示在最新"].exists, "顯示在最新 is in 最新's options")
        XCTAssertEqual(hideRead.value as? String, "1")
        // The switch sits at the row's trailing end (the row is the element on iOS 17).
        hideRead.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -30, dy: 0)).tap()
        XCTAssertEqual(hideRead.value as? String, "0")
        attach(app, "aggregation-hide-read")

        app.terminate()
        let relaunched = application(fresh: false)
        relaunched.launch()
        openAggregationSettings(relaunched)
        let reread = relaunched.switches["aggregation.hideRead"].firstMatch
        reveal(reread, in: relaunched)
        XCTAssertEqual(reread.value as? String, "0")
        relaunched.terminate()
        application(fresh: true).launch()
    }

    /// Search 9d: 數據來源 on top, each purpose with its n/m; 搜尋來源 lists the libraries and Open
    /// Library (moved from 網路設定), and a switch turned off there counts and lasts. The home's
    /// sections are no longer on the page.
    /// 「已勾選 2 個，共 3 個」 as numbers.
    @MainActor
    private func checkedCount(_ row: XCUIElement) -> (checked: Int, total: Int) {
        let numbers = (row.value as? String ?? "").split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard numbers.count == 2 else {
            XCTFail("not a count: \(row.value ?? "")")
            return (-1, -1)
        }
        return (numbers[0], numbers[1])
    }

    @MainActor
    func testDataSources() {
        let app = application(fresh: true)
        app.launch()
        openAggregationSettings(app)

        let search = app.buttons["aggregation.dataSources.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["aggregation.dataSources.latest"].exists)
        XCTAssertTrue(app.buttons["aggregation.dataSources.metadata"].exists)
        // Gutenberg, 青空文庫 and any module that searches (Open Library is one: not with
        // -no-official-modules), all checked; spoken as words, not a fraction.
        let total = checkedCount(search).total
        XCTAssertGreaterThanOrEqual(total, 2, "\(search.value ?? "")")
        XCTAssertEqual(checkedCount(search).checked, total, "\(search.value ?? "")")
        XCTAssertFalse(app.staticTexts["首頁欄目"].exists, "the home's sections are 編輯首頁's")
        attach(app, "aggregation-data-sources")

        search.tap()
        XCTAssertTrue(app.navigationBars["搜尋來源"].waitForExistence(timeout: 5), app.debugDescription)
        let gutenberg = app.switches["aggregation.search.gutenberg.builtin.gutenberg"].firstMatch
        XCTAssertTrue(gutenberg.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(gutenberg.value as? String, "1")
        // The switch sits at the row's trailing end (the row is the element on iOS 17).
        gutenberg.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -30, dy: 0)).tap()
        XCTAssertEqual(gutenberg.value as? String, "0")
        attach(app, "aggregation-search-sources")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(checkedCount(search).checked, total - 1, search.debugDescription)

        app.terminate()
        let relaunched = application(fresh: false)
        relaunched.launch()
        openAggregationSettings(relaunched)
        let reread = relaunched.buttons["aggregation.dataSources.search"].firstMatch
        XCTAssertTrue(reread.waitForExistence(timeout: 5))
        XCTAssertEqual(checkedCount(reread).checked, total - 1, reread.debugDescription)
        reread.tap()
        let off = relaunched.switches["aggregation.search.gutenberg.builtin.gutenberg"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 5))
        off.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -30, dy: 0)).tap()
        XCTAssertEqual(off.value as? String, "1", "left checked for the other tests")
        relaunched.terminate()
        application(fresh: true).launch()
    }
}
