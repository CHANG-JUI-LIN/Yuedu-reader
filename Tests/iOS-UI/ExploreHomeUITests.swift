import XCTest

/// Unified library 5c-3 and 5d-1: the Explore home as a new install sees it, its 範圍 menu
/// with the libraries, custom pages and browser, and the China storefront. Each launch starts
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

    @MainActor
    private func chooseScope(_ app: XCUIApplication, _ title: String) {
        let menu = app.buttons["explore.scopeMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), app.debugDescription)
        menu.tap()
        let option = app.buttons[title].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
    }

    /// 精選's first list: a row of covers, so the home is drawn.
    private let featuredCard = "home.card.gutenberg.24264"
    private let gutenbergID = "builtin.gutenberg"

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

    /// 範圍 filters the same home to one library, as Emby's library switch does (5d-3b,
    /// decision 19), and the choice survives a relaunch. The library's whole catalog is its
    /// own page, from 瀏覽完整目錄 at the top; under 全部, 瀏覽書庫 lists every library
    /// (decision 20).
    @MainActor
    func testScopeFiltersTheHomeAndBack() {
        let app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Project Gutenberg"].exists, "the home names no source")

        // 瀏覽書庫 lists the libraries, each opening its own page.
        let libraries = app.buttons["home.libraries"].firstMatch
        XCTAssertTrue(libraries.waitForExistence(timeout: 5), app.debugDescription)
        libraries.tap()
        let gutenbergLink = app.buttons["home.libraries.gutenberg.\(gutenbergID)"].firstMatch
        XCTAssertTrue(gutenbergLink.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["home.libraries.aozora.builtin.aozora"].firstMatch.exists)
        attach(app, "explore-home-libraries")
        gutenbergLink.tap()
        XCTAssertTrue(app.buttons["publicLibrary.categories"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // The same home, with Gutenberg's books alone; its catalog at the top.
        chooseScope(app, "Project Gutenberg")
        XCTAssertEqual(app.buttons["explore.scopeMenu"].value as? String, "Project Gutenberg")
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10), "the home stays, filtered")
        XCTAssertTrue(app.navigationBars["探索"].exists || app.tabBars.buttons["探索"].firstMatch.isHittable)
        let catalog = app.buttons["home.catalog"].firstMatch
        XCTAssertTrue(catalog.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "explore-home-scope-gutenberg")
        catalog.tap()
        XCTAssertTrue(app.navigationBars["Project Gutenberg"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["publicLibrary.categories"].firstMatch.waitForExistence(timeout: 10))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.terminate()
        let relaunched = application(reset: false)
        relaunched.launch()
        openExplore(relaunched)
        XCTAssertTrue(relaunched.buttons["home.catalog"].firstMatch.waitForExistence(timeout: 15), "the scope is kept")
        XCTAssertEqual(relaunched.buttons["explore.scopeMenu"].value as? String, "Project Gutenberg")

        // 青空文庫: no Gutenberg book stays on the home.
        chooseScope(relaunched, "青空文庫")
        XCTAssertTrue(relaunched.buttons[featuredCard].firstMatch.waitForNonExistence(timeout: 10), relaunched.debugDescription)
        relaunched.buttons["home.catalog"].firstMatch.tap()
        XCTAssertTrue(relaunched.navigationBars["青空文庫"].waitForExistence(timeout: 10), relaunched.debugDescription)
        attach(relaunched, "explore-home-scope-aozora-catalog")
        relaunched.navigationBars.buttons.element(boundBy: 0).tap()

        chooseScope(relaunched, "全部")
        XCTAssertTrue(relaunched.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(relaunched.buttons["explore.scopeMenu"].value as? String, "全部")
    }

    /// 範圍 also opens the custom pages and the browser (unified library 5d-1). A custom page
    /// deletes itself from its own ⋯. With the browser hidden (編輯首頁, 5d-2), 範圍 leaves it out.
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

        // Hidden, it is not in 範圍. 編輯首頁 (5d-2) will hide it; until then the stored choice.
        app.terminate()
        let hidden = application(extra: ["-explore.showsBrowser", "NO"])
        hidden.launch()
        openExplore(hidden)
        XCTAssertTrue(hidden.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))
        hidden.buttons["explore.scopeMenu"].firstMatch.tap()
        XCTAssertTrue(hidden.buttons["全部"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(hidden.buttons["瀏覽器"].exists, "hidden from 範圍")
        attach(hidden, "explore-scope-no-browser")
    }

    /// A connection added in 設定 → 遠端書庫 is in 範圍; its catalog opens from the top of the
    /// home. The server does not exist; the page is shown whether or not it loads.
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
        // The home, filtered to a library no section draws from yet; its catalog at the top.
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForNonExistence(timeout: 10))
        let catalog = app.buttons["home.catalog"].firstMatch
        XCTAssertTrue(catalog.waitForExistence(timeout: 10), app.debugDescription)
        catalog.tap()
        XCTAssertTrue(app.navigationBars[host].waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "explore-home-connection-page")
        app.navigationBars[host].buttons.element(boundBy: 0).tap()
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
}
