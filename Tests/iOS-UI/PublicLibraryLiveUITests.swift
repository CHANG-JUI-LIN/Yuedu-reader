import XCTest

/// Explicit release checks. Normal test runs stay offline; each opt-in is run
/// separately so the real theme import can happen between the two checks.
final class PublicLibraryLiveUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private func enabled(_ key: String) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment[key] == "1" || environment["TEST_RUNNER_" + key] == "1"
    }

    @MainActor
    private func launch(pro: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-yd_source_disclaimer_accepted", "YES", "-book-source-store-dir", "/tmp/YueduPublicLibraries-manual-empty"]
        if pro { app.launchArguments += ["-debug-force-pro"] }
        app.launchEnvironment["CFNETWORK_DIAGNOSTICS"] = "3"
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        XCTAssertTrue(app.staticTexts["Project Gutenberg"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testGutenbergWithoutPro() throws {
        guard enabled("PUBLIC_LIBRARY_LIVE_UI") else { throw XCTSkip("Explicit live Gutenberg release check") }
        let app = launch(pro: false)
        screenshot(app, "nonpro-home")
        let query = app.searchFields["搜尋公有書庫"].firstMatch
        query.tap()
        query.typeText("Pride and Prejudice\n")
        let result = app.collectionViews.staticTexts["Pride and Prejudice"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 45), app.debugDescription)
        screenshot(app, "nonpro-search")
        result.tap()
        let edition = app.collectionViews.cells.firstMatch
        XCTAssertTrue(edition.waitForExistence(timeout: 45), app.debugDescription)
        screenshot(app, "nonpro-editions")
        edition.tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["開始閱讀", "繼續閱讀"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(read.isEnabled)
        XCTAssertTrue(app.buttons["加入書架"].firstMatch.isEnabled)
        XCTAssertTrue(app.buttons["下載供離線閱讀"].firstMatch.isEnabled)
        screenshot(app, "nonpro-detail")
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Gutenberg")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 90), app.debugDescription)
        screenshot(app, "nonpro-remote-reader")
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        let inward = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: inward)
        let add = app.buttons["加入書架"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        XCTAssertTrue(app.buttons["已加入書架"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["下載供離線閱讀"].firstMatch.tap()
        XCTAssertTrue(app.buttons["已下載"].firstMatch.waitForExistence(timeout: 120), app.debugDescription)
        screenshot(app, "nonpro-shelved-and-downloaded")
    }

    @MainActor
    func testAozoraFixtureWithImportedThemeAndPro() throws {
        guard enabled("PUBLIC_LIBRARY_THEME_UI") else { throw XCTSkip("Requires the supplied qitheme and catalog fixture") }
        let app = launch(pro: true)
        XCTAssertTrue(app.staticTexts["青空文庫"].firstMatch.waitForExistence(timeout: 10))
        screenshot(app, "pro-qitheme-library-home")
        let authors = app.buttons["依作家"].firstMatch
        XCTAssertTrue(authors.exists)
        authors.tap()
        let author = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "架空 一郎")).firstMatch
        XCTAssertTrue(author.waitForExistence(timeout: 10))
        screenshot(app, "pro-qitheme-aozora-authors")
        author.tap()
        let work = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "架空の物語")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        work.tap()
        XCTAssertTrue(app.buttons["加入書架"].firstMatch.waitForExistence(timeout: 10))
        screenshot(app, "pro-qitheme-aozora-detail")
    }
}
