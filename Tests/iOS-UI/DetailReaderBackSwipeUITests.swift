import XCTest

/// Prepare with scripts/navigation_swipe_fixture.py and serve localhost:18765.
/// These tests deliver actual touches to the production Explore/detail/reader.
final class DetailReaderBackSwipeUITests: XCTestCase {
    @MainActor func testSlideEdgeBack() { exerciseReader(style: "滑動") }
    @MainActor func testCoverEdgeBack() { exerciseReader(style: "覆蓋翻頁") }
    @MainActor func testCurlEdgeBack() { exerciseReader(style: "仿真翻書") }
    @MainActor func testInstantEdgeBack() { exerciseReader(style: "無動畫") }
    @MainActor func testScrollEdgeBack() { exerciseReader(style: "滑動", scroll: true) }

    @MainActor
    private func exerciseReader(style: String, scroll: Bool = false) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_page_turn_style", style, "-yd_scroll_mode", scroll ? "YES" : "NO"]
        app.launch()
        let book = app.staticTexts["Navigation Swipe Fixture"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read Now", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        let originalPage = content.label
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let shortDrag = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        // The hold belongs to the user's gesture: releasing a short, stationary
        // drag must cancel, preserving the same reader and reading position.
        edge.press(forDuration: 0.05, thenDragTo: shortDrag, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertEqual(content.label, originalPage)
        XCTAssertFalse(read.exists)

        // Interior pans must still turn pages / scroll, without navigating back.
        let interior = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7))
        let next = app.coordinate(withNormalizedOffset: CGVector(dx: scroll ? 0.8 : 0.2, dy: scroll ? 0.35 : 0.7))
        interior.press(forDuration: 0.05, thenDragTo: next)
        XCTAssertFalse(read.exists)
        if !scroll {
            let pageChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                content.exists && content.label != originalPage
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [pageChanged], timeout: 5), .completed, "Interior pan must turn the page")
        }

        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        // Also exercise the reserved strip away from the physical screen edge.
        let reservedStrip = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: app.frame.height * 0.5))
        reservedStrip.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(read.waitForExistence(timeout: 8), "Edge drag must pop to the original detail.\n\(app.debugDescription)")
        XCTAssertFalse(content.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Returned to detail - \(style) - scroll \(scroll)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // SwiftUI's route must also be reconciled, so reopening works normally.
        read.tap()
        XCTAssertTrue(content.waitForExistence(timeout: 15))
        edge.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(read.waitForExistence(timeout: 8))
    }
}
