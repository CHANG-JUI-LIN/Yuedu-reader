import XCTest

/// The reader sizes itself from its own window, and holds its first layout until that window
/// has reported a size. If the report never came, the book would sit on 載入中 forever — so
/// this opens a reflowable TXT through the real shelf and expects the reader to show up and
/// stay usable across a rotation, the one window-shape change an XCUITest can make.
///
/// It runs on every device the app supports: on an iPhone the reader opens through the card
/// transition, on an iPad modally, and on iOS 17 the reporter is the back-deployed
/// `onGeometryChange`. (The page count itself is not readable from here — the reader's page
/// readout is drawn into the page, not exposed as an element — so the relayout is pinned by
/// `ReaderViewportFollowsWindowTests` and by the simulator checks in the change's notes.)
final class ReaderWindowSizeUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    func testReaderOpensAndStaysUsableAcrossRotation() throws {
        let book = FileManager.default.temporaryDirectory
            .appendingPathComponent("window_probe.txt")
        let paragraph = "這是用來驗證視窗尺寸的測試段落，內容很長很長很長，需要自動換行到好幾行才看得出欄寬是否跟著視窗改變。"
            + "The quick brown fox jumps over the lazy dog, again and again, so the line wraps visibly.\n"
        let text = (1...3).map { chapter in
            "第\(chapter)章 測試章節\(chapter)\n" + String(repeating: paragraph, count: 40)
        }.joined(separator: "\n")
        try text.write(to: book, atomically: true, encoding: .utf8)

        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(zh-Hant)",
                               "-AppleLocale", "zh_TW", "-auto-import-epub", book.path]
        app.launch()

        let shelfBook = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "window_probe")
        ).firstMatch
        XCTAssertTrue(shelfBook.waitForExistence(timeout: 60), app.debugDescription)
        shelfBook.tap()

        // The reader hides its chrome as it opens; a tap in the middle of the page brings it up.
        XCTAssertTrue(waitForReaderChrome(in: app), "the reader must open\n\(app.debugDescription)")

        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(waitForReaderChrome(in: app),
                      "the reader must stay usable after rotating to landscape\n\(app.debugDescription)")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitForReaderChrome(in: app),
                      "the reader must stay usable after rotating back\n\(app.debugDescription)")
    }

    /// True once the reader's back button is on screen, tapping the middle of the page to raise
    /// the chrome while it is not. Waits on the element itself — no fixed delay.
    @MainActor
    private func waitForReaderChrome(in app: XCUIApplication) -> Bool {
        let back = app.buttons["reader_back_button"]
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if back.exists { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return false
        }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: 60) == .completed
    }
}
