import XCTest

/// Unified library 5c-3 and 5d-1: the Explore home as a new install sees it, its ••• with
/// 首頁配置 and the browser (decision 36), and the China storefront. Each launch starts
/// from no saved home (`-reset-explore-home`) and an empty book-source library of its own.
/// Gutenberg's feeds answer from fixtures (its rows load with the home since 5d-1c); its
/// covers still load from gutenberg.org as their cards show.
final class ExploreHomeUITests: XCTestCase {
    private var sourceDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExploreHomeUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        // 最新, whatever list asks: the transport reads the path alone.
        let latest = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Latest</title>
        <entry><id>https://www.gutenberg.org/ebooks/79760.opds</id><title>Fixture Release</title><content>Fixture Author</content><link rel="subsection" type="application/atom+xml" href="/ebooks/79760.opds"/></entry>
        </feed>
        """
        try Data(latest.utf8).write(to: sourceDirectory.appendingPathComponent("ebooks_search.opds.xml"))
        // 熱門 (5d-6a), the same path by downloads: a book of its own, so a row shows its list.
        let popular = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Popular</title>
        <entry><id>https://www.gutenberg.org/ebooks/84.opds</id><title>Fixture Popular</title><content>Fixture Author</content><link rel="subsection" type="application/atom+xml" href="/ebooks/84.opds"/></entry>
        </feed>
        """
        try Data(popular.utf8).write(to: sourceDirectory.appendingPathComponent("ebooks_search.opds@sort_order=downloads.xml"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: sourceDirectory)
    }

    @MainActor
    private func application(reset: Bool = true, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-book-source-store-dir", sourceDirectory.path]
        if reset { app.launchArguments += ["-reset-public-library-explore", "-reset-explore-home"] }
        app.launchArguments += extra
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = sourceDirectory.path
        return app
    }

    @MainActor
    private func openExplore(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// ••• : a native menu from iOS 18, a chooser sheet on iOS 17.
    @MainActor
    private func openMore(_ app: XCUIApplication) {
        let more = app.buttons["explore.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
        more.tap()
    }

    /// An item of the open •••: the chooser's row also reads its subtitle after the title.
    @MainActor
    private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    /// ••• → 首頁配置 → `name`.
    @MainActor
    private func chooseConfiguration(_ app: XCUIApplication, _ name: String) {
        openConfigurations(app)
        let option = item(app, name)
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
    }

    /// ••• → 首頁配置: a submenu from iOS 18, whose label also reads the current one; iOS 17's
    /// chooser lists them in place.
    @MainActor
    private func openConfigurations(_ app: XCUIApplication) {
        openMore(app)
        guard #available(iOS 18, *) else { return }
        let submenu = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "首頁配置")).firstMatch
        XCTAssertTrue(submenu.waitForExistence(timeout: 5), app.debugDescription)
        submenu.tap()
    }

    /// ••• → 首頁配置 → 新增首頁配置, named `name`, from 空白 or 預設.
    @MainActor
    private func addConfiguration(_ app: XCUIApplication, _ name: String, from start: String) {
        openConfigurations(app)
        let add = item(app, "新增首頁配置")
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        add.tap()
        let field = app.textFields["名稱"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.typeText(name)
        app.buttons[start].firstMatch.tap()
    }

    /// 精選's first list: a row of covers, so the home is drawn.
    private let featuredCard = "home.card.gutenberg.24264"
    private let gutenbergID = "builtin.gutenberg"

    /// A new install, without book sources: 繼續閱讀 (empty, so not drawn), then 精選. No
    /// library tiles since unified library 5d-1, and no 範圍 since decision 36: the libraries
    /// open from 資源庫 (5h).
    @MainActor
    func testNewInstallShowsTheDefaultSections() {
        let app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        // 古騰堡熱門, a new install's (decision 24), before 精選.
        XCTAssertTrue(app.buttons["home.card.gutenberg.84"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["我的書庫"].exists, "no 我的書庫 on the home")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.tile.")).firstMatch.exists)
        XCTAssertTrue(app.buttons["explore.more"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["explore.scopeMenu"].exists, "no 範圍 (decision 36)")
        XCTAssertFalse(app.buttons["explore.modeMenu"].exists, "the old roots' switch is not on the home")
        attach(app, "explore-home-new-install")
    }

    /// Decision 15: Gutenberg's 最新 loads when 探索 opens, with no 載入 to tap, wherever the
    /// row sits on the page.
    @MainActor
    func testGutenbergLatestLoadsWithTheHome() {
        let app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let latest = app.buttons["home.card.gutenberg.79760"].firstMatch
        for _ in 0..<6 where !latest.exists { app.swipeUp() }
        XCTAssertTrue(latest.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.row.load.")).firstMatch.exists)
        attach(app, "explore-home-gutenberg-latest")
    }

    /// 顯示在最新 (5d-3f), in 最新's own options since decision 36: turned off for Gutenberg in
    /// 設定 → 聚合設定 → 最新, Gutenberg's 最新 is not asked for and its book is not on the home.
    @MainActor
    func testShowInLatestOff() {
        let app = application()
        app.launch()
        // The home is saved once 探索 has read it; 聚合設定 lists its sections then.
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let settingsTab = app.tabBars.buttons["設定"].firstMatch
        settingsTab.tap()
        let row = app.buttons["settings_aggregation"].firstMatch
        for _ in 0..<4 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let latest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                                      "aggregation.homeSection.", "最新")).firstMatch
        for _ in 0..<4 where !latest.isHittable { app.swipeUp() }
        XCTAssertTrue(latest.waitForExistence(timeout: 5), app.debugDescription)
        latest.tap()
        let toggle = app.switches["homeSection.latest.library.gutenberg.\(gutenbergID)"].firstMatch
        for _ in 0..<3 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(toggle.value as? String, "1")
        // The switch sits at the row's trailing end; 30 pt in lands on it whether the element is
        // the whole row (iOS 17) or the switch alone.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -30, dy: 0)).tap()
        XCTAssertEqual(toggle.value as? String, "0")
        attach(app, "latest-show-in-latest")
        // Back to 聚合設定, then 設定's root: the tab bar shows on tab roots only.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<6 { app.swipeUp() }
        XCTAssertFalse(app.buttons["home.card.gutenberg.79760"].firstMatch.exists, "Gutenberg is off in 最新")
    }

    /// 精簡閱讀卡片 (5d-3c), in the design fixture's 繼續閱讀: the ••• beside a shelf copy's card
    /// is a control of its own, reachable by touch and VoiceOver, and offers 從繼續閱讀移除 and
    /// 標記為已讀完.
    @MainActor
    func testCompactCardMenu() {
        let app = application(extra: ["-explore-home-fixture"])
        app.launch()
        let more = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.card.more.'")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(more.label, "更多")
        XCTAssertTrue(more.isHittable)
        attach(app, "home-compact-card")
        more.tap()
        XCTAssertTrue(app.buttons["從繼續閱讀移除"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["標記為已讀完"].firstMatch.exists)
        attach(app, "home-compact-card-menu")
    }

    /// ••• switches 首頁配置 (unified library 5d-4, under ••• since decision 36) and opens the
    /// browser (5d-1). A 首頁配置 made from 新增首頁配置 starts from 空白 or 預設; 編輯首頁 deletes
    /// it. With the browser hidden (編輯首頁, 5d-2), ••• leaves it out.
    @MainActor
    func testConfigurationsAndTheBrowser() {
        let app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))

        // From 空白: nothing on the home but the way to fill it.
        let name = "測試配置\(UUID().uuidString.prefix(4))"
        addConfiguration(app, name, from: "從空白開始")
        XCTAssertTrue(app.staticTexts["這個首頁配置還沒有欄目"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons[featuredCard].exists)
        attach(app, "explore-configuration-blank")

        // 首頁配置 lists 預設, 空白 and the new one; 預設 is the home as it was.
        openConfigurations(app)
        XCTAssertTrue(item(app, "空白").waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "explore-more-configurations")
        item(app, "預設").tap()
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        chooseConfiguration(app, name)
        XCTAssertTrue(app.staticTexts["這個首頁配置還沒有欄目"].waitForExistence(timeout: 10), app.debugDescription)

        // 編輯首頁 deletes it, which ends the edit, and 預設 shows again.
        app.buttons["home.edit"].firstMatch.tap()
        let delete = app.buttons["homeEditor.deleteConfiguration"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "explore-configuration-editing")
        delete.tap()
        XCTAssertTrue(app.staticTexts["刪除「\(name)」？"].waitForExistence(timeout: 5), app.debugDescription)
        // The dialog's, not the card's of the same name.
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "刪除",
                                         "homeEditor.deleteConfiguration")).firstMatch.tap()
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["home.editDoneBar"].exists, "no longer editing")
        openConfigurations(app)
        XCTAssertTrue(item(app, "空白").waitForExistence(timeout: 5))
        XCTAssertFalse(item(app, name).exists, "deleted from 首頁配置")

        // From 預設: its sections.
        item(app, "預設").tap()
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        addConfiguration(app, name, from: "從預設開始")
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10), app.debugDescription)

        // The browser opens full screen and closes back to the home.
        // A menu item carries no identifier into the accessibility tree: found by its label.
        openMore(app)
        let browser = item(app, "瀏覽器")
        XCTAssertTrue(browser.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "explore-more-menu")
        browser.tap()
        XCTAssertTrue(app.textFields["輸入網址或搜尋"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "explore-more-browser")
        app.buttons["關閉"].firstMatch.tap()
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10))

        // Hidden, it is not in •••. 編輯首頁 (5d-2) hides it; here the stored choice.
        app.terminate()
        let hidden = application(extra: ["-explore.showsBrowser", "NO"])
        hidden.launch()
        openExplore(hidden)
        XCTAssertTrue(hidden.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))
        openMore(hidden)
        XCTAssertTrue(item(hidden, "重新整理").waitForExistence(timeout: 5), hidden.debugDescription)
        XCTAssertFalse(item(hidden, "瀏覽器").exists, "hidden from •••")
        attach(hidden, "explore-more-no-browser")
    }

    /// ••• → 偏好閱讀語言 and ••• → 參與聚合的來源 push 聚合設定, and back is the home (decision
    /// 36); ••• → 重新整理 keeps the home drawn.
    @MainActor
    func testMoreOpensAggregationSettings() {
        let app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))
        for entry in ["偏好閱讀語言", "參與聚合的來源"] {
            openMore(app)
            let option = item(app, entry)
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
            option.tap()
            XCTAssertTrue(app.navigationBars["聚合設定"].waitForExistence(timeout: 8), app.debugDescription)
            attach(app, "explore-more-\(entry)")
            app.navigationBars["聚合設定"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        }
        openMore(app)
        item(app, "重新整理").tap()
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
    }

    /// A custom page saved before 5d-4, chosen as the old 首屏頁面, is the 首頁配置 the home opens
    /// on; its ranking became a section, which 編輯首頁 shows. Its source is not on this device,
    /// so nothing loads.
    @MainActor
    func testCustomPageMovesIn() {
        let app = application(extra: ["-seed-custom-explore-page"])
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.staticTexts["探索還沒有內容"].waitForExistence(timeout: 15), app.debugDescription)
        openConfigurations(app)
        XCTAssertTrue(item(app, "週末書單").waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "explore-custom-page-moved-in")
        item(app, "週末書單").tap()

        app.buttons["home.edit"].firstMatch.tap()
        XCTAssertTrue(app.buttons["homeEditor.section.5D4C0000-0000-4000-8000-000000000002"].firstMatch
            .waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["週末書單"].exists)
        XCTAssertTrue(app.buttons["homeEditor.renameConfiguration"].exists)
        attach(app, "explore-custom-page-editing")
    }

    /// The China storefront: no public library on the home.
    @MainActor
    func testChinaShowsNoPublicLibraries() {
        let app = application(extra: ["-debug-storefront-country", "CHN"])
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons["explore.more"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        // No source and no 精選: the home is 繼續閱讀 alone, or, with nothing read on this
        // simulator, says where to go instead of staying blank. The shelf is the simulator's own.
        let continueReading = app.staticTexts["繼續閱讀"].firstMatch
        let empty = app.staticTexts["探索還沒有內容"].firstMatch
        XCTAssertTrue(continueReading.waitForExistence(timeout: 15) || empty.exists, app.debugDescription)
        XCTAssertFalse(continueReading.exists && empty.exists, "the empty state only on an empty home")
        XCTAssertFalse(app.buttons[featuredCard].exists)
        XCTAssertFalse(app.staticTexts["Project Gutenberg"].exists)
        XCTAssertFalse(app.staticTexts["青空文庫"].exists)
        attach(app, "explore-home-china-empty")
    }
}
