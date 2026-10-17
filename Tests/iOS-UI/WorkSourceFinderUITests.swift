import XCTest

/// 「尋找可用來源」 (Discovery 7b-2): a library work's 作品詳情 searches the enabled sources as
/// soon as it opens (maintainer, 2026-10-17), and says how the search ended.
///
/// Gutenberg's 熱門 answers from fixtures, so the home has Moby Dick's card without a network.
/// The one book source's host does not exist: every source fails, which the row must call a
/// failed search, not 「未找到」 (a fetch failure is counted as an empty answer, Phase 0b).
final class WorkSourceFinderUITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("WorkSourceFinderUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Latest</title></feed>".utf8)
            .write(to: directory.appendingPathComponent("ebooks_search.opds.xml"))
        let entry = "<entry><id>https://www.gutenberg.org/ebooks/2701.opds</id><title>Moby Dick</title>"
            + "<content>Herman Melville</content>"
            + "<link rel=\"subsection\" type=\"application/atom+xml\" href=\"/ebooks/2701.opds\"/></entry>"
        try Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Popular</title>\(entry)</feed>".utf8)
            .write(to: directory.appendingPathComponent("ebooks_search.opds@sort_order=downloads.xml"))
        let sources = directory.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source: [String: Any] = [
            "bookSourceName": "尋找來源測試",
            "bookSourceUrl": "https://find-sources-ui-test.example",
            "searchUrl": "https://find-sources-ui-test.example/search?q={{key}}",
            "ruleSearch": ["bookList": "class.book", "name": "tag.h3@text", "bookUrl": "tag.a@href"],
            "enabled": true,
        ]
        try JSONSerialization.data(withJSONObject: [source]).write(to: sources.appendingPathComponent("book_sources.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testSearchesWhenOpenedAndSaysItFailed() {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.appendingPathComponent("sources").path,
                               "-reset-public-library-explore", "-reset-explore-home"]
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = directory.path
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        let book = app.buttons["home.card.gutenberg.2701"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()

        let find = app.descendants(matching: .any)["detail.info.findSources"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<8 where !find.isHittable { app.swipeUp() }
        XCTAssertEqual(find.label, "尋找可用來源")
        // Nothing tapped: the page searched on its own.
        let failed = NSPredicate(format: "value == %@", "搜尋失敗")
        expectation(for: failed, evaluatedWith: find)
        waitForExpectations(timeout: 60)
        attach(app, "find-sources-failed")
        // 重試 is the row's second line: it can search again.
        XCTAssertTrue(find.isHittable, app.debugDescription)
    }
}
