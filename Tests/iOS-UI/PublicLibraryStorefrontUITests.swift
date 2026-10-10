import XCTest

/// Deterministic UI coverage: scroll-driven card expansion and paging, fixture-only OPDS.
/// The test changes no book-source data outside its own temporary directory.
///
/// Since unified library 5c-3 the cards open from the Explore home's 精選 rows, as a new install
/// sees them (`-reset-explore-home`), and the store's own pages from its 我的書庫 tile.
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
            "-reset-public-library-explore", "-reset-explore-home"]
        if pro { app.launchArguments.append("-debug-force-pro") }
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = fixtureDirectory.path
        return app
    }

    /// A 精選 card on the home, scrolled to.
    @MainActor
    private func homeCard(_ app: XCUIApplication, _ number: Int) -> XCUIElement {
        let card = app.buttons["home.card.gutenberg.\(number)"].firstMatch
        for _ in 0..<4 where !card.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(card.exists, app.debugDescription)
        return card
    }

    @MainActor
    private func openBook(_ app: XCUIApplication) -> XCUIElement {
        app.launch()
        let explore = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(explore.waitForExistence(timeout: 30))
        explore.tap()
        screenshot(app, "storefront-home")
        homeCard(app, 24264).tap()
        let close = app.buttons["publicLibrary.closeSheet"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let author = app.buttons["publicLibrary.author.https://www.gutenberg.org/ebooks/author/10001.opds"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10), app.debugDescription)
        return close
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testCardExpansionCarouselAndAuthorWithoutPro() {
        let app = application()
        let close = openBook(app)
        screenshot(app, "storefront-card-resting")
        let author = app.buttons["publicLibrary.author.https://www.gutenberg.org/ebooks/author/10001.opds"].firstMatch
        let restingY = author.frame.minY

        // Scrolling the card up expands it; the card's own scroll is the gesture.
        let carousel = app.scrollViews["publicLibrary.carousel"].firstMatch
        XCTAssertTrue(carousel.exists, app.debugDescription)
        carousel.swipeUp()
        XCTAssertTrue(close.isHittable, "The bar's close button stays over the expanded card")
        screenshot(app, "storefront-card-expanded")

        // Scrolling back returns the card to rest, then page horizontally.
        carousel.swipeDown()
        expectation(for: NSPredicate { _, _ in abs(author.frame.minY - restingY) < 2 }, evaluatedWith: author)
        waitForExpectations(timeout: 5)
        carousel.swipeLeft()
        let secondAuthor = app.buttons["publicLibrary.author.https://www.gutenberg.org/ebooks/author/10002.opds"].firstMatch
        XCTAssertTrue(secondAuthor.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertGreaterThan(secondAuthor.frame.midX, app.frame.minX)
        XCTAssertLessThan(secondAuthor.frame.midX, app.frame.maxX)
        screenshot(app, "storefront-card-next-book")
        carousel.swipeRight()
        XCTAssertTrue(author.waitForExistence(timeout: 10))
        author.tap()
        XCTAssertTrue(app.navigationBars["曹雪芹"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["publicLibrary.book.gutenberg:https://www.gutenberg.org/ebooks/23962.opds"].firstMatch.waitForExistence(timeout: 10))
        screenshot(app, "storefront-author-grid")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        homeCard(app, 23962).tap()
        XCTAssertTrue(secondAuthor.waitForExistence(timeout: 10), "Opening a nonfirst shelf book preserves the selection")
        XCTAssertGreaterThan(secondAuthor.frame.midX, app.frame.minX)
        XCTAssertLessThan(secondAuthor.frame.midX, app.frame.maxX)
        close.tap()
    }

    /// The store's pages are pushed by value (unified library 5c, decision 5): a card opened
    /// two pages deep pushes its author on top of them, and backing out walks the same pages.
    @MainActor
    func testCardFromAPushedPageKeepsTheStack() {
        let app = application()
        app.launch()
        let explore = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(explore.waitForExistence(timeout: 30))
        explore.tap()
        let gutenberg = app.buttons["home.tile.gutenberg.builtin.gutenberg"].firstMatch
        XCTAssertTrue(gutenberg.waitForExistence(timeout: 10), app.debugDescription)
        gutenberg.tap()
        let categories = app.buttons["publicLibrary.categories"].firstMatch
        XCTAssertTrue(categories.waitForExistence(timeout: 10))
        categories.tap()
        XCTAssertTrue(app.navigationBars["分類"].waitForExistence(timeout: 10))
        app.buttons["中文書籍"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["中文書籍"].waitForExistence(timeout: 10))
        app.buttons["publicLibrary.book.gutenberg:https://www.gutenberg.org/ebooks/24264.opds"].firstMatch.tap()
        let close = app.buttons["publicLibrary.closeSheet"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let author = app.buttons["publicLibrary.author.https://www.gutenberg.org/ebooks/author/10001.opds"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10), app.debugDescription)
        author.tap()
        XCTAssertTrue(app.navigationBars["曹雪芹"].waitForExistence(timeout: 10))
        screenshot(app, "storefront-author-from-category")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Back from the author returns to the card")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["中文書籍"].exists, "The card closes onto the page it was opened from")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["分類"].waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(categories.waitForExistence(timeout: 10))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(gutenberg.waitForExistence(timeout: 10), "Back from the store's page returns to the home")
    }

    @MainActor
    func testProThemeCard() {
        let app = application(pro: true)
        let close = openBook(app)
        screenshot(app, "storefront-pro-theme-resting")
        let carousel = app.scrollViews["publicLibrary.carousel"].firstMatch
        carousel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            .press(forDuration: 0.1, thenDragTo: carousel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)), withVelocity: .slow, thenHoldForDuration: 0.3)
        screenshot(app, "storefront-pro-theme-expanded")
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testPullDownClosesRestingCard() {
        let app = application()
        let close = openBook(app)
        let carousel = app.scrollViews["publicLibrary.carousel"].firstMatch
        carousel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: carousel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Letting go of a pulled-down card closes it")
        XCTAssertTrue(app.tabBars.buttons["探索"].firstMatch.isHittable)
    }
}
