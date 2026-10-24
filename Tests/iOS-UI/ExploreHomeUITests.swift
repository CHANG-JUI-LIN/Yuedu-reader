import XCTest

/// Unified library 5c-3 and 5d-1: the Explore home as a new install sees it, its 首頁配置 page
/// (its own button since 2026-10-22), its ••• with the browser (decision 36), and the China
/// storefront. Each launch starts
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

    /// `officialModules`: the bundled modules' lists on the home, as a reader has them.
    @MainActor
    private func application(reset: Bool = true, officialModules: Bool = false, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (officialModules ? [] : ["-no-official-modules"])
            + ["-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
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

    /// 首頁配置's own button (maintainer, 2026-10-22): its page. On iOS 27 the bar has slid away
    /// from a home scrolled down; a short drag up brings it back, the page still far down.
    @MainActor
    private func openConfigurations(_ app: XCUIApplication) {
        let button = app.buttons["explore.configurations"].firstMatch
        if !button.waitForExistence(timeout: 3) || !button.isHittable {
            let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 150)), withVelocity: .slow,
                        thenHoldForDuration: 0.3)
        }
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
        button.tap()
        XCTAssertTrue(app.navigationBars["首頁配置"].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Back from 首頁配置's page to the home.
    @MainActor
    private func closeConfigurations(_ app: XCUIApplication) {
        app.navigationBars["首頁配置"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["explore.configurations"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    /// `name`'s row on 首頁配置's page: 預設 also reads its subtitle after it, and in 編輯
    /// the reader's own read the delete control's 「移除」 before. iOS 27 joins them with 「、」,
    /// iOS 17 with 「, 」.
    @MainActor
    private func configurationRow(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let format = "identifier BEGINSWITH %@ AND (label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@"
            + " OR label ENDSWITH %@ OR label ENDSWITH %@)"
        return app.buttons.matching(NSPredicate(format: format, "homeConfigurations.row.", name, name + "、", name + ", ",
                                                "、" + name, ", " + name)).firstMatch
    }

    /// A tap on `row` on 首頁配置's page, which stays open.
    @MainActor
    private func chooseOnPage(_ app: XCUIApplication, _ row: XCUIElement) {
        row.tap()
        XCTAssertTrue(waitUntilSelected(row), app.debugDescription)
    }

    @MainActor
    private func waitUntilSelected(_ element: XCUIElement, _ selected: Bool = true) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == %@", NSNumber(value: selected)),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    /// 首頁配置 → `name`, back on the home.
    @MainActor
    private func chooseConfiguration(_ app: XCUIApplication, _ name: String) {
        openConfigurations(app)
        let row = configurationRow(app, name)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(waitUntilSelected(row), app.debugDescription)
        closeConfigurations(app)
    }

    /// 首頁配置 → 預設配置, named `name`, back on the home.
    @MainActor
    /// - Parameter template: `default` for 預設配置, `blank` for 空白模板.
    private func addConfiguration(_ app: XCUIApplication, _ name: String, template: String = "default") {
        openConfigurations(app)
        app.buttons["homeConfigurations.template.\(template)"].firstMatch.tap()
        let field = app.textFields["名稱"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.typeText(name)
        app.alerts.buttons["新增"].firstMatch.tap()
        // The new one is chosen, and the page stays.
        let row = configurationRow(app, name)
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(waitUntilSelected(row), app.debugDescription)
        closeConfigurations(app)
    }

    /// 精選書單's first list, a 專題集合 card (decision 37), so the home is drawn.
    private let featuredCard = "home.collection.gutenberg.chinese"
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

    /// 編輯首頁 and 完成 on the default home: the bar's ••• becomes 完成 and comes back, and the tab
    /// bar steps aside for the editor's ＋ while the home is edited (maintainer, 2026-10-17). Both
    /// open at the home's end, where 編輯首頁 and 完成 are (2026-10-17): the cards are taller than
    /// the rows, and the scroll view, left where it was, showed the editor's middle on the way in
    /// and, past the end of the shorter home, nothing at all on the way out.
    @MainActor
    func testEditingTheHomeSwitchesTheBarButton() {
        let app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let edit = app.buttons["home.edit"].firstMatch
        for _ in 0..<12 where !(edit.exists && edit.isHittable) { app.swipeUp() }
        edit.tap()
        let done = app.buttons["home.editDoneBar"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["explore.more"].exists, app.debugDescription)
        let tabBar = app.tabBars.firstMatch
        let tabBarGone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !tabBar.exists || !tabBar.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [tabBarGone], timeout: 5), .completed, app.debugDescription)
        // The editor's end with no scrolling: its 完成 above the ＋, and the bar's 完成 still there.
        let add = app.buttons["homeEditor.addSection"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        let editDone = app.buttons["home.editDone"].firstMatch
        XCTAssertTrue(showsAtTheEnd(editDone, above: { add.frame.minY }, app), "entering: \(app.debugDescription)")
        XCTAssertTrue(done.isHittable, app.debugDescription)
        attach(app, "home-editor-end")
        // A section's settings and the page they push keep it hidden, and so does the way back
        // (maintainer, 2026-10-17): each asks, as a page under another withdraws its request.
        let section = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeEditor.section.")).firstMatch
        for _ in 0..<12 where !(section.exists && section.isHittable) { app.swipeDown() }
        section.tap()
        let layout = app.buttons["homeSection.layout"].firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(tabBar.exists && tabBar.isHittable, "settings: \(app.debugDescription)")
        layout.tap()
        let layoutChoice = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeSection.layoutChoice.")).firstMatch
        XCTAssertTrue(layoutChoice.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(tabBar.exists && tabBar.isHittable, "layouts: \(app.debugDescription)")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(layout.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(tabBar.exists && tabBar.isHittable, "back to settings: \(app.debugDescription)")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(section.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(tabBar.exists && tabBar.isHittable, "back to the editor: \(app.debugDescription)")
        // The bar's 完成, from the editor's top: the home's end, its 編輯首頁 above the tab bar.
        done.tap()
        XCTAssertTrue(app.buttons["explore.more"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(tabBar.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(tabBar.isHittable, app.debugDescription)
        XCTAssertTrue(showsAtTheEnd(edit, above: { tabBar.frame.minY }, app), "the bar's 完成: \(app.debugDescription)")
        // The editor's own 完成, at its end, does the same.
        edit.tap()
        XCTAssertTrue(showsAtTheEnd(editDone, above: { add.frame.minY }, app), "entering again: \(app.debugDescription)")
        editDone.tap()
        XCTAssertTrue(showsAtTheEnd(edit, above: { tabBar.frame.minY }, app), "the editor's 完成: \(app.debugDescription)")
        attach(app, "home-after-editing")
    }

    /// `element` settles in the lower half of the window, all of it above `bottom` — the ＋'s or
    /// the tab bar's top. By its frame: an element scrolled under a bar still reads as hittable.
    @MainActor
    private func showsAtTheEnd(_ element: XCUIElement, above bottom: @escaping () -> CGFloat,
                               _ app: XCUIApplication) -> Bool {
        let window = app.windows.firstMatch
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists else { return false }
            let frame = element.frame
            return frame.minY >= window.frame.midY && frame.maxY <= bottom()
        }, object: nil)
        return XCTWaiter.wait(for: [settled], timeout: 5) == .completed
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

    /// 顯示在最新 (5d-3f), in 最新's own options since decision 36 and 數據來源's 最新來源 since
    /// search 9d: turned off for Gutenberg in 設定 → 聚合設定 → 最新來源, Gutenberg's 最新 is not
    /// asked for and its book is not on the home.
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
        // 數據來源 → 最新來源 (search 9d): the same switches 最新's own options show.
        let latest = app.buttons["aggregation.dataSources.latest"].firstMatch
        XCTAssertTrue(latest.waitForExistence(timeout: 5), app.debugDescription)
        latest.tap()
        let toggle = app.switches["aggregation.latest.gutenberg.\(gutenbergID)"].firstMatch
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

    /// 精選 (decision 37), in the design fixture's 繼續閱讀: a shelf copy's large card keeps the
    /// ••• 精簡閱讀卡片 has, inside the card and reachable on its own.
    @MainActor
    func testFeaturedCardMenu() {
        let app = application(extra: ["-explore-home-fixture"])
        app.launch()
        let mores = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.card.more.'"))
        XCTAssertTrue(mores.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.card.' AND NOT identifier BEGINSWITH 'home.card.more.'"))
        // 精選's card is the tall one; its ••• sits inside it.
        func featuredMore() -> XCUIElement? {
            let tall = cards.allElementsBoundByIndex.filter { $0.frame.height > 200 && $0.frame.width > app.frame.width * 0.6 }
            return mores.allElementsBoundByIndex.first { more in tall.contains { $0.frame.contains(more.frame) } }
        }
        var more = featuredMore()
        for _ in 0..<4 where more == nil {
            app.swipeUp()
            more = featuredMore()
        }
        XCTAssertNotNil(more, app.debugDescription)
        guard let found = more else { return }
        XCTAssertEqual(found.label, "更多")
        XCTAssertTrue(found.isHittable)
        attach(app, "home-featured-card")
        found.tap()
        XCTAssertTrue(app.buttons["從繼續閱讀移除"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "home-featured-card-menu")
    }

    /// 首頁配置's own button opens its page (maintainer, 2026-10-22; under ••• from decision 36):
    /// 預設配置 starts from 預設's sections; a tap switches and stays there, its check mark moving;
    /// 編輯 moves 預設 among the reader's own (2026-10-23), which a relaunch keeps; a swipe
    /// deletes the reader's own, after asking. There is no 空白 since 2026-10-23. ••• opens the
    /// browser (5d-1), always there, even for a reader who had hidden it before it lost its
    /// switch (maintainer, 2026-10-17).
    @MainActor
    func testConfigurationsAndTheBrowser() {
        var app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))

        // From 預設配置: the app's defaults.
        let name = "測試配置\(UUID().uuidString.prefix(4))"
        addConfiguration(app, name)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.staticTexts["這個首頁配置還沒有欄目"].exists, app.debugDescription)
        attach(app, "explore-configuration-from-defaults")

        // The page lists 預設 and the new one, checked, no built-in 空白, and the two templates;
        // a tap moves the check and stays.
        openConfigurations(app)
        let own = configurationRow(app, name)
        XCTAssertTrue(own.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(own.isSelected)
        XCTAssertFalse(app.buttons["homeConfigurations.row.blank"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["homeConfigurations.template.blank"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["homeConfigurations.template.default"].exists, app.debugDescription)
        attach(app, "explore-configurations-page")
        let defaults = configurationRow(app, "預設")
        defaults.tap()
        XCTAssertTrue(waitUntilSelected(defaults), app.debugDescription)
        XCTAssertFalse(own.isSelected)
        XCTAssertTrue(app.navigationBars["首頁配置"].exists, "a tap stays on the page")

        // 編輯: 預設 dragged by its reorder handle (the list's own button around the
        // line.horizontal.3 image) onto the lower half of the reader's own handle, inside that row.
        XCTAssertLessThan(defaults.frame.minY, own.frame.minY)
        app.navigationBars["首頁配置"].buttons["編輯"].tap()
        let handles = app.buttons.containing(.image, identifier: "line.horizontal.3")
        XCTAssertTrue(handles.element(boundBy: 1).waitForExistence(timeout: 5), app.debugDescription)
        handles.element(boundBy: 0).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.5, thenDragTo: handles.element(boundBy: 1).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        attach(app, "explore-configurations-moved")
        app.navigationBars["首頁配置"].buttons["完成"].tap()
        XCTAssertGreaterThan(configurationRow(app, "預設").frame.minY, configurationRow(app, name).frame.minY,
                             app.debugDescription)

        // The order is kept.
        app.terminate()
        app = application(reset: false)
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))
        openConfigurations(app)
        let ownAgain = configurationRow(app, name)
        XCTAssertTrue(ownAgain.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertGreaterThan(configurationRow(app, "預設").frame.minY, ownAgain.frame.minY, app.debugDescription)

        // Its swipe deletes it, after asking, and 預設 is chosen again.
        chooseOnPage(app, ownAgain)
        ownAgain.swipeLeft()
        let delete = app.buttons["刪除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "explore-configuration-swipe")
        delete.tap()
        XCTAssertTrue(app.staticTexts["刪除「\(name)」？"].waitForExistence(timeout: 5), app.debugDescription)
        // The dialog's, drawn over the row's.
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "刪除")).allElementsBoundByIndex.last { $0.isHittable }
        XCTAssertNotNil(confirm, app.debugDescription)
        confirm?.tap()
        XCTAssertTrue(ownAgain.waitForNonExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(waitUntilSelected(configurationRow(app, "預設")), app.debugDescription)
        closeConfigurations(app)
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

        // From 空白模板: no section, and the home says so.
        addConfiguration(app, "空白的", template: "blank")
        XCTAssertTrue(app.staticTexts["這個首頁配置還沒有欄目"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons[featuredCard].exists, app.debugDescription)
        attach(app, "explore-configuration-from-blank")

        // Hidden before 2026-10-17, with 編輯首頁's switch: there all the same.
        app.terminate()
        let hidden = application(extra: ["-explore.showsBrowser", "NO"])
        hidden.launch()
        openExplore(hidden)
        XCTAssertTrue(hidden.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))
        openMore(hidden)
        XCTAssertTrue(item(hidden, "瀏覽器").waitForExistence(timeout: 5), hidden.debugDescription)
    }

    /// Another 首頁配置 opens at the home's top (2026-10-23). Made from 預設配置 with the home
    /// scrolled to its end, the bar brought back, it stayed blank but for 編輯首頁, at that offset
    /// and any scrolled to, and so did 預設 picked again. The official modules' lists on, as on
    /// the maintainer's device: on the shorter home of the fixtures alone it drew.
    @MainActor
    func testConfigurationOpensAtTheTop() {
        let app = application(officialModules: true)
        app.launch()
        openExplore(app)
        let edit = app.buttons["home.edit"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 20), app.debugDescription)
        for _ in 0..<10 where !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.isHittable, app.debugDescription)
        app.swipeDown()
        let first = app.staticTexts["為你推薦"].firstMatch
        addConfiguration(app, "週末")
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "explore-configuration-opens-at-top")

        for _ in 0..<10 where !edit.isHittable { app.swipeUp() }
        app.swipeDown()
        chooseConfiguration(app, "預設")
        XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
    }

    /// ••• → 中繼資料語言偏好推薦 and ••• → 參與聚合的來源 push 聚合設定, and back is the home (decision
    /// 36); ••• → 重新整理 keeps the home drawn.
    @MainActor
    func testMoreOpensAggregationSettings() {
        let app = application()
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.buttons[featuredCard].firstMatch.waitForExistence(timeout: 15))
        for entry in ["中繼資料語言偏好推薦", "參與聚合的來源"] {
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
    /// on, the reader's own, renamed on its page from 首頁配置's 編輯; its ranking became a
    /// section, which 編輯首頁 shows. Its source is not on this device, so nothing loads.
    @MainActor
    func testCustomPageMovesIn() {
        let app = application(extra: ["-seed-custom-explore-page"])
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.staticTexts["探索還沒有內容"].waitForExistence(timeout: 15), app.debugDescription)
        openConfigurations(app)
        let moved = configurationRow(app, "週末書單")
        XCTAssertTrue(moved.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(moved.isSelected, app.debugDescription)
        attach(app, "explore-custom-page-moved-in")

        // 編輯: a tap opens its photo and name instead of switching.
        app.navigationBars["首頁配置"].buttons["編輯"].tap()
        XCTAssertTrue(moved.waitForExistence(timeout: 3), app.debugDescription)
        moved.tap()
        let field = app.textFields["homeConfigurationForm.name"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(field.value as? String, "週末書單")
        XCTAssertTrue(app.buttons["homeConfigurationForm.photo"].firstMatch.exists, app.debugDescription)
        attach(app, "explore-configuration-form")
        // Latin: CJK typed by XCUITest can submit on its own.
        field.tap()
        field.typeText(" 2")
        app.navigationBars["週末書單"].buttons.element(boundBy: 0).tap()
        let renamed = configurationRow(app, "週末書單 2")
        XCTAssertTrue(renamed.waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars["首頁配置"].buttons["完成"].tap()
        closeConfigurations(app)

        app.buttons["home.edit"].firstMatch.tap()
        XCTAssertTrue(app.buttons["homeEditor.section.5D4C0000-0000-4000-8000-000000000002"].firstMatch
            .waitForExistence(timeout: 5), app.debugDescription)
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
