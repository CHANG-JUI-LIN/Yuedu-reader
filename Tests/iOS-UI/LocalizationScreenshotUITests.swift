import XCTest

/// The idiomatic localization review (2026-10-12): the tab bar and the settings root in every
/// language, kept as screenshots so a reviewer can check wording and truncation.
final class LocalizationScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testTabBarAndSettingsInEveryLanguage() {
        let languages = [("en", "en_US"), ("ja", "ja_JP"), ("ko", "ko_KR"), ("zh-Hans", "zh_CN"), ("zh-Hant", "zh_TW")]
        for (language, locale) in languages {
            let app = XCUIApplication()
            app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(\(language))", "-AppleLocale", locale]
            app.launch()
            let tabs = app.tabBars.firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout: 30), app.debugDescription)
            XCTAssertEqual(tabs.buttons.count, 5, app.debugDescription)
            screenshot(app, "\(language)-library")
            tabs.buttons.element(boundBy: 3).tap()
            XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            screenshot(app, "\(language)-settings")
            // The language footer names the app as iOS Settings lists it: its display name.
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "YueduReader")).firstMatch.exists,
                           "\(language): the footer must name 閱讀, not the bundle name")
            app.terminate()
        }
    }
}
