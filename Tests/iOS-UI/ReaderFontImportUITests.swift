import XCTest

/// Feedback #61 (iOS 18.7.8, build 135, with a recording): 閱讀設定 › 字體 › 匯入字體… closed the
/// menu and showed nothing. Not the menu: the iOS 17 + button, outside any menu, failed the
/// same way, while 匯入閱讀設定 on the same sheet worked. Both presenters — the sheet, and the
/// reader it hands the picker to on iOS 17 — carried a font `.fileImporter` beside
/// `readerStyleImportPresentation`'s, and SwiftUI presents only one of two on a view.
///
/// The book is served from outside the simulator, from the repo root:
/// `python3 -I scripts/reader_chrome_fixture.py` (port 18771), as for
/// `ReaderChromeAccessibilityUITests`. Its source lives in a scratch `-book-source-store-dir`.
final class ReaderFontImportUITests: XCTestCase {
    // `localhost`, not 127.0.0.1: a request to a reserved address is refused (`safeURL`).
    private static let fixture = "http://localhost:18771"
    private static let sourceName = "Font Import Source"
    private var directory: URL!
    private let token = String(Int.random(in: 1000...9999))
    private var title: String { "Chrome Fixture \(token)" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderFontImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        try JSONSerialization.data(withJSONObject: [source])
            .write(to: directory.appendingPathComponent("book_sources.json"))
        _ = try Data(contentsOf: URL(string: "\(Self.fixture)/reset?token=\(token)")!)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testReaderSettingsFontImportOpensDocumentPicker() throws {
        let app = try openReaderSettings()

        // 字體 is a menu row with 匯入字體… inside it where reader settings presents the picker
        // itself, and a separate + button beside the row where it hands the picker to the reader.
        let directImport = app.buttons["匯入字體..."].firstMatch
        let fontRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "字體")).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in directImport.exists || fontRow.exists },
                                              object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed, app.debugDescription)
        if directImport.exists, directImport.isHittable {
            directImport.tap()
        } else {
            fontRow.tap()
            let menuItem = app.buttons["匯入字體..."].firstMatch
            XCTAssertTrue(menuItem.waitForExistence(timeout: 5), app.debugDescription)
            menuItem.tap()
        }
        expectDocumentPicker(app, after: "匯入字體...")
    }

    /// The same sheet's direct import button, outside any menu.
    @MainActor
    func testReaderSettingsBackupImportOpensDocumentPicker() throws {
        let app = try openReaderSettings()
        let button = app.buttons["匯入閱讀設定"].firstMatch
        // A row half under the home indicator still counts as hittable, and a tap at its centre
        // there is the system's (seen on iOS 18.6): scroll until the centre clears that band.
        let clear = app.windows.firstMatch.frame.maxY - 44
        for _ in 0..<12 where !(button.exists && button.isHittable && button.frame.midY < clear) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(button.isHittable && button.frame.midY < clear, "\(button.frame)\n\(app.debugDescription)")
        button.tap()
        expectDocumentPicker(app, after: "匯入閱讀設定")
    }

    /// The reader on the run's book, with 閱讀設定 open over it.
    @MainActor
    private func openReaderSettings() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-debug-force-pro",
                               "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.path]
        app.launch()
        openBook(app)

        let text = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "測試閱讀器工具列")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), "the chapter never showed\n\(app.debugDescription)")
        showChrome(app)
        // 主題 opens the quick panel; its bottom-row 自訂 opens 閱讀設定. The panel's background
        // pager has a 自訂 too, above it.
        app.buttons["reader_tool_settings"].firstMatch.tap()
        let autoRead = app.buttons["自動閱讀"].firstMatch
        XCTAssertTrue(autoRead.waitForExistence(timeout: 10), app.debugDescription)
        let customize = app.buttons.matching(NSPredicate(format: "label == %@", "自訂")).allElementsBoundByIndex
            .max { $0.frame.minY < $1.frame.minY }
        try XCTUnwrap(customize, app.debugDescription).tap()
        XCTAssertTrue(app.navigationBars["閱讀設定"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    /// The system's document picker: its 瀏覽／最近項目 tabs.
    @MainActor
    private func expectDocumentPicker(_ app: XCUIApplication, after action: String) {
        let picker = app.descendants(matching: .any).matching(NSPredicate(
            format: "label IN %@ OR identifier IN %@",
            ["瀏覽", "最近項目", "Browse", "Recents"], ["Browse", "Recents"]
        )).firstMatch
        let shown = picker.waitForExistence(timeout: 15)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "after \(action)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertTrue(shown, "\(action) showed no document picker\n\(app.debugDescription)")
    }

    // MARK: Route

    /// 資源庫 › 所有來源配置 › the source › the run's book › 立即閱讀.
    @MainActor
    private func openBook(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["資源庫"].firstMatch
        let rail = app.buttons["資源庫"].firstMatch
        let found = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in tab.exists || rail.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 30), .completed, app.debugDescription)
        (tab.exists ? tab : rail).tap()
        let all = app.buttons["library.sources.all"].firstMatch
        for _ in 0..<6 where !all.exists { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(all.waitForExistence(timeout: 10), app.debugDescription)
        all.tap()
        let source = app.buttons["library.source.\(Self.sourceName)"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        source.tap()
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '立即閱讀' OR label BEGINSWITH '開始閱讀'"))
            .firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 30), app.debugDescription)
        for _ in 0..<6 where !read.isHittable { app.swipeDown(velocity: .slow) }
        read.tap()
    }

    /// Taps the page until the reader's chrome is up (its top bar's back button hittable).
    @MainActor
    private func showChrome(_ app: XCUIApplication) {
        let back = app.buttons["reader_back_button"]
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if back.exists, back.isHittable { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 60), .completed, app.debugDescription)
    }
}
