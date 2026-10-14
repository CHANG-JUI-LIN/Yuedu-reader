import XCTest
import StoreKitTest

/// Prepare with scripts/navigation_swipe_fixture.py and serve localhost:18765. Run `clean` then
/// `prepare` before each run of the suite: its manga tests add the fixture's manga to the shelf
/// and read on, and a shelf copy opens where it was left, not on page 1.
/// These tests deliver actual touches to the production Explore/detail/reader.
/// Every launch pins 探索 to its book sources (`-explore.mode sources`): a public-library UI
/// test run before these leaves its own mode saved on the simulator. A source's book is reached
/// from a section of Explore's home, which opens 作品詳情 (`openDiscoveredBook`).
/// Each test's first launch also empties the reading-settings stores (`-reset-reading-settings`):
/// the reader wears them over `-yd_scroll_mode` / `-yd_page_turn_style`, and a scroll-mode
/// test had left scroll mode there, so every paged test after it opened a scrolling reader.
final class DetailReaderBackSwipeUITests: XCTestCase {
    private var storeKitSession: SKTestSession?

    @MainActor
    private func configureStoreKit() throws {
        let configuration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Configuration/YueduPro.storekit")
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        storeKitSession = session
    }

    /// Each fixture source's one discover category (scripts/navigation_swipe_fixture.py).
    private static let categories = ["Navigation Swipe Fixture": "Navigation Test", "Navigation Manga Fixture": "Manga Test",
                                      "Navigation Audio Fixture": "Audio Test", "Navigation Bare Fixture": "Bare Test"]

    /// The fixture source's book from Explore's home, as a reader reaches a book source there now:
    /// 編輯首頁 → 新增欄目 → its discover category as a row (範圍 only filters the home since
    /// unified library 5d-3b, and the source's own catalog entry went with 瀏覽完整目錄); the
    /// row's card opens 作品詳情, which is the source's own page (5f-3).
    @MainActor
    private func openDiscoveredBook(_ app: XCUIApplication, named name: String) {
        guard let category = Self.categories[name] else { return XCTFail("No fixture category for \(name)") }
        // At the end of the home, drawn once scrolled to.
        XCTAssertTrue(app.buttons["explore.more"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let edit = app.buttons["home.edit"].firstMatch
        for _ in 0..<12 where !(edit.exists && edit.isHittable) { app.swipeUp() }
        XCTAssertTrue(edit.waitForExistence(timeout: 5), app.debugDescription)
        edit.tap()
        let add = app.buttons["homeEditor.addSection"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 where !add.isHittable { app.swipeUp() }
        add.tap()
        let layout = app.buttons["homeNewSection.layout.row"].firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 5), app.debugDescription)
        // Each layout is a row with its preview (decision 34).
        for _ in 0..<4 where !layout.isHittable { app.swipeUp() }
        layout.tap()
        let source = app.buttons["homeSection.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5), app.debugDescription)
        source.tap()
        let sources = app.buttons["homePicker.bookSources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 5), app.debugDescription)
        sources.tap()
        let sourceRow = app.buttons["homePicker.source.\(name)"].firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10), app.debugDescription)
        sourceRow.tap()
        let item = app.buttons["homePicker.item.\(category)"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), app.debugDescription)
        item.tap()
        let confirm = app.buttons["homeSection.add"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        let done = app.buttons["home.editDone"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        done.tap()
        // The new section's card, not the same book in 繼續閱讀 from an earlier test: the first
        // card under the section's title.
        // A text, or a button where the title opens 查看全部.
        let header = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'home.row.header.' AND label == %@", category)).firstMatch
        for _ in 0..<12 where !(header.exists && header.isHittable) { app.swipeUp() }
        XCTAssertTrue(header.waitForExistence(timeout: 5), app.debugDescription)
        let cards = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'home.card.bookSource.' AND label BEGINSWITH %@", name))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            cards.allElementsBoundByIndex.contains { $0.frame.minY > header.frame.maxY }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed, app.debugDescription)
        let card = cards.allElementsBoundByIndex
            .filter { $0.frame.minY > header.frame.maxY }
            .min { $0.frame.minY < $1.frame.minY }
        card?.tap()
    }

    /// The 搜索 tab finds the book across sources, and its result opens the detail. Explore's own
    /// search narrowed its source tiles, which left with them in unified library 5d-1.
    @MainActor
    private func openSearchedBook(_ app: XCUIApplication, query: String, named name: String) {
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15), app.debugDescription)
        searchTab.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        search.tap()
        search.typeText(query + "\n")
        // iOS 17 lists results in a UIKit table, later systems in a SwiftUI list.
        let result = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND (elementType == %d OR elementType == %d)",
                                  name, XCUIElement.ElementType.cell.rawValue,
                                  XCUIElement.ElementType.button.rawValue)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), app.debugDescription)
        result.tap()
    }

    @MainActor
    func testDetailReaderLoadsAndReturns() throws {
        try exerciseNativeEntry(fromSearch: false)
    }

    @MainActor
    func testSearchDetailReaderLoadsAndReturns() throws {
        try exerciseNativeEntry(fromSearch: true)
    }

    /// 作品詳情 · Editorial Minimalism: the book's genre is a link to the source's category of
    /// that name, and 同題材 shows that category's other books; both open a book's detail.
    @MainActor
    func testGenreLinkAndRelatedWorksOpenTheSourcesCategory() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings, search)"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Swipe Fixture")

        let genre = app.buttons["detail.link.Related"].firstMatch
        XCTAssertTrue(genre.waitForExistence(timeout: 15), app.debugDescription)
        attachScreenshot(app, named: "作品詳情 - genre link")
        genre.tap()
        let categoryTitle = app.navigationBars.staticTexts["Related"].firstMatch
        XCTAssertTrue(categoryTitle.waitForExistence(timeout: 15), app.debugDescription)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Navigation Related Fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        row.tap()
        // The related book's own page: only it has the related book's description.
        let relatedIntro = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reached from a genre")).firstMatch
        XCTAssertTrue(relatedIntro.waitForExistence(timeout: 15), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(categoryTitle.waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(genre.waitForExistence(timeout: 10), app.debugDescription)

        let header = app.staticTexts["More in This Genre"].firstMatch
        for _ in 0..<8 where !(header.exists && header.isHittable) { app.swipeUp() }
        XCTAssertTrue(header.waitForExistence(timeout: 15), app.debugDescription)
        attachScreenshot(app, named: "作品詳情 - 同題材")
        let cards = app.buttons.matching(identifier: "detail.related.book")
        let card = cards.matching(NSPredicate(format: "label CONTAINS %@", "Navigation Related Fixture")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(cards.count, 1, "同題材 must leave out the book on the page.\n\(app.debugDescription)")
        card.tap()
        XCTAssertTrue(relatedIntro.waitForExistence(timeout: 15), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
    }

    /// The audiobook detail page pushes a genre's category too, and comes back to itself: its
    /// dismissal is the stable `presentationMode`, never iOS 17's ever-replaced DismissAction.
    @MainActor
    func testAudiobookGenreLinkOpensTheSourcesCategory() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings, search)"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Audio Fixture")

        let genre = app.buttons["detail.link.Related"].firstMatch
        XCTAssertTrue(genre.waitForExistence(timeout: 15), app.debugDescription)
        attachScreenshot(app, named: "有聲書詳情 - genre link")
        genre.tap()
        let categoryTitle = app.navigationBars.staticTexts["Related"].firstMatch
        XCTAssertTrue(categoryTitle.waitForExistence(timeout: 15), app.debugDescription)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Navigation Related Fixture")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(genre.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(categoryTitle.exists, app.debugDescription)
    }

    /// The detail page's design baseline (Editorial Minimalism, 2026-10-12): a book with only a
    /// title, an author and its chapters looks finished. Nothing waits to appear — no section
    /// header over a spinner, no 簡介 — and the actions are 方案 A's: a text-only reading capsule
    /// and 加入書架 as plain text beside it. Run in light, in dark and with Pro and a theme pack.
    @MainActor
    func testBareBookDetailLooksFinished() throws {
        try exerciseBareBook(pro: false)
    }

    @MainActor
    func testBareBookDetailLooksFinishedWithPro() throws {
        try exerciseBareBook(pro: true)
    }

    @MainActor
    private func exerciseBareBook(pro: Bool) throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(zh-Hant)",
                               "-AppleLocale", "zh_TW", "-yd_root_tab_visible_ids", "(explore, settings)"]
        if pro { app.launchArguments.append("-debug-force-pro") }
        app.launch()
        // A theme pack brings its own tab bar, which can open on 書架.
        let explore = app.tabBars.buttons["探索"].firstMatch
        if explore.waitForExistence(timeout: 10), !explore.isSelected { explore.tap() }
        openDiscoveredBook(app, named: "Navigation Bare Fixture")
        let read = app.buttons["立即閱讀"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        let add = app.buttons["加入書架"].firstMatch
        XCTAssertTrue(add.exists, app.debugDescription)
        XCTAssertEqual(abs(add.frame.midY - read.frame.midY) < 2, true, "One row: \(read.frame) \(add.frame)")
        XCTAssertTrue(app.descendants(matching: .any)["detail.info.chapters"].firstMatch.waitForExistence(timeout: 15),
                      app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["detail.facts"].exists, "Chapters and source are in 作品資訊 only")
        XCTAssertFalse(app.staticTexts["同題材作品"].exists, app.debugDescription)
        XCTAssertFalse(app.staticTexts["簡介"].exists, app.debugDescription)
        attachScreenshot(app, named: pro ? "最少資料 - Pro" : "最少資料")
    }

    /// 繼續閱讀 carries where reading resumes (方案 A, 2026-10-12): after reading chapter 3 of a
    /// shelved book, its reading button reads 「繼續閱讀」 with 「第 3 章」 as its value.
    @MainActor
    func testReadButtonCarriesTheResumeChapter() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(zh-Hant)",
                               "-AppleLocale", "zh_TW", "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Swipe Fixture")
        let add = app.buttons["加入書架"].firstMatch
        let resume = app.buttons["繼續閱讀"].firstMatch
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["加入書架", "移除書架"])).firstMatch
            .waitForExistence(timeout: 15), app.debugDescription)
        if add.exists {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
            add.tap()
        }
        XCTAssertTrue(resume.waitForExistence(timeout: 10), app.debugDescription)
        let chapter = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chapter 3")).firstMatch
        for _ in 0..<4 where !(chapter.exists && chapter.isHittable) { app.swipeUp() }
        XCTAssertTrue(chapter.waitForExistence(timeout: 10), app.debugDescription)
        chapter.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Chapter 3 paragraph")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(resume.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<4 where !resume.isHittable { app.swipeDown() }
        let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "第 3 章"), object: resume)
        XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 10), .completed,
                       "value: \(String(describing: resume.value))\n\(app.debugDescription)")
        attachScreenshot(app, named: "繼續閱讀 第 3 章")
        // Scrolled away, the action follows into the bar: on iOS 26 the bar's own glass is
        // its only capsule.
        app.swipeUp()
        app.swipeUp()
        let compact = app.navigationBars.buttons["繼續閱讀"].firstMatch
        XCTAssertTrue(compact.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot(app, named: "導覽列 繼續閱讀")
    }

    /// Back from reading a book not on the shelf, by a swipe or Back, the detail asks
    /// 「加入書架？」 (2026-10-13); these tests leave it off the shelf.
    @MainActor
    private func declineShelvePrompt(_ app: XCUIApplication, _ decline: String) {
        let button = app.alerts.buttons[decline].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the detail asks to keep the book read\n\(app.debugDescription)")
        button.tap()
    }

    @MainActor
    private func exerciseNativeEntry(fromSearch: Bool) throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings, search)",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        if fromSearch {
            openSearchedBook(app, query: "navigation swipe", named: "Navigation Swipe Fixture")
        } else {
            openDiscoveredBook(app, named: "Navigation Swipe Fixture")
        }
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        if !fromSearch { attachScreenshot(app, named: "作品詳情 - book source") }
        // An earlier test may have added the book; only one off the shelf is asked about.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Add to Library", "Remove"])).firstMatch
            .waitForExistence(timeout: 15), app.debugDescription)
        let offShelf = app.buttons["Add to Library"].firstMatch.exists
        for _ in 0..<2 {
            read.tap()
            let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 30), "The reader must finish loading after a detail push.\n\(app.debugDescription)")
            XCTAssertFalse(read.exists, "Opening must stay in the reader")
            // iOS 17 uses UIKit's narrow physical-edge recognizer; the 30 pt
            // content-pop reservation is available starting with iOS 26.
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            if offShelf { declineShelvePrompt(app, "Don't Add") }
            XCTAssertTrue(read.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertFalse(content.exists)
        }
        if !fromSearch {
            // 作品詳情 is one page: back from it is Explore's home.
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(app.buttons["explore.more"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        }
    }

    @MainActor
    func testDetailMangaReaderLoadsAndReturns() throws {
        try exerciseMangaEntry(fromSearch: false)
    }

    @MainActor
    func testSearchDetailMangaReaderLoadsAndReturns() throws {
        try exerciseMangaEntry(fromSearch: true)
    }

    /// A manga opens in FixedPageReaderView, pushed onto the detail's own stack.
    /// That reader once wrapped itself in a second NavigationStack there, and
    /// manga stopped opening from a book detail (Technotes/iOS17ReaderNavigationWatchdog.md).
    @MainActor
    private func exerciseMangaEntry(fromSearch: Bool) throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings, search)"]
        app.launch()
        if fromSearch {
            openSearchedBook(app, query: "manga fixture", named: "Navigation Manga Fixture")
        } else {
            openDiscoveredBook(app, named: "Navigation Manga Fixture")
        }
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        let progress = app.sliders["Reading Progress"]
        // An earlier test may have added the book; only one off the shelf is asked about.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Add to Library", "Remove"])).firstMatch
            .waitForExistence(timeout: 15), app.debugDescription)
        let offShelf = app.buttons["Add to Library"].firstMatch.exists
        for entry in 1...2 {
            // Read Now stays disabled until the detail has loaded the contents.
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: read)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
            read.tap()
            waitForMangaPage(app)
            XCTAssertFalse(read.exists, "Opening must stay in the reader")
            showMangaControls(app, expecting: "Page 1 of 3")
            attachScreenshot(app, named: "Manga reader - \(fromSearch ? "search" : "explore") detail - entry \(entry)")
            if entry == 1 {
                // With the controls up, a tap on a turning zone only puts them away.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
                waitForMangaControlsHidden(app, because: "A turning tap must put the controls away")
                showMangaControls(app, expecting: "Page 1 of 3")
                // A swipe turns the page and puts them away too. Right to left: the
                // next page comes in from the left, under a drag to the right.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
                waitForMangaControlsHidden(app, because: "Turning the page must put the controls away")
                showMangaControls(app, expecting: "Page 2 of 3")
            }
            app.navigationBars.buttons["Back"].tap()
            if offShelf { declineShelvePrompt(app, "Don't Add") }
            XCTAssertTrue(read.waitForExistence(timeout: 8), "Back must return to the same detail.\n\(app.debugDescription)")
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: progress)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed, app.debugDescription)
        }
    }

    /// The report's recipe on TestFlight build 5 (iOS 17, 2026-10-02): the 搜索 tab's own
    /// page in Simplified Chinese, a manga result, its detail, the manga reader and back,
    /// three times over. With 最近閱讀's reader as a second item destination on the search
    /// page, iOS 17.5 froze on the first tap of the result (Technotes/iOS17ReaderNavigationWatchdog.md);
    /// with that freeze removed, the second round's reader no longer left on Back.
    @MainActor
    func testSearchTabMangaResultOpensEveryTime() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-yd_root_tab_visible_ids", "(bookshelf, explore, settings, search)"]
        app.launch()
        let searchTab = app.tabBars.buttons["搜索"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15), app.debugDescription)
        searchTab.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        search.tap()
        search.typeText("manga fixture\n")
        // iOS 17 lists results in a UIKit table, later systems in a SwiftUI list.
        let result = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND (elementType == %d OR elementType == %d)",
                                  "Navigation Manga Fixture", XCUIElement.ElementType.cell.rawValue,
                                  XCUIElement.ElementType.button.rawValue)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), app.debugDescription)
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["立即阅读", "继续阅读"])).firstMatch
        let readerBack = app.navigationBars.buttons["返回"]
        for round in 1...3 {
            result.tap()
            XCTAssertTrue(read.waitForExistence(timeout: 15), "Round \(round): the result must open its detail.\n\(app.debugDescription)")
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: read)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
            read.tap()
            waitForMangaPage(app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(readerBack.waitForExistence(timeout: 8), app.debugDescription)
            if round == 1 {
                // The reported screenshot is a continuous image strip. Cover it as
                // well as the paged reader in the following entry rounds.
                app.buttons["阅读设置"].tap()
                let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "阅读模式")).firstMatch
                XCTAssertTrue(mode.waitForExistence(timeout: 5), app.debugDescription)
                let close = app.buttons["关闭"].firstMatch
                XCTAssertTrue(close.isHittable, app.debugDescription)
                attachScreenshot(app, named: "Manga reading settings - search detail")
                mode.tap()
                app.buttons["条漫"].firstMatch.tap()
                close.tap()
                let page = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "webtoon_page_")).firstMatch
                XCTAssertTrue(page.waitForExistence(timeout: 15), app.debugDescription)
            }
            let progress = app.sliders["阅读进度"]
            XCTAssertTrue(progress.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(progress.isHittable, "The search reader's native progress control must be usable")
            let bottomBar = app.toolbars.firstMatch
            XCTAssertTrue(bottomBar.exists, app.debugDescription)
            XCTAssertGreaterThanOrEqual(progress.frame.minY, bottomBar.frame.minY)
            XCTAssertLessThanOrEqual(progress.frame.maxY, bottomBar.frame.maxY)
            attachScreenshot(app, named: "Search tab manga - native bottom bar - round \(round)")
            if round == 1 {
                app.buttons["阅读设置"].tap()
                let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "阅读模式")).firstMatch
                XCTAssertTrue(mode.waitForExistence(timeout: 5), app.debugDescription)
                let close = app.buttons["关闭"].firstMatch
                XCTAssertTrue(close.isHittable, app.debugDescription)
                attachScreenshot(app, named: "Manga reading settings - search detail - webtoon")
                // Reading mode persists. Restore paged mode explicitly before
                // reopening the book in the following entries.
                mode.tap()
                app.buttons["从右到左"].firstMatch.tap()
                close.tap()
                XCTAssertTrue(app.images["fixed_page_image"].waitForExistence(timeout: 15), app.debugDescription)
            }
            readerBack.tap()
            XCTAssertTrue(read.waitForExistence(timeout: 8), "Round \(round): Back must return to the detail.\n\(app.debugDescription)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let left = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: read)
            XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 8), .completed,
                           "Round \(round): Back must return to the results.\n\(app.debugDescription)")
        }
    }

    /// The shelf opens a manga with its card push, whose bar belongs to the shelf's
    /// UIKit navigation controller rather than to a SwiftUI stack. The book is added
    /// right before the app leaves the foreground and is killed: the shelf saves on a
    /// debounce, and leaving the foreground has to write it (it once lost the book).
    @MainActor
    func testShelfMangaOpensOnThePage() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "42017D70-DAD6-4EDE-845E-C5DBAC606CA4"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Manga Fixture")
        let add = app.buttons["Add to Library"]
        let remove = app.buttons["Remove"]
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Add to Library", "Remove"])).firstMatch.waitForExistence(timeout: 15))
        if add.exists {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
            add.tap()
            XCTAssertTrue(remove.waitForExistence(timeout: 10), app.debugDescription)
        }
        XCUIDevice.shared.press(.home)
        let left = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed)
        app.terminate()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings)", "-bookLayoutIsGrid", "NO"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Navigation Manga Fixture")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15), app.debugDescription)
        book.tap()
        waitForMangaPage(app)
        showMangaControls(app, expecting: "Page 1 of 3")
        attachScreenshot(app, named: "Manga reader - shelf")
        app.buttons["Reading Settings"].tap()
        let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading Mode")).firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 5), app.debugDescription)
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.isHittable, app.debugDescription)
        attachScreenshot(app, named: "Manga reading settings - shelf")
        close.tap()
        XCTAssertTrue(app.sliders["Reading Progress"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons["Back"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 8), "Back must return to the shelf.\n\(app.debugDescription)")
    }

    /// A pinch zooms a fixed page in and back out, and a double tap zooms without its
    /// first tap doing anything else. Each page used to sit in a second, disabled zoom
    /// layer that still claimed the pinch, so a double tap was the only way to zoom —
    /// and the reader's single tap did not wait for it, so on a turning zone the first
    /// tap of a double tap turned the page. A zoomed page turned away from and back to
    /// is still zoomed, as in Aidoku.
    @MainActor
    func testMangaPageZoomsWithPinchAndDoubleTap() throws {
        let app = try openMangaFromExplore()
        let fitted = try XCTUnwrap(pageFrameOnScreen(app), app.debugDescription)
        let isFitted = { (frame: CGRect) in
            abs(frame.width - fitted.width) < 2 && abs(frame.minX - fitted.minX) < 2 && abs(frame.minY - fitted.minY) < 2
        }
        app.pinch(withScale: 2.5, velocity: 1)
        waitForPageOnScreen(app, because: "A pinch out must zoom the page in") { $0.width > fitted.width * 1.5 }
        attachScreenshot(app, named: "Manga reader - pinched in")
        app.pinch(withScale: 0.3, velocity: -1)
        waitForPageOnScreen(app, because: "A pinch in must bring the page back to its fitted size and place", isFitted)

        // Right to left: the left side is the next-page zone.
        let nextZone = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let previousZone = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        nextZone.doubleTap()
        waitForPageOnScreen(app, because: "A double tap on a turning zone must zoom in") { $0.width > fitted.width * 1.5 }
        let zoomed = try XCTUnwrap(pageFrameOnScreen(app))
        let isZoomedAsLeft = { (frame: CGRect) in
            abs(frame.width - zoomed.width) < 2 && abs(frame.minX - zoomed.minX) < 2 && abs(frame.minY - zoomed.minY) < 2
        }
        nextZone.tap()
        waitForPageOnScreen(app, because: "The next page must open at its fitted size", isFitted)
        previousZone.tap()
        waitForPageOnScreen(app, because: "The page turned back to must still be zoomed where it was left", isZoomedAsLeft)
        // It is the first page again — and bringing the controls up leaves its zoom alone.
        showMangaControls(app, expecting: "Page 1 of 3")
        waitForPageOnScreen(app, because: "Bringing up the controls must leave the zoom alone", isZoomedAsLeft)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForMangaControlsHidden(app, because: "A tap in the middle must put the controls away")
        nextZone.doubleTap()
        waitForPageOnScreen(app, because: "A second double tap must zoom back out", isFitted)
        leaveMangaReader(app)
    }

    /// With double-tap zoom switched off in settings, a double tap is just two taps and
    /// zooms nothing; a pinch still zooms.
    @MainActor
    func testMangaDoubleTapZoomCanBeTurnedOff() throws {
        let app = try openMangaFromExplore(extraArguments: ["-yd_fixed_page_double_tap_zoom", "NO"])
        let fitted = try XCTUnwrap(pageFrameOnScreen(app), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (self.pageFrameOnScreen(app)?.width ?? 0) > fitted.width * 1.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 2), .timedOut,
                       "With double-tap zoom off, a double tap must not zoom.\n\(app.debugDescription)")
        app.pinch(withScale: 2.5, velocity: 1)
        waitForPageOnScreen(app, because: "A pinch must still zoom") { $0.width > fitted.width * 1.5 }
        leaveMangaReader(app)
    }

    /// The webtoon strip zooms through its layout: a pinch grows the pages, a zoomed strip
    /// pans sideways, and a double tap zooms in and back out. The strip used to be scaled
    /// as one view around the middle of the screen, its sides out of reach. The reading
    /// mode is kept with the book when it is closed and opened again, and the auto-scroll
    /// button stays away until switched on in settings.
    /// The book goes on the shelf first: a book only browsed from a detail page keeps
    /// nothing once closed, its settings included.
    /// The test puts the mode back to right to left and leaves the book on the shelf, as
    /// `testShelfMangaOpensOnThePage` does; the next run needs `navigation_swipe_fixture.py`
    /// `clean` and `prepare`.
    @MainActor
    func testWebtoonStripZoomsAndPansSideways() throws {
        let app = try openMangaFromExplore(addingToLibrary: true)
        setMangaReadingMode("Webtoon", in: app)
        XCTAssertFalse(app.buttons["Start Auto-Scroll"].exists,
                       "The auto-scroll button stays away until it is switched on.\n\(app.debugDescription)")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.sliders["Reading Progress"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons["Back"].tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8), app.debugDescription)
        read.tap()
        let strip = "webtoon_page_"
        XCTAssertTrue(app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", strip))
            .firstMatch.waitForExistence(timeout: 15),
                      "Opened again, the book must still read as a webtoon.\n\(app.debugDescription)")
        // Measured on whichever page covers the middle of the screen: the book may open on
        // any page, and chapters loading around it renumber the pages.
        let fitted = try XCTUnwrap(pageFrameOnScreen(app, identifier: strip), app.debugDescription)

        app.pinch(withScale: 2.5, velocity: 1)
        waitForPageOnScreen(app, identifier: strip, because: "A pinch out must zoom the strip in") {
            $0.width > fitted.width * 1.5
        }
        attachScreenshot(app, named: "Webtoon - pinched in")
        let zoomed = try XCTUnwrap(pageFrameOnScreen(app, identifier: strip))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)))
        waitForPageOnScreen(app, identifier: strip, because: "A zoomed strip must pan sideways") {
            $0.minX < zoomed.minX - 50
        }
        app.pinch(withScale: 0.2, velocity: -1)
        waitForPageOnScreen(app, identifier: strip, because: "A pinch in must bring the strip back to the screen's width") {
            abs($0.width - fitted.width) < 2 && abs($0.minX - fitted.minX) < 2
        }

        let tapPoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        tapPoint.doubleTap()
        waitForPageOnScreen(app, identifier: strip, because: "A double tap must zoom the strip to 2x") {
            abs($0.width - fitted.width * 2) < 4
        }
        tapPoint.doubleTap()
        waitForPageOnScreen(app, identifier: strip, because: "A second double tap must zoom it back out") {
            abs($0.width - fitted.width) < 2
        }

        // The three-page chapter has long pulled the next one in below. Back at its top, the
        // strip still holds each chapter once — the first page is still page 0, where a
        // second copy of this chapter used to be prepended — and the controls speak for the
        // chapter on screen, with its own page count and title.
        XCTAssertTrue(app.images["webtoon_page_0"].exists,
                      "The chapter must not be loaded above itself.\n\(app.debugDescription)")
        showMangaControls(app, expecting: "Page 1 of 3")
        XCTAssertTrue(app.navigationBars["Chapter 1"].exists,
                      "The title must stay on the chapter being read.\n\(app.debugDescription)")
        setMangaReadingMode("Right to Left", in: app)
        leaveMangaReader(app)
    }

    /// Switches the open manga's reading mode in its settings sheet, and puts the
    /// controls away again.
    @MainActor
    private func setMangaReadingMode(_ mode: String, in app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let settings = app.buttons["Reading Settings"]
        if !settings.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        settings.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading Mode")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        picker.tap()
        let option = app.buttons[mode].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        option.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        close.tap()
        XCTAssertTrue(app.sliders["Reading Progress"].waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForMangaControlsHidden(app, because: "A tap in the middle must put the controls away", file: file, line: line)
    }

    /// Opens the manga fixture from its Explore list, on its first page — first putting it
    /// on the shelf when asked.
    @MainActor
    private func openMangaFromExplore(extraArguments: [String] = [],
                                      addingToLibrary: Bool = false) throws -> XCUIApplication {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "42017D70-DAD6-4EDE-845E-C5DBAC606CA4"]
            + extraArguments
        app.launch()
        openDiscoveredBook(app, named: "Navigation Manga Fixture")
        if addingToLibrary {
            let add = app.buttons["Add to Library"]
            let remove = app.buttons["Remove"]
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Add to Library", "Remove"]))
                .firstMatch.waitForExistence(timeout: 15), app.debugDescription)
            if add.exists {
                let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
                XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
                add.tap()
                XCTAssertTrue(remove.waitForExistence(timeout: 10), app.debugDescription)
            }
        }
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: read)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
        read.tap()
        waitForMangaPage(app)
        return app
    }

    /// Leaves the reader for the detail it came from, and sends the app to the background.
    /// A book read from a detail without being shelved is a temporary one, deleted when the
    /// reader closes — but the shelf saves on a 2-second debounce, so a test that ends right
    /// after would be killed before the deletion is written, and the next test would find
    /// the book kept, opening on its last page. Leaving the foreground writes at once.
    @MainActor
    private func leaveMangaReader(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let slider = app.sliders["Reading Progress"]
        if !slider.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(slider.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        app.navigationBars.buttons["Back"].tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8), "Back must return to the detail.\n\(app.debugDescription)",
                      file: file, line: line)
        XCUIDevice.shared.press(.home)
        let left = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed, file: file, line: line)
    }

    /// The frame of the page covering the middle of the screen, among the images whose
    /// identifier starts with `identifier`. The paged reader keeps its neighbours in the
    /// hierarchy, off screen, under the same identifier; the webtoon strip numbers its pages.
    @MainActor
    private func pageFrameOnScreen(_ app: XCUIApplication, identifier: String = "fixed_page_image") -> CGRect? {
        let middle = CGPoint(x: app.frame.midX, y: app.frame.midY)
        return app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", identifier)).allElementsBoundByIndex
            .map(\.frame)
            .first { $0.contains(middle) }
    }

    @MainActor
    private func waitForPageOnScreen(_ app: XCUIApplication, identifier: String = "fixed_page_image",
                                     because reason: String,
                                     file: StaticString = #filePath, line: UInt = #line,
                                     _ condition: @escaping (CGRect) -> Bool) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.pageFrameOnScreen(app, identifier: identifier).map(condition) ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                       "\(reason); the page on screen is at \(String(describing: pageFrameOnScreen(app, identifier: identifier))).\n\(app.debugDescription)",
                       file: file, line: line)
    }

    /// The fixed-page reader opens on the page, with no controls over it.
    @MainActor
    private func waitForMangaPage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.images["fixed_page_image"].waitForExistence(timeout: 30),
                      "The first page's image must be on screen.\n\(app.debugDescription)", file: file, line: line)
        XCTAssertFalse(app.sliders["Reading Progress"].exists,
                       "The manga reader must open on the page, without its controls", file: file, line: line)
    }

    /// A tap in the middle brings the controls up. The progress slider speaks the
    /// page indicator (第 %d / %d 頁); chapter 1 has three pages.
    @MainActor
    private func showMangaControls(_ app: XCUIApplication, expecting indicator: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // `exists` first: reading `value` of a missing element fails the test outright.
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", indicator), object: app.sliders["Reading Progress"])
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed,
                       "The controls must show \(indicator).\n\(app.debugDescription)", file: file, line: line)
    }

    @MainActor
    private func waitForMangaControlsHidden(_ app: XCUIApplication, because reason: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.sliders["Reading Progress"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed,
                       "\(reason).\n\(app.debugDescription)", file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// With the menu up, a tap on a page-turn zone only puts the menu away, as in
    /// Apple Books and legado; the next tap turns the page.
    @MainActor
    func testTapWithMenuUpOnlyPutsMenuAway() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_appearance_reader_interface", "classic",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Swipe Fixture")
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: read)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        let originalPage = content.label
        let menu = app.buttons["reader_back_button"]
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        // The middle row's right third turns to the next page.
        let nextPageZone = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        nextPageZone.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, app.debugDescription)
        XCTAssertEqual(content.label, originalPage, "The tap that puts the menu away must not also turn the page")
        nextPageZone.tap()
        let pageChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            content.exists && content.label != originalPage
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pageChanged], timeout: 5), .completed, "With the menu away, the tap turns the page")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.tap()
        XCTAssertTrue(read.waitForExistence(timeout: 8), app.debugDescription)
    }

    @MainActor func testSlideTurnHidesMenu() throws { try exerciseMenuHidesOnPageTurn(style: "滑動") }
    @MainActor func testCoverTurnHidesMenu() throws { try exerciseMenuHidesOnPageTurn(style: "覆蓋翻頁") }
    @MainActor func testCurlTurnHidesMenu() throws { try exerciseMenuHidesOnPageTurn(style: "仿真翻書") }
    @MainActor func testInstantTurnHidesMenu() throws { try exerciseMenuHidesOnPageTurn(style: "無動畫") }
    @MainActor func testScrollHidesMenu() throws { try exerciseMenuHidesOnPageTurn(style: "滑動", scroll: true) }

    /// Turning the page with the menu up puts the menu away, whichever gesture
    /// turned it: each page-turn style has its own (UIKit's swipe, the cover pan,
    /// the instant pan), and scroll mode turns by dragging.
    @MainActor
    private func exerciseMenuHidesOnPageTurn(style: String, scroll: Bool = false) throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_appearance_reader_interface", "classic",
                               "-yd_page_turn_style", style, "-yd_scroll_mode", scroll ? "YES" : "NO"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Swipe Fixture")
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: read)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        let originalPage = content.label
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let menu = app.buttons["reader_back_button"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        // Across the middle of the page, clear of the menu's bars and the back-swipe edge.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: scroll ? 0.5 : 0.8, dy: scroll ? 0.6 : 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: scroll ? 0.5 : 0.2, dy: scroll ? 0.4 : 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed,
                       "Turning the page must put the menu away.\n\(app.debugDescription)")
        if !scroll {
            let pageChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                content.exists && content.label != originalPage
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [pageChanged], timeout: 5), .completed, "The drag must also turn the page")
        }
        // The menu still comes back on a tap; leaving through it releases the trial book.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.tap()
        XCTAssertTrue(read.waitForExistence(timeout: 8), app.debugDescription)
    }

    @MainActor
    func testClassicReaderControlsFromExploreAreAccessible() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_appearance_reader_interface", "classic",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Swipe Fixture")
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader_back_button"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.textFields["Search or enter URL"].exists, "The covered browser must leave the accessibility tree")
        for label in ["Contents", "Settings", "Next Chapter"] {
            let button = app.buttons[label].firstMatch
            XCTAssertTrue(button.exists, app.debugDescription)
            XCTAssertTrue(button.isHittable, app.debugDescription)
        }
        app.buttons["Contents"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Chapter 2"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    /// A book-source book on the shelf has one page, 作品詳情, which is its source's own page with
    /// its chapter list and 換源 (unified library 5f-4, decision 29): the ••• has no 書籍詳情.
    /// Taking the book off the shelf from that page goes back to the shelf.
    @MainActor
    func testShelfOnlineBookOpensWorkDetail() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Swipe Fixture")
        let remove = app.buttons["Remove"]
        let add = app.buttons["Add to Library"]
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Add to Library", "Remove"])).firstMatch.waitForExistence(timeout: 15))
        if add.exists {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
            add.tap()
            XCTAssertTrue(remove.waitForExistence(timeout: 10), app.debugDescription)
        }
        // The shelf is written when the app leaves the foreground, not on 加入書架's tap.
        XCUIDevice.shared.press(.home)
        let left = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed)
        app.terminate()
        app.launchArguments = ["-explore.mode", "sources", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings)", "-bookLayoutIsGrid", "NO"]
        app.launch()
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Navigation Swipe Fixture，")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), app.debugDescription)
        let more = cell.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        let work = app.buttons["Book Details"].firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Book Details")).count, 1, "作品詳情 is the book's one page.\n\(app.debugDescription)")
        work.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.info.chapters"].firstMatch.waitForExistence(timeout: 15),
                      "作品詳情 is the source's own page, with its chapters.\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Contents"].firstMatch.exists, app.debugDescription)
        XCTAssertTrue(remove.waitForExistence(timeout: 15), app.debugDescription)
        attachScreenshot(app, named: "Work detail - shelf online book")
        // The page's reader closes back onto it with its bar on screen (iOS 17 lost it once,
        // through the shelf's card coordinator).
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(remove.waitForExistence(timeout: 10), "The reader closes onto 作品詳情.\n\(app.debugDescription)")
        // The back button, named after the shelf; only later systems give it an identifier.
        XCTAssertTrue(app.navigationBars.buttons["Library"].firstMatch.isHittable, app.debugDescription)
        attachScreenshot(app, named: "Work detail - after the reader")
        let pageButton = remove.frame
        remove.tap()
        // The confirmation's own 移除書架: an action sheet below on iOS 17, a popover over the
        // page's button on later systems, so it is told apart by where it is, not by order.
        XCTAssertTrue(app.staticTexts["Remove This Book from Your Library?"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "Remove"))
            .allElementsBoundByIndex.first { $0.frame != pageButton }
        XCTAssertNotNil(confirm, app.debugDescription)
        confirm?.tap()
        XCTAssertTrue(app.tabBars.buttons["Library"].firstMatch.waitForExistence(timeout: 10),
                      "Removing it goes back to the shelf.\n\(app.debugDescription)")
        XCTAssertTrue(cell.waitForNonExistence(timeout: 10), "The book leaves the shelf.\n\(app.debugDescription)")
    }

    /// A title the reader gave a shelf book is the one its 作品詳情 shows, not the source's
    /// (5f-4d, decision 32: the reader's own edits come first).
    @MainActor
    func testWorkDetailShowsTheShelfCopysEditedTitle() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Swipe Fixture")
        let remove = app.buttons["Remove"]
        let add = app.buttons["Add to Library"]
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Add to Library", "Remove"])).firstMatch.waitForExistence(timeout: 15))
        if remove.exists {
            // On the shelf from an earlier run, maybe renamed: put back with the source's title.
            let pageButton = remove.frame
            remove.tap()
            XCTAssertTrue(app.staticTexts["Remove This Book from Your Library?"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
            app.buttons.matching(NSPredicate(format: "label == %@", "Remove"))
                .allElementsBoundByIndex.first { $0.frame != pageButton }?.tap()
            XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        }
        if add.exists {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
            add.tap()
            XCTAssertTrue(remove.waitForExistence(timeout: 10), app.debugDescription)
        }
        XCUIDevice.shared.press(.home)
        let left = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed)
        app.terminate()
        app.launchArguments = ["-explore.mode", "sources", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings, search)", "-bookLayoutIsGrid", "NO"]
        app.launch()

        // 編輯書籍資訊 renames the copy.
        let edited = "Renamed On The Shelf"
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Navigation Swipe Fixture，")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), app.debugDescription)
        cell.buttons["More"].firstMatch.tap()
        let editInfo = app.buttons["Edit Details"].firstMatch
        XCTAssertTrue(editInfo.waitForExistence(timeout: 5), app.debugDescription)
        editInfo.tap()
        // 書名 is under the cover's section: the field holding the source's title.
        XCTAssertTrue(app.navigationBars["Book Info"].waitForExistence(timeout: 5), app.debugDescription)
        let titleField = app.textFields.matching(NSPredicate(format: "value == %@", "Navigation Swipe Fixture")).firstMatch
        for _ in 0..<6 where !(titleField.exists && titleField.isHittable) { app.swipeUp() }
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), app.debugDescription)
        // At its end, so the deletes take the whole title.
        titleField.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        // Into the focused field: once edited, the query by its old value finds nothing.
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Navigation Swipe Fixture".count + 4) + edited)
        // 簡介 (5f-4d-2): the reader's own, written as a Legado format to show it is read as text.
        let ownIntro = "<md>**Written on the shelf**"
        let introField = app.textFields["bookInfo.intro"].firstMatch.exists ? app.textFields["bookInfo.intro"].firstMatch
            : app.textViews["bookInfo.intro"].firstMatch
        for _ in 0..<6 where !(introField.exists && introField.isHittable) { app.swipeUp() }
        XCTAssertTrue(introField.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Leave blank to show the description from the book or its source."].firstMatch.exists,
                      "The 簡介 footer says where an empty field's description comes from.\n\(app.debugDescription)")
        attachScreenshot(app, named: "編輯資訊 簡介 footer")
        introField.tap()
        app.typeText(ownIntro)
        let save = app.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "Done"])).firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 5), app.debugDescription)
        save.tap()
        let renamed = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", edited + "，")).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 10), app.debugDescription)

        // 搜索's result for the same book opens 作品詳情 (5f-4c, decision 29), the source's page
        // with the reader's title and 簡介, as the shelf's does.
        openSearchedBook(app, query: "navigation swipe", named: "Navigation Swipe Fixture")
        XCTAssertTrue(app.staticTexts[edited].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts[ownIntro].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(remove.waitForExistence(timeout: 15), app.debugDescription)
        attachScreenshot(app, named: "Work detail - from 搜索")
        // Back to 搜索's root, where the tab bar is.
        app.navigationBars.buttons.firstMatch.tap()
        let libraryTab = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 10), app.debugDescription)
        libraryTab.tap()

        // 作品詳情 shows the copy's title once its source has answered with its own.
        renamed.buttons["More"].firstMatch.tap()
        let work = app.buttons["Book Details"].firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 5), app.debugDescription)
        work.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.info.chapters"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Contents"].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        attachScreenshot(app, named: "Work detail - edited title")
        XCTAssertTrue(app.staticTexts[edited].firstMatch.exists, "The copy's own title is shown.\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts[ownIntro].firstMatch.exists, "The reader's own 簡介, as plain text.\n\(app.debugDescription)")
        // The fixture's source has the book's name too; only its 來源 cell may show it.
        let sourceCell = app.descendants(matching: .any)["detail.info.source"].firstMatch.frame
        let sourceTitles = app.staticTexts.matching(NSPredicate(format: "label == %@", "Navigation Swipe Fixture")).allElementsBoundByIndex
        XCTAssertTrue(sourceTitles.allSatisfy { sourceCell.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }, "Not the source's title.\n\(app.debugDescription)")

        // Leaves the shelf as it found it.
        let pageButton = remove.frame
        remove.tap()
        XCTAssertTrue(app.staticTexts["Remove This Book from Your Library?"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        app.buttons.matching(NSPredicate(format: "label == %@", "Remove"))
            .allElementsBoundByIndex.first { $0.frame != pageButton }?.tap()
        XCTAssertTrue(renamed.waitForNonExistence(timeout: 10), app.debugDescription)
    }

    /// The classic reader's 選單 → 作品詳情 (5f-4b, decision 32), which shows the book being read.
    @MainActor
    private func openWorkDetailFromReader(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let menu = app.buttons["Menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.tap()
        let work = app.buttons["Book Details"].firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Book Details")).count, 1, "The reader's detail is 作品詳情.\n\(app.debugDescription)")
        work.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.info.chapters"].firstMatch.waitForExistence(timeout: 15),
                      "作品詳情 shows the source's page of the book being read.\n\(app.debugDescription)")
    }

    /// 作品詳情 from the reader returns to that same reader: 繼續閱讀 goes back to it, and the
    /// reader's own back then leaves it, with no second reader under it. Both ways a reader opens:
    /// the shelf's card coordinator (a UIKit-hosted detail) and 探索's 作品詳情 (SwiftUI's stack).
    @MainActor
    func testReaderOpensWorkDetailAndReturnsToIt() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)", "-yd_appearance_reader_interface", "classic",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Swipe Fixture")
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        let add = app.buttons["Add to Library"]
        if add.exists {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
            add.tap()
            XCTAssertTrue(app.buttons["Remove"].waitForExistence(timeout: 10), app.debugDescription)
        }
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        let edgeBack = {
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        }

        // 探索 → 作品詳情 → the reader → 作品詳情 → 繼續閱讀 → the same reader → back → 探索's 作品詳情.
        read.tap()
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        openWorkDetailFromReader(app)
        attachScreenshot(app, named: "Work detail from the reader - explore")
        let resume = app.buttons["Resume"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10), app.debugDescription)
        resume.tap()
        XCTAssertTrue(content.waitForExistence(timeout: 15), "繼續閱讀 returns to the reader.\n\(app.debugDescription)")
        edgeBack()
        XCTAssertTrue(content.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(read.waitForExistence(timeout: 10), "Back from the reader is 探索's 作品詳情.\n\(app.debugDescription)")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["explore.more"].firstMatch.waitForExistence(timeout: 10),
                      "One 作品詳情 under the reader, then the home.\n\(app.debugDescription)")

        // The shelf: its card coordinator opens the reader, whose 作品詳情 is hosted by UIKit.
        XCUIDevice.shared.press(.home)
        let left = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed)
        app.terminate()
        app.launchArguments = ["-explore.mode", "sources", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings)", "-bookLayoutIsGrid", "NO",
                               "-yd_appearance_reader_interface", "classic", "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        let cell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Navigation Swipe Fixture，")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 15), app.debugDescription)
        cell.tap()
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        openWorkDetailFromReader(app)
        attachScreenshot(app, named: "Work detail from the reader - shelf")
        XCTAssertTrue(resume.waitForExistence(timeout: 10), app.debugDescription)
        resume.tap()
        XCTAssertTrue(content.waitForExistence(timeout: 15), "繼續閱讀 returns to the reader.\n\(app.debugDescription)")
        // The reader comes back with its controls as they were left: up.
        let back = app.buttons["reader_back_button"].firstMatch
        if !back.waitForExistence(timeout: 2) { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "Back from the reader is the shelf.\n\(app.debugDescription)")
        XCTAssertTrue(app.tabBars.buttons["Library"].firstMatch.isHittable, app.debugDescription)
    }

    @MainActor
    func testShelfListExposesOneBookButtonAndOpensReader() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Swipe Fixture")
        let remove = app.buttons["Remove"]
        let add = app.buttons["Add to Library"]
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Add to Library", "Remove"])).firstMatch.waitForExistence(timeout: 15))
        if add.exists {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
            add.tap()
            XCTAssertTrue(remove.waitForExistence(timeout: 10), app.debugDescription)
        }
        // The shelf is written when the app leaves the foreground, not on 加入書架's tap.
        XCUIDevice.shared.press(.home)
        let left = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed)
        app.terminate()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings)",
                               "-bookLayoutIsGrid", "NO", "-yd_appearance_reader_interface", "classic"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Navigation Swipe Fixture，Regression"))
        XCTAssertTrue(book.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(book.count, 1, "A list book must expose one combined activation target")
        book.firstMatch.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
    }

    @MainActor
    func testListeningStartsCapsuleAndRolePanelRemainsAvailable() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_tts_use_system_voice", "YES",
                               "-yd_appearance_reader_interface", "classic"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Swipe Fixture")
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let listen = app.buttons["Listen"].firstMatch
        XCTAssertTrue(listen.waitForExistence(timeout: 5), app.debugDescription)
        listen.tap()
        let playback = app.buttons["now_playing_reader_play_pause"]
        let panelPlayback = app.buttons["tts_panel_play_pause"]
        XCTAssertTrue(playback.waitForExistence(timeout: 15), "Listening must show the floating capsule.\n\(app.debugDescription)")
        func awaitPlaybackLabel(_ label: String, line: UInt = #line) {
            let state = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: playback)
            XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 10), .completed, app.debugDescription, line: line)
            XCTAssertFalse(panelPlayback.exists, "Listening must keep the full TTS panel closed", line: line)
        }
        awaitPlaybackLabel("Pause")
        XCTAssertTrue(playback.isHittable, app.debugDescription)
        playback.tap()
        awaitPlaybackLabel("Play")
        XCTAssertTrue(listen.waitForExistence(timeout: 5), app.debugDescription)
        listen.tap()
        awaitPlaybackLabel("Pause")
        XCTAssertTrue(listen.waitForExistence(timeout: 5), app.debugDescription)
        listen.tap()
        awaitPlaybackLabel("Pause")
        attachScreenshot(app, named: "Listening starts the floating capsule")
        app.buttons["now_playing_reader_open_panel"].tap()
        XCTAssertTrue(panelPlayback.waitForExistence(timeout: 5), "The capsule must still open the full controls on demand.\n\(app.debugDescription)")
        let roles = app.buttons["Multi-Voice Read Aloud"].firstMatch
        XCTAssertTrue(roles.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(roles.isHittable)
        roles.tap()
        XCTAssertTrue(app.navigationBars["Multi-Voice Read Aloud"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["Reset"].firstMatch.exists, app.debugDescription)
    }

    @MainActor func testSlideEdgeBack() throws { try exerciseReader(style: "滑動") }
    @MainActor func testCoverEdgeBack() throws { try exerciseReader(style: "覆蓋翻頁") }
    @MainActor func testCurlEdgeBack() throws { try exerciseReader(style: "仿真翻書") }
    @MainActor func testInstantEdgeBack() throws { try exerciseReader(style: "無動畫") }
    @MainActor func testScrollEdgeBack() throws { try exerciseReader(style: "滑動", scroll: true) }

    @MainActor
    private func exerciseReader(style: String, scroll: Bool = false) throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-explore.mode", "sources", "-reset-explore-home", "-reset-reading-settings", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_page_turn_style", style, "-yd_scroll_mode", scroll ? "YES" : "NO"]
        app.launch()
        openDiscoveredBook(app, named: "Navigation Swipe Fixture")
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read", "Resume"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        let originalPage = content.label
        var edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        if #unavailable(iOS 26) {
            // Before iOS 26's content-pop recognizer (and its 30 pt reservation,
            // NavigationBackSwipeReservationController.backGesture), UIKit's screen-edge
            // recognizer begins only on a touch at the physical edge, where a finger
            // sliding in from the bezel lands: from 8 pt it fails at once (iOS 17.5).
            edge = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        }
        let shortDrag = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        // The hold belongs to the user's gesture: releasing a short, stationary
        // drag must cancel, preserving the same reader and reading position.
        edge.press(forDuration: 0.05, thenDragTo: shortDrag, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertEqual(content.label, originalPage)
        XCTAssertFalse(read.exists)

        // Interior pans must still turn pages / scroll, without navigating back.
        let interior = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7))
        let next = app.coordinate(withNormalizedOffset: CGVector(dx: scroll ? 0.8 : 0.2, dy: scroll ? 0.35 : 0.7))
        interior.press(forDuration: 0.05, thenDragTo: next)
        XCTAssertFalse(read.exists)
        if !scroll {
            let pageChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                content.exists && content.label != originalPage
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [pageChanged], timeout: 5), .completed, "Interior pan must turn the page")
        }

        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        if #available(iOS 26, *) {
            // Also exercise the reserved strip away from the physical screen edge.
            let reservedStrip = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: app.frame.height * 0.5))
            reservedStrip.press(forDuration: 0.05, thenDragTo: end)
        } else {
            // No reserved strip before iOS 26 (see `edge`): a 28 pt start never begins.
            edge.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(read.waitForExistence(timeout: 8), "Edge drag must pop to the original detail.\n\(app.debugDescription)")
        XCTAssertFalse(content.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Returned to detail - \(style) - scroll \(scroll)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // SwiftUI's route must also be reconciled, so reopening works normally.
        read.tap()
        XCTAssertTrue(content.waitForExistence(timeout: 15))
        edge.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(read.waitForExistence(timeout: 8))
    }
}
