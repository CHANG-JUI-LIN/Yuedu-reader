import XCTest

/// 資源庫 (Phase 5 plan, decisions 30 and 31; 5h): the tab between 探索 and 搜尋, its card saying
/// what moved there, and each of its rows opening the page it names.
final class LibraryTabUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               // The card shows until it is closed: shown again for this run.
                               "-reset-library-notice"] + extra
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

    /// A card far down the page: the grid builds its cards only near the screen.
    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        var swipes = 0
        while !element.exists, swipes < 6 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            swipes += 1
        }
        return element
    }

    /// An item of the open •••: the iOS 17 chooser's row also reads its subtitle after the title.
    private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
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

        let rss = scrolledTo(app.buttons["library.rss"].firstMatch, in: app)
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

    /// Laid out as the old 探索 root was: 格狀 puts two tiles side by side, the list stacks
    /// them as cards, from that page's stored keys.
    @MainActor
    func testGridAndList() {
        let grid = launch(["-explore.showsGrid", "YES", "-explore.gridColumnCount", "2"])
        let gutenberg = grid.buttons["library.public.builtin.gutenberg"].firstMatch
        let aozora = grid.buttons["library.public.builtin.aozora"].firstMatch
        XCTAssertTrue(aozora.waitForExistence(timeout: 5), grid.debugDescription)
        XCTAssertEqual(gutenberg.frame.minY, aozora.frame.minY, accuracy: 1)
        XCTAssertLessThan(gutenberg.frame.maxX, aozora.frame.minX)
        attach(grid, "library-grid")

        // The page's one menu holds 格狀 and 每列欄數; iOS 17's chooser, 格狀 and each column count.
        grid.buttons["library.more"].firstMatch.tap()
        XCTAssertTrue(item(grid, "格狀").waitForExistence(timeout: 5), grid.debugDescription)
        if #available(iOS 18, *) {
            XCTAssertTrue(grid.buttons["每列欄數"].firstMatch.exists, grid.debugDescription)
        } else {
            XCTAssertTrue(item(grid, "3 欄").exists, grid.debugDescription)
        }
        grid.terminate()

        let list = launch(["-explore.showsGrid", "NO"])
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
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryTabUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sources: [[String: Any]] = [("男频書源甲", "男频"), ("男频書源乙", "男频"), ("女频書源", "女频")].enumerated()
            .map { index, entry in
                [
                    "bookSourceName": entry.0,
                    "bookSourceGroup": entry.1,
                    "bookSourceUrl": "https://library-ui-test-\(index).example",
                    "exploreUrl": "熱門::https://library-ui-test-\(index).example/hot",
                    "enabled": true,
                    "enabledExplore": true,
                ]
            }
        try JSONSerialization.data(withJSONObject: sources)
            .write(to: directory.appendingPathComponent("book_sources.json"))

        let app = launch(["-book-source-store-dir", directory.path,
                          "-explore.showsGrid", "YES", "-explore.gridColumnCount", "2"])
        let all = app.buttons["library.sources.all"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(all.value as? String, "3 個來源配置")
        let male = app.buttons["library.group.男频"].firstMatch
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

    /// The ••• (decision 31): 新增來源配置 opens the same import as 來源配置管理's 「+」, and
    /// 管理來源配置 pushes 來源配置管理. On iOS 17 both are rows of a chooser.
    @MainActor
    func testMoreMenu() {
        let app = launch()
        let more = app.buttons["library.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        if #available(iOS 18, *) {
            let add = app.buttons["新增來源配置"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(app.buttons["管理來源配置"].firstMatch.exists, app.debugDescription)
            attach(app, "library-more-menu")
            add.tap()
        }
        let network = item(app, "網路匯入")
        XCTAssertTrue(network.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(item(app, "手動新增").exists && item(app, "本機匯入").exists, app.debugDescription)
        attach(app, "library-more-add")
        network.tap()
        XCTAssertTrue(app.navigationBars["網路匯入"].waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "library-more-network-import")
        app.navigationBars["網路匯入"].buttons["關閉"].tap()
        XCTAssertFalse(app.navigationBars["網路匯入"].waitForExistence(timeout: 2), app.debugDescription)

        more.tap()
        let manage = item(app, "管理來源配置")
        XCTAssertTrue(manage.waitForExistence(timeout: 5), app.debugDescription)
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
