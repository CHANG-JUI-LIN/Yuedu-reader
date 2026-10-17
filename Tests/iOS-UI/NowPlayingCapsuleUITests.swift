import XCTest

/// Narration outlives the reader it was started in: start 聽書 in one book, back out, open
/// another, and the first book is still being read aloud — its capsule on the second book's
/// page, stoppable from there. Stopping it ends it for good.
///
/// The books are text files the test writes, imported at launch (`-auto-import-epub`, DEBUG).
final class NowPlayingCapsuleUITests: XCTestCase {
    private let narrated = "膠囊測試甲"
    private let other = "膠囊測試乙"
    private var folder: URL!

    private func body(_ title: String) -> String { "\(title)正文，用來確認閱讀器打開了這本書。" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("Capsule-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for title in [narrated, other] {
            let text = "第一章 開始\n\n\(body(title))\n\n" + String(repeating: "\(body(title))\n", count: 200)
            try Data(text.utf8).write(to: folder.appendingPathComponent("\(title).txt"))
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func launch(_ app: XCUIApplication, importing title: String) {
        app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-auto-import-epub", folder.appendingPathComponent("\(title).txt").path,
                               "-auto-import-title", title, "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO",
                               // The on-device voice: an online one depends on the network, and a
                               // failed request pauses narration — not what this test is about.
                               "-yd_tts_use_system_voice", "YES"]
        app.launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()
        _ = shelfBook(app, title)
    }

    @MainActor
    private func shelfBook(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), app.debugDescription)
        return cell
    }

    @MainActor
    private func open(_ app: XCUIApplication, _ title: String) {
        shelfBook(app, title).tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body(title))).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), "The reader opens \(title).\n\(app.debugDescription)")
    }

    @MainActor
    private func leaveReader(_ app: XCUIApplication, to title: String) {
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        _ = shelfBook(app, title)
    }

    @MainActor
    private func capsule(_ app: XCUIApplication, _ control: String) -> XCUIElement {
        app.buttons["now_playing_reader_\(control)"].firstMatch
    }

    @MainActor
    private func startNarration(_ app: XCUIApplication, in title: String) {
        // 聽書 sits on the book card the title pill opens.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let listen = app.buttons["聽書"].firstMatch
        if !listen.waitForExistence(timeout: 3) {
            let pill = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(pill.waitForExistence(timeout: 5), app.debugDescription)
            pill.tap()
        }
        XCTAssertTrue(listen.waitForExistence(timeout: 5), app.debugDescription)
        listen.tap()
        XCTAssertTrue(capsule(app, "play_pause").waitForExistence(timeout: 20), "Narration starts.\n\(app.debugDescription)")
    }

    @MainActor
    func testNarrationOutlivesItsReader() {
        let app = XCUIApplication()
        // Two launches: `-auto-import-epub` takes one book each.
        launch(app, importing: other)
        app.terminate()
        launch(app, importing: narrated)

        // A reader that never narrated.
        open(app, other)
        leaveReader(app, to: other)

        open(app, narrated)
        startNarration(app, in: narrated)
        screenshot(app, "narrating")
        leaveReader(app, to: other)

        open(app, other)
        let playPause = capsule(app, "play_pause")
        XCTAssertTrue(playPause.waitForExistence(timeout: 10),
                      "The first book is still being read aloud.\n\(app.debugDescription)")
        XCTAssertEqual(playPause.label, "暫停", "…and still playing, not paused.")
        screenshot(app, "other-book-with-narration")

        capsule(app, "stop").tap()
        XCTAssertTrue(playPause.waitForNonExistence(timeout: 10), "✕ ends the narration.\n\(app.debugDescription)")
        leaveReader(app, to: other)
    }
}
