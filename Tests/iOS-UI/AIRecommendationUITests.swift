import XCTest

/// AI 推薦 8f: the official module end to end. Its section is added to the home, 產生推薦 asks
/// the AI service, the works appear, one opens 作品詳情 with its 推薦理由 and 來源, and
/// 重新產生 replaces the list.
///
/// The AI service is a fixture served from outside the simulator before the run, from the repo
/// root: `python3 -I scripts/ai_recommendation_fixture.py` (port 18767). The app is pointed at it
/// with `-debug-ai-endpoint` and given Pro with `-debug-force-pro` (both DEBUG only). It
/// answers 十二國記 and 鬼吹燈 first, then 球狀閃電 and 銀河英雄傳說.
///
/// A run needs a book the reader has opened: the test imports a text file
/// (`-auto-import-epub` with an absolute path) and opens it once. Without the official modules
/// there is no Open Library to look the works up in, so nothing leaves the machine.
final class AIRecommendationUITests: XCTestCase {
    private let title = "AI 推薦測試"
    private let body = "AI 推薦測試正文，用來確認閱讀器打開了這本書。"
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AIRecommendation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // No book source: 作品詳情 searches the enabled ones as it opens, and step 4 reads the
        // row with none to search.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sources"), withIntermediateDirectories: true)
        let text = "第一章 開始\n\n\(body)\n\n" + String(repeating: "\(body)\n", count: 20)
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(title).txt"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        var swipes = 0
        while !element.exists, swipes < 10 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            swipes += 1
        }
        return element
    }

    /// An AI pick's card on the home, by the title the fixture gave.
    @MainActor
    private func card(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.card.bibliographic.' AND label == %@", title)).firstMatch
    }

    @MainActor
    func testGenerateOpenAndRegenerate() {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-debug-force-pro", "-debug-ai-endpoint", "http://localhost:18767",
                               "-reset-explore-home", "-reset-ai-recommendations",
                               "-book-source-store-dir", folder.appendingPathComponent("sources").path,
                               "-auto-import-epub", folder.appendingPathComponent("\(title).txt").path,
                               "-auto-import-title", title, "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO",
                               "-yd_appearance_reader_interface", "classic"]
        app.launch()

        // A book the reader has opened: the run sends the recently read ones.
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), app.debugDescription)
        book.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), "The reader opens the book.\n\(app.debugDescription)")
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        XCTAssertTrue(content.waitForNonExistence(timeout: 10), app.debugDescription)

        // 1. The section, from 資源庫's 官方模組. 探索 first: its home is made on the first visit.
        let exploreTab = app.tabBars.buttons["探索"].firstMatch
        exploreTab.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.'")).firstMatch
            .waitForExistence(timeout: 30), app.debugDescription)
        app.tabBars.buttons["資源庫"].firstMatch.tap()
        let official = scrolledTo(app.buttons["library.module.official.aiRecommendations"].firstMatch, in: app)
        XCTAssertTrue(official.waitForExistence(timeout: 10), app.debugDescription)
        official.tap()
        let add = app.buttons["aiModule.addToHome"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.tap()
        XCTAssertTrue(app.descendants(matching: .any)["aiModule.onHome"].firstMatch.waitForExistence(timeout: 5),
                      app.debugDescription)
        attach(app, "ai-module-on-home")

        // 2. 產生推薦, on the home's row. The tab bar shows on root pages only: back first.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(exploreTab.waitForExistence(timeout: 5), app.debugDescription)
        exploreTab.tap()
        let generate = scrolledTo(app.buttons["home.ai.generate"].firstMatch, in: app)
        XCTAssertTrue(generate.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "ai-row-before-first-run")
        generate.tap()

        // 3. The works.
        let first = card(app, "十二國記")
        XCTAssertTrue(first.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(card(app, "鬼吹燈").exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "AI 產生 · Fixture · ")).firstMatch.exists,
                      "The subtitle names the service.\n\(app.debugDescription)")
        attach(app, "ai-row-works")

        // 4. 作品詳情: 推薦理由, marked AI 產生, and 來源 saying nothing is readable.
        // The row is the home's last: on iOS 17 the opaque tab bar covers the card's centre.
        let tabBar = app.tabBars.firstMatch
        for _ in 0..<4 where first.frame.maxY > tabBar.frame.minY {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
        }
        first.tap()
        let reason = app.staticTexts["你最近讀了不少架空奇幻，這部群像小說節奏紮實。"].firstMatch
        let find = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(scrolledTo(reason, in: app).exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["推薦理由"].firstMatch.exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts["AI 產生"].firstMatch.exists, app.debugDescription)
        attach(app, "ai-work-detail-reason")
        for _ in 0..<8 where !find.isHittable { app.swipeUp() }
        XCTAssertEqual(find.label, "來源")
        expectation(for: NSPredicate(format: "value CONTAINS %@", "未找到可用來源"), evaluatedWith: find)
        waitForExpectations(timeout: 10)
        attach(app, "ai-work-detail-find-sources")
        app.navigationBars.buttons.firstMatch.tap()

        // 5. 重新產生 from the row's •••: the new list replaces the old one.
        let more = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.row.more.'")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
        more.tap()
        let regenerate = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "重新產生", "重新產生,")).firstMatch
        XCTAssertTrue(regenerate.waitForExistence(timeout: 5), app.debugDescription)
        regenerate.tap()
        XCTAssertTrue(card(app, "球狀閃電").waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(card(app, "銀河英雄傳說").exists, app.debugDescription)
        XCTAssertFalse(card(app, "十二國記").exists, "重新產生 replaces the list.\n\(app.debugDescription)")
        attach(app, "ai-row-regenerated")
    }
}
