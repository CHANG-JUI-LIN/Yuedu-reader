import XCTest

/// Promotional recording, English UI: Explore as it ships (built-in public catalogs), a book's details page, and one
/// book read from a local file, recognized in the demo Calibre server and on Project Gutenberg, then read online.
/// Needs the demo Calibre Content Server on 127.0.0.1:8765 holding Pride and Prejudice, the connection saved as
/// "My Calibre", and `Documents/Pride and Prejudice.epub` in the app's container. `record_continuous.py`
/// timestamps the `CALIBRE_PROMO_*` lines printed here.
final class SourcesPromoUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private let title = "Pride and Prejudice"

    private func mark(_ name: String) { print("CALIBRE_PROMO_\(name)") }

    /// Pacing for the viewer of the recording; every wait for app state below is a `waitForExistence` or an expectation.
    private func dwell(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    /// Whole element inside the screen, clear of the bars. `isHittable` records a failure for an element scrolled
    /// out of a horizontal row, so position is judged from the frame.
    @MainActor
    private func onScreen(_ app: XCUIApplication, _ element: XCUIElement) -> Bool {
        let frame = element.frame, screen = app.frame
        return frame.minX >= 0 && frame.maxX <= screen.width && frame.minY >= 100 && frame.maxY <= screen.height - 100
    }

    /// Anything but the app itself: the app's name, 閱讀, is also its folder's name in Files.
    @MainActor
    private func element(_ app: XCUIApplication, _ format: String, _ value: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "\(format) AND elementType != %d", value, XCUIElement.ElementType.application.rawValue))
            .firstMatch
    }

    // MARK: - Before the recording

    @MainActor
    private func importLocalFile(_ app: XCUIApplication) {
        app.tabBars.buttons["Library"].tap()
        app.buttons["home_add_book"].firstMatch.tap()
        let choose = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tap to Choose")).firstMatch
        if !choose.waitForExistence(timeout: 4) {
            // The add menu's file item: its icon is its identifier.
            let importFile = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "Import File", "folder")).firstMatch
            XCTAssertTrue(importFile.waitForExistence(timeout: 8), app.debugDescription)
            importFile.tap()
        }
        XCTAssertTrue(choose.waitForExistence(timeout: 8), app.debugDescription)
        choose.tap()
        let onDevice = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH 'DOC.sidebar.item.' AND label CONTAINS 'iPhone'")).firstMatch
        if !onDevice.waitForExistence(timeout: 4) {
            // The picker can open on Recents; the device's folders are under Browse.
            let browse = app.buttons.matching(NSPredicate(format: "label == %@", "Browse")).firstMatch
            XCTAssertTrue(browse.waitForExistence(timeout: 5), app.debugDescription)
            browse.tap()
            if !onDevice.waitForExistence(timeout: 4) { browse.tap() }
        }
        XCTAssertTrue(onDevice.waitForExistence(timeout: 10), app.debugDescription)
        onDevice.tap()
        let folder = element(app, "label == %@", "閱讀")
        XCTAssertTrue(folder.waitForExistence(timeout: 8), app.debugDescription)
        folder.tap()
        let file = element(app, "label BEGINSWITH %@", title)
        XCTAssertTrue(file.waitForExistence(timeout: 8), app.debugDescription)
        file.tap()
        let open = app.buttons.matching(NSPredicate(format: "label == %@", "Open")).firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(element(app, "label BEGINSWITH %@", title).waitForExistence(timeout: 30), app.debugDescription)
    }

    // MARK: - 1. Explore as it ships

    @MainActor
    private func tourExplore(_ app: XCUIApplication) {
        mark("scene1-explore")
        dwell(3.0)
        app.swipeUp(velocity: .slow)
        dwell(1.4)
        app.swipeUp(velocity: .slow)
        dwell(1.4)
        app.swipeUp(velocity: .slow)
        dwell(1.4)
        mark("scene1-bottom")
    }

    // MARK: - 2. A book's page

    @MainActor
    private func openDetails(_ app: XCUIApplication) throws {
        for _ in 0..<5 { app.swipeDown() }
        let card = app.buttons["home.card.gutenberg.1342"].firstMatch
        for _ in 0..<12 where !(card.exists && onScreen(app, card)) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(card.exists && onScreen(app, card), app.debugDescription)
        dwell(0.8)
        card.tap()
        XCTAssertTrue(app.buttons["Read"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        mark("scene2-details")
        dwell(2.6)
        app.swipeUp(velocity: .slow)
        dwell(2.2)
        mark("scene2-more")
        app.buttons["BackButton"].firstMatch.tap()
    }

    // MARK: - 3. The same book, everywhere

    /// The longest on-screen paragraph, from one snapshot of the tree: while the reader lays out a new source its
    /// texts come and go, and querying them one by one fails on the ones already gone.
    @MainActor
    private func visibleProse(_ app: XCUIApplication) -> String? {
        guard let root = try? app.snapshot() else { return nil }
        let screen = root.frame
        var best: String?
        func walk(_ node: XCUIElementSnapshot) {
            let f = node.frame
            if node.elementType == .staticText, node.label.count > 100, f.minX.isFinite, f.minY.isFinite,
               f.minX >= 0, f.maxX <= screen.width, f.minY >= 0, f.maxY <= screen.height,
               node.label.count > (best?.count ?? 0) {
                best = node.label
            }
            node.children.forEach(walk)
        }
        walk(root)
        return best
    }

    @MainActor
    private func waitForProse(_ app: XCUIApplication, timeout: TimeInterval) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.visibleProse(app) != nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: timeout), .completed, "Prose must render.\n\(app.debugDescription)")
    }

    @MainActor
    private func turnPage(_ app: XCUIApplication) {
        let before = visibleProse(app)
        XCTAssertNotNil(before, app.debugDescription)
        app.swipeLeft()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let after = self.visibleProse(app) else { return false }
            return after != before
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15),
                       .completed, "A page turn must change the visible prose.\n\(app.debugDescription)")
    }

    @MainActor
    private func switchSources(_ app: XCUIApplication) {
        mark("scene3-library")
        app.tabBars.buttons["Library"].tap()
        let local = element(app, "label BEGINSWITH %@", title)
        XCTAssertTrue(local.waitForExistence(timeout: 10), app.debugDescription)
        dwell(1.4)
        local.tap()
        // The file opens on its title page; the next page is prose.
        dwell(1.6)
        app.swipeLeft()
        waitForProse(app, timeout: 20)
        mark("scene3-reading-local")
        dwell(1.4)

        let capsule = app.buttons["reader_title_capsule"].firstMatch
        if !capsule.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(capsule.waitForExistence(timeout: 10), app.debugDescription)
        dwell(1.0)
        capsule.press(forDuration: 1.2)
        XCTAssertTrue(app.staticTexts["Current Source"].waitForExistence(timeout: 10), app.debugDescription)
        mark("scene3-switch-sheet")
        let calibre = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "My Calibre, \(title)")).firstMatch
        let gutenberg = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Project Gutenberg, \(title)")).firstMatch
        XCTAssertTrue(calibre.waitForExistence(timeout: 45), app.debugDescription)
        XCTAssertTrue(gutenberg.waitForExistence(timeout: 45), app.debugDescription)
        mark("scene3-sources-found")
        dwell(3.4)

        gutenberg.tap()
        mark("scene4-switching")
        waitForProse(app, timeout: 120)
        mark("scene4-reading-online")
        dwell(2.0)
        turnPage(app)
        mark("scene4-page2")
        dwell(1.6)
    }

    // MARK: - The take

    @MainActor
    func testContinuousPromotion() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-onboarding.completed", "YES"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Library"].waitForExistence(timeout: 30), app.debugDescription)
        importLocalFile(app)
        // Right after an import the Library is still settling, and the first tab tap can be lost.
        let exploreBar = app.navigationBars["Explore"].firstMatch
        for _ in 0..<3 where !exploreBar.exists {
            app.tabBars.buttons["Explore"].tap()
            _ = exploreBar.waitForExistence(timeout: 5)
        }
        XCTAssertTrue(exploreBar.exists, app.debugDescription)
        let carousel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.row.header.' AND label CONTAINS 'Trending Light Novels'")).firstMatch
        XCTAssertTrue(carousel.waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(app.buttons["home.card.gutenberg.1342"].firstMatch.waitForExistence(timeout: 30), app.debugDescription)
        dwell(4.0)   // covers finish loading before the take starts

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
        tourExplore(app)
        try openDetails(app)
        switchSources(app)
        print("CALIBRE_PROMO_RECORDING_COMPLETE")
    }
}
