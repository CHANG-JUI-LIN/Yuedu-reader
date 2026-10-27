import StoreKitTest
import XCTest

/// 資源庫 (Phase 5 plan, decisions 30 and 31; 5h): the tab between 探索 and 設定, its card saying
/// sources are listed here and added in 設定, and each of its rows opening the page it names.
final class LibraryTabUITests: XCTestCase {
    /// iOS 17.5 asks for an Apple ID as the app reads StoreKit, over every page, unless a test
    /// session answers it (`StoreKitTestSessions`): the ••• is checked there too.
    private var storeKitSession: SKTestSession?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// A source library in a scratch directory, for `-book-source-store-dir`: the simulator's own
    /// sources are never touched, and 來源配置 shows only once one has a discover page. Each entry
    /// is a name and its group; `discovers` gives each a discover page.
    private func sourceDirectory(_ entries: [(name: String, group: String)], discovers: Bool = true) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTabUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sources: [[String: Any]] = entries.enumerated().map { index, entry in
            var source: [String: Any] = [
                "bookSourceName": entry.name,
                "bookSourceGroup": entry.group,
                "bookSourceUrl": "https://library-ui-test-\(index).example",
                "enabled": true,
            ]
            if discovers {
                source["exploreUrl"] = "熱門::https://library-ui-test-\(index).example/hot"
                source["enabledExplore"] = true
            }
            return source
        }
        try JSONSerialization.data(withJSONObject: sources)
            .write(to: directory.appendingPathComponent("book_sources.json"))
        return directory
    }

    @MainActor
    private func launch(_ extra: [String] = []) throws -> XCUIApplication {
        storeKitSession = try StoreKitTestSessions.fresh(StoreKitTestSessions.yueduPro())
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               // The card shows until it is closed: shown again for this run.
                               "-reset-library-notice"] + extra
        app.launch()
        let tab = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A card or row far down the page, scrolled until it sits whole above the tab bar: the grid
    /// and a module page's form build their rows only near the screen, and a card built below
    /// the screen or under the tab bar exists without being where a tap lands. A module page is
    /// a `Form`, a collection view rather than a scroll view: pass it as `container`.
    @MainActor
    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication,
                            scrolling container: XCUIElement? = nil) -> XCUIElement {
        let container = container ?? app.scrollViews.firstMatch
        let tabBar = app.tabBars.firstMatch
        let bottom = tabBar.exists ? tabBar.frame.minY : app.frame.maxY
        var swipes = 0
        while !(element.exists && element.frame.maxY <= bottom), swipes < 6 {
            container.swipeUp(velocity: .slow)
            swipes += 1
        }
        return element
    }

    /// An item of an open menu, or a row of an iOS 17 chooser (來源配置管理's 「+」), which also reads
    /// its subtitle after the title.
    @MainActor
    private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    @MainActor
    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// A pushed page goes back with a swipe from the screen's leading edge, as every pushed page
    /// does, and the tab bar it hid comes back. It once went back only with the bar's back
    /// button, while the card reader's driver held the stack's delegate (maintainer, 2026-10-16).
    @MainActor
    func testPushedPageSwipesBack() throws {
        let app = try launch()
        let more = app.buttons["library.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
        more.tap()
        let manage = item(app, "管理來源配置")
        XCTAssertTrue(manage.waitForExistence(timeout: 5), app.debugDescription)
        manage.tap()
        let page = app.navigationBars["來源配置管理"]
        XCTAssertTrue(page.waitForExistence(timeout: 5), app.debugDescription)

        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))

        XCTAssertTrue(app.tabBars.buttons["資源庫"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(page.exists, app.debugDescription)
    }

    @MainActor
    func testTabsAndRows() throws {
        let directory = try sourceDirectory([("介面測試來源", "測試")])
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try launch(["-book-source-store-dir", directory.path])
        // 探索・書架・資源庫・設定・搜尋, and no RSS tab (decision 30; 搜尋 last since 2026-10-16,
        // 探索 first since 2026-10-25).
        let names = app.tabBars.buttons.allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(names, ["探索", "書架", "資源庫", "設定", "搜尋"])

        let close = app.buttons["library.noticeClose"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(close.label, "關閉")
        XCTAssertTrue(app.staticTexts["所有來源都在這裡"].exists)
        attach(app, "library-tab")
        close.tap()
        XCTAssertFalse(app.staticTexts["所有來源都在這裡"].waitForExistence(timeout: 2))

        // The rows are visited top to bottom, as the page lists them. A row the page has scrolled
        // past sits under the status bar, where XCUITest still counts it as hittable and does not
        // scroll it back, so the tap lands on the status bar and opens nothing: 遠端書庫, visited
        // after 訂閱 and 來源配置, failed that way (2026-10-16).

        // 古騰堡 and 青空文庫 open what they offer, as an official module's card does: no shelves
        // to browse (maintainer, 2026-10-22).
        let gutenberg = app.buttons["library.public.builtin.gutenberg"].firstMatch
        XCTAssertTrue(gutenberg.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.staticTexts["公有書庫"].exists, "no 公有書庫 group: the libraries are 官方模組 (M2b)")
        gutenberg.tap()
        XCTAssertTrue(app.navigationBars["Project Gutenberg"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["publicLibrary.categories"].exists, "瀏覽所有分類 was the shelves' page")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.card.")).firstMatch.exists,
                       "no books on an official module's page")
        attach(app, "library-gutenberg")
        // 會連線的網站 comes after the lists the module offers, below the screen.
        let gutenbergHost = scrolledTo(app.staticTexts["www.gutenberg.org"].firstMatch, in: app,
                                       scrolling: app.collectionViews.firstMatch)
        XCTAssertTrue(gutenbergHost.waitForExistence(timeout: 5), app.debugDescription)
        back(app)

        let aozora = app.buttons["library.public.builtin.aozora"].firstMatch
        XCTAssertTrue(aozora.waitForExistence(timeout: 5), app.debugDescription)
        aozora.tap()
        XCTAssertTrue(app.navigationBars["青空文庫"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["依分類"].exists, "依分類 is a 首頁 list, not a page here")
        attach(app, "library-aozora")
        let aozoraHost = scrolledTo(app.staticTexts["www.aozora.gr.jp"].firstMatch, in: app,
                                    scrolling: app.collectionViews.firstMatch)
        XCTAssertTrue(aozoraHost.waitForExistence(timeout: 5), app.debugDescription)
        back(app)

        let sources = app.buttons["library.sources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 5), app.debugDescription)
        sources.tap()
        XCTAssertTrue(app.navigationBars["來源配置管理"].waitForExistence(timeout: 5), app.debugDescription)
        back(app)

        let rss = scrolledTo(app.buttons["library.rss"].firstMatch, in: app)
        XCTAssertTrue(rss.waitForExistence(timeout: 5), app.debugDescription)
        rss.tap()
        XCTAssertTrue(app.navigationBars["RSS 訂閱"].waitForExistence(timeout: 5), app.debugDescription)
        back(app)

        // Adding a source is 設定's (maintainer, 2026-10-27): 來源配置管理 and 遠端書庫 are its
        // rows, beside 模組. 遠端書庫 is no card here while nothing is connected.
        app.tabBars.buttons["設定"].firstMatch.tap()
        let remote = app.buttons["settings_remote_libraries"].firstMatch
        XCTAssertTrue(remote.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["settings_sources"].exists && app.buttons["settings_modules"].exists,
                      app.debugDescription)
        attach(app, "settings-sources")
        remote.tap()
        XCTAssertTrue(app.navigationBars["遠端書庫"].waitForExistence(timeout: 5), app.debugDescription)
        back(app)
        app.buttons["settings_sources"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["來源配置管理"].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// RSS 訂閱, the page's last card, as a reader who has closed 所有來源都在這裡 finds it. With
    /// the card closed its section's lazy grid was an empty, zero-sized node in VoiceOver's tree
    /// and in XCUITest's, so VoiceOver never reached it and a test could tap it only where it
    /// was drawn (2026-10-26, iOS 27). `testTabsAndRows` closes the card mid-run and missed it.
    @MainActor
    func testSubscriptionsWithTheNoticeClosed() throws {
        let app = try launch(["-library.tabNoticeDismissed", "YES"])
        let rss = scrolledTo(app.buttons["library.rss"].firstMatch, in: app)
        XCTAssertTrue(rss.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(rss.label, "RSS 訂閱")
        attach(app, "library-subscriptions")
        rss.tap()
        XCTAssertTrue(app.navigationBars["RSS 訂閱"].waitForExistence(timeout: 5), app.debugDescription)
    }

    /// Laid out as the old 探索 root was: 格狀 puts two tiles side by side, the list stacks
    /// them as cards, from that page's stored keys.
    @MainActor
    func testGridAndList() throws {
        let grid = try launch(["-explore.showsGrid", "YES", "-explore.gridColumnCount", "2"])
        // 模組 (M2b): AI 推薦, then 古騰堡 beside it, then 青空文庫 on the next row.
        let recommendations = grid.buttons["library.module.official.aiRecommendations"].firstMatch
        let gutenberg = grid.buttons["library.public.builtin.gutenberg"].firstMatch
        let aozora = grid.buttons["library.public.builtin.aozora"].firstMatch
        XCTAssertTrue(aozora.waitForExistence(timeout: 5), grid.debugDescription)
        XCTAssertEqual(recommendations.frame.minY, gutenberg.frame.minY, accuracy: 1)
        XCTAssertLessThan(recommendations.frame.maxX, gutenberg.frame.minX)
        XCTAssertGreaterThan(aozora.frame.minY, gutenberg.frame.maxY - 1)
        attach(grid, "library-grid")

        // The page's one menu holds 格狀 and 每列欄數, a native menu on iOS 17 too.
        grid.buttons["library.more"].firstMatch.tap()
        XCTAssertTrue(item(grid, "格狀").waitForExistence(timeout: 5), grid.debugDescription)
        XCTAssertTrue(grid.buttons["每列欄數"].firstMatch.exists, grid.debugDescription)
        grid.terminate()

        let list = try launch(["-explore.showsGrid", "NO"])
        let listGutenberg = list.buttons["library.public.builtin.gutenberg"].firstMatch
        let listAozora = list.buttons["library.public.builtin.aozora"].firstMatch
        XCTAssertTrue(listAozora.waitForExistence(timeout: 5), list.debugDescription)
        XCTAssertLessThan(listGutenberg.frame.maxY, listAozora.frame.minY + 1)
        XCTAssertEqual(listGutenberg.frame.width, listAozora.frame.width, accuracy: 1)
        attach(list, "library-list")
    }

    /// 來源配置 (decision 31): 所有來源配置 and a card per group, never every source on the root;
    /// a group opens its sources; the search narrows the sources in place. The library is a
    /// fixture in a scratch directory, so the simulator's own sources are never touched.
    @MainActor
    func testSourcesByGroup() throws {
        let directory = try sourceDirectory([("男频書源甲", "男频"), ("男频書源乙", "男频"), ("女频書源", "女频")])
        defer { try? FileManager.default.removeItem(at: directory) }

        let app = try launch(["-book-source-store-dir", directory.path,
                          "-explore.showsGrid", "YES", "-explore.gridColumnCount", "2"])
        let all = app.buttons["library.sources.all"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(all.value as? String, "3 個來源配置")
        // 模組 and 遠端書庫 come first: the groups' second row is below the screen.
        let male = scrolledTo(app.buttons["library.group.男频"].firstMatch, in: app)
        XCTAssertTrue(male.exists, app.debugDescription)
        XCTAssertEqual(male.value as? String, "2 個來源配置")
        XCTAssertTrue(app.buttons["library.group.女频"].exists)
        // The sources themselves are not on the root.
        XCTAssertFalse(app.buttons["library.source.女频書源"].exists)
        attach(app, "library-sources")

        male.tap()
        XCTAssertTrue(app.navigationBars["男频"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["library.source.男频書源甲"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["library.source.男频書源乙"].exists)
        XCTAssertFalse(app.buttons["library.source.女频書源"].exists)
        attach(app, "library-group")
        back(app)

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), app.debugDescription)
        search.tap()
        search.typeText("女频")
        XCTAssertTrue(app.buttons["library.source.女频書源"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["library.source.男频書源甲"].exists)
        XCTAssertFalse(app.buttons["library.sources.all"].exists)
    }

    /// 來源配置 with no source that has a discover page: no section, not a card that leads to
    /// 來源配置管理 (maintainer, 2026-10-27). The ••• still manages them.
    @MainActor
    func testSourcesWithoutDiscoverHaveNoSection() throws {
        let directory = try sourceDirectory([("沒有發現頁的來源", "測試")], discovers: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try launch(["-book-source-store-dir", directory.path])
        // The page is drawn once 模組 is: AI 推薦 is always there.
        let modules = app.buttons["library.module.official.aiRecommendations"].firstMatch
        XCTAssertTrue(modules.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(scrolledTo(app.buttons["library.rss"].firstMatch, in: app).exists, app.debugDescription)
        XCTAssertFalse(app.buttons["library.sources"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["library.sources.all"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["來源配置"].exists, app.debugDescription)
        attach(app, "library-no-sources")
    }

    /// The ••• (decision 31): 管理來源配置 and the layout, a native menu on iOS 17 too. 新增來源配置
    /// and 新增模組 left it for 設定 (maintainer, 2026-10-27).
    @MainActor
    func testMoreMenu() throws {
        let app = try launch()
        let more = app.buttons["library.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        let manage = item(app, "管理來源配置")
        XCTAssertTrue(manage.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(item(app, "新增來源配置").exists || item(app, "手動新增").exists, app.debugDescription)
        XCTAssertFalse(item(app, "新增模組").exists || item(app, "從網址").exists, app.debugDescription)
        attach(app, "library-more-menu")
        manage.tap()
        XCTAssertTrue(app.navigationBars["來源配置管理"].waitForExistence(timeout: 5), app.debugDescription)

        // 來源配置管理's 「+」 opens the same flow.
        app.navigationBars["來源配置管理"].buttons["新增來源配置"].tap()
        let local = item(app, "本機匯入")
        XCTAssertTrue(local.waitForExistence(timeout: 5), app.debugDescription)
        local.tap()
        XCTAssertTrue(app.navigationBars["匯入來源配置"].waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "source-manager-local-import")
        app.navigationBars["匯入來源配置"].buttons["關閉"].tap()
        XCTAssertFalse(app.navigationBars["匯入來源配置"].waitForExistence(timeout: 2), app.debugDescription)
    }
}
