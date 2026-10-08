import XCTest

/// Drives 設定 → 管理書源 → ⋯ → 書源驗證 on a fresh launch, the path where 開始驗證 did not
/// respond the first time: the options sheet was built from a stale, empty source list
/// (「將對 0 個書源」) and its start button was disabled.
///
/// The library is a three-source fixture in a scratch directory handed to the app with
/// `-book-source-store-dir`, so the simulator's own book sources are never touched.
final class BookSourceManagementUITests: XCTestCase {
    private var storeDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceManagementUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let sources: [[String: Any]] = (0..<3).map { index in
            [
                "bookSourceName": "介面測試書源\(index)",
                "bookSourceUrl": "https://ui-test-\(index).example",
                "searchUrl": "https://ui-test-\(index).example/search?q={{key}}",
                "enabled": true,
            ]
        }
        try JSONSerialization.data(withJSONObject: sources)
            .write(to: storeDirectory.appendingPathComponent("book_sources.json"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: storeDirectory)
    }

    /// Opt-in end-to-end probe with a real library of tens of thousands of sources:
    ///
    ///     TEST_RUNNER_BOOK_SOURCE_UI_LIBRARY=<Legado JSON array>   (e.g. a 50,000-source pack)
    ///
    /// Opens 書源管理, scrolls, switches pages, selects the page, and checks the app is still
    /// alive. Screenshots land in the result bundle.
    @MainActor
    func testLargeLibraryOpensScrollsAndSwitchesPages() throws {
        let key = "BOOK_SOURCE_UI_LIBRARY"
        let env = ProcessInfo.processInfo.environment
        guard let library = env[key] ?? env["TEST_RUNNER_" + key] else {
            throw XCTSkip("Set \(key) to a Legado source pack")
        }
        try FileManager.default.removeItem(at: storeDirectory.appendingPathComponent("book_sources.json"))
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: library),
            to: storeDirectory.appendingPathComponent("book_sources.json"))
        let expectedCount = try (JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: library))) as? [Any])?.count ?? 0

        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-yd_source_disclaimer_accepted", "YES",
            "-yd_booksource_list_grouped", "NO",
            "-book-source-store-dir", storeDirectory.path,
        ]
        app.launch()
        for label in ["不允許", "Don’t Allow"] where app.buttons[label].waitForExistence(timeout: 3) {
            app.buttons[label].tap()
        }
        let settingsTab = app.tabBars.buttons["設定"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 60), "settings tab should exist")
        settingsTab.tap()
        let manageRow = app.buttons["管理來源配置"].firstMatch
        for _ in 0..<6 where !manageRow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(manageRow.waitForExistence(timeout: 5))

        let opened = Date()
        manageRow.tap()
        let selectAll = app.buttons["全選"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 60), "書源管理 should open")
        let allPage = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "全部 ")).firstMatch
        XCTAssertTrue(allPage.waitForExistence(timeout: 30), "the page buttons should render")
        let openSeconds = Date().timeIntervalSince(opened)
        // Counts are formatted for the locale (「全部 50,000」); compare the numbers.
        XCTAssertEqual(numbers(in: allPage.label), [expectedCount])
        attachScreenshot(app, "large library opened")

        let list = app.collectionViews.firstMatch
        for _ in 0..<8 {
            list.swipeUp(velocity: .fast)
        }
        attachScreenshot(app, "large library scrolled")
        for _ in 0..<8 {
            list.swipeDown(velocity: .fast)
        }

        selectAll.tap()
        XCTAssertEqual(numbers(in: selectAll.value), [expectedCount, expectedCount])
        let fetchPage = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "抓取異常 ")).firstMatch
        fetchPage.tap()
        // A different page starts with nothing selected.
        XCTAssertEqual(numbers(in: selectAll.value), [0, 0])
        allPage.tap()
        XCTAssertEqual(numbers(in: selectAll.value), [0, expectedCount])
        attachScreenshot(app, "large library after page switches")

        XCTAssertEqual(app.state, .runningForeground, "the app must survive the large library")
        print("UI_LARGE_LIBRARY sources=\(expectedCount) openSeconds=\(String(format: "%.2f", openSeconds))")
    }

    /// The integers in a label or value such as 「全部 50,000」 or 「12/50,000」.
    private func numbers(in value: Any?) -> [Int] {
        let text = (value as? String) ?? ""
        return text.split(separator: "/").compactMap { part in
            Int(part.filter(\.isNumber))
        }
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testValidationOptionsCountTheSourcesOnFirstOpen() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-yd_source_disclaimer_accepted", "YES",
            "-book-source-store-dir", storeDirectory.path,
        ]
        app.launch()

        // The notification prompt can land on top of the shelf on a fresh install.
        for label in ["不允許", "Don’t Allow"] where app.buttons[label].waitForExistence(timeout: 3) {
            app.buttons[label].tap()
        }

        let settingsTab = app.tabBars.buttons["設定"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20), "settings tab should exist")
        settingsTab.tap()

        let manageRow = app.buttons["管理來源配置"].firstMatch
        for _ in 0..<6 where !manageRow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(manageRow.waitForExistence(timeout: 5), "管理書源 should be reachable")
        manageRow.tap()

        let firstSource = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "介面測試書源0")).firstMatch
        XCTAssertTrue(firstSource.waitForExistence(timeout: 15), "the fixture library should list")

        let more = app.navigationBars.buttons["更多"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the toolbar 更多 menu should exist")
        more.tap()
        let validate = app.buttons["來源配置驗證"].firstMatch
        XCTAssertTrue(validate.waitForExistence(timeout: 5), "書源驗證 should be in the menu")
        validate.tap()

        let count = app.staticTexts["將對 3 個來源配置進行五階段驗證"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the options sheet should count the 3 sources")
        let start = app.buttons["開始驗證"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isEnabled, "開始驗證 must be tappable the first time the sheet opens")

        attachScreenshot(app, "書源驗證 first open")

        // The run itself: the result sheet opens and lists the three sources.
        start.tap()
        let results = app.staticTexts["驗證結果"].firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 15), "the result sheet should open")
        let finished = app.staticTexts["驗證完成"].firstMatch
        XCTAssertTrue(finished.waitForExistence(timeout: 120), "the three sources should finish")
        XCTAssertTrue(app.staticTexts["介面測試書源2"].firstMatch.exists)
        attachScreenshot(app, "書源驗證 results")
    }
}
