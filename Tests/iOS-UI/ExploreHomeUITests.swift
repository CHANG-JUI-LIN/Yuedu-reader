import XCTest

/// Unified library 5c-3 and 5d-1: the Explore home as a new install sees it, its 範圍 menu
/// with the libraries, custom pages and browser, the China storefront, and 使用舊版探索頁. Each launch starts from no saved
/// home (`-reset-explore-home`) and an empty book-source library of its own.
final class ExploreHomeUITests: XCTestCase {
    private var sourceDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExploreHomeUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
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

    @MainActor
    private func chooseScope(_ app: XCUIApplication, _ title: String) {
        let menu = app.buttons["explore.scopeMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.tap()
        let option = app.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
    }

    /// Taps a Toggle's switch, at the trailing end of its row.
    @MainActor
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }

    /// 精選's first list: a row of covers, so the home is drawn.
    private let featuredCard = "home.card.gutenberg.24264"

    /// A new install, without book sources: 繼續閱讀 (empty, so not drawn), then 精選. No
    /// library tiles since unified library 5d-1: the libraries are in 範圍.
    @MainActor
    func testNewInstallShowsTheDefaultSections() {
        let app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.staticTexts["我的書庫"].exists, "no 我的書庫 on the home")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.tile.")).firstMatch.exists)
        XCTAssertEqual(app.buttons["explore.scopeMenu"].value as? String, "全部")
        XCTAssertFalse(app.buttons["explore.modeMenu"].exists, "the old roots' switch is not on the home")
        attach(app, "explore-home-new-install")
    }

    /// 範圍 shows one source's own page in place, at the root, and comes back to 全部; the choice
    /// survives a relaunch.
    @MainActor
    func testScopeShowsOneSourceInPlaceAndBack() {
        let app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))

        chooseScope(app, "Project Gutenberg")
        XCTAssertTrue(app.navigationBars["Project Gutenberg"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["publicLibrary.featured.chinese"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["publicLibrary.categories"].firstMatch.exists)
        XCTAssertTrue(app.tabBars.buttons["探索"].firstMatch.isHittable, "the source's page is the root: the tab bar stays")
        XCTAssertEqual(app.buttons["explore.scopeMenu"].value as? String, "Project Gutenberg")
        attach(app, "explore-home-scope-gutenberg")

        app.terminate()
        let relaunched = application(reset: false)
        relaunched.launch()
        openExplore(relaunched)
        XCTAssertTrue(relaunched.navigationBars["Project Gutenberg"].waitForExistence(timeout: 15), "the scope is kept")

        chooseScope(relaunched, "青空文庫")
        XCTAssertTrue(relaunched.navigationBars["青空文庫"].waitForExistence(timeout: 10))
        attach(relaunched, "explore-home-scope-aozora")

        chooseScope(relaunched, "全部")
        XCTAssertTrue(relaunched.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(relaunched.buttons["explore.scopeMenu"].value as? String, "全部")
    }

    /// 範圍 also opens the custom pages and the browser (unified library 5d-1). A custom page
    /// deletes itself from its own ⋯; 探索設定 takes the browser out of 範圍.
    @MainActor
    func testScopeOpensCustomPagesAndTheBrowser() {
        let app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))

        // A custom page, made from ＋, is listed under 自訂頁.
        let name = "測試頁\(UUID().uuidString.prefix(4))"
        app.buttons["新增自訂頁"].firstMatch.tap()
        let field = app.textFields["名稱"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.typeText(name)
        app.buttons["新建"].firstMatch.tap()
        let menu = app.buttons["explore.scopeMenu"].firstMatch
        menu.tap()
        let pages = app.buttons["自訂頁"].firstMatch
        XCTAssertTrue(pages.waitForExistence(timeout: 5), app.debugDescription)
        pages.tap()
        let page = app.buttons[name].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5), app.debugDescription)
        page.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "explore-scope-custom-page")

        // Deleting it from its ⋯ leaves the page.
        app.navigationBars[name].buttons["更多"].firstMatch.tap()
        let delete = app.buttons["刪除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        delete.tap()
        XCTAssertTrue(app.staticTexts["刪除「\(name)」？"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["刪除"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars[name].waitForNonExistence(timeout: 10), "a deleted page closes")
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10))
        menu.tap()
        XCTAssertTrue(app.buttons["全部"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["自訂頁"].exists, "no pages, no 自訂頁")

        // The browser opens full screen and closes back to the home.
        // A menu item carries no identifier into the accessibility tree: found by its label.
        let browser = app.buttons["瀏覽器"].firstMatch
        XCTAssertTrue(browser.exists, app.debugDescription)
        browser.tap()
        XCTAssertTrue(app.textFields["輸入網址或搜尋"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "explore-scope-browser")
        app.buttons["關閉"].firstMatch.tap()
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10))

        // 探索設定 takes it out of 範圍.
        app.buttons["探索設定"].firstMatch.tap()
        let shows = app.switches["explore.showsBrowser"].firstMatch
        XCTAssertTrue(shows.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(shows.value as? String, "1")
        flip(shows)
        XCTAssertEqual(shows.value as? String, "0")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(shows.waitForNonExistence(timeout: 5))
        menu.tap()
        XCTAssertTrue(app.buttons["全部"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["瀏覽器"].exists, "hidden from 範圍")
        attach(app, "explore-scope-no-browser")
    }

    /// A connection added in 設定 → 遠端書庫 is in 範圍, which shows its library in place. The
    /// server does not exist; the page is shown whether or not it loads.
    @MainActor
    func testConnectionIsInScope() {
        let app = application()
        app.launch()
        let notNow = app.buttons["不允許"]
        if notNow.waitForExistence(timeout: 3) { notNow.tap() }
        let settings = app.tabBars.buttons["設定"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let row = app.buttons["settings_remote_libraries"].firstMatch
        for _ in 0..<4 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let host = "home-\(UUID().uuidString.prefix(8).lowercased()).example"
        let addOPDS = app.buttons["remote_library_add_opds"].firstMatch
        for _ in 0..<3 where !addOPDS.isHittable { app.swipeUp() }
        addOPDS.tap()
        let url = app.textFields["伺服器網址"].firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText("https://\(host)/opds")
        app.buttons["儲存"].firstMatch.tap()
        // Back to 設定's root: the tab bar shows on tab roots only.
        let remoteLibraries = app.navigationBars.matching(NSPredicate(format: "identifier != %@", "設定")).firstMatch
        XCTAssertTrue(remoteLibraries.waitForExistence(timeout: 5))
        remoteLibraries.buttons.element(boundBy: 0).tap()

        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        chooseScope(app, host)
        XCTAssertTrue(app.navigationBars[host].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.tabBars.buttons["探索"].firstMatch.isHittable, "in place, at the root")
        attach(app, "explore-home-connection-page")
        chooseScope(app, "全部")

        // Leave nothing behind for the next run.
        settings.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let added = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", host)).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 5))
        added.swipeLeft()
        app.buttons["刪除"].firstMatch.tap()
        XCTAssertTrue(added.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    /// The China storefront: no public library anywhere on the home or in 範圍.
    @MainActor
    func testChinaShowsNoPublicLibraries() {
        let app = application(extra: ["-debug-storefront-country", "CHN"])
        app.launch()
        openExplore(app)
        let menu = app.buttons["explore.scopeMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), app.debugDescription)
        // No source and no 精選: the home is 繼續閱讀 alone, or, with nothing read on this
        // simulator, says where to go instead of staying blank. The shelf is the simulator's own.
        let continueReading = app.staticTexts["繼續閱讀"].firstMatch
        let empty = app.staticTexts["探索還沒有內容"].firstMatch
        XCTAssertTrue(continueReading.waitForExistence(timeout: 15) || empty.exists, app.debugDescription)
        XCTAssertFalse(continueReading.exists && empty.exists, "the empty state only on an empty home")
        XCTAssertFalse(app.buttons[featuredCard].exists)
        attach(app, "explore-home-china-empty")
        menu.tap()
        XCTAssertTrue(app.buttons["全部"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Project Gutenberg"].exists)
        XCTAssertFalse(app.buttons["青空文庫"].exists)
        attach(app, "explore-home-china-scope")
    }

    /// 使用舊版探索頁 brings back the old root, whose own gear turns it off again. 探索設定 is the
    /// page's sheet, so it closes as the switch replaces the page.
    @MainActor
    func testClassicRootSwitch() {
        let app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))

        app.buttons["探索設定"].firstMatch.tap()
        let toggle = app.switches["explore.classicRoot"].firstMatch
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        flip(toggle)
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 5), "the sheet goes with the page that showed it")
        XCTAssertTrue(app.buttons["publicLibrary.featured.chinese"].firstMatch.waitForExistence(timeout: 10),
                      "the old 公有書庫 root")
        attach(app, "explore-classic-root")

        app.buttons["探索設定"].firstMatch.tap()
        for _ in 0..<6 where !toggle.isHittable { app.swipeUp() }
        flip(toggle)
        XCTAssertTrue(toggle.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10), "back on the home")
    }
}
