import XCTest

final class PublicLibraryExploreUITests: XCTestCase {
    private var sourceDirectory: URL!
    private let tipTitle = "可以切換探索內容"

    override func setUpWithError() throws {
        continueAfterFailure = false
        sourceDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicLibraryExploreUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: sourceDirectory)
    }

    @MainActor
    private func application(reset: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-yd_source_disclaimer_accepted", "YES", "-book-source-store-dir", sourceDirectory.path]
        if reset { app.launchArguments += ["-reset-tips", "-reset-public-library-explore"] }
        return app
    }

    @MainActor
    private func openExplore(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testNoSourcesShowsLibrariesWithoutSwitch() {
        let app = application(reset: true)
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.staticTexts["Project Gutenberg"].firstMatch.waitForExistence(timeout: 10))
        for title in ["熱門", "最新", "中文", "English"] {
            XCTAssertTrue(app.buttons[title].firstMatch.exists, title)
        }
        XCTAssertFalse(app.buttons["explore.modeMenu"].exists)
        XCTAssertFalse(app.staticTexts[tipTitle].exists)
        XCTAssertFalse(app.staticTexts["青空文庫"].exists)
        attach(app, "Public libraries without Pro or sources")
    }

    @MainActor
    func testFirstImportGuideAndModePersistAcrossLaunches() throws {
        let app = application(reset: true)
        app.launch()
        openExplore(app)
        XCTAssertTrue(app.staticTexts["Project Gutenberg"].firstMatch.waitForExistence(timeout: 10))
        app.tabBars.buttons["設定"].firstMatch.tap()
        let manage = app.buttons["管理書源"].firstMatch
        for _ in 0..<6 where !manage.exists { app.swipeUp() }
        XCTAssertTrue(manage.waitForExistence(timeout: 5))
        manage.tap()
        let add = app.buttons["新增書源"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
        app.buttons["本地導入"].firstMatch.tap()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("[{\"bookSourceName\":\"Public library UI fixture\",\"bookSourceUrl\":\"https://public-library-ui.example\",\"enabled\":true}]")
        app.navigationBars["匯入書源"].buttons["checkmark"].tap()
        let confirm = app.buttons["匯入"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Public library UI fixture"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts[tipTitle].exists, "The import screen must not show the Explore tip")
        app.navigationBars["書源管理"].buttons["關閉"].tap()
        openExplore(app)
        XCTAssertTrue(app.staticTexts["Project Gutenberg"].firstMatch.waitForExistence(timeout: 10), "Importing does not switch mode")
        XCTAssertTrue(app.staticTexts[tipTitle].firstMatch.waitForExistence(timeout: 10))
        attach(app, "First import guide")
        let menu = app.buttons["explore.modeMenu"].firstMatch
        XCTAssertTrue(menu.exists)
        XCTAssertEqual(menu.label, "切換探索內容")
        XCTAssertEqual(menu.value as? String, "公有書庫")
        app.buttons["切換到書源"].firstMatch.tap()
        XCTAssertTrue(app.searchFields["搜索書源"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(menu.value as? String, "書源")
        attach(app, "Book sources after the guide action")
        app.terminate()
        let relaunched = application(reset: false)
        relaunched.launch()
        openExplore(relaunched)
        XCTAssertTrue(relaunched.searchFields["搜索書源"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(relaunched.staticTexts[tipTitle].exists)
        let savedMenu = relaunched.buttons["explore.modeMenu"].firstMatch
        XCTAssertEqual(savedMenu.value as? String, "書源")
        savedMenu.tap()
        relaunched.buttons["公有書庫"].firstMatch.tap()
        XCTAssertTrue(relaunched.staticTexts["Project Gutenberg"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(savedMenu.value as? String, "公有書庫")
        XCTAssertFalse(relaunched.staticTexts[tipTitle].exists)
    }
}
