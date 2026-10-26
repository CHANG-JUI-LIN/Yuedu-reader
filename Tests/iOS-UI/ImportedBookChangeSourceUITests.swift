import XCTest

/// A book imported on this device changes source like any other (maintainer, 2026-10-26:
/// 「書架導入的書長按書名膠囊為什麼不能直接換源」): holding the reader's title capsule opens 換源,
/// which names where the book is read from now; picking a 來源配置 moves the shelf book to that
/// source's copy, and the imported file stays in 換源 to switch back to.
///
/// The book is a text file the test writes, imported at launch (`-auto-import-epub`, DEBUG). The
/// switch reads the same book from `reader_chrome_fixture.py`'s source, run from the repo root:
/// `python3 -I scripts/reader_chrome_fixture.py` (port 18771). Its source lives in a scratch
/// `-book-source-store-dir`, so the simulator's own sources are never touched.
final class ImportedBookChangeSourceUITests: XCTestCase {
    // `localhost`, not 127.0.0.1: a request to a reserved address is refused (`safeURL`).
    private static let fixture = "http://localhost:18771"
    private static let sourceName = "Chrome Source"
    /// A new book every run: `-auto-import-epub` skips a title already on the shelf, and the
    /// fixture serves the run's title.
    private let token = String(Int.random(in: 1000...9999))
    private var title: String { "Chrome Fixture \(token)" }
    private let importedLine = "匯入的書也能換源。"
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportedChangeSource-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The fixture's book names this author: the copy the source finds is the same work.
        let text = "《\(title)》作者：測試作者\n\n第1章\n\n" + String(repeating: "\(importedLine)\n", count: 40)
            + "\n第2章\n\n" + String(repeating: "\(importedLine)\n", count: 40)
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(title).txt"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    /// Under a StoreKit test session: without one, iOS 17.5 puts a system Apple ID sign-in over
    /// the app on every launch, and the reader is never reached.
    @MainActor
    private func launch(sourceDirectory: URL? = nil) throws -> XCUIApplication {
        _ = try StoreKitTestSessions.fresh(StoreKitTestSessions.yueduPro())
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-auto-import-epub", folder.appendingPathComponent("\(title).txt").path,
                               "-auto-import-title", title]
            + (sourceDirectory.map { ["-book-source-store-dir", $0.path] } ?? [])
        app.launch()
        return app
    }

    /// Opens the imported book from 書架 and holds its title capsule.
    @MainActor
    private func openChangeSource(_ app: XCUIApplication) -> XCUIElement {
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30), app.debugDescription)
        shelfTab.tap()
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), app.debugDescription)
        book.tap()
        return holdCapsule(app)
    }

    @MainActor
    private func holdCapsule(_ app: XCUIApplication) -> XCUIElement {
        let capsule = app.buttons["reader_title_capsule"].firstMatch
        if !capsule.waitForExistence(timeout: 5) || !capsule.isHittable {
            // The chrome shows on a tap in the page's middle.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(capsule.waitForExistence(timeout: 10), app.debugDescription)
        capsule.press(forDuration: 1.2)
        let current = app.staticTexts["目前來源"].firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 10), "換源 opens.\n\(app.debugDescription)")
        return current
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testImportedBookCapsuleLongPressOpensChangeSource() throws {
        let app = try launch()
        let current = openChangeSource(app)
        attach(app, "imported-change-source")
        XCTAssertFalse(app.buttons["reader_book_card_details"].exists, app.debugDescription)
        app.buttons["關閉"].firstMatch.tap()
        XCTAssertTrue(current.waitForNonExistence(timeout: 10), app.debugDescription)
    }

    /// The imported book switches to the source's copy, and back to the file from 已知的閱讀來源.
    @MainActor
    func testImportedBookSwitchesToSourceAndBack() throws {
        let sources = folder.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source: [String: Any] = [
            "bookSourceName": Self.sourceName,
            "bookSourceUrl": Self.fixture,
            "bookSourceType": 0,
            "enabled": true,
            "searchUrl": "\(Self.fixture)/search?q={{key}}&page={{page}}",
            "ruleSearch": ["bookList": "class.book", "name": "tag.h3@text", "author": "class.author@text",
                           "bookUrl": "tag.a@href"],
            "ruleToc": ["chapterList": "class.chapter", "chapterName": "tag.a@text", "chapterUrl": "tag.a@href"],
            "ruleContent": ["content": "id.content@html"],
            // A new search cache key each run (it includes this): no earlier run's results.
            "lastUpdateTime": Int(Date().timeIntervalSince1970 * 1000),
        ]
        try JSONSerialization.data(withJSONObject: [source]).write(to: sources.appendingPathComponent("book_sources.json"))
        _ = try Data(contentsOf: URL(string: "\(Self.fixture)/reset?token=\(token)")!)

        let app = try launch(sourceDirectory: sources)
        let current = openChangeSource(app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", Self.sourceName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The source finds the book.\n\(app.debugDescription)")
        row.tap()
        XCTAssertTrue(current.waitForNonExistence(timeout: 30), "The switch closes 換源.\n\(app.debugDescription)")
        let sourceText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "這是一段用來測試閱讀器工具列的正文")).firstMatch
        XCTAssertTrue(sourceText.waitForExistence(timeout: 30), "The reader reads the source's copy.\n\(app.debugDescription)")
        attach(app, "switched-to-source")

        _ = holdCapsule(app)
        let local = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "本機")).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 10), "The imported file is kept to switch back to.\n\(app.debugDescription)")
        local.tap()
        XCTAssertTrue(current.waitForNonExistence(timeout: 30), app.debugDescription)
        let importedText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", importedLine)).firstMatch
        XCTAssertTrue(importedText.waitForExistence(timeout: 30), "The reader reads the imported file again.\n\(app.debugDescription)")
        attach(app, "switched-back")
    }
}
