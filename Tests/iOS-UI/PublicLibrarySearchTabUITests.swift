import XCTest

/// Unified library 5d-1b (Phase 5 plan, decision 17 as amended 2026-10-11): one search on the
/// 搜索 tab covers the sources and the public libraries, with no scope to switch (one list of
/// works since unified search 4c-3, Gutenberg's books in it since search 9b). Gutenberg's search
/// answers from fixtures; the test changes no book-source data outside its own temporary
/// directory.
final class PublicLibrarySearchTabUITests: XCTestCase {
    private var fixtureDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicLibrarySearchTab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        // Gutenberg's search feed, whatever the query: the transport reads the path alone.
        let search = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Search</title>
        <entry><id>https://www.gutenberg.org/ebooks/24264.opds</id><title>紅樓夢</title><content>曹雪芹</content><link rel="subsection" type="application/atom+xml" href="/ebooks/24264.opds"/></entry>
        </feed>
        """
        try Data(search.utf8).write(to: fixtureDirectory.appendingPathComponent("ebooks_search.opds.xml"))
        let book = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>紅樓夢</title>
        <entry><id>urn:gutenberg:24264:3</id><title>紅樓夢</title><author><name>曹雪芹</name></author>
        <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">
        <p>
        Summary:
        搜索分頁測試使用的書籍介紹。
        </p>
        <p>EBook No.: 24264</p>
        <p>Rights: Public domain in the USA.</p>
        </div></content>
        <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="https://www.gutenberg.org/ebooks/24264.epub3.images" length="1000"/>
        </entry></feed>
        """
        try Data(book.utf8).write(to: fixtureDirectory.appendingPathComponent("ebooks_24264.opds.xml"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixtureDirectory)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A work of the search's one list, by its title: the row's label starts with it, on iOS 17's
    /// UIKit table and later systems' SwiftUI list alike.
    @MainActor
    private func work(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
    }

    /// With no book source and no Open Library the public libraries are the whole result.
    /// Search 9b: the keyboard's Search asks Gutenberg with everything else, and its books join
    /// the one list (no 「在 Project Gutenberg 搜尋」 row, no 載入更多); a book pushes 作品詳情
    /// onto the tab's stack.
    @MainActor
    func testNoSourcesSearchesThePublicLibraries() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-no-official-modules",
                               "-yd_source_disclaimer_accepted", "YES",
                               // Open Library is a live service: off, so nothing leaves the machine.
                               "-yd_search_open_library", "NO",
                               "-book-source-store-dir", fixtureDirectory.appendingPathComponent("sources").path]
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = fixtureDirectory.path
        app.launch()

        let tab = app.tabBars.buttons["搜尋"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        XCTAssertTrue(app.staticTexts["輸入書名或作者搜尋"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        // Latin letters: the fixture feed answers 紅樓夢 whatever the query.
        field.typeText("Hong Lou Meng\n")
        let result = work(app, "紅樓夢")
        XCTAssertTrue(result.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["publicLibrary.searchGutenberg"].exists, "no row to ask Gutenberg")
        XCTAssertFalse(app.buttons["載入更多"].exists, "no button to load more")
        XCTAssertFalse(app.buttons["公有書庫"].exists, "no scope to switch")
        // Search 9c: the works under a header per kind, and the 類型 chip above them.
        // A SwiftUI section header is static text; iOS 17's UIKit header is a heading element.
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "書籍")).firstMatch.exists,
                      app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any)["search.kindFilter"].firstMatch.exists, app.debugDescription)
        attach(app, "search-tab-gutenberg-in-list")

        result.tap()
        let source = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(source.value as? String, "Project Gutenberg")
        let intro = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "搜索分頁測試使用的書籍介紹")).firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 10), "作品詳情 loads the book's entry.\n\(app.debugDescription)")
        attach(app, "search-tab-work-detail")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Back from 作品詳情 returns to the list")
    }

    /// 2026-10-12: the illustrated Sense and Sensibility (#21839) drew three author lines in the
    /// hero — its commentator and illustrator too, as 「Austen, Jane」. The hero names the
    /// author; the others are 作品資訊's rows, by what they did. The book's entry is Gutenberg's
    /// own, saved with the unit tests' fixtures.
    @MainActor
    func testHeroNamesTheAuthorAndInfoListsTheOthers() throws {
        let search = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Search</title>
        <entry><id>https://www.gutenberg.org/ebooks/21839.opds</id><title>Sense and Sensibility</title><content>Austen, Jane</content><link rel="subsection" type="application/atom+xml" href="/ebooks/21839.opds"/></entry>
        </feed>
        """
        try Data(search.utf8).write(to: fixtureDirectory.appendingPathComponent("ebooks_search.opds.xml"))
        let entry = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("iOS/yuedu appTests/Fixtures/Gutenberg/21839.xml")
        try FileManager.default.copyItem(at: entry, to: fixtureDirectory.appendingPathComponent("ebooks_21839.opds.xml"))

        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-no-official-modules",
                               "-yd_source_disclaimer_accepted", "YES",
                               // Open Library is a live service: off, so nothing leaves the machine.
                               "-yd_search_open_library", "NO",
                               "-book-source-store-dir", fixtureDirectory.appendingPathComponent("sources").path]
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = fixtureDirectory.path
        app.launch()
        let tab = app.tabBars.buttons["搜尋"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Sense and Sensibility\n")
        let result = work(app, "Sense and Sensibility")
        XCTAssertTrue(result.waitForExistence(timeout: 15), app.debugDescription)
        result.tap()

        let author = app.buttons["publicLibrary.author.https://www.gutenberg.org/ebooks/author/68.opds"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(author.label.hasPrefix("Jane Austen"), author.label)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'publicLibrary.author.'")).count, 1,
                       "the hero names the author alone")
        let illustrator = app.descendants(matching: .any).matching(NSPredicate(format: "label == '插畫' AND value == 'Hugh Thomson'")).firstMatch
        for _ in 0..<4 where !illustrator.exists { app.swipeUp() }
        XCTAssertTrue(illustrator.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == '評註' AND value == 'Austin Dobson'"))
            .firstMatch.exists, app.debugDescription)
        attach(app, "work-detail-contributors")
        illustrator.tap()
        XCTAssertTrue(app.navigationBars["Hugh Thomson"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
    }
}
