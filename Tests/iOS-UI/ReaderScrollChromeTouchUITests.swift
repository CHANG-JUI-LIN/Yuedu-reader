import XCTest

/// FB-173: in 滾動 mode, once the reading menu was up, the page took no more touches — a tap
/// on the text left the menu up and a drag did not scroll — while every menu button still
/// worked. Only leaving the book and opening it again brought the page back.
///
/// The local book is a text file the test writes, imported at launch (`-auto-import-epub`
/// with an absolute path, DEBUG). The online book is served from outside the simulator, from
/// the repo root: `python3 -I scripts/reader_chrome_fixture.py` (port 18771).
final class ReaderScrollChromeTouchUITests: XCTestCase {
    private static let fixture = "http://localhost:18771"
    private static let sourceName = "Chrome Source"
    private let title = "滾動選單觸控測試"
    private let body = "滾動選單觸控測試正文，用來確認選單叫出後頁面仍然能點能滑。"
    private let token = String(Int.random(in: 1000...9999))
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderScrollChromeTouch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var text = ""
        for chapter in 1...4 {
            text += "第\(chapter)章 測試\(chapter)\n\n"
            for paragraph in 0..<60 { text += "\(body)第\(chapter)章第\(paragraph)段。\n\n" }
        }
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(title).txt"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The bottom bar's 目錄 button: there exactly while the reading menu is up.
    @MainActor
    private func menuButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["reader_tool_tableOfContents"].firstMatch
    }

    @MainActor
    func testLocalBookPageTakesTouchesAfterTheMenuWasShown() {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-auto-import-epub", folder.appendingPathComponent("\(title).txt").path,
                               "-auto-import-title", title, "-yd_scroll_mode", "YES",
                               "-book-source-store-dir", folder.appendingPathComponent("sources").path]
        app.launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), app.debugDescription)
        cell.tap()
        checkPageTakesTouches(app, text: body)
    }

    /// The reporter's way in: 探索's 繼續閱讀 pushes the reader onto 探索's own stack
    /// (`PublicLibraryReaderRoute`), not through 書架's card transition.
    @MainActor
    func testContinueReadingPageTakesTouchesAfterTheMenuWasShown() {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-auto-import-epub", folder.appendingPathComponent("\(title).txt").path,
                               "-auto-import-title", title, "-yd_scroll_mode", "YES",
                               "-book-source-store-dir", folder.appendingPathComponent("sources").path]
        app.launch()
        // Opened once from 書架, so it is on 繼續閱讀.
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), app.debugDescription)
        cell.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 60), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let back = app.buttons["reader_back_button"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()

        let exploreTab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(exploreTab.waitForExistence(timeout: 10), app.debugDescription)
        exploreTab.tap()
        let card = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'home.card.' AND label BEGINSWITH %@", title + "，")
        ).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 30), app.debugDescription)
        card.tap()
        checkPageTakesTouches(app, text: body)
    }

    @MainActor
    func testOnlineBookPageTakesTouchesAfterTheMenuWasShown() throws {
        let source: [String: Any] = [
            "bookSourceName": Self.sourceName,
            "bookSourceUrl": Self.fixture,
            "bookSourceType": 0,
            "enabled": true,
            "enabledExplore": true,
            "exploreUrl": "熱門::\(Self.fixture)/explore?page={{page}}",
            "searchUrl": "\(Self.fixture)/search?q={{key}}&page={{page}}",
            "ruleExplore": ["bookList": "class.book", "name": "tag.h3@text", "author": "class.author@text",
                            "bookUrl": "tag.a@href"],
            "ruleSearch": ["bookList": "class.book", "name": "tag.h3@text", "author": "class.author@text",
                           "bookUrl": "tag.a@href"],
            "ruleToc": ["chapterList": "class.chapter", "chapterName": "tag.a@text", "chapterUrl": "tag.a@href"],
            "ruleContent": ["content": "id.content@html"],
            "lastUpdateTime": Int(Date().timeIntervalSince1970 * 1000),
        ]
        let sources = folder.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [source]).write(to: sources.appendingPathComponent("book_sources.json"))
        _ = try Data(contentsOf: URL(string: "\(Self.fixture)/reset?token=\(token)")!)

        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-yd_scroll_mode", "YES",
                               "-book-source-store-dir", sources.path]
        app.launch()
        let libraryTab = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 30), app.debugDescription)
        libraryTab.tap()
        let all = app.buttons["library.sources.all"].firstMatch
        for _ in 0..<6 where !all.exists { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(all.waitForExistence(timeout: 10), app.debugDescription)
        all.tap()
        let sourceButton = app.buttons["library.source.\(Self.sourceName)"].firstMatch
        XCTAssertTrue(sourceButton.waitForExistence(timeout: 10), app.debugDescription)
        sourceButton.tap()
        let book = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chrome Fixture \(token)")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '立即閱讀' OR label BEGINSWITH '開始閱讀'")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 30), app.debugDescription)
        for _ in 0..<6 where !read.isHittable { app.swipeDown(velocity: .slow) }
        read.tap()
        checkPageTakesTouches(app, text: "測試閱讀器工具列")
    }

    /// Menu up, a tap on the page puts it away; menu up again, a drag on the page scrolls it.
    @MainActor
    private func checkPageTakesTouches(_ app: XCUIApplication, text: String) {
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 60), "The reader opens the book.\n\(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        screenshot(app, "opened")

        let middle = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.tap()
        XCTAssertTrue(menuButton(app).waitForExistence(timeout: 5), "The menu comes up.\n\(app.debugDescription)")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        screenshot(app, "menu-up")

        middle.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: menuButton(app))
        let tapResult = XCTWaiter.wait(for: [hidden], timeout: 5)
        screenshot(app, "after-second-tap")
        XCTAssertEqual(tapResult, .completed, "A tap on the page hides the menu.\n\(app.debugDescription)")

        middle.tap()
        XCTAssertTrue(menuButton(app).waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let before = content.frame.minY
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        start.press(forDuration: 0.05, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let after = content.exists ? content.frame.minY : -.greatestFiniteMagnitude
        screenshot(app, "after-drag")
        XCTAssertNotEqual(before, after, accuracy: 20, "A drag on the page scrolls it.\n\(app.debugDescription)")
    }
}
