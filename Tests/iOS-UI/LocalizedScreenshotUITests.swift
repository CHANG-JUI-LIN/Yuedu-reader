import XCTest

/// Screenshot harness: walks the same three screens in every shipping locale so
/// the website and App Store listings can be refreshed from one run.
///
/// Preconditions (set up by scripts/run_localized_screenshots.sh):
/// - App installed, the public-domain EPUBs already imported onto the shelf
///   (Alice / 紅樓夢 / 西遊記 / こころ / 운수 좋은 날).
///
/// Each test launches in one locale, captures Library → Reading → Settings and
/// attaches them; the driver script exports the attachments out of the
/// xcresult bundle.
final class LocalizedScreenshotUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - One test per locale (a fresh launch each time)

    @MainActor func testScreenshotsEnglish() throws {
        try capture(locale: "en", region: "en_US", bookTitle: "Alice's Adventures in Wonderland")
    }

    @MainActor func testScreenshotsTraditionalChinese() throws {
        try capture(locale: "zh-Hant", region: "zh_TW", bookTitle: "紅樓夢")
    }

    @MainActor func testScreenshotsSimplifiedChinese() throws {
        try capture(locale: "zh-Hans", region: "zh_CN", bookTitle: "西游记")
    }

    @MainActor func testScreenshotsJapanese() throws {
        try capture(locale: "ja", region: "ja_JP", bookTitle: "こころ")
    }

    @MainActor func testScreenshotsKorean() throws {
        try capture(locale: "ko", region: "ko_KR", bookTitle: "운수 좋은 날")
    }

    // MARK: - Walk

    @MainActor
    private func capture(locale: String, region: String, bookTitle: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(\(locale))", "-AppleLocale", region]
        app.launch()

        // The app restores the last tab it was on, so always start from Library.
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30), "[\(locale)] tab bar should appear")
        tabBar.buttons.element(boundBy: 0).tap()

        // The shelf renders as a table in list mode and a grid in cover mode, so
        // wait on the book row itself rather than on one container's identifier.
        // Book titles are not localized, which makes this locale-independent.
        let row = app.staticTexts[bookTitle]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "[\(locale)] \(bookTitle) should be on the shelf")
        // Covers decode asynchronously; a settled shelf is what we want to show.
        Thread.sleep(forTimeInterval: 3.0)
        attach(name: "\(locale)-library")

        row.tap()

        // The reader opens with its chrome hidden, so no toolbar element exists
        // yet to wait on — the shelf row going away is what marks the
        // transition. Waiting on `reader_back_button` here would always fail.
        XCTAssertTrue(row.waitForNonExistence(timeout: 20), "[\(locale)] reader should replace the shelf")
        Thread.sleep(forTimeInterval: 5.0)

        // Shot at the chapter opening: the heading plus the first paragraphs is
        // what the page is meant to show. (An earlier version turned a page
        // first with swipeLeft(); it never actually advanced, so it only added
        // time.)
        attach(name: "\(locale)-reading")

        // Reading toolbar: a centre tap expands it. This is also where the
        // reader's own controls finally become queryable.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let back = app.buttons["reader_back_button"]
        XCTAssertTrue(back.waitForExistence(timeout: 15), "[\(locale)] reading toolbar should expand")
        Thread.sleep(forTimeInterval: 1.0)
        attach(name: "\(locale)-reading-toolbar")

        // Table of contents, reached by the tool identifier rather than its
        // label, which is localized.
        let toc = app.buttons["reader_tool_tableOfContents"]
        if toc.waitForExistence(timeout: 5) {
            toc.tap()
            Thread.sleep(forTimeInterval: 2.5)
            attach(name: "\(locale)-toc")
            app.swipeDown()            // the TOC is a sheet
            Thread.sleep(forTimeInterval: 1.5)
        }

        // Putting the sheet away can leave the chrome hidden: bring it back to reach the back button.
        if !back.waitForExistence(timeout: 2) { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(back.waitForExistence(timeout: 5), "[\(locale)] reading toolbar should be up to leave the book")
        back.tap()
        Thread.sleep(forTimeInterval: 2.0)

        // Settings is next to last in the default tab order (書架・探索・資源庫・設定・搜尋).
        let settingsIndex = tabBar.buttons.count - 2
        if settingsIndex >= 0 {
            tabBar.buttons.element(boundBy: settingsIndex).tap()
            Thread.sleep(forTimeInterval: 2.0)
            attach(name: "\(locale)-settings")
        }
    }

    // MARK: - Formats other than EPUB

    @MainActor func testFormatsEnglish() throws {
        try captureFormats(locale: "en", region: "en_US")
    }

    @MainActor func testFormatsTraditionalChinese() throws {
        try captureFormats(locale: "zh-Hant", region: "zh_TW")
    }

    @MainActor func testFormatsSimplifiedChinese() throws {
        try captureFormats(locale: "zh-Hans", region: "zh_CN")
    }

    /// Comics and PDF were the two formats the website had no screenshot for.
    @MainActor
    private func captureFormats(locale: String, region: String) throws {
        // The scanned PDF opens on its colophon/contents leaf, which is almost
        // blank; the drawings start a few leaves in. The comic's first page is
        // already a full Sunday page, so it needs no advancing.
        for (title, shot, advance) in [("Little Nemo in Slumberland", "manga", 0),
                                       ("北斎漫画 一編", "pdf", 6)] {
            let app = XCUIApplication()
            app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(\(locale))", "-AppleLocale", region]
            app.launch()

            let tabBar = app.tabBars.firstMatch
            XCTAssertTrue(tabBar.waitForExistence(timeout: 30), "[\(locale)] tab bar")
            tabBar.buttons.element(boundBy: 0).tap()

            let row = app.staticTexts[title]
            XCTAssertTrue(row.waitForExistence(timeout: 30), "[\(locale)] \(title) should be on the shelf")
            row.tap()
            XCTAssertTrue(row.waitForNonExistence(timeout: 20), "[\(locale)] \(title) should open")
            // Page images decode after the view appears; a comic page is large.
            Thread.sleep(forTimeInterval: 6.0)
            // Drag across the page, left to right. Three things make this the
            // only gesture that advances: the pages are images, so a tap on
            // them does nothing; `swipeLeft()` is too short and fast to
            // register; and FixedPageReaderView defaults to `.rtl` (the manga
            // convention), so dragging right-to-left asks for the *previous*
            // page and silently does nothing on page 1.
            for _ in 0..<advance {
                let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
                let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.88, dy: 0.5))
                start.press(forDuration: 0.08, thenDragTo: end)
                Thread.sleep(forTimeInterval: 1.4)
            }
            if advance > 0 { Thread.sleep(forTimeInterval: 3.0) }
            attach(name: "\(locale)-\(shot)")
            app.terminate()
        }
    }

    @MainActor
    private func attach(name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        print("UI-SHOT \(name)")
    }
}
