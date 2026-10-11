import XCTest

/// Unified library 5d-1b (Phase 5 plan, decision 17 as amended 2026-10-11): one search on the
/// 搜索 tab covers the sources and a 公有書庫 section, with no scope to switch. Gutenberg's search answers from fixtures; the test changes no
/// book-source data outside its own temporary directory.
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
        <summary>搜索分頁測試使用的書籍介紹。</summary>
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

    /// With no book source the 公有書庫 section is the whole result, and the keyboard's Search
    /// asks Gutenberg; its results open in the tab's own stack, and a book pushes 作品詳情 onto it.
    @MainActor
    func testNoSourcesSearchesThePublicLibraries() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", fixtureDirectory.appendingPathComponent("sources").path]
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = fixtureDirectory.path
        app.launch()

        let tab = app.tabBars.buttons["搜索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        XCTAssertTrue(app.staticTexts["輸入書名或作者搜索"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)

        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("紅樓夢")
        // iOS 17 lists it in a UIKit table, later systems in a SwiftUI list.
        let gutenberg = app.descendants(matching: .any)["publicLibrary.searchGutenberg"].firstMatch
        XCTAssertTrue(gutenberg.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["公有書庫"].exists, "no scope to switch")
        attach(app, "search-tab-library-section")
        field.typeText("\n")
        let result = app.buttons["publicLibrary.book.gutenberg:https://www.gutenberg.org/ebooks/24264.opds"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 15), app.debugDescription)
        attach(app, "search-tab-gutenberg-results")

        result.tap()
        let source = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(source.value as? String, "Project Gutenberg")
        let intro = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "搜索分頁測試使用的書籍介紹")).firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 10), "作品詳情 loads the book's entry.\n\(app.debugDescription)")
        attach(app, "search-tab-work-detail")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Back from 作品詳情 returns to the results")
    }
}
