import XCTest

/// Search 9e: 搜尋 as Emby's (plan `2026-10-15-search-emby.md`) — the results under a header per
/// kind, the 類型 chip, every page fetched by itself with nothing to tap or scroll for
/// (maintainer, 2026-10-15), Gutenberg's books among the rest, and a library unchecked in
/// 聚合設定 → 搜尋來源 left out.
///
/// The two book sources are a fixture served from outside the simulator, from the repo root:
/// `python3 -I scripts/search_paging_fixture.py` (port 18768); each test resets its count. Its
/// text source has three pages of twenty books; its audio source one page of two. Gutenberg
/// answers from `YUEDU_PUBLIC_LIBRARY_FIXTURES`; Open Library is off, so nothing leaves the machine.
final class SearchEmbyAcceptanceUITests: XCTestCase {
    // `localhost`, not 127.0.0.1: a source naming a reserved address is refused (`safeURL`).
    private static let fixture = "http://localhost:18768"
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SearchEmbyAcceptance-\(UUID().uuidString)")
        let sources = directory.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        func source(_ name: String, path: String, type: Int) -> [String: Any] {
            [
                "bookSourceName": name,
                "bookSourceUrl": "\(Self.fixture)/\(path)",
                "bookSourceType": type,
                "searchUrl": "\(Self.fixture)/\(path)/search?q={{key}}&page={{page}}",
                "ruleSearch": ["bookList": "class.book", "name": "tag.h3@text", "author": "class.author@text",
                               "bookUrl": "tag.a@href"],
                "enabled": true,
                // A new search cache key each run (it includes this): no cached page 1, since
                // the fixture counts the pages asked for.
                "lastUpdateTime": Int(Date().timeIntervalSince1970 * 1000),
            ]
        }
        try JSONSerialization.data(withJSONObject: [source("分頁測試", path: "text", type: 0),
                                                    source("有聲測試", path: "audio", type: 1)])
            .write(to: sources.appendingPathComponent("book_sources.json"))
        // Gutenberg's search feed, whatever the query. Its book is titled the query itself, so it
        // ranks first and is on screen: an unrelated title would rank after every row of the sources.
        let gutenberg = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Search</title>
        <entry><id>https://www.gutenberg.org/ebooks/24264.opds</id><title>Paging</title><content>古騰堡作者</content><link rel="subsection" type="application/atom+xml" href="/ebooks/24264.opds"/></entry>
        </feed>
        """
        try Data(gutenberg.utf8).write(to: directory.appendingPathComponent("ebooks_search.opds.xml"))
        // The pages asked for, counted from this test on.
        _ = try Data(contentsOf: URL(string: "\(Self.fixture)/reset")!)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func launch(fresh: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-no-official-modules",
                               "-yd_source_disclaimer_accepted", "YES", "-yd_search_open_library", "NO",
                               "-book-source-store-dir", directory.appendingPathComponent("sources").path]
        if fresh { app.launchArguments += ["-reset-explore-home"] }
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = directory.path
        app.launch()
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A work of the list, by its title.
    @MainActor
    private func work(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
    }

    @MainActor
    private func header(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// Types `query` into the 搜尋 tab's field and sends it.
    @MainActor
    private func search(_ app: XCUIApplication, _ query: String) {
        let tab = app.tabBars.buttons["搜尋"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        // Latin letters: typing Chinese through XCUITest submits early on the iOS 27 simulator.
        field.typeText(query + "\n")
    }

    /// The text source's pages asked for so far, from the fixture.
    private func pagesAsked() throws -> [String] {
        let data = try Data(contentsOf: URL(string: "\(Self.fixture)/log")!)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The search has ended: its pause control is gone.
    @MainActor
    private func waitForSearchToEnd(_ app: XCUIApplication) {
        let pause = app.buttons["暫停搜索"].firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: pause)
        waitForExpectations(timeout: 30)
    }

    /// Results under 書籍 and 有聲書, Gutenberg's among the books; 類型 keeps one kind. Every page
    /// came without a scroll or a button: when the search ends, the text source's page 4 (its
    /// first empty one) was asked for, and its page 3's books are at the list's end.
    @MainActor
    func testGroupsFilterAndAutoLoad() throws {
        let app = launch()
        search(app, "Paging")
        XCTAssertTrue(work(app, "Paging 1-01").waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(header(app, "書籍").exists, app.debugDescription)
        XCTAssertTrue(work(app, "Paging").waitForExistence(timeout: 15), "Gutenberg answers with the rest.\n\(app.debugDescription)")
        waitForSearchToEnd(app)
        XCTAssertFalse(app.buttons["載入更多"].exists, "no button to load more")
        attach(app, "search-groups")

        // Nothing scrolled, every page asked for.
        XCTAssertEqual(try pagesAsked(), ["1", "2", "3", "4"])

        // 類型 → 有聲書: its group alone.
        let kind = app.descendants(matching: .any)["search.kindFilter"].firstMatch
        XCTAssertTrue(kind.exists, app.debugDescription)
        XCTAssertEqual(kind.value as? String, "全部")
        kind.tap()
        let audioChoice = app.buttons["有聲書"].firstMatch
        XCTAssertTrue(audioChoice.waitForExistence(timeout: 5), app.debugDescription)
        audioChoice.tap()
        XCTAssertTrue(work(app, "Paging Audio 01").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(header(app, "有聲書").exists, app.debugDescription)
        XCTAssertFalse(work(app, "Paging 1-01").exists, "類型 hides the other kinds")
        XCTAssertFalse(header(app, "書籍").exists)
        XCTAssertEqual(kind.value as? String, "有聲書")
        attach(app, "search-kind-audio")
        kind.tap()
        let all = app.buttons["全部"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5), app.debugDescription)
        all.tap()
        XCTAssertTrue(work(app, "Paging 1-01").waitForExistence(timeout: 5), app.debugDescription)

        // The end of the list: page 3's last book, and nothing more asked for on the way.
        let lastBook = work(app, "Paging 3-20")
        // Slow swipes, each less than a screen: no row passes unseen.
        for _ in 0..<40 where !lastBook.exists {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(lastBook.exists, app.debugDescription)
        attach(app, "search-last-page")
        XCTAssertEqual(try pagesAsked(), ["1", "2", "3", "4"])
    }

    /// 聚合設定 → 搜尋來源: Gutenberg unchecked, the next search has none of its books.
    @MainActor
    func testUncheckedLibraryIsNotSearched() {
        let app = launch()
        let settings = app.tabBars.buttons["設定"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let aggregation = app.buttons["settings_aggregation"].firstMatch
        for _ in 0..<4 where !aggregation.exists { app.swipeUp() }
        XCTAssertTrue(aggregation.waitForExistence(timeout: 5))
        aggregation.tap()
        let sources = app.buttons["aggregation.dataSources.search"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 5), app.debugDescription)
        sources.tap()
        let gutenberg = app.switches["aggregation.search.gutenberg.builtin.gutenberg"].firstMatch
        XCTAssertTrue(gutenberg.waitForExistence(timeout: 5), app.debugDescription)
        gutenberg.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -30, dy: 0)).tap()
        XCTAssertEqual(gutenberg.value as? String, "0")
        // Back to 設定's root: the tab bar shows on tab roots only.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        search(app, "Paging")
        XCTAssertTrue(work(app, "Paging 1-01").waitForExistence(timeout: 30), app.debugDescription)
        waitForSearchToEnd(app)
        XCTAssertFalse(work(app, "Paging").exists, "Gutenberg is not asked")
        attach(app, "search-without-gutenberg")

        // Checked again for the other tests: a fresh launch resets 聚合設定.
        app.terminate()
        _ = launch()
    }
}
