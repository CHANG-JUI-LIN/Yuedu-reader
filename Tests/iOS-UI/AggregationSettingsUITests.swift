import XCTest

/// Unified library 5d-3d and 5d-3e: 設定 → 聚合設定 (Phase 5 plan, decision 21), laid out as
/// Emby's Home Screen page since decision 36. 偏好閱讀語言 starts as the interface language; a
/// language added there leads Gutenberg's categories once moved first, and the choice survives
/// a relaunch. 書庫順序 orders the libraries' rows. 隱藏已讀, one switch, starts on. 數據來源
/// (search 9d) lists each purpose's places with how many are checked.
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

    @MainActor
    func testReadingLanguages() {
        let app = application(fresh: true)
        app.launch()
        openAggregationSettings(app)

        let chinese = app.staticTexts["aggregation.language.zh"].firstMatch
        reveal(chinese, in: app)
        XCTAssertTrue(chinese.waitForExistence(timeout: 5), "the interface language to start with")
        XCTAssertEqual(chinese.value as? String, "第 1 優先")
        let prefer = app.buttons["優先推薦偏好語言"].firstMatch
        reveal(prefer, in: app)
        XCTAssertTrue(prefer.isSelected)

        // 新增語言 adds 日本語 last; dragging it above 中文 moves it first.
        let add = app.buttons["aggregation.addLanguage"].firstMatch
        reveal(add, in: app)
        add.tap()
        let offer = app.buttons["aggregation.offer.ja"].firstMatch
        XCTAssertTrue(offer.waitForExistence(timeout: 5), app.debugDescription)
        offer.tap()
        let japanese = app.staticTexts["aggregation.language.ja"].firstMatch
        XCTAssertTrue(japanese.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(japanese.value as? String, "第 2 優先")
        reveal(japanese, in: app)
        japanese.press(forDuration: 1.0, thenDragTo: chinese)
        XCTAssertEqual(app.staticTexts["aggregation.language.ja"].firstMatch.value as? String, "第 1 優先")

        let only = app.buttons["只推薦偏好語言"].firstMatch
        reveal(only, in: app)
        only.tap()
        XCTAssertTrue(only.isSelected)
        attach(app, "aggregation-settings")

        // Saved: a relaunch without the reset reads it back.
        app.terminate()
        let relaunched = application(fresh: false)
        relaunched.launch()
        openAggregationSettings(relaunched)
        let rereadOnly = relaunched.buttons["只推薦偏好語言"].firstMatch
        reveal(rereadOnly, in: relaunched)
        XCTAssertEqual(relaunched.staticTexts["aggregation.language.ja"].firstMatch.value as? String, "第 1 優先")
        XCTAssertTrue(rereadOnly.isSelected)
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

        // Saved: a relaunch reads it back. (範圍, which listed the libraries in this order, left
        // 探索 with decision 36; 最新 takes its libraries in it, LibraryOrderTests.)
        app.terminate()
        let relaunched = application(fresh: false)
        relaunched.launch()
        openAggregationSettings(relaunched)
        let rereadAozora = relaunched.descendants(matching: .any)["aggregation.library.aozora.builtin.aozora"].firstMatch
        XCTAssertTrue(rereadAozora.waitForExistence(timeout: 5), relaunched.debugDescription)
        XCTAssertEqual(rereadAozora.value as? String, "第 1 個")
        relaunched.terminate()
        // Leave the simulator as a new install has it, for the Explore tests after this one.
        application(fresh: true).launch()
    }

    /// Decision 36: one 隱藏已讀 for the whole home, at the bottom of the page, under the home's
    /// sections, which are under 書庫順序 and the languages.
    @MainActor
    func testHideReadSwitch() {
        let app = application(fresh: true)
        app.launch()
        openAggregationSettings(app)
        let language = app.staticTexts["aggregation.language.zh"].firstMatch
        XCTAssertTrue(language.waitForExistence(timeout: 5), app.debugDescription)
        let library = app.descendants(matching: .any)["aggregation.library.gutenberg.builtin.gutenberg"].firstMatch
        reveal(library, in: app)
        XCTAssertTrue(library.exists, app.debugDescription)
        let hideRead = app.switches["aggregation.hideRead"].firstMatch
        reveal(hideRead, in: app)
        XCTAssertTrue(hideRead.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(isAbove(library, hideRead), "隱藏已讀 is last")
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
        app.launchArguments += ["-yd_search_open_library", "YES"]
        app.launch()
        openAggregationSettings(app)

        let search = app.buttons["aggregation.dataSources.search"].firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["aggregation.dataSources.latest"].exists)
        XCTAssertTrue(app.buttons["aggregation.dataSources.metadata"].exists)
        // Gutenberg, 青空文庫, Open Library and any module that searches, all checked; spoken as
        // words, not a fraction.
        let total = checkedCount(search).total
        XCTAssertGreaterThanOrEqual(total, 3, "\(search.value ?? "")")
        XCTAssertEqual(checkedCount(search).checked, total, "\(search.value ?? "")")
        XCTAssertFalse(app.staticTexts["首頁欄目"].exists, "the home's sections are 編輯首頁's")
        attach(app, "aggregation-data-sources")

        search.tap()
        XCTAssertTrue(app.navigationBars["搜尋來源"].waitForExistence(timeout: 5), app.debugDescription)
        let gutenberg = app.switches["aggregation.search.gutenberg.builtin.gutenberg"].firstMatch
        XCTAssertTrue(gutenberg.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.switches["aggregation.search.openLibrary"].exists, app.debugDescription)
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
