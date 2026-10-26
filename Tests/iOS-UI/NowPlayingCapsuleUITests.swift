import XCTest

/// Narration outlives the reader it was started in: start 聽書 in one book, back out, open
/// another, and the first book is still being read aloud — its capsule on the second book's
/// page, stoppable from there, its cover opening the first book over the second. Stopping it
/// ends it for good.
///
/// The books are text files the test writes, imported at launch (`-auto-import-epub`, DEBUG).
final class NowPlayingCapsuleUITests: XCTestCase {
    private let narrated = "膠囊測試甲"
    private let other = "膠囊測試乙"
    private let audiobook = "膠囊測試有聲書"
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
    private func launch(_ app: XCUIApplication, importing title: String, fileExtension: String = "txt",
                        extraArguments: [String] = []) {
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-auto-import-epub", folder.appendingPathComponent("\(title).\(fileExtension)").path,
                               "-auto-import-title", title, "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO",
                               // The on-device voice: an online one depends on the network, and a
                               // failed request pauses narration — not what this test is about.
                               "-yd_tts_use_system_voice", "YES"] + extraArguments
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

    /// The app root's capsule, drawn on every tab while no reader is on screen.
    @MainActor
    private func shelfCapsule(_ app: XCUIApplication, _ control: String) -> XCUIElement {
        app.buttons["now_playing_global_\(control)"].firstMatch
    }

    @MainActor
    private func startNarration(_ app: XCUIApplication, in title: String) {
        // 聽書 is one of the bottom bar's tools; the book card no longer has one.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let listen = app.buttons["reader_tool_listen"].firstMatch
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

        // The capsule's cover opens the first book over this one. It used to do nothing here —
        // only the reader narrating opens a panel, and this one is not — while VoiceOver still
        // promised the panel (`NowPlayingCapsuleVoiceOverTests` checks the hint now).
        reopenNarratedBook(app, over: other)
        // Closing it comes back to the second book, the first still being read aloud, and the
        // cover opens it again.
        closeModalReader(app)
        XCTAssertTrue(page(app, narrated).waitForNonExistence(timeout: 10), "Back on the second book.\n\(app.debugDescription)")
        XCTAssertTrue(playPause.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(playPause.label, "暫停", "The first book is still being read aloud.")
        reopenNarratedBook(app, over: other)
        closeModalReader(app)
        XCTAssertTrue(page(app, narrated).waitForNonExistence(timeout: 10), app.debugDescription)

        capsule(app, "stop").tap()
        XCTAssertTrue(playPause.waitForNonExistence(timeout: 10), "✕ ends the narration.\n\(app.debugDescription)")
        leaveReader(app, to: other)
    }

    /// A page of `title`'s reader: every page of the test books carries its body text.
    @MainActor
    private func page(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body(title))).firstMatch
    }

    /// The capsule of a reader presented over another reader. XCUITest lists the reader under the
    /// cover too, and its capsule comes first.
    @MainActor
    private func coveringCapsule(_ app: XCUIApplication, _ control: String) -> XCUIElement {
        app.buttons.matching(identifier: "now_playing_reader_\(control)").element(boundBy: 1)
    }

    /// Taps the cover of the narrated book's capsule in `title`'s reader: the narrated book opens
    /// over it, and its reader takes the narration over — its capsule opens its own 語音朗讀 panel.
    @MainActor
    private func reopenNarratedBook(_ app: XCUIApplication, over title: String) {
        let cover = capsule(app, "open_panel")
        XCTAssertEqual(cover.label, narrated, "VoiceOver names the book being read aloud.")
        cover.tap()
        XCTAssertTrue(page(app, narrated).waitForExistence(timeout: 30),
                      "The cover opens the book being read aloud.\n\(app.debugDescription)")
        let covered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"), object: page(app, title)
        )
        XCTAssertEqual(XCTWaiter.wait(for: [covered], timeout: 10), .completed,
                       "…over the book that was open.\n\(app.debugDescription)")
        let playPause = coveringCapsule(app, "play_pause")
        XCTAssertTrue(playPause.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(playPause.label, "暫停", "Still playing through the reopen.")
        screenshot(app, "reopened-over-\(title)")

        coveringCapsule(app, "open_panel").tap()
        let panelPlayPause = app.buttons["tts_panel_play_pause"].firstMatch
        XCTAssertTrue(panelPlayPause.waitForExistence(timeout: 10),
                      "The reopened reader drives the narration.\n\(app.debugDescription)")
        XCTAssertEqual(panelPlayPause.label, "暫停")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(panelPlayPause.waitForNonExistence(timeout: 10), app.debugDescription)
    }

    /// Closes a reader presented full screen with its 返回 button, showing the bars if need be.
    /// The reader under it keeps its bars hidden here, so the one 返回 button is the cover's.
    @MainActor
    private func closeModalReader(_ app: XCUIApplication) {
        let close = app.buttons["reader_back_button"].firstMatch
        if !close.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(close.isHittable, "The 返回 button tapped is the cover's.\n\(app.debugDescription)")
        close.tap()
    }

    /// Feedback #83: closing the book mid-narration kept it being read aloud and took its
    /// capsule away, so nothing on the shelf could pause or stop it. The shelf shows it now, and
    /// the capsule's cover reopens the book — whose reader takes the narration over.
    @MainActor
    func testClosedBookKeepsItsNarrationOnTheShelf() {
        let app = XCUIApplication()
        // The on-device voice's fastest, so the narration gets past the first page while the
        // book is closed.
        launch(app, importing: narrated, extraArguments: ["-yd_tts_speech_rate", "1.0"])

        open(app, narrated)
        startNarration(app, in: narrated)
        leaveReader(app, to: narrated)

        let playPause = shelfCapsule(app, "play_pause")
        XCTAssertTrue(playPause.waitForExistence(timeout: 10),
                      "The closed book's narration has its capsule on the shelf.\n\(app.debugDescription)")
        XCTAssertEqual(playPause.label, "暫停", "…and is still playing.")
        let cover = shelfCapsule(app, "open_panel")
        XCTAssertEqual(cover.label, narrated, "VoiceOver names the book being read aloud.")
        screenshot(app, "shelf-with-narration")

        playPause.tap()
        XCTAssertTrue(playPause.wait(for: \.label, toEqual: "播放", timeout: 5), "Paused from the shelf.")
        playPause.tap()
        XCTAssertTrue(playPause.wait(for: \.label, toEqual: "暫停", timeout: 5), "Resumed from the shelf.")

        // The book was closed on its first page, which is where its saved position is. Let the
        // narration read on past it — the shelf shows nothing of where it is, so this waits.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "narration reads past page 1")], timeout: 40)
        // Reopen it paused: playing narration turns the reader's page to the spoken sentence on
        // its own, a sentence later, so only paused narration shows where the reader opened.
        playPause.tap()
        XCTAssertTrue(playPause.wait(for: \.label, toEqual: "播放", timeout: 5), "Paused before reopening.")

        cover.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body(narrated))).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), "The cover reopens the book.\n\(app.debugDescription)")
        let readerPlayPause = capsule(app, "play_pause")
        XCTAssertTrue(readerPlayPause.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(readerPlayPause.label, "播放", "Still paused through the reopen.")
        // The page on screen is one element whose label is its text, and only the first page
        // starts with the chapter heading (the running header above it is the heading alone).
        // The reader opens where the narration is, not on the saved first page.
        let firstPage = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@", "第一章", body(narrated)
        )).firstMatch
        let leftFirstPage = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"), object: firstPage
        )
        XCTAssertEqual(XCTWaiter.wait(for: [leftFirstPage], timeout: 15), .completed,
                       "The reopened book is on the page being read aloud.\n\(app.debugDescription)")
        XCTAssertTrue(playPause.waitForNonExistence(timeout: 5), "One capsule: the reader's.\n\(app.debugDescription)")
        screenshot(app, "reopened-reader")

        readerPlayPause.tap()
        XCTAssertTrue(readerPlayPause.wait(for: \.label, toEqual: "暫停", timeout: 5), "Resumed in the reopened reader.")

        // The reader took the narration over: its capsule opens its own 語音朗讀 panel, which
        // it would not for narration it is not driving.
        capsule(app, "open_panel").tap()
        let panelPlayPause = app.buttons["tts_panel_play_pause"].firstMatch
        XCTAssertTrue(panelPlayPause.waitForExistence(timeout: 10),
                      "The reopened reader drives the narration.\n\(app.debugDescription)")
        XCTAssertEqual(panelPlayPause.label, "暫停")
        app.buttons["完成"].firstMatch.tap()
        XCTAssertTrue(panelPlayPause.waitForNonExistence(timeout: 10), app.debugDescription)

        capsule(app, "stop").tap()
        XCTAssertTrue(readerPlayPause.waitForNonExistence(timeout: 10), "✕ ends the narration.\n\(app.debugDescription)")
        let close = app.buttons["reader_back_button"].firstMatch
        if !close.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.tap()
        _ = shelfBook(app, narrated)
        XCTAssertFalse(playPause.waitForExistence(timeout: 3), "Stopped narration leaves no capsule behind.\n\(app.debugDescription)")
    }

    /// An audiobook playing on after its player closed shows on every reader's capsule, and the
    /// capsule's cover opens its player again — also over a reader presented full screen, as
    /// 搜索's 最近閱讀 presents one. The app root presented that player, and presenting it from
    /// there closed a reader presented full screen: 收合 came back to 最近閱讀, the book gone.
    @MainActor
    func testAudiobookPlayerOpensOverAFullScreenReader() throws {
        try silentWAV(seconds: 300).write(to: folder.appendingPathComponent("\(audiobook).wav"))
        let app = XCUIApplication()
        let tabs = ["-yd_root_tab_visible_ids", "(bookshelf, settings, search)"]
        launch(app, importing: other, extraArguments: tabs)
        // Opened once, so 最近閱讀 lists it.
        open(app, other)
        leaveReader(app, to: other)
        app.terminate()
        launch(app, importing: audiobook, fileExtension: "wav", extraArguments: tabs)

        // The shelf opens an audiobook in its player, which plays it; 收合 leaves it playing.
        shelfBook(app, audiobook).tap()
        let collapse = app.buttons["收合"].firstMatch
        XCTAssertTrue(collapse.waitForExistence(timeout: 30), "The audiobook's player opens.\n\(app.debugDescription)")
        collapse.tap()
        XCTAssertTrue(shelfCapsule(app, "play_pause").waitForExistence(timeout: 10),
                      "The audiobook plays on with its player closed.\n\(app.debugDescription)")

        // 書架 pushes the reader inside its tab.
        open(app, other)
        openAudiobookPlayer(app, over: other)
        leaveReader(app, to: other)

        // 最近閱讀 presents it full screen.
        app.tabBars.buttons["搜尋"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        let recent = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", other)).firstMatch
        XCTAssertTrue(recent.waitForExistence(timeout: 10), app.debugDescription)
        recent.tap()
        XCTAssertTrue(page(app, other).waitForExistence(timeout: 30), "最近閱讀 opens the book.\n\(app.debugDescription)")
        openAudiobookPlayer(app, over: other)

        capsule(app, "stop").tap()
        XCTAssertTrue(capsule(app, "play_pause").waitForNonExistence(timeout: 10),
                      "✕ ends the audiobook.\n\(app.debugDescription)")
        closeModalReader(app)
        XCTAssertTrue(recent.waitForExistence(timeout: 10), "Back on 最近閱讀.\n\(app.debugDescription)")
    }

    /// Taps the cover of the audiobook's capsule in `title`'s reader: the audiobook's player
    /// opens over it, and 收合 comes back to the reader.
    @MainActor
    private func openAudiobookPlayer(_ app: XCUIApplication, over title: String) {
        let cover = capsule(app, "open_panel")
        XCTAssertTrue(cover.waitForExistence(timeout: 10), "The reader's capsule shows the audiobook.\n\(app.debugDescription)")
        cover.tap()
        let collapse = app.buttons["收合"].firstMatch
        XCTAssertTrue(collapse.waitForExistence(timeout: 10),
                      "The capsule's cover opens the audiobook's player.\n\(app.debugDescription)")
        screenshot(app, "audiobook-player-over-\(title)")
        collapse.tap()
        XCTAssertTrue(collapse.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(page(app, title).waitForExistence(timeout: 10), "Back on the book.\n\(app.debugDescription)")
        XCTAssertTrue(cover.waitForExistence(timeout: 10), "The audiobook plays on.\n\(app.debugDescription)")
    }

    /// A 16-bit mono WAV of silence: an audiobook to play, without a sound.
    private func silentWAV(seconds: Int, sampleRate: Int = 8000) -> Data {
        let byteCount = UInt32(seconds * sampleRate * 2)
        var data = Data()
        func append(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append(UInt32(36) + byteCount); append("WAVE")
        // PCM, one channel, 16 bits a sample.
        append("fmt "); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        append("data"); append(byteCount)
        data.append(Data(count: Int(byteCount)))
        return data
    }
}
