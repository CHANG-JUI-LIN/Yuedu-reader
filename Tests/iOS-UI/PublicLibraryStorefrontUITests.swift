import XCTest

/// Deterministic UI coverage: real native detents/paging, fixture-only OPDS.
/// The test changes no book-source data outside its own temporary directory.
final class PublicLibraryStorefrontUITests: XCTestCase {
    private var fixtureDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("PublicLibraryStorefront-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        for (id, title, author, person) in [(24264, "紅樓夢", "曹雪芹", 10001), (23962, "西遊記", "吳承恩", 10002), (23950, "三國志演義", "羅貫中", 10003)] {
            let xml = """
            <feed xmlns="http://www.w3.org/2005/Atom"><title>\(title)</title>
            <entry><id>urn:gutenberg:\(id):3</id><title>\(title)</title><author><name>\(author)</name></author>
            <summary>這是書店互動測試使用的書籍介紹。測試只讀取本機目錄，不下載正文。</summary>
            <link rel="http://opds-spec.org/acquisition" type="application/epub+zip" href="https://www.gutenberg.org/ebooks/\(id).epub3.images" length="1000"/>
            <link rel="related" type="application/atom+xml" title="By \(author)…" href="/ebooks/author/\(person).opds"/>
            </entry></feed>
            """
            try Data(xml.utf8).write(to: fixtureDirectory.appendingPathComponent("ebooks_\(id).opds.xml"))
        }
        let authors = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>曹雪芹</title>
        <entry><id>https://www.gutenberg.org/ebooks/24264.opds</id><title>紅樓夢</title><content>曹雪芹</content><link rel="subsection" type="application/atom+xml" href="/ebooks/24264.opds"/></entry>
        <entry><id>https://www.gutenberg.org/ebooks/23962.opds</id><title>作者作品測試</title><content>曹雪芹</content><link rel="subsection" type="application/atom+xml" href="/ebooks/23962.opds"/></entry>
        </feed>
        """
        try Data(authors.utf8).write(to: fixtureDirectory.appendingPathComponent("ebooks_author_10001.opds.xml"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixtureDirectory)
    }

    @MainActor
    private func application(pro: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-yd_source_disclaimer_accepted", "YES", "-book-source-store-dir", fixtureDirectory.appendingPathComponent("sources").path,
            "-reset-public-library-explore"]
        if pro { app.launchArguments.append("-debug-force-pro") }
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = fixtureDirectory.path
        return app
    }

    @MainActor
    private func openBook(_ app: XCUIApplication) -> XCUIElement {
        app.launch()
        let explore = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(explore.waitForExistence(timeout: 30))
        explore.tap()
        screenshot(app, "storefront-home")
        let book = app.buttons["publicLibrary.book.gutenberg:https://www.gutenberg.org/ebooks/24264.opds"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 10))
        book.tap()
        let resize = app.buttons["publicLibrary.resizeSheet"].firstMatch
        XCTAssertTrue(resize.waitForExistence(timeout: 10))
        let author = app.buttons["publicLibrary.author.https://www.gutenberg.org/ebooks/author/10001.opds"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10), app.debugDescription)
        return resize
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testSheetDetentsCarouselAndAuthorWithoutPro() {
        let app = application()
        let resize = openBook(app)
        screenshot(app, "storefront-sheet-medium")
        XCTAssertEqual(resize.label, "展開為全螢幕", app.debugDescription)

        // A vertical gesture on the sheet content expands the native detent.
        let carousel = app.scrollViews["publicLibrary.carousel"].firstMatch
        XCTAssertTrue(carousel.exists, app.debugDescription)
        XCTAssertLessThan(carousel.frame.height, app.frame.height * 0.6)
        carousel.swipeUp()
        XCTAssertTrue(resize.waitForExistence(timeout: 5))
        let expanded = NSPredicate(format: "label == %@", "還原為半螢幕")
        expectation(for: expanded, evaluatedWith: resize)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThan(carousel.frame.height, app.frame.height * 0.75)
        screenshot(app, "storefront-sheet-expanded")

        // Return using the native pan, then page horizontally at medium height.
        let close = app.buttons["publicLibrary.closeSheet"].firstMatch
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.midX, dy: close.frame.minY - 8))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.64))
        start.press(forDuration: 0.05, thenDragTo: end)
        expectation(for: NSPredicate(format: "label == %@", "展開為全螢幕"), evaluatedWith: resize)
        waitForExpectations(timeout: 5)
        carousel.swipeLeft()
        let secondAuthor = app.buttons["publicLibrary.author.https://www.gutenberg.org/ebooks/author/10002.opds"].firstMatch
        XCTAssertTrue(secondAuthor.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThan(secondAuthor.frame.midX, app.frame.minX)
        XCTAssertLessThan(secondAuthor.frame.midX, app.frame.maxX)
        XCTAssertEqual(resize.label, "展開為全螢幕", "Horizontal paging must not change the detent")
        screenshot(app, "storefront-sheet-next-book")
        resize.tap()
        expectation(for: expanded, evaluatedWith: resize)
        waitForExpectations(timeout: 5)
        XCTAssertGreaterThan(secondAuthor.frame.midX, app.frame.minX)
        XCTAssertLessThan(secondAuthor.frame.midX, app.frame.maxX, "Resizing preserves the paged book")
        resize.tap()
        expectation(for: NSPredicate(format: "label == %@", "展開為全螢幕"), evaluatedWith: resize)
        waitForExpectations(timeout: 5)
        carousel.swipeRight()
        let author = app.buttons["publicLibrary.author.https://www.gutenberg.org/ebooks/author/10001.opds"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10))
        author.tap()
        XCTAssertTrue(app.navigationBars["曹雪芹"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["publicLibrary.book.gutenberg:https://www.gutenberg.org/ebooks/23962.opds"].firstMatch.waitForExistence(timeout: 10))
        screenshot(app, "storefront-author-grid")
        XCTAssertLessThan(app.navigationBars["曹雪芹"].frame.minY, app.frame.height * 0.2, "Author navigation uses the expanded sheet")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(resize.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(app.buttons["publicLibrary.categories"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["publicLibrary.book.gutenberg:https://www.gutenberg.org/ebooks/23962.opds"].firstMatch.tap()
        XCTAssertTrue(secondAuthor.waitForExistence(timeout: 10), "Opening a nonfirst shelf book preserves the selection")
        XCTAssertGreaterThan(secondAuthor.frame.midX, app.frame.minX)
        XCTAssertLessThan(secondAuthor.frame.midX, app.frame.maxX)
        close.tap()
    }

    @MainActor
    func testProThemeAndAccessibleResizeControls() {
        let app = application(pro: true)
        let resize = openBook(app)
        XCTAssertEqual(resize.label, "展開為全螢幕")
        resize.tap()
        expectation(for: NSPredicate(format: "label == %@", "還原為半螢幕"), evaluatedWith: resize)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(resize.label, "還原為半螢幕")
        screenshot(app, "storefront-pro-theme-expanded")
        resize.tap()
        expectation(for: NSPredicate(format: "label == %@", "展開為全螢幕"), evaluatedWith: resize)
        waitForExpectations(timeout: 5)
        screenshot(app, "storefront-pro-theme-medium")
        app.buttons["publicLibrary.closeSheet"].firstMatch.tap()
    }
}
