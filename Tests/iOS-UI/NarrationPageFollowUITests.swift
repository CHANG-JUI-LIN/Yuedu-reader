import XCTest

/// Paged 聽書 turns the page when the spoken sentence moves onto the next one — even when
/// every line of the chapter reads the same.
///
/// Following used to locate the spoken sentence by searching the chapter text from the page's
/// start. A sentence repeated on the page resolved to its first occurrence, so on a chapter of
/// identical lines every segment landed on page 1's first line: narration ran to the end of the
/// chapter (`playback ended index=37`) while the anchor sat at `(ch0,off8)` and the page never
/// turned. The position now comes from the narration offset map, as the playback wash's does.
///
/// The book is a text file the test writes, imported at launch (`-auto-import-epub`, DEBUG).
final class NarrationPageFollowUITests: XCTestCase {
    /// A new title every run: `-auto-import-epub` skips a title already on the shelf, and the
    /// copy a previous run left there reopens where that run's narration had turned to.
    private let title = "聽書翻頁測試\(UUID().uuidString.prefix(4))"
    private let opener = "第一章 開始"
    private let line = "這一行和其他每一行都完全一樣。"
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("NarrationFollow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "\(opener)\n\n" + String(repeating: "\(line)\n", count: 200)
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(title).txt"))
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

    /// The text of the page under the middle of the screen. The page is the reader's one
    /// VoiceOver element, labelled with its text; a page controller may keep its neighbours in
    /// the tree, so the one on screen is picked by position.
    @MainActor
    private func pageOnScreen(_ app: XCUIApplication) -> String? {
        let middle = CGPoint(x: app.frame.midX, y: app.frame.midY)
        return app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", line)).allElementsBoundByIndex
            .first { $0.frame.contains(middle) }?
            .label
    }

    @MainActor
    func testNarrationTurnsThePageThroughIdenticalLines() {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-auto-import-epub", folder.appendingPathComponent("\(title).txt").path,
                               "-auto-import-title", title, "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO",
                               // The on-device voice, at twice the normal rate: an online voice
                               // depends on the network, and a page takes a minute at 1×.
                               "-yd_tts_use_system_voice", "YES", "-yd_tts_speech_rate", "1.0"]
        app.launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), app.debugDescription)
        book.tap()

        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.pageOnScreen(app)?.contains(self.opener) == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [opened], timeout: 30), .completed,
                       "The reader opens on the chapter's first page.\n\(app.debugDescription)")

        // 聽書 is one of the bottom bar's tools. Nothing is tapped after it: a tap on the page
        // while narrating is browsing, and browsing stops the page from following.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let listen = app.buttons["reader_tool_listen"].firstMatch
        XCTAssertTrue(listen.waitForExistence(timeout: 5), app.debugDescription)
        listen.tap()
        let playPause = app.buttons["now_playing_reader_play_pause"].firstMatch
        XCTAssertTrue(playPause.waitForExistence(timeout: 20), "Narration starts.\n\(app.debugDescription)")
        screenshot(app, "narrating-page-1")

        // Every page after the first reads the same, so the opener leaving the screen is the turn.
        let turned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let page = self.pageOnScreen(app) else { return false }
            return !page.contains(self.opener)
        }, object: nil)
        let result = XCTWaiter.wait(for: [turned], timeout: 120)
        screenshot(app, "after-waiting-for-the-turn")
        // Checked either way, so a failure says which went wrong: the page stayed put while the
        // voice read on, or the voice itself stopped (on the simulator, a paused host audio
        // device stalls the system voice at its first segment).
        XCTAssertTrue(playPause.exists && playPause.label == "暫停",
                      "Narration is still playing.\n\(app.debugDescription)")
        XCTAssertEqual(result, .completed,
                       "Narration reads past page 1, so the reader turns to page 2.\n\(app.debugDescription)")

        app.buttons["now_playing_reader_stop"].firstMatch.tap()
    }
}
