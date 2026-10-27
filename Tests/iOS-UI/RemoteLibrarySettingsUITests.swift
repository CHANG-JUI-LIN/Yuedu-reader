import XCTest

/// Unified library 2b: 設定 → 遠端書庫 manages every connection without the bookshelf.
final class RemoteLibrarySettingsUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testAddEditAndDeleteFromSettings() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let notNow = app.buttons["Don’t Allow"]
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }

        // 遠端書庫 is 設定's again (maintainer, 2026-10-27: every way to add a source is there);
        // 資源庫 lists only the libraries connected.
        let settingsTab = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20))
        settingsTab.tap()
        let row = app.buttons["settings_remote_libraries"].firstMatch
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), "遠端書庫 sits in 設定")
        row.tap()
        XCTAssertTrue(app.navigationBars["Remote Library"].waitForExistence(timeout: 8))

        // Each kind has its own add row, pushing that kind's editor.
        for kind in ["webDAV", "opds", "calibre"] {
            let addRow = app.buttons["remote_library_add_\(kind)"].firstMatch
            for _ in 0..<3 where !addRow.isHittable { app.swipeUp() }
            XCTAssertTrue(addRow.waitForExistence(timeout: 5), "add row for \(kind)")
            addRow.tap()
            XCTAssertTrue(app.navigationBars["Add Server"].waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Remote Library"].waitForExistence(timeout: 5))
        }

        // A connection added here appears in its section, and swiping deletes it.
        let host = "settings-\(UUID().uuidString.prefix(8).lowercased()).example"
        let addOPDS = app.buttons["remote_library_add_opds"].firstMatch
        for _ in 0..<3 where !addOPDS.isHittable { app.swipeUp() }
        addOPDS.tap()
        let url = app.textFields["Server URL"].firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText("https://\(host)/opds")
        app.navigationBars["Add Server"].buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Remote Library"].waitForExistence(timeout: 5))

        // The row reads as one element (name, then server), so it is found by its label.
        let added = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", host)).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 5), "the new connection is listed under its host")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "remote-library-settings"
        attachment.lifetime = .keepAlways
        add(attachment)

        added.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertFalse(added.waitForExistence(timeout: 2), "swipe-delete removes it")
    }

    /// Unified library 5c-5: OPDS's 範例目錄 moved here from the bookshelf's OPDS list. An
    /// example adds an ordinary connection and leaves the list until that is removed.
    @MainActor
    func testExampleCatalogAddsAConnection() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let notNow = app.buttons["Don’t Allow"]
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }
        // 遠端書庫 is 設定's again (maintainer, 2026-10-27: every way to add a source is there);
        // 資源庫 lists only the libraries connected.
        let settingsTab = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20))
        settingsTab.tap()
        let row = app.buttons["settings_remote_libraries"].firstMatch
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars["Remote Library"].waitForExistence(timeout: 8))

        let example = app.buttons["remote_library_example"].firstMatch
        for _ in 0..<3 where !example.isHittable { app.swipeUp() }
        XCTAssertTrue(example.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(example.label, "Project Gutenberg")
        example.tap()

        let added = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "gutenberg.org/ebooks.opds")).firstMatch
        XCTAssertTrue(added.waitForExistence(timeout: 5), "the example is now a connection")
        XCTAssertFalse(example.exists, "an added example leaves the list")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "remote-library-example-added"
        attachment.lifetime = .keepAlways
        add(attachment)

        added.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(example.waitForExistence(timeout: 5), "removed, it is offered again")
    }

    /// Unified library 2d, end to end against a real WebDAV server: a library added in
    /// Settings is indexed on its own, and its row says so. Opt-in, with
    /// `TEST_RUNNER_YUEDU_WEBDAV_BENCHMARK_URL` pointing at a server holding `t1k/`
    /// (1,000 books).
    @MainActor
    func testWebDAVLibraryIndexesItself() throws {
        let key = "YUEDU_WEBDAV_BENCHMARK_URL"
        let env = ProcessInfo.processInfo.environment
        guard let server = env[key] ?? env["TEST_RUNNER_" + key] else {
            throw XCTSkip("Set \(key) to a WebDAV server holding t1k/")
        }
        let app = XCUIApplication()
        app.launchArguments += ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let notNow = app.buttons["Don’t Allow"]
        if notNow.waitForExistence(timeout: 5) { notNow.tap() }
        // 遠端書庫 is 設定's again (maintainer, 2026-10-27: every way to add a source is there);
        // 資源庫 lists only the libraries connected.
        let settingsTab = app.tabBars.buttons["Settings"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20))
        settingsTab.tap()
        let row = app.buttons["settings_remote_libraries"].firstMatch
        for _ in 0..<4 where !row.isHittable { app.swipeUp() }
        row.tap()

        let addRow = app.buttons["remote_library_add_webDAV"].firstMatch
        XCTAssertTrue(addRow.waitForExistence(timeout: 5))
        addRow.tap()
        let url = app.textFields["Server URL"].firstMatch
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap()
        url.typeText(server + "t1k/")
        XCTAssertTrue(app.switches["Index Books in Background"].firstMatch.exists, "the toggle is there, on by default")
        app.navigationBars["Add Server"].buttons["Save"].tap()

        let indexed = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Indexed 1000 books")).firstMatch
        let found = indexed.waitForExistence(timeout: 120)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "webdav-indexed"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(found, "the library indexes itself and the row says so")

        indexed.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
    }
}
