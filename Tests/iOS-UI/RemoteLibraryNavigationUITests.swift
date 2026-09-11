import XCTest

final class RemoteLibraryNavigationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSeparateLibraryEntrancesAndComputerReceiver() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let add = app.buttons["home_add_book"]
        XCTAssertTrue(add.waitForExistence(timeout: 20))
        XCTAssertEqual(add.label, "Add Book")

        for title in ["WebDAV Library", "OPDS Library", "Calibre Library"] {
            add.tap()
            let entry = app.buttons[title].firstMatch
            XCTAssertTrue(entry.waitForExistence(timeout: 5), "Independent entrance: \(title)")
            entry.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
            XCTAssertTrue(app.buttons["Add Server"].firstMatch.exists)
            if title == "Calibre Library" {
                let receiver = app.buttons["Receive from computer"].firstMatch
                XCTAssertTrue(receiver.waitForExistence(timeout: 5))
                XCTAssertTrue(receiver.isHittable, "Receiving must remain available when no server is configured")
                receiver.tap()
                XCTAssertTrue(app.navigationBars["Receive from computer"].waitForExistence(timeout: 5))
                let host = app.textFields["Computer IP or hostname"]
                for _ in 0..<3 where !host.isHittable { app.swipeUp() }
                XCTAssertTrue(host.waitForExistence(timeout: 5))
                XCTAssertTrue(app.buttons["Connect"].exists)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "calibre-computer-receiver"
                attachment.lifetime = .keepAlways
                self.add(attachment)
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            }
            app.navigationBars.buttons["Close"].tap()
            XCTAssertTrue(add.waitForExistence(timeout: 5))
        }
    }
}
