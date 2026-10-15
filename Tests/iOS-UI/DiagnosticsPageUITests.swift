import XCTest

/// Drives 設定 → 回饋中心 → 診斷紀錄 on a real simulator and captures what it looks like.
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
        // The labels below are English; pin the language so the simulator's own does not matter.
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_source_disclaimer_accepted", "YES"]
        app.launch()

        // The notification prompt can land on top of the shelf on a fresh install.
        let notNow = app.buttons["Don’t Allow"]
        if notNow.waitForExistence(timeout: 5) {
            notNow.tap()
        }

        let settingsTab = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20), "settings tab should exist")
        settingsTab.tap()

        let feedbackCenter = app.buttons["settings_feedback_center"].firstMatch
        // SwiftUI does not expose a Form row to XCTest until it is near the
        // viewport, so scroll before asserting that this bottom-row entry exists.
        for _ in 0..<8 where !feedbackCenter.exists {
            app.swipeUp()
        }
        XCTAssertTrue(feedbackCenter.waitForExistence(timeout: 5), "the feedback center row should be reachable")
        feedbackCenter.tap()

        let target = app.buttons["Diagnostic Log"].firstMatch
        XCTAssertTrue(target.waitForExistence(timeout: 10), "the diagnostics row should be in 回饋中心")
        target.tap()

        let exportControl = app.descendants(matching: .any)["diagnostics_export_button"]
        XCTAssertTrue(
            exportControl.waitForExistence(timeout: 15),
            "export must be a directly presented control, not hidden behind a toolbar Menu"
        )

        // The filter section starts below the export row and might not be materialized
        // in the accessibility tree until the Form is scrolled.
        let verboseToggle = app.switches.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Verbose")
        ).firstMatch
        for _ in 0..<3 where !verboseToggle.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            verboseToggle.waitForExistence(timeout: 5),
            "the diagnostics Form should render its filter section"
        )

        attach(app, name: "diagnostics-light")

        // Section headers prove the Form/Section structure rather than a plain list.
        XCTAssertTrue(app.staticTexts["Filter"].exists || app.staticTexts["FILTER"].exists,
                      "the Filter section header should render")
        for _ in 0..<3 where !app.staticTexts["Log"].exists && !app.staticTexts["LOG"].exists {
            app.swipeUp()
        }
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
