import XCTest

final class ContinuousScrollMomentumUITests: XCTestCase {
    @MainActor
    func testReverseFlickKeepsMomentumAcrossGeometryAndChapterInsertion() throws {
        try verifyReverseFlick(usesTXT: false)
    }

    @MainActor
    func testTXTReverseFlickKeepsMomentumWhenPreviousChapterArrives() throws {
        try verifyReverseFlick(usesTXT: true)
    }

    @MainActor
    private func verifyReverseFlick(usesTXT: Bool) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-continuous-scroll-gesture-test"]
        if usesTXT { app.launchArguments.append("-continuous-scroll-txt-test") }
        app.launch()
        let status = app.staticTexts["viewport_gesture_status"]
        XCTAssertTrue(status.waitForExistence(timeout: 30))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            status.label.hasPrefix("ready")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        // Finger DOWN moves toward earlier, unmeasured paragraphs. These are
        // real pan/release events; no programmatic contentOffset simulation.
        for _ in 0..<5 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.25))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.8))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
        }
        for direction in [1.0, -1.0, 1.0, -1.0] {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5 + direction * 0.06))
            start.press(forDuration: 0.01, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        }
        // Cross content boundaries at a defined moderate finger velocity too;
        // rapid flicks and tiny slow drags alone missed the reported scenario.
        for direction in [1.0, -1.0, 1.0, -1.0] {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: direction > 0 ? 0.3 : 0.75))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: direction > 0 ? 0.75 : 0.3))
            start.press(forDuration: 0.01, thenDragTo: end,
                        withVelocity: XCUIGestureVelocity(rawValue: 450), thenHoldForDuration: 0)
        }
        let values = Dictionary(uniqueKeysWithValues: status.label.split(separator: " ").compactMap { field -> (String, Double)? in
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let number = Double(parts[1]) else { return nil }
            return (String(parts[0]), number)
        })
        print("[ViewportMomentum] \(status.label)")
        XCTAssertGreaterThan(try XCTUnwrap(values["corrections"]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(values["counts"]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(values["insertions"]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(values["decelInsertions"]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(values["continued"]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(values["surfaces"]), 0)
        XCTAssertGreaterThan(try XCTUnwrap(values["paints"]), 0)
        XCTAssertEqual(values["interrupted"], 0)
        XCTAssertEqual(values["progressInside"], 0)
        XCTAssertLessThanOrEqual(try XCTUnwrap(values["error"]), 1 / (try XCTUnwrap(values["scale"])) + 0.001)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
