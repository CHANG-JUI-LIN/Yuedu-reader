import XCTest

/// Maintainer, 2026-10-17: 「導入一本斗羅大陸 txt，然後點開作品詳情，會自動出現書籍簡介和封面嗎，在導入書源後」.
/// A TXT with no 「作者：」 line (so 「未知作者」) joins the shelf beside one book source; its
/// 作品詳情 shows the source's description and cover, filled by title because every match names
/// one author, and lists the source's book among the work's versions without a tap.
///
/// Needs `python3 -I scripts/work_fill_fixture.py` (port 18771). Each run imports a title of
/// its own, so a copy and its ledger entry from an earlier run are not this run's.
final class WorkFillUITests: XCTestCase {
    private let intro = "唐門外門弟子唐三"
    private var title = ""
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        title = "斗罗大陆\(Int.random(in: 1000...9999))"
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkFill-\(UUID().uuidString)")
        let sources = folder.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let text = "第一章 斗罗世界\n\n" + String(repeating: "唐三睜開眼睛，看見了陌生的天空。\n", count: 30)
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(title).txt"))
        let source: [String: Any] = [
            "bookSourceName": "填寫測試來源",
            "bookSourceUrl": "http://localhost:18771",
            "searchUrl": "http://localhost:18771/search?q={{key}}",
            "ruleSearch": ["bookList": "class.book", "name": "class.name@text", "author": "class.author@text",
                           "intro": "class.intro@text", "kind": "class.kind@text", "coverUrl": "tag.img@src",
                           "bookUrl": "tag.a@href"],
            "enabled": true,
        ]
        try JSONSerialization.data(withJSONObject: [source]).write(to: sources.appendingPathComponent("book_sources.json"))
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

    private func fixtureLog() throws -> String {
        try String(contentsOf: URL(string: "http://localhost:18771/log")!, encoding: .utf8)
    }

    @MainActor
    func testUnknownAuthorTXTGetsIntroCoverAndSources() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-reset-explore-home",
                               "-book-source-store-dir", folder.appendingPathComponent("sources").path,
                               "-auto-import-epub", folder.appendingPathComponent("\(title).txt").path,
                               "-auto-import-title", title]
        app.launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()

        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), app.debugDescription)
        let more = cell.buttons["更多"].firstMatch
        if more.exists {
            more.tap()
        } else {
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.96)).tap()
        }
        let menuItem = app.buttons["作品詳情"].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), app.debugDescription)
        menuItem.tap()

        // 簡介: filled while the page is open, or before.
        let introText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", intro)).firstMatch
        XCTAssertTrue(introText.waitForExistence(timeout: 60), app.debugDescription)
        attach(app, "work-fill-detail")
        XCTAssertFalse(app.staticTexts["作者其他作品"].exists, "「未知作者」 is no author: no other works of it")
        let log = try fixtureLog()
        XCTAssertTrue(log.contains("/cover.png"), "The match's cover was downloaded: \(log)")

        // 來源's automatic search ran on its own and found the source's book.
        let find = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(find.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<8 where !find.isHittable { app.swipeUp() }
        expectation(for: NSPredicate(format: "value CONTAINS %@", "找到 1 個來源"), evaluatedWith: find)
        waitForExpectations(timeout: 60)
        attach(app, "work-fill-sources")

        // The shelf's cover is the filled one too.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "work-fill-shelf")
    }
}
