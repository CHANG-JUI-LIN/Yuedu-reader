import XCTest

/// Unified library 5c-5: the bookshelf ＋ puts books on the shelf — from Files or from a
/// computer. Libraries left it: they are browsed from Explore's 範圍
/// (`ExploreHomeUITests`) and set up in 設定 → 遠端書庫 (`RemoteLibrarySettingsUITests`).
final class RemoteLibraryNavigationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAddMenuKeepsTheComputerReceiverWithoutLibraries() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        // The app opens on 探索; 書架 is "Library" in English.
        let shelfTab = app.tabBars.buttons["Library"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 20), app.debugDescription)
        shelfTab.tap()
        let add = app.buttons["home_add_book"]
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        XCTAssertEqual(add.label, "Add Book")

        add.tap()
        XCTAssertTrue(app.buttons["Import from Files…"].firstMatch.waitForExistence(timeout: 5))
        for title in ["WebDAV Library", "OPDS Library", "Calibre Library"] {
            XCTAssertFalse(app.buttons[title].exists, "\(title) is browsed from Explore now")
        }
        let receiver = app.buttons["Receive from Computer"].firstMatch
        XCTAssertTrue(receiver.exists, "Receiving needs no server, so it stays on ＋")
        receiver.tap()

        let page = app.navigationBars["Receive from Computer"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        let host = app.textFields["Computer IP Address or Host Name"]
        for _ in 0..<3 where !host.isHittable { app.swipeUp() }
        XCTAssertTrue(host.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Connect"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "calibre-computer-receiver"
        attachment.lifetime = .keepAlways
        self.add(attachment)

        page.buttons["Close"].tap()
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertFalse(page.exists)
    }
}
