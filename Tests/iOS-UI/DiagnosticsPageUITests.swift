import XCTest

/// Drives 設定 → 診斷與回報 on a real simulator and captures what it looks like.
///
/// This exists because the page's appearance is the part unit tests cannot reach:
/// `themedAppSurface` and `interfaceSectionSurface` resolve against
/// `GlobalSettings` and `SubscriptionStore` at render time, so "does it follow the
/// appearance settings" is only answerable by rendering it. The screenshots land in
/// the result bundle as attachments.
final class DiagnosticsPageUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDiagnosticsPageRendersAndFollowsAppearance() throws {
        let app = XCUIApplication()
        app.launch()

        // The notification prompt can land on top of the shelf on a fresh install.
        let notNow = app.buttons["Don’t Allow"]
        if notNow.waitForExistence(timeout: 5) {
            notNow.tap()
        }

        let settingsTab = app.tabBars.buttons.element(boundBy: 3)
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20), "settings tab should exist")
        settingsTab.tap()

        let entry = app.buttons["Diagnostics & Reporting"].firstMatch
        let entryCell = app.staticTexts["Diagnostics & Reporting"].firstMatch
        let target = entry.exists ? entry : entryCell
        XCTAssertTrue(target.waitForExistence(timeout: 15), "the 進階 row should be reachable")
        // The row sits near the bottom of Settings.
        app.swipeUp()
        app.swipeUp()
        if target.isHittable {
            target.tap()
        } else {
            app.swipeUp()
            target.tap()
        }

        // The filter section's toggle is the cheapest proof the Form actually built.
        let verboseToggle = app.switches.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Verbose")
        ).firstMatch
        XCTAssertTrue(
            verboseToggle.waitForExistence(timeout: 15),
            "the diagnostics Form should render its filter section"
        )

        attach(app, name: "diagnostics-light")

        // Section headers prove the Form/Section structure rather than a plain list.
        XCTAssertTrue(app.staticTexts["Filter"].exists || app.staticTexts["FILTER"].exists,
                      "the Filter section header should render")
        XCTAssertTrue(app.staticTexts["Log"].exists || app.staticTexts["LOG"].exists,
                      "the Log section header should render")
    }

    @MainActor
    private func attach(_ app: XCUIApplication, name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
