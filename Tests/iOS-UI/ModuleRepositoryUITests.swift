import XCTest

/// M6 (maintainer, 2026-10-17: 「模組要做到截圖這樣」): 設定 → 模組 (moved out of 資源庫's •••
/// the same day: 「模組設定頁在設置好了」), where an address holding a repository's index is
/// subscribed to; its page lists the modules, 選擇 installs two at once, and 停用 on a module's
/// page takes its card out of 資源庫.
///
/// Needs `python3 -I scripts/module_repository_fixture.py` (port 18772). The app asks
/// `localhost`: `safeURL` refuses the `127.0.0.1` literal.
final class ModuleRepositoryUITests: XCTestCase {
    static let indexURL = "http://localhost:18772/index.json"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// An item of an open menu or the iOS 17 chooser, whose row also reads its subtitle.
    @MainActor
    private func item(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    @MainActor
    private func scrolledTo(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        var swipes = 0
        while !element.exists, swipes < 8 {
            app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            swipes += 1
        }
        return element
    }

    @MainActor
    func testSubscribeInstallTwoAndDisable() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleRepositoryUITests-\(UUID().uuidString)")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-no-official-modules", "-onboarding.completed", "YES",
                               "-yd_source_disclaimer_accepted", "YES", "-rule-module-store-dir", folder.path,
                               // An earlier run's 停用 is in the app's defaults; this run starts with none.
                               "-ruleModules.disabled", "()", "-ruleModules.hiddenInLibrary", "()"]
        app.launch()
        let tab = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        let settings = app.tabBars.buttons["設定"].firstMatch
        settings.tap()

        // 設定 → 資源 → 模組.
        let manage = app.buttons["settings_modules"].firstMatch
        XCTAssertTrue(manage.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<6 where !manage.isHittable { app.swipeUp(velocity: .slow) }
        attach(app, "settings-modules-row")
        manage.tap()
        XCTAssertTrue(app.navigationBars["模組"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["modules.official"].exists && app.buttons["modules.imported"].exists, app.debugDescription)
        attach(app, "modules-manager-empty")

        // 新增模組 → 從網址 → the index → 訂閱模組倉庫.
        app.buttons["modules.add"].firstMatch.tap()
        let address = item(app, "從網址")
        XCTAssertTrue(address.waitForExistence(timeout: 5), app.debugDescription)
        address.tap()
        let field = app.textFields["module.import.address"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), app.debugDescription)
        field.tap()
        field.typeText(Self.indexURL)
        app.buttons["module.import.load"].firstMatch.tap()
        let commit = app.buttons["module.import.commit"].firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(commit.label, "訂閱模組倉庫")
        XCTAssertTrue(app.staticTexts["甲模組"].exists && app.staticTexts["乙模組"].exists, app.debugDescription)
        attach(app, "modules-repository-preview")
        commit.tap()
        XCTAssertFalse(commit.waitForExistence(timeout: 3), "the sheet closes once subscribed")

        let row = app.buttons["modules.repository.\(Self.indexURL)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(row.label.hasPrefix("測試倉庫"), row.label)
        attach(app, "modules-manager-subscribed")
        row.tap()

        // 選擇 both, then 安裝 2 個.
        XCTAssertTrue(app.navigationBars["測試倉庫"].waitForExistence(timeout: 5), app.debugDescription)
        let alpha = app.buttons["modules.repository.entry.repo.alpha"].firstMatch
        XCTAssertTrue(alpha.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(alpha.value.map { "\($0)".contains("安裝") } ?? false, "\(String(describing: alpha.value))")
        attach(app, "modules-repository")
        app.buttons["modules.repository.select"].firstMatch.tap()
        alpha.tap()
        app.buttons["modules.repository.entry.repo.beta"].firstMatch.tap()
        let install = app.buttons["modules.repository.installSelection"].firstMatch
        XCTAssertTrue(install.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(install.label, "安裝 2 個")
        attach(app, "modules-repository-selecting")
        install.tap()
        let summary = app.staticTexts["已安裝 2 個、更新 0 個模組。"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(alpha.value.map { "\($0)".contains("安裝") } ?? true, "installed: its version, not 安裝")
        attach(app, "modules-repository-installed")

        // 甲模組's page → 停用.
        alpha.tap()
        XCTAssertTrue(app.navigationBars["甲模組"].waitForExistence(timeout: 5), app.debugDescription)
        let toggle = app.buttons["module.enabled"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["module.export"].exists, "匯出 is on the toolbar")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["已停用"].waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "modules-module-disabled")

        // 資源庫 (模組's pages hide the tab bar): 乙模組's card, not 甲模組's. 資源庫's ••• neither
        // adds nor manages modules: 設定 does.
        for _ in 0..<4 where !tab.isHittable {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(tab.waitForExistence(timeout: 5), app.debugDescription)
        tab.tap()
        let more = app.buttons["library.more"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
        more.tap()
        XCTAssertTrue(item(app, "管理來源配置").waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(item(app, "新增模組").exists, "模組 is added in 設定 now")
        XCTAssertFalse(item(app, "管理模組").exists, "模組 is managed in 設定 now")
        attach(app, "library-more")
        // Closes the menu: a tap beside it, on the large title.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.08)).tap()
        let beta = scrolledTo(app.buttons["library.module.repo.beta"].firstMatch, in: app)
        XCTAssertTrue(beta.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["library.module.repo.alpha"].exists, "a module turned off has no card in 資源庫")
        attach(app, "modules-library-cards")
    }
}
