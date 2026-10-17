import XCTest

/// Deterministic UI coverage: scroll-driven card expansion and paging, fixture-only OPDS.
/// The test changes no book-source data outside its own temporary directory.
///
/// Since unified library 5c-3 the cards open from the Explore home, as a new install sees it
/// (`-reset-explore-home`): its books from 熱門, answered here by a fixture, and the store's
/// lists from 精選書單's cards (decision 37).
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
            <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">
            <p>This edition has images.</p>
            <p>
            Title:
            \(title)
            </p>
            <p>
            Summary:
            這是書店互動測試使用的書籍介紹。測試只讀取本機目錄，不下載正文。
            </p>
            <p>EBook No.: \(id)</p>
            <p>Downloads: 1000</p>
            <p>Rights: Public domain in the USA.</p>
            </div></content>
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
        // 熱門, the home's row of books, holding the three books above.
        let popular = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Popular</title>
        <entry><id>https://www.gutenberg.org/ebooks/24264.opds</id><title>紅樓夢</title><content>曹雪芹</content><link rel="subsection" type="application/atom+xml" href="/ebooks/24264.opds"/></entry>
        <entry><id>https://www.gutenberg.org/ebooks/23962.opds</id><title>西遊記</title><content>吳承恩</content><link rel="subsection" type="application/atom+xml" href="/ebooks/23962.opds"/></entry>
        <entry><id>https://www.gutenberg.org/ebooks/23950.opds</id><title>三國志演義</title><content>羅貫中</content><link rel="subsection" type="application/atom+xml" href="/ebooks/23950.opds"/></entry>
        </feed>
        """
        try Data(popular.utf8).write(to: fixtureDirectory.appendingPathComponent("ebooks_search.opds@sort_order=downloads.xml"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: fixtureDirectory)
    }

    @MainActor
    private func application(pro: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-yd_source_disclaimer_accepted", "YES", "-book-source-store-dir", fixtureDirectory.appendingPathComponent("sources").path,
            "-reset-public-library-explore", "-reset-explore-home"]
        if pro { app.launchArguments.append("-debug-force-pro") }
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = fixtureDirectory.path
        return app
    }

    /// A book of 熱門 on the home, scrolled to.
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
    func testCardExpansionCarouselAndAuthorWithoutPro() throws {
        try XCTSkipIf(true, "The store's card carousel is off 探索 and 搜索 for now (Phase 5 plan, decision 27); its code stays.")
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

    /// The store's pages are pushed by value (unified library 5c, decision 5), and since 5f a book
    /// opens 作品詳情 on top of the page it was tapped on (Phase 5 plan, decision 27). 作品詳情 is
    /// the book's one page (decision 28): the catalog entry's format, actions and description are
    /// on it, with no second page under it. The page is 中文書籍's, opened from its 精選書單 card.
    @MainActor
    func testBookFromAPushedPageKeepsTheStack() {
        let app = application()
        app.launch()
        let explore = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(explore.waitForExistence(timeout: 30))
        explore.tap()
        let list = app.buttons["home.collection.gutenberg.chinese"].firstMatch
        for _ in 0..<4 where !list.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(list.exists, app.debugDescription)
        list.tap()
        XCTAssertTrue(app.navigationBars["中文書籍"].waitForExistence(timeout: 10))
        app.buttons["publicLibrary.book.gutenberg:https://www.gutenberg.org/ebooks/24264.opds"].firstMatch.tap()
        let source = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["publicLibrary.closeSheet"].exists, "No card carousel over the store's page")
        let format = app.descendants(matching: .any)["detail.info.format"].firstMatch
        XCTAssertTrue(format.waitForExistence(timeout: 10), "The catalog entry is read on the page.\n\(app.debugDescription)")
        XCTAssertEqual(format.value as? String, "EPUB")
        // The page is where the book is read: no download or library-website rows (2026-10-12).
        XCTAssertFalse(app.buttons["下載供離線閱讀"].firstMatch.exists, app.debugDescription)
        // Gutenberg's content is the book's record; the description is its Summary field alone.
        let description = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '書店互動測試'")).firstMatch
        XCTAssertTrue(description.exists, "The entry's description.\n\(app.debugDescription)")
        XCTAssertFalse(description.label.contains("EBook No."), "The record's other fields are not the description: \(description.label)")
        XCTAssertFalse(description.label.hasPrefix("Summary"), description.label)
        screenshot(app, "work-detail-from-collection")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["中文書籍"].waitForExistence(timeout: 10), "Back from 作品詳情 returns to the page it was opened from")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(list.waitForExistence(timeout: 10), "Back from 中文書籍 returns to the home")
        XCTAssertTrue(app.tabBars.buttons["探索"].firstMatch.isHittable, "The home is 探索's root")
    }

    /// A home card opens 作品詳情 (decision 27): the book, what reads it, and where it is from.
    @MainActor
    func testHomeCardOpensWorkDetail() {
        let app = application()
        app.launch()
        let explore = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(explore.waitForExistence(timeout: 30))
        explore.tap()
        homeCard(app, 24264).tap()
        let source = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(source.value as? String, "Project Gutenberg")
        XCTAssertTrue(app.staticTexts["紅樓夢"].firstMatch.exists, app.debugDescription)
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["開始閱讀", "繼續閱讀"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 10), app.debugDescription)
        let enabled = NSPredicate(format: "isEnabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: enabled, evaluatedWith: read)], timeout: 10), .completed,
                       "Reads once the catalog entry is in.\n\(app.debugDescription)")
        screenshot(app, "work-detail-from-home")

        // Editorial Minimalism: the author leads to their page, and 作者其他作品 lists their
        // other books from that page's feed, without this one.
        let author = app.buttons["publicLibrary.author.https://www.gutenberg.org/ebooks/author/10001.opds"].firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10), app.debugDescription)
        author.tap()
        XCTAssertTrue(app.navigationBars["曹雪芹"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(author.waitForExistence(timeout: 10), app.debugDescription)
        let otherWorks = app.staticTexts["作者其他作品"].firstMatch
        for _ in 0..<6 where !(otherWorks.exists && otherWorks.isHittable) { app.swipeUp() }
        XCTAssertTrue(otherWorks.waitForExistence(timeout: 10), app.debugDescription)
        let cards = app.buttons.matching(identifier: "detail.authorWorks.book")
        let other = cards.matching(NSPredicate(format: "label CONTAINS '作者作品測試'")).firstMatch
        XCTAssertTrue(other.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(cards.count, 1, "Not the book on the page.\n\(app.debugDescription)")
        screenshot(app, "work-detail-author-works")
        other.tap()
        // Its own page: the card reads as one button, so only the page's title is this text.
        XCTAssertTrue(app.staticTexts["作者作品測試"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(otherWorks.waitForExistence(timeout: 10), app.debugDescription)

        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(homeCard(app, 24264).waitForExistence(timeout: 10))
        XCTAssertTrue(explore.isHittable, "Back from 作品詳情 returns to the home")
    }

    @MainActor
    func testProThemeCard() throws {
        try XCTSkipIf(true, "The store's card carousel is off 探索 and 搜索 for now (Phase 5 plan, decision 27); its code stays.")
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
    func testPullDownClosesRestingCard() throws {
        try XCTSkipIf(true, "The store's card carousel is off 探索 and 搜索 for now (Phase 5 plan, decision 27); its code stays.")
        let app = application()
        let close = openBook(app)
        let carousel = app.scrollViews["publicLibrary.carousel"].firstMatch
        carousel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: carousel.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)), withVelocity: .slow, thenHoldForDuration: 0.1)
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Letting go of a pulled-down card closes it")
        XCTAssertTrue(app.tabBars.buttons["探索"].firstMatch.isHittable)
    }
}
