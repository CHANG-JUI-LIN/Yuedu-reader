import XCTest

/// 為你推薦 (Discovery Phase 7a-4): on a new install's home, mixed from what the home's rows
/// loaded, and its form's 來源分類.
///
/// Each launch starts from the defaults (`-reset-explore-home`) and a book-source library of its
/// own. Gutenberg's 熱門 answers from fixtures, so 為你推薦 has the library row's books without a
/// network; the book source's host answers nothing.
final class ForYouSectionUITests: XCTestCase {
    private var directory: URL!
    private let card = "home.card.gutenberg.2701"

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ForYouSectionUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Latest</title></feed>".utf8)
            .write(to: directory.appendingPathComponent("ebooks_search.opds.xml"))
        let books = [(2701, "Moby Dick", "Herman Melville"), (1513, "Romeo and Juliet", "William Shakespeare"),
                     (2641, "A Room with a View", "E. M. Forster"), (145, "Middlemarch", "George Eliot")]
        let entries = books.map { number, title, author in
            "<entry><id>https://www.gutenberg.org/ebooks/\(number).opds</id><title>\(title)</title><content>\(author)</content>"
                + "<link rel=\"subsection\" type=\"application/atom+xml\" href=\"/ebooks/\(number).opds\"/></entry>"
        }.joined()
        try Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Popular</title>\(entries)</feed>".utf8)
            .write(to: directory.appendingPathComponent("ebooks_search.opds@sort_order=downloads.xml"))
        let sources = directory.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source: [String: Any] = [
            "bookSourceName": "推薦測試來源",
            "bookSourceUrl": "https://for-you-ui-test.example",
            "exploreUrl": "排行榜::https://for-you-ui-test.example/rank",
            "enabled": true,
            "enabledExplore": true,
        ]
        try JSONSerialization.data(withJSONObject: [source]).write(to: sources.appendingPathComponent("book_sources.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func launchExplore() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.appendingPathComponent("sources").path,
                               "-reset-public-library-explore", "-reset-explore-home"]
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = directory.path
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        return app
    }

    @MainActor
    private func header(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH 'home.row.header.' AND label CONTAINS %@", "為你推薦")).firstMatch
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A new install's home has 為你推薦 under 系列下一本, from 熱門's books, and its card opens
    /// the book.
    @MainActor
    func testNewInstallShowsForYou() {
        let app = launchExplore()
        let forYou = header(app)
        XCTAssertTrue(forYou.waitForExistence(timeout: 20), app.debugDescription)
        // 為你推薦 is above 熱門: the first of the book's cards is its own.
        let book = app.buttons[card].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertLessThan(forYou.frame.minY, book.frame.minY)
        attach(app, "for-you-home")
        book.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.info.source"].firstMatch.waitForExistence(timeout: 10),
                      app.debugDescription)
    }

    /// Its form lists the home's categories; 加入分類 adds one from a source, and 移除 takes it
    /// away. 新增欄目 offers it among App 資料.
    @MainActor
    func testFormAddsAndRemovesACategory() {
        let app = launchExplore()
        let forYou = header(app)
        XCTAssertTrue(forYou.waitForExistence(timeout: 20), app.debugDescription)
        forYou.press(forDuration: 1.0)
        let settings = app.buttons["設定"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription)
        settings.tap()

        let add = app.buttons["homeSection.forYou.add"].firstMatch
        for _ in 0..<4 where !(add.exists && add.isHittable) { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["來源分類"].exists, app.debugDescription)
        add.tap()
        let source = app.buttons["homePicker.source.推薦測試來源"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        source.tap()
        let category = app.buttons["homePicker.item.排行榜"].firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription)
        category.tap()

        let added = app.descendants(matching: .any)["homeSection.forYou.推薦測試來源.排行榜"].firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "for-you-form")
        added.swipeLeft()
        let remove = app.buttons["移除"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        remove.tap()
        XCTAssertTrue(added.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testNewSectionOffersForYou() {
        let app = launchExplore()
        XCTAssertTrue(header(app).waitForExistence(timeout: 20), app.debugDescription)
        let edit = app.buttons["home.edit"].firstMatch
        for _ in 0..<12 where !(edit.exists && edit.isHittable) { app.swipeUp() }
        edit.tap()
        let addSection = app.buttons["homeEditor.addSection"].firstMatch
        XCTAssertTrue(addSection.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 where !addSection.isHittable { app.swipeUp() }
        addSection.tap()
        let layout = app.buttons["homeNewSection.layout.row"].firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<4 where !layout.isHittable { app.swipeUp() }
        layout.tap()
        let sourceButton = app.buttons["homeSection.source"].firstMatch
        XCTAssertTrue(sourceButton.waitForExistence(timeout: 5), app.debugDescription)
        sourceButton.tap()
        XCTAssertTrue(app.buttons["homePicker.item.為你推薦"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "for-you-in-app-data")
    }
}
