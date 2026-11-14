import XCTest

/// 檢視有聲書 on 作品詳情 (maintainer, 2026-11-14: 「文字和有聲書互相顯示」): the page's search finds
/// the work in its other form too, and the hero offers it under its actions. A book's page offers
/// its audiobook; the audiobook's page, a book source's own, searches once more and offers the book.
///
/// Needs `python3 -I scripts/work_fill_fixture.py` (port 18771) and a second copy of it,
/// `python3 -I scripts/work_fill_fixture.py 18772`: a text source reads the first and an audio
/// source the second, so the title has a book and an audiobook by one author.
final class WorkOtherFormUITests: XCTestCase {
    private var title = ""
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        title = "斗罗大陆\(Int.random(in: 1000...9999))"
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkOtherForm-\(UUID().uuidString)")
        let sources = folder.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        // The book names its author: the work in its other form is matched by the author's name.
        let text = "《\(title)》作者：唐家三少\n\n第一章 斗罗世界\n\n" + String(repeating: "唐三睜開眼睛，看見了陌生的天空。\n", count: 30)
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(title).txt"))
        func source(_ name: String, port: Int, type: Int) -> [String: Any] {
            ["bookSourceName": name, "bookSourceUrl": "http://localhost:\(port)", "bookSourceType": type,
             "searchUrl": "http://localhost:\(port)/search?q={{key}}",
             "ruleSearch": ["bookList": "class.book", "name": "class.name@text", "author": "class.author@text",
                            "intro": "class.intro@text", "kind": "class.kind@text", "coverUrl": "tag.img@src",
                            "bookUrl": "tag.a@href"],
             "enabled": true]
        }
        try JSONSerialization.data(withJSONObject: [source("文字測試來源", port: 18771, type: 0),
                                                    source("有聲測試來源", port: 18772, type: 1)])
            .write(to: sources.appendingPathComponent("book_sources.json"))
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
    func testABookOffersItsAudiobookAndTheAudiobookItsBook() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
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

        // The book's page: its audiobook, as the audio source has it, by its author and source.
        let audiobook = app.buttons["detail.otherForm"].firstMatch
        XCTAssertTrue(audiobook.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertEqual(audiobook.label, "檢視有聲書")
        XCTAssertTrue((audiobook.value as? String)?.contains("有聲測試來源") == true, "\(String(describing: audiobook.value))")
        for _ in 0..<3 where !audiobook.isHittable { app.swipeUp() }
        attach(app, "other-form-audiobook")
        audiobook.tap()

        // The audiobook's page, its source's own: one search more, and the book it is of.
        let book = app.buttons.matching(NSPredicate(format: "identifier == 'detail.otherForm' AND label == %@", "檢視書籍")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 60), app.debugDescription)
        XCTAssertTrue((book.value as? String)?.contains("文字測試來源") == true, "\(String(describing: book.value))")
        for _ in 0..<3 where !book.isHittable { app.swipeUp() }
        attach(app, "other-form-book")
        // And that card opens too, from a source's page: the book as its source has it
        // (maintainer's phone, 2026-11-14: the card on a source's page did nothing).
        let play = app.buttons["開始播放"].firstMatch
        XCTAssertTrue(play.exists, app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "立即閱讀", "開始閱讀")).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertFalse(play.isHittable, "the book's page is on top of the audiobook's")
        attach(app, "other-form-book-opened")
    }
}
