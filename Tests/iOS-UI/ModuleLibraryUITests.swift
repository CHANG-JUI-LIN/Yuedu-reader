import XCTest

/// Phase 6e: 資源庫's 模組. A module is added from an address through the •••, its card
/// appears, its page lists its lists and sites, and 移除模組 takes it away.
///
/// The fixture is served over HTTP from outside the simulator before the run:
/// `python3 -m http.server 18766 --bind 127.0.0.1` in a folder holding `uitest-module.json`
/// (the module below). The app asks `localhost`: `safeURL` refuses the `127.0.0.1` literal.
final class ModuleLibraryUITests: XCTestCase {
    static let fixtureURL = "http://localhost:18766/uitest-module.json"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleLibraryUITests-\(UUID().uuidString)")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-rule-module-store-dir", folder.path]
        app.launch()
        let tab = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        var swipes = 0
        while !element.exists, swipes < 8 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            swipes += 1
        }
        return element
    }

    /// An item of the open •••: the iOS 17 chooser's row also reads its subtitle after the title.
    private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    @MainActor
    func testAddFromAddressThenRemove() {
        let app = launch()
        let empty = scrolledTo(app.buttons["library.modules.add"].firstMatch, in: app)
        XCTAssertTrue(empty.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "modules-empty")

        // ••• → 新增模組 → 從網址; on iOS 17 a chooser row, opened once the chooser has gone.
        app.buttons["library.more"].firstMatch.tap()
        if #available(iOS 18, *) {
            let add = app.buttons["新增模組"].firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
            add.tap()
        }
        let address = item(app, "從網址")
        XCTAssertTrue(address.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(item(app, "從檔案").exists && item(app, "從剪貼簿").exists, app.debugDescription)
        attach(app, "modules-add-routes")
        address.tap()

        let field = app.textFields["module.import.address"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText(Self.fixtureURL)
        app.buttons["module.import.load"].firstMatch.tap()

        let commit = app.buttons["module.import.commit"].firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.staticTexts["localhost"].exists, "the sites it connects to are shown first")
        attach(app, "modules-import-preview")
        commit.tap()

        let card = scrolledTo(app.buttons["library.module.uitest.module"].firstMatch, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(card.label, "測試模組")
        attach(app, "modules-card")
        card.tap()

        XCTAssertTrue(app.navigationBars["測試模組"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["新書"].exists, app.debugDescription)
        XCTAssertTrue(app.staticTexts[Self.fixtureURL].exists, app.debugDescription)
        attach(app, "modules-page")

        let remove = scrolledTo(app.buttons["module.remove"].firstMatch, in: app)
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        remove.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "移除模組", "module.remove")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()

        XCTAssertFalse(app.navigationBars["測試模組"].waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(scrolledTo(app.buttons["library.modules.add"].firstMatch, in: app).waitForExistence(timeout: 10),
                      app.debugDescription)
        attach(app, "modules-removed")
    }
}
