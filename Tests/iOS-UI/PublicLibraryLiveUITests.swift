import XCTest

/// Explicit release checks. Normal test runs stay offline; each opt-in is run
/// separately so the real theme import can happen between the two checks.
final class PublicLibraryLiveUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func enabled(_ key: String) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment[key] == "1" || environment["TEST_RUNNER_" + key] == "1"
    }

    @MainActor
    private func launch(pro: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-yd_source_disclaimer_accepted", "YES", "-book-source-store-dir", "/tmp/YueduPublicLibraries-manual-empty"]
        if pro { app.launchArguments += ["-debug-force-pro"] }
        app.launchEnvironment["CFNETWORK_DIAGNOSTICS"] = "3"
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        XCTAssertTrue(app.buttons["publicLibrary.featured.chinese"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testGutenbergWithoutPro() throws {
        guard enabled("PUBLIC_LIBRARY_LIVE_UI") else { throw XCTSkip("Explicit live Gutenberg release check") }
        let app = launch(pro: false)
        screenshot(app, "nonpro-home")
        let query = app.searchFields["搜尋公有書庫"].firstMatch
        query.tap()
        query.typeText("The Picture of Dorian Gray\n")
        let result = app.buttons["publicLibrary.book.gutenberg:https://www.gutenberg.org/ebooks/174.opds"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 45), app.debugDescription)
        screenshot(app, "nonpro-search")
        result.tap()
        XCTAssertTrue(app.buttons["publicLibrary.closeSheet"].firstMatch.waitForExistence(timeout: 45), app.debugDescription)
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["開始閱讀", "繼續閱讀"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(read.isEnabled)
        let alreadyShelved = app.buttons["已加入書架"].firstMatch.exists
        XCTAssertTrue(alreadyShelved || app.buttons["加入書架"].firstMatch.isEnabled)
        print("Existing state: shelved=\(alreadyShelved)")
        screenshot(app, "nonpro-detail")
        read.tap()
        // The hero also says Project Gutenberg. Wait for the actual book text,
        // so a still-running range request cannot be mistaken for reader readiness.
        let footer = app.otherElements["頁尾"].firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertTrue(app.buttons["publicLibrary.closeSheet"].firstMatch.waitForNonExistence(timeout: 10))
        // This edition begins with an image-only cover. Scroll into its text.
        let content = app.collectionViews.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "(?s).{101,}")).firstMatch
        for _ in 0..<4 where !content.exists { app.swipeUp() }
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        screenshot(app, "nonpro-remote-reader")
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let inward = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: inward)
        let add = app.buttons["加入書架"].firstMatch
        if !alreadyShelved {
            XCTAssertTrue(add.waitForExistence(timeout: 10))
            add.tap()
        }
        XCTAssertTrue(app.buttons["已加入書架"].firstMatch.waitForExistence(timeout: 10))
        screenshot(app, "nonpro-shelved")
    }

    @MainActor
    func testAozoraFixtureWithImportedThemeAndPro() throws {
        guard enabled("PUBLIC_LIBRARY_THEME_UI") else { throw XCTSkip("Requires the supplied qitheme and catalog fixture") }
        let app = launch(pro: true)
        screenshot(app, "pro-qitheme-library-home")
        app.buttons["publicLibrary.categories"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["青空文庫"].firstMatch.waitForExistence(timeout: 10))
        let authors = app.buttons["依作家"].firstMatch
        XCTAssertTrue(authors.exists)
        authors.tap()
        let author = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "架空 一郎")).firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10))
        screenshot(app, "pro-qitheme-aozora-authors")
        author.tap()
        let work = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "架空の物語")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        work.tap()
        XCTAssertTrue(app.buttons["加入書架"].firstMatch.waitForExistence(timeout: 10))
        // A lazy carousel can expose offscreen children to accessibility. Check
        // the selected edition's unique credit is actually on the visible page.
        let translator = app.buttons["publicLibrary.author.002翻訳者"].firstMatch
        XCTAssertTrue(translator.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(translator.frame.midX, app.frame.minX)
        XCTAssertLessThan(translator.frame.midX, app.frame.maxX)
        screenshot(app, "pro-qitheme-aozora-detail")
    }

    /// The catalog published on yuedureader.com (2026-10-11): pulling the home down fetches it
    /// even within the daily check, and 範圍 → 青空文庫 then shows its works.
    @MainActor
    func testAozoraCatalogFromTheWebsite() throws {
        guard enabled("AOZORA_CATALOG_LIVE_UI") else { throw XCTSkip("Explicit live Aozora catalog check") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-reset-explore-home"]
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let menu = app.buttons["explore.scopeMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), app.debugDescription)
        app.swipeDown()

        menu.tap()
        let aozora = app.buttons["青空文庫"].firstMatch
        XCTAssertTrue(aozora.waitForExistence(timeout: 5), app.debugDescription)
        aozora.tap()
        // 範圍 shows 青空文庫's own sections (decision 35): 新上架作品's covers, once the catalog is read.
        let cover = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.card.aozora.")).firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 90), app.debugDescription)
        XCTAssertTrue(app.buttons["新上架作品"].firstMatch.exists, app.debugDescription)
        screenshot(app, "aozora-from-website")

        menu.tap()
        app.buttons["全部"].firstMatch.tap()
    }

    /// 作品詳情's order (maintainer, 2026-10-12): the work's 分類 under the author open 依分類's
    /// list; 作品關聯 comes before 作品資訊, which ends the page and holds the bibliography (底本).
    @MainActor
    func testAozoraWorkDetailOrder() throws {
        guard enabled("AOZORA_CATALOG_LIVE_UI") else { throw XCTSkip("Explicit live Aozora catalog check") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-reset-explore-home"]
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let menu = app.buttons["explore.scopeMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), app.debugDescription)
        menu.tap()
        let aozora = app.buttons["青空文庫"].firstMatch
        XCTAssertTrue(aozora.waitForExistence(timeout: 5), app.debugDescription)
        aozora.tap()
        // A work from 依分類's 小說・故事: a newly added work can have no NDC yet, and then no 分類.
        let byCategory = app.buttons["依分類"].firstMatch
        XCTAssertTrue(byCategory.waitForExistence(timeout: 90), app.debugDescription)
        byCategory.tap()
        XCTAssertTrue(app.staticTexts["小說・故事"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        let work = app.collectionViews.buttons.firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 10), app.debugDescription)
        work.tap()

        let classification = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "detail.link.classification.")).firstMatch
        XCTAssertTrue(classification.waitForExistence(timeout: 15), app.debugDescription)
        let name = classification.label
        screenshot(app, "aozora-detail-top")

        // The end of the page: 作者其他作品 above 作品資訊, which holds 底本.
        let basis = app.descendants(matching: .any)["detail.info.basis"].firstMatch
        for _ in 0..<6 where !(basis.exists && basis.isHittable) { app.swipeUp() }
        XCTAssertTrue(basis.waitForExistence(timeout: 10), app.debugDescription)
        let other = app.descendants(matching: .any)["detail.authorWorks.book"].firstMatch
        if other.exists {
            XCTAssertLessThan(other.frame.maxY, basis.frame.minY, "作品資訊 comes after 作者其他作品")
        }
        screenshot(app, "aozora-detail-bottom")

        // The 分類 opens its works.
        for _ in 0..<6 where !classification.isHittable { app.swipeDown() }
        classification.tap()
        XCTAssertTrue(app.navigationBars[name].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        screenshot(app, "aozora-classification-page")
    }

    /// 2026-10-12: back from reading a 青空文庫 work, its 作品詳情 listed the copy the reading
    /// made as 「書架」 and lost the work's details. The work stands for its copy now.
    /// 2026-10-13: reading no longer puts the work on the shelf; back from the reader — here by
    /// a swipe — the page asks 「加入書架？」: 不加入 leaves it off the shelf, 加入書架 adds it.
    @MainActor
    func testAozoraWorkKeepsItsPageAfterReading() throws {
        guard enabled("AOZORA_CATALOG_LIVE_UI") else { throw XCTSkip("Explicit live Aozora catalog check") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-reset-explore-home",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let menu = app.buttons["explore.scopeMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), app.debugDescription)
        menu.tap()
        let aozora = app.buttons["青空文庫"].firstMatch
        XCTAssertTrue(aozora.waitForExistence(timeout: 5), app.debugDescription)
        aozora.tap()
        // 青空文庫's own sections (decision 35) → 新上架作品's first work.
        let work = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.card.aozora.")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 90), app.debugDescription)
        screenshot(app, "aozora-scope-page")
        let title = String(work.label.split(whereSeparator: { "，、,".contains($0) }).first ?? "")
        // A run before this one may have added it: start with it off the shelf.
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        shelfTab.tap()
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        if cell.waitForExistence(timeout: 5) {
            openShelfMenu(app, cell)
            let delete = app.buttons["刪除書籍"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
            delete.tap()
            let confirm = app.alerts.buttons["刪除"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
            confirm.tap()
            XCTAssertTrue(cell.waitForNonExistence(timeout: 10))
        }
        tab.tap()
        XCTAssertTrue(work.waitForExistence(timeout: 15), app.debugDescription)
        work.tap()

        let source = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 15), app.debugDescription)
        let add = app.buttons["加入書架"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)

        // 不加入: still off the shelf, and the page says so.
        readAndSwipeBack(app)
        let prompt = app.alerts["將「\(title)」加入書架？"].firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), "a swipe back asks\n\(app.debugDescription)")
        screenshot(app, "aozora-shelve-prompt")
        prompt.buttons["不加入"].tap()
        XCTAssertTrue(source.waitForExistence(timeout: 15), "The reader closes onto 作品詳情.\n\(app.debugDescription)")
        XCTAssertNotEqual(source.value as? String, "書架", "The work, not its copy, is the version shown")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '繼續閱讀'")).firstMatch.waitForExistence(timeout: 10),
                      "the copy read keeps its place\n\(app.debugDescription)")
        XCTAssertTrue(add.exists, "not added\n\(app.debugDescription)")

        // 加入書架: on the shelf.
        readAndSwipeBack(app)
        XCTAssertTrue(prompt.waitForExistence(timeout: 10), app.debugDescription)
        prompt.buttons["加入書架"].tap()
        XCTAssertTrue(app.buttons["已加入書架"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        screenshot(app, "aozora-detail-after-reading")

        // From 書架, the same page: the copy is the work's (2026-10-12: it showed 來源 書架 alone).
        app.terminate()
        app.launch()
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 15), "\(title)\n\(app.debugDescription)")
        openShelfMenu(app, cell)
        let detailItem = app.buttons["作品詳情"].firstMatch
        XCTAssertTrue(detailItem.waitForExistence(timeout: 5), app.debugDescription)
        detailItem.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 15), app.debugDescription)
        let named = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "青空文庫"), object: source)
        XCTAssertEqual(XCTWaiter.wait(for: [named], timeout: 30), .completed, app.debugDescription)
        let basis = app.descendants(matching: .any)["detail.info.basis"].firstMatch
        for _ in 0..<6 where !basis.exists { app.swipeUp() }
        XCTAssertTrue(basis.waitForExistence(timeout: 10), "the work's bibliography\n\(app.debugDescription)")
        screenshot(app, "aozora-detail-from-shelf")
    }

    /// 2026-10-13: 作品詳情 reads a work's 目錄 as it opens, as a book source's page lists its
    /// chapters: the first few under 簡介, all of them under 查看全部, each opening the reader there.
    @MainActor
    func testAozoraWorkListsItsChapters() throws {
        guard enabled("AOZORA_CATALOG_LIVE_UI") else { throw XCTSkip("Explicit live Aozora catalog check") }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-reset-explore-home",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let menu = app.buttons["explore.scopeMenu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 15), app.debugDescription)
        menu.tap()
        let aozora = app.buttons["青空文庫"].firstMatch
        XCTAssertTrue(aozora.waitForExistence(timeout: 5), app.debugDescription)
        aozora.tap()
        let work = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.card.aozora.")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 90), app.debugDescription)
        work.tap()

        let source = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 15), app.debugDescription)
        let offShelf = app.buttons["加入書架"].firstMatch.waitForExistence(timeout: 10)
        let first = app.buttons["detail.toc.0"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 60), "目錄 is read as the page opens\n\(app.debugDescription)")
        for _ in 0..<4 where !first.isHittable { app.swipeUp() }
        XCTAssertTrue(first.isHittable, app.debugDescription)
        screenshot(app, "aozora-detail-toc")
        // Read ahead of reading, the copy is not one that was read.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '開始閱讀' OR label BEGINSWITH '繼續閱讀'")).firstMatch.exists)
        if offShelf { XCTAssertTrue(app.buttons["加入書架"].firstMatch.exists, "making the copy did not shelve it") }

        let all = app.buttons["查看全部"].firstMatch
        if all.exists, all.isHittable {
            all.tap()
            XCTAssertTrue(app.navigationBars["目錄"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            screenshot(app, "aozora-toc-sheet")
            app.navigationBars["目錄"].buttons["關閉"].firstMatch.tap()
            XCTAssertTrue(first.waitForExistence(timeout: 10), app.debugDescription)
        }

        let chapter = first.label
        first.tap()
        XCTAssertTrue(app.otherElements["頁尾"].firstMatch.waitForExistence(timeout: 90), "\(chapter)\n\(app.debugDescription)")
        screenshot(app, "aozora-reader-at-chapter")
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        if offShelf {
            let prompt = app.alerts.firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 10), "the copy read is asked about\n\(app.debugDescription)")
            prompt.buttons["不加入"].tap()
        }
        XCTAssertTrue(first.waitForExistence(timeout: 15), "back on 作品詳情 with its 目錄\n\(app.debugDescription)")
    }

    @MainActor
    private func readAndSwipeBack(_ app: XCUIApplication) {
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '開始閱讀' OR label BEGINSWITH '繼續閱讀'")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 30), app.debugDescription)
        read.tap()
        let footer = app.otherElements["頁尾"].firstMatch
        XCTAssertTrue(footer.waitForExistence(timeout: 90), app.debugDescription)
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
    }

    /// A shelf cell's •••, in the grid and the list alike.
    @MainActor
    private func openShelfMenu(_ app: XCUIApplication, _ cell: XCUIElement) {
        let more = cell.buttons["更多"].firstMatch
        if more.exists { more.tap() } else { cell.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.96)).tap() }
    }
}
