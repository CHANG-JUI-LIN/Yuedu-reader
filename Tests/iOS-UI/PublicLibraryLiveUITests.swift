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
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-yd_source_disclaimer_accepted", "YES", "-book-source-store-dir", "/tmp/YueduPublicLibraries-manual-empty"]
        if pro { app.launchArguments += ["-debug-force-pro"] }
        app.launchEnvironment["CFNETWORK_DIAGNOSTICS"] = "3"
        app.launch()
        // The storefront's search and shelves went with its page (2026-10-22): the libraries'
        // books are found on 搜尋 and open 作品詳情.
        let tab = app.tabBars.buttons["搜尋"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        return app
    }

    /// A work of 搜尋's one list, by its title: the row's label starts with it.
    @MainActor
    private func searched(_ app: XCUIApplication, _ query: String, title: String) -> XCUIElement {
        let field = app.searchFields.firstMatch
        field.tap()
        // Typing CJK submits the search on its own; the newline covers Latin letters.
        field.typeText(query + "\n")
        return app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The first of 青空文庫's works on the home: 最新 takes its libraries in turn (LibraryOrderTests).
    @MainActor
    private func homeAozoraWork(_ app: XCUIApplication) -> XCUIElement {
        let latest = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "最新")).firstMatch
        for _ in 0..<8 where !(latest.exists && latest.isHittable) { app.swipeUp() }
        XCTAssertTrue(latest.exists, app.debugDescription)
        let work = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.card.aozora.")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 90), "青空文庫's works in 最新, once its catalog is read\n\(app.debugDescription)")
        return work
    }

    @MainActor
    func testGutenbergWithoutPro() throws {
        guard enabled("PUBLIC_LIBRARY_LIVE_UI") else { throw XCTSkip("Explicit live Gutenberg release check") }
        let app = launch(pro: false)
        screenshot(app, "nonpro-search-tab")
        let result = searched(app, "The Picture of Dorian Gray", title: "The Picture of Dorian Gray")
        XCTAssertTrue(result.waitForExistence(timeout: 45), app.debugDescription)
        screenshot(app, "nonpro-search")
        result.tap()
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
        screenshot(app, "pro-qitheme-search-tab")
        // 分類's 依作家 went with the storefront (2026-10-22); the work is found by 搜尋.
        let work = searched(app, "架空の物語", title: "架空の物語")
        XCTAssertTrue(work.waitForExistence(timeout: 30), app.debugDescription)
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
    /// even within the daily check, and 最新 then shows its works.
    @MainActor
    func testAozoraCatalogFromTheWebsite() throws {
        guard enabled("AOZORA_CATALOG_LIVE_UI") else { throw XCTSkip("Explicit live Aozora catalog check") }
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-reset-explore-home"]
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        XCTAssertTrue(app.buttons["explore.more"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        app.swipeDown()

        _ = homeAozoraWork(app)
        screenshot(app, "aozora-from-website")
    }

    /// 作品詳情's order (maintainer, 2026-10-12): the work's 分類 under the author open 依分類's
    /// list; 作品關聯 comes before 作品資訊, which ends the page and holds the bibliography (底本).
    @MainActor
    func testAozoraWorkDetailOrder() throws {
        guard enabled("AOZORA_CATALOG_LIVE_UI") else { throw XCTSkip("Explicit live Aozora catalog check") }
        // 青空文庫's card in 資源庫 opens no shelves since 2026-10-22: the work comes from 搜索.
        // 羅生門 has an NDC (a newly added work can have none yet, and then no 分類).
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-reset-explore-home"]
        app.launch()
        let tab = app.tabBars.buttons["搜尋"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10))
        let work = searched(app, "羅生門", title: "羅生門")
        XCTAssertTrue(work.waitForExistence(timeout: 90), app.debugDescription)
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
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-reset-explore-home",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let work = homeAozoraWork(app)
        screenshot(app, "aozora-home-latest")
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
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-reset-explore-home",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        homeAozoraWork(app).tap()

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

        // A later chapter, so landing there is not where 開始閱讀 would land anyway.
        openChapterAndSwipeBack(app, row: app.buttons["detail.toc.1"].exists ? 1 : 0, offShelf: offShelf, landsOnTitle: true)
        XCTAssertTrue(first.waitForExistence(timeout: 15), "back on 作品詳情 with its 目錄\n\(app.debugDescription)")
    }

    /// A Gutenberg book's 目錄 comes from its EPUB read in ranges, as reading does; the session
    /// it opened is released, and reading afterwards prepares the book again.
    @MainActor
    func testGutenbergWorkListsItsChapters() throws {
        guard enabled("PUBLIC_LIBRARY_LIVE_UI") else { throw XCTSkip("Explicit live Gutenberg release check") }
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-reset-explore-home",
                               "-yd_appearance_reader_interface", "classic",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        // The home's Gutenberg rows (古騰堡熱門, 精選): 範圍 left 探索 with decision 36.
        let work = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.card.gutenberg.")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 90), app.debugDescription)
        work.tap()

        let source = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 30), app.debugDescription)
        let offShelf = app.buttons["加入書架"].firstMatch.waitForExistence(timeout: 30)
        let first = app.buttons["detail.toc.0"].firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 120), "目錄 is read as the page opens\n\(app.debugDescription)")
        for _ in 0..<4 where !first.isHittable { app.swipeUp() }
        screenshot(app, "gutenberg-detail-toc")
        if offShelf { XCTAssertTrue(app.buttons["加入書架"].firstMatch.exists, "making the copy did not shelve it") }

        // Its chapters share spine files: an entry inside one opens at its #anchor, past the
        // file's first page, in either mode. The reader opens in the mode its theme keeps, so
        // each run sets it first, and the mode found is put back.
        XCTAssertTrue(app.buttons["detail.toc.2"].exists, "the work has a third 目錄 entry\n\(app.debugDescription)")
        var original: String?
        for mode in ["滑動", "捲動"] {
            let previous = setReaderMode(app, mode, offShelf: offShelf)
            if original == nil { original = previous }
            XCTAssertTrue(first.waitForExistence(timeout: 15), app.debugDescription)
            openChapterAndSwipeBack(app, row: 2, offShelf: offShelf, landsOnTitle: false, landsInsideItsFile: true)
            XCTAssertTrue(first.waitForExistence(timeout: 15), app.debugDescription)
        }
        if let original, original != "捲動" {
            _ = setReaderMode(app, original, offShelf: offShelf)
            XCTAssertTrue(first.waitForExistence(timeout: 15), app.debugDescription)
        }
        // The session 目錄 opened is gone; reading prepares the book again.
        for _ in 0..<4 where !app.buttons.matching(NSPredicate(format: "label BEGINSWITH '開始閱讀' OR label BEGINSWITH '繼續閱讀'")).firstMatch.isHittable {
            app.swipeDown()
        }
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '開始閱讀' OR label BEGINSWITH '繼續閱讀'")).firstMatch
        read.tap()
        showReaderControls(app, "read again")
        screenshot(app, "gutenberg-read-again")
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        if offShelf {
            let prompt = app.alerts.firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 10), app.debugDescription)
            prompt.buttons["不加入"].tap()
        }
        XCTAssertTrue(source.waitForExistence(timeout: 15), app.debugDescription)
    }

    /// Opens `row` of 目錄, checks the reader is at that chapter, and swipes back to the page,
    /// declining 「加入書架？」 for a copy off the shelf.
    @MainActor
    private func openChapterAndSwipeBack(_ app: XCUIApplication, row: Int, offShelf: Bool, landsOnTitle: Bool,
                                         landsInsideItsFile: Bool = false) {
        let entry = app.buttons["detail.toc.\(row)"].firstMatch
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
        let chapter = entry.label.trimmingCharacters(in: .whitespaces)
        entry.tap()
        showReaderControls(app, chapter)
        if landsInsideItsFile {
            // The controls' 「N/M · x%」: the entry's anchor is past its file's first page.
            let progress = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "^[0-9]+/[0-9]+ .*")).firstMatch
            let landed = XCTNSPredicateExpectation(predicate: NSPredicate { object, _ in
                guard let progress = object as? XCUIElement, progress.exists else { return false }
                return (Self.chapterPage(progress.label) ?? 0) > 1
            }, object: progress)
            XCTAssertEqual(XCTWaiter().wait(for: [landed], timeout: 60), .completed,
                           "「\(chapter)」 opens at its anchor, not its file's start: \(progress.exists ? progress.label : "no progress")")
        }
        if landsOnTitle, row > 0 {
            let text = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", chapter)).firstMatch
            XCTAssertTrue(text.waitForExistence(timeout: 30), "the reader opens at 「\(chapter)」\n\(app.debugDescription)")
        }
        screenshot(app, "reader-at-chapter-\(row)")
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        if offShelf {
            let prompt = app.alerts.firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 10), "the copy read is asked about\n\(app.debugDescription)")
            prompt.buttons["不加入"].tap()
        }
    }

    /// The chapter page in the reader controls' progress, 「N/M  ·  x%」.
    private static func chapterPage(_ label: String) -> Int? {
        guard let range = label.range(of: #"^\d+/"#, options: .regularExpression) else { return nil }
        return Int(label[range].filter(\.isNumber))
    }

    /// Waits for the reader a 作品詳情 tap pushed to load, and shows its controls. Paged mode
    /// draws its 頁尾 into the page, so the controls are what both modes expose.
    @MainActor
    private func showReaderControls(_ app: XCUIApplication, _ context: String) {
        XCTAssertTrue(app.descendants(matching: .any)["detail.info.source"].firstMatch.waitForNonExistence(timeout: 30),
                      "\(context)\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["載入中…"].firstMatch.waitForNonExistence(timeout: 90), "\(context)\n\(app.debugDescription)")
        let settings = app.buttons["reader_tool_settings"].firstMatch
        for _ in 0..<5 where !settings.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = settings.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(settings.exists, "\(context)\n\(app.debugDescription)")
    }

    /// Opens 目錄's third entry (the first two are a cover and a frontispiece, whose images a
    /// tap opens), sets the reader's 翻頁 to `mode` from its 設置 panel, and swipes back to the
    /// page. Returns the mode the reader had.
    @MainActor
    private func setReaderMode(_ app: XCUIApplication, _ mode: String, offShelf: Bool) -> String? {
        let entry = app.buttons["detail.toc.2"].firstMatch
        for _ in 0..<4 where !entry.isHittable { app.swipeUp() }
        entry.tap()
        showReaderControls(app, "set 翻頁 to \(mode)")
        app.buttons["reader_tool_settings"].firstMatch.tap()
        let turn = app.buttons["翻頁"].firstMatch
        XCTAssertTrue(turn.waitForExistence(timeout: 10), app.debugDescription)
        let previous = turn.value as? String
        if previous != mode {
            turn.tap()
            let option = app.buttons[mode].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
            option.tap()
            let set = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", mode), object: turn)
            XCTAssertEqual(XCTWaiter().wait(for: [set], timeout: 5), .completed, "翻頁 is \(mode)\n\(app.debugDescription)")
        }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        if !turn.waitForNonExistence(timeout: 3) {
            turn.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        XCTAssertTrue(turn.waitForNonExistence(timeout: 5), "the 設置 panel closes\n\(app.debugDescription)")
        screenshot(app, "reader-mode-\(mode)")
        let edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        if offShelf {
            let prompt = app.alerts.firstMatch
            XCTAssertTrue(prompt.waitForExistence(timeout: 10), app.debugDescription)
            prompt.buttons["不加入"].tap()
        }
        return previous
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
