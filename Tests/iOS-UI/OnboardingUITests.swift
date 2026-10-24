import XCTest

/// 新手導覽: up at a device's first launch, turned with 繼續, and left by a start that opens
/// the page it names, by 略過, or brought back from 設定 → 關於.
final class OnboardingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// `showsTour`: launched as a device that has not seen the tour. `NO` rather than left out,
    /// since an earlier run on the simulator may have finished it.
    @MainActor
    private func launch(showsTour: Bool, arguments: [String] = []) -> XCUIApplication {
        // A simulator that never answered the notification prompt shows it at launch, over the
        // tour, and SpringBoard's alert takes every touch until it is answered.
        addUIInterruptionMonitor(withDescription: "System permission prompt") { alert in
            alert.buttons.element(boundBy: 0).tap()
            return true
        }
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", showsTour ? "NO" : "YES",
                               "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"] + arguments
        app.launch()
        return app
    }

    /// Turns with 繼續 to the last page, a screenshot of each on the way; returns the last
    /// page's start that connects a library.
    @MainActor
    private func turnToTheStarts(_ app: XCUIApplication) -> XCUIElement {
        let next = app.buttons["onboarding.continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), app.debugDescription)
        let connect = app.buttons["onboarding.start.connectLibrary"]
        var page = 1
        while !(connect.exists && connect.isHittable), page < 6 {
            attach("onboarding-page-\(page)")
            next.tap()
            page += 1
        }
        XCTAssertTrue(connect.waitForExistence(timeout: 5), app.debugDescription)
        attach("onboarding-page-\(page)")
        return connect
    }

    @MainActor
    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 設定 → 關於 → 新手導覽; returns the row that brought it back.
    @MainActor
    private func replayFromAbout(_ app: XCUIApplication) -> XCUIElement {
        let settings = app.tabBars.buttons["設定"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30))
        settings.tap()
        let about = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "關於 Yuedu Reader")).firstMatch
        for _ in 0..<12 where !(about.exists && about.isHittable) { app.swipeUp() }
        about.tap()
        let replay = app.buttons["about.onboarding"]
        XCTAssertTrue(replay.waitForExistence(timeout: 5), app.debugDescription)
        // Its title and what it does, with neither symbol's name around them.
        XCTAssertTrue(replay.label.hasPrefix("新手導覽"), replay.label)
        XCTAssertTrue(replay.label.hasSuffix("再看一次 App 介紹和基本操作"), replay.label)
        replay.tap()
        return replay
    }

    @MainActor
    func testConnectLibraryOpensRemoteLibraries() throws {
        let app = launch(showsTour: true)
        let connect = turnToTheStarts(app)
        // The last page leaves by its own choices; 略過 is gone from it.
        let skip = app.buttons["onboarding.skip"]
        XCTAssertFalse(skip.exists && skip.isHittable)

        connect.tap()
        XCTAssertTrue(app.buttons["remote_library_add_webDAV"].firstMatch.waitForExistence(timeout: 10),
                      app.debugDescription)
        XCTAssertTrue(app.navigationBars["遠端書庫"].exists)
        XCTAssertTrue(app.buttons["onboarding.continue"].waitForNonExistence(timeout: 5))
    }

    /// 新增來源配置 opens 來源配置管理 on 資源庫, where the toolbar adds one. A device that never
    /// opened it is shown 注意事項 first, as from anywhere else.
    @MainActor
    func testAddSourcesOpensSourceManagement() throws {
        let app = launch(showsTour: true, arguments: ["-yd_source_disclaimer_accepted", "NO"])
        _ = turnToTheStarts(app)
        let add = app.buttons["onboarding.start.addSources"]
        XCTAssertTrue(add.isHittable, app.debugDescription)

        add.tap()
        XCTAssertTrue(app.buttons["onboarding.continue"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["注意事項"].waitForExistence(timeout: 10), app.debugDescription)
        app.buttons["繼續"].tap()
        XCTAssertTrue(app.navigationBars["注意事項"].waitForNonExistence(timeout: 5), app.debugDescription)
        // It hides the tab bar for a toolbar of its own; back leads to 資源庫's root.
        let back = app.navigationBars["來源配置管理"].buttons["資源庫"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        back.tap()
        XCTAssertTrue(app.buttons["library.sources"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let library = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(library.isSelected)
    }

    /// 資源庫 opened before the tour came back: its tab is already there when 連接書庫 picks it,
    /// and 遠端書庫 opens over its root.
    @MainActor
    func testConnectLibraryFromAReplayOpensOverTheLibrary() throws {
        let app = launch(showsTour: false)
        let library = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 30))
        library.tap()
        let manageSources = app.buttons["library.sources"].firstMatch
        XCTAssertTrue(manageSources.waitForExistence(timeout: 10), app.debugDescription)

        _ = replayFromAbout(app)
        turnToTheStarts(app).tap()
        XCTAssertTrue(app.buttons["remote_library_add_webDAV"].firstMatch.waitForExistence(timeout: 10),
                      app.debugDescription)
        XCTAssertTrue(app.navigationBars["遠端書庫"].exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(manageSources.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(library.isSelected)
    }

    @MainActor
    func testSkipLeavesForTheTabs() throws {
        let app = launch(showsTour: true)
        let skip = app.buttons["onboarding.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 30), app.debugDescription)
        skip.tap()
        XCTAssertTrue(app.buttons["onboarding.continue"].waitForNonExistence(timeout: 5))
        let bookshelf = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(bookshelf.waitForExistence(timeout: 5))
        XCTAssertTrue(bookshelf.isHittable)
    }

    @MainActor
    func testAboutBringsTheTourBack() throws {
        let app = launch(showsTour: false)
        XCTAssertTrue(app.tabBars.buttons["設定"].firstMatch.waitForExistence(timeout: 30))
        XCTAssertFalse(app.buttons["onboarding.continue"].exists)
        let replay = replayFromAbout(app)

        let skip = app.buttons["onboarding.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5), app.debugDescription)
        skip.tap()
        XCTAssertTrue(app.buttons["onboarding.continue"].waitForNonExistence(timeout: 5))
        // Left where it was brought back from.
        XCTAssertTrue(replay.isHittable)
    }
}
