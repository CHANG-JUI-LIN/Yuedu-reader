import XCTest

/// Reddit r/calibre promotional recording, English UI, against the demo Calibre Content Server on
/// 127.0.0.1:8765. One uninterrupted flow: connect the server, design the Explore home from its feeds,
/// open a book from it and read. `record_continuous.py` timestamps the `CALIBRE_PROMO_*` lines printed here.
final class CalibrePromoUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let serverName = "My Calibre"
    private let serverURL = "http://127.0.0.1:8765/opds"

    private func mark(_ name: String) { print("CALIBRE_PROMO_\(name)") }

    /// Pacing for the viewer of the recording; every wait for app state below is a `waitForExistence`.
    private func dwell(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-onboarding.completed", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 30), app.debugDescription)
        return app
    }

    /// Whole element inside the screen, clear of the bars. `isHittable` records a failure for an
    /// element scrolled out of a horizontal row, so position is judged from the frame.
    @MainActor
    private func onScreen(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        let frame = element.frame, screen = app.frame
        return frame.minX >= 0 && frame.maxX <= screen.width && frame.minY >= 100 && frame.maxY <= screen.height - 100
    }

    /// Slow swipes: a default swipe coasts past lazily built rows before they can be found.
    @MainActor
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 40) {
        for _ in 0..<maxSwipes where !(element.exists && onScreen(app, element)) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.exists && onScreen(app, element), app.debugDescription)
    }

    // MARK: - 1. Connect

    @MainActor
    private func connectCalibre(_ app: XCUIApplication) {
        mark("scene1-settings")
        app.tabBars.buttons["Settings"].tap()
        let libraries = app.buttons["settings_remote_libraries"].firstMatch
        reveal(app, libraries, maxSwipes: 8)
        libraries.tap()
        let add = app.buttons["remote_library_add_calibre"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8), app.debugDescription)
        reveal(app, add, maxSwipes: 8)
        add.tap()
        let name = app.textFields["Server Name (Optional)"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 8), app.debugDescription)
        mark("scene1-form")
        name.tap()
        name.typeText(serverName)
        let url = app.textFields["Server URL"].firstMatch
        url.tap()
        url.typeText(serverURL)
        mark("scene1-filled")
        dwell(1.0)
        app.navigationBars.buttons["Save"].firstMatch.tap()
        let saved = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", serverName)).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 8), app.debugDescription)
        mark("scene1-saved")
        dwell(0.8)
        saved.tap()
        let check = app.buttons["Test Connection"].firstMatch
        reveal(app, check, maxSwipes: 6)
        check.tap()
        XCTAssertTrue(app.staticTexts["Connected"].waitForExistence(timeout: 15), app.debugDescription)
        mark("scene1-connected")
        dwell(1.6)
        app.navigationBars.buttons["Save"].firstMatch.tap()
    }

    // MARK: - 2. Design the Explore home

    @MainActor
    private func addSection(_ app: XCUIApplication, layout: String, feed: String, title: String, subtitle: String) {
        // A floating button at the screen's bottom edge: always reachable, so no scrolling to it.
        let addButton = app.buttons["homeEditor.addSection"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 8), app.debugDescription)
        addButton.tap()
        XCTAssertTrue(app.buttons["homeNewSection.layout.row"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        reveal(app, app.buttons["homeNewSection.layout.\(layout)"].firstMatch)
        app.buttons["homeNewSection.layout.\(layout)"].firstMatch.tap()

        // The name goes in before the source is chosen: choosing a source only fills a title the reader has not
        // typed, so the field starts empty and there is nothing to delete. A tall preview (a list) pushes the
        // title below the fold, so it is scrolled to while the keyboard is still down.
        let titleField = app.textFields["homeSection.title"].firstMatch
        reveal(app, titleField)
        titleField.tap()
        titleField.typeText(title)
        XCTAssertEqual(titleField.value as? String, title)
        let subtitleField = app.textFields["homeSection.subtitle"].firstMatch
        XCTAssertTrue(subtitleField.waitForExistence(timeout: 5), app.debugDescription)
        subtitleField.tap()
        subtitleField.typeText(subtitle + "\n")
        XCTAssertEqual(subtitleField.value as? String, subtitle)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Return should close the keyboard.\n\(app.debugDescription)")

        let source = app.buttons["homeSection.source"].firstMatch
        reveal(app, source)
        source.tap()
        let calibre = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", serverName)).firstMatch
        XCTAssertTrue(calibre.waitForExistence(timeout: 8), app.debugDescription)
        calibre.tap()
        let feedItem = app.buttons["homePicker.item.\(feed)"].firstMatch
        XCTAssertTrue(feedItem.waitForExistence(timeout: 10), app.debugDescription)
        feedItem.tap()
        let add = app.buttons["homeSection.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 8), app.debugDescription)
        dwell(0.8)
        add.tap()
        XCTAssertTrue(app.buttons["homeEditor.addSection"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
    }

    @MainActor
    private func designExplore(_ app: XCUIApplication) {
        mark("scene2-explore")
        app.tabBars.buttons["Explore"].tap()
        let more = app.descendants(matching: .any)["explore.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
        dwell(1.0)
        more.tap()
        let edit = app.buttons["pencil"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5), app.debugDescription)
        mark("scene2-editor")
        edit.tap()
        let chooseCarousel = app.buttons["homeEditor.chooseCarousel"].firstMatch
        XCTAssertTrue(chooseCarousel.waitForExistence(timeout: 8), app.debugDescription)

        // The defaults are other people's lists; hide them all and keep the page about this library.
        let toggles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'homeEditor.toggle.'"))
        for toggle in toggles.allElementsBoundByIndex where (toggle.value as? String) == "Shown" { toggle.tap() }
        mark("scene2-hidden")

        chooseCarousel.tap()
        let calibre = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", serverName)).firstMatch
        XCTAssertTrue(calibre.waitForExistence(timeout: 8), app.debugDescription)
        calibre.tap()
        let newest = app.buttons["homePicker.item.By Newest"].firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 10), app.debugDescription)
        newest.tap()
        XCTAssertTrue(app.buttons["homeEditor.addSection"].firstMatch.waitForExistence(timeout: 8), app.debugDescription)
        mark("scene2-carousel")

        addSection(app, layout: "heroGrid", feed: "By Title", title: "Your Whole Library", subtitle: "A to Z, covers and all")
        mark("scene2-section1")
        addSection(app, layout: "list", feed: "By Newest", title: "Tags, Straight from Calibre", subtitle: "Your metadata comes along for the ride")
        mark("scene2-section2")

        app.buttons["home.editDoneBar"].firstMatch.tap()
        mark("scene2-done")
    }

    // MARK: - 3. Show the home

    @MainActor
    private func scrollHome(_ app: XCUIApplication) {
        let carousel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.row.header.' AND label CONTAINS 'By Newest'")).firstMatch
        XCTAssertTrue(carousel.waitForExistence(timeout: 15), app.debugDescription)
        // The editor leaves the page scrolled to its end; the tour starts from the carousel.
        for _ in 0..<6 where !(carousel.exists && onScreen(app, carousel)) { app.swipeDown() }
        XCTAssertTrue(carousel.exists && onScreen(app, carousel), app.debugDescription)
        dwell(3.0)
        mark("scene3-top")
        app.swipeUp(velocity: .slow)
        dwell(1.2)
        app.swipeUp(velocity: .slow)
        dwell(1.2)
        mark("scene3-bottom")
        // Back up to the grid, where the book to open sits.
        for _ in 0..<6 where !(carousel.exists && onScreen(app, carousel)) { app.swipeDown() }
        dwell(0.6)
    }

    // MARK: - 4. Open a book and read

    @MainActor
    private func visibleProse(_ app: XCUIApplication) -> String? {
        app.staticTexts.allElementsBoundByIndex.filter { $0.isHittable && $0.label.count > 100 }
            .map(\.label).max(by: { $0.count < $1.count })
    }

    @MainActor
    private func turnPage(_ app: XCUIApplication, mark name: String) {
        let before = visibleProse(app)
        XCTAssertNotNil(before, app.debugDescription)
        app.swipeLeft()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let after = self.visibleProse(app) else { return false }
            return after != before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed,
                       "A page turn must change the actual visible prose.\n\(app.debugDescription)")
        mark(name)
    }

    @MainActor
    private func openAndRead(_ app: XCUIApplication) throws {
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.card.calibre.' AND label == 'Deep Work'"))
        var card: XCUIElement?
        for _ in 0..<20 {
            card = cards.allElementsBoundByIndex.first { onScreen(app, $0) }
            if card != nil { break }
            app.swipeUp(velocity: .slow)
        }
        try XCTUnwrap(card, app.debugDescription).tap()
        let read = app.buttons["Read"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        mark("scene4-detail")
        dwell(2.0)
        let introduction = app.buttons["detail.toc.4"].firstMatch
        XCTAssertTrue(introduction.waitForExistence(timeout: 15), app.debugDescription)
        reveal(app, introduction, maxSwipes: 6)
        XCTAssertTrue(introduction.label.contains("Introduction"), app.debugDescription)
        introduction.tap()
        let prose = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Swiss canton")).firstMatch
        XCTAssertTrue(prose.waitForExistence(timeout: 45), "Actual Introduction prose must render.\n\(app.debugDescription)")
        mark("scene4-reading")
        dwell(2.2)
        turnPage(app, mark: "scene4-page2")
        dwell(1.4)
        turnPage(app, mark: "scene4-page3")
        dwell(1.6)
    }

    // MARK: - The take

    @MainActor
    func testContinuousPromotion() throws {
        let app = launch()
        let environment = ProcessInfo.processInfo.environment
        if environment["YUEDU_PROMO_RECORDING"] == "1" || environment["TEST_RUNNER_YUEDU_PROMO_RECORDING"] == "1" {
            let gate = FileManager.default.temporaryDirectory.appendingPathComponent("calibre-promo-recording-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: gate, withIntermediateDirectories: true)
            let ack = gate.appendingPathComponent("recording-started")
            print("CALIBRE_PROMO_RECORDING_GATE=\(gate.path)")
            let recordingStarted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: ack.path)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [recordingStarted], timeout: 30), .completed)
        }
        mark("READY_TO_RECORD")
        connectCalibre(app)
        designExplore(app)
        scrollHome(app)
        try openAndRead(app)
        print("CALIBRE_PROMO_RECORDING_COMPLETE")
    }
}
