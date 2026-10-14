import XCTest

/// Phase 6e: 資源庫's 模組. A module is added from an address through the •••, its card
/// appears, its page lists its lists and sites, and 移除模組 takes it away.
///
/// The fixture is served over HTTP from outside the simulator before the run:
/// `python3 -m http.server 18766 --bind 127.0.0.1` in a folder holding
/// - `uitest-module.json`: id `uitest.module`, title 測試模組, hosts `["localhost"]`, one list
///   `new` (新書) requesting `http://localhost:18766/new.html` with rules `li` / `h3@text`;
/// - `new.html`: `<ul><li><h3>模組第一本</h3></li><li><h3>模組第二本</h3></li></ul>`.
///
/// The app asks `localhost`: `safeURL` refuses the `127.0.0.1` literal.
final class ModuleLibraryUITests: XCTestCase {
    static let fixtureURL = "http://localhost:18766/uitest-module.json"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(disclaimerAccepted: Bool = true, extra: [String] = []) -> XCUIApplication {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleLibraryUITests-\(UUID().uuidString)")
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", disclaimerAccepted ? "YES" : "NO",
                               "-rule-module-store-dir", folder.path] + extra
        app.launch()
        let tab = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
        XCTAssertTrue(app.buttons["library.more"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        return app
    }

    /// 資源庫's •••. On iOS 27 the bar slides away as the page scrolls (`.minimizesBar`), so the
    /// page goes back to its top first.
    private func tapMore(_ app: XCUIApplication) {
        let more = app.buttons["library.more"].firstMatch
        var swipes = 0
        while !more.isHittable, swipes < 8 {
            app.scrollViews.firstMatch.swipeDown(velocity: .fast)
            swipes += 1
        }
        more.tap()
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

    /// ••• → 新增模組 → 從網址 → the fixture → ✓, from 資源庫.
    @MainActor
    private func addFixtureModule(_ app: XCUIApplication) {
        // ••• → 新增模組 → 從網址; on iOS 17 a chooser row, opened once the chooser has gone.
        tapMore(app)
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
        XCTAssertFalse(commit.waitForExistence(timeout: 3), "the sheet closes once the module is added")
    }

    @MainActor
    func testAddFromAddressThenRemove() {
        let app = launch()
        let empty = scrolledTo(app.buttons["library.modules.add"].firstMatch, in: app)
        XCTAssertTrue(empty.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "modules-empty")

        addFixtureModule(app)

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

    /// 6e-2: a `yuedu://module?src=` link, opened from outside, shows the source disclaimer the
    /// first time, then the same import sheet as 從網址, already loading the module.
    @MainActor
    func testOpenLinkShowsDisclaimerThenImport() throws {
        guard #available(iOS 16.4, *) else { throw XCTSkip("XCUIDevice.system.open(_:) needs iOS 16.4") }
        let app = launch(disclaimerAccepted: false)
        let link = try XCTUnwrap(URL(string: "yuedu://module?src=" + Self.fixtureURL))
        XCTAssertTrue(app.tabBars.buttons["資源庫"].firstMatch.isSelected, app.debugDescription)
        // From the system, as a link tapped elsewhere arrives: `XCUIApplication.open(_:)`
        // relaunches the app instead (seen: a new pid, back on 書架, launch arguments gone).
        XCUIDevice.shared.system.open(link)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirm = springboard.buttons["Open"].firstMatch
        if confirm.waitForExistence(timeout: 5) { confirm.tap() }

        let proceed = app.buttons["繼續"].firstMatch
        XCTAssertTrue(proceed.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "module-link-disclaimer")
        proceed.tap()

        let commit = app.buttons["module.import.commit"].firstMatch
        XCTAssertTrue(commit.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.textFields["module.import.address"].exists, "the link is the address: no field to fill")
        XCTAssertTrue(app.staticTexts["localhost"].exists, "the sites it connects to are shown first")
        attach(app, "module-link-preview")
        commit.tap()
        XCTAssertFalse(commit.waitForExistence(timeout: 3), "the sheet closes once the module is added")
        // The link reaches the window already open, not a new one starting on 書架.
        XCTAssertTrue(app.tabBars.buttons["資源庫"].firstMatch.isSelected, app.debugDescription)

        let card = scrolledTo(app.buttons["library.module.uitest.module"].firstMatch, in: app)
        XCTAssertTrue(card.waitForExistence(timeout: 10), app.debugDescription)
        attach(app, "module-link-card")
    }

    /// 6f: a module's list is a source of 選擇內容來源. Its section's preview loads the list, and
    /// once added the home shows it as a row.
    @MainActor
    func testModuleListOnTheHome() {
        let app = launch(extra: ["-reset-explore-home"])
        addFixtureModule(app)

        app.tabBars.buttons["探索"].firstMatch.tap()
        // 編輯首頁 is the home's last button, built once scrolled to.
        XCTAssertTrue(app.navigationBars["探索"].waitForExistence(timeout: 20), app.debugDescription)
        let edit = app.buttons["home.edit"].firstMatch
        for _ in 0..<12 where !(edit.exists && edit.isHittable) { app.swipeUp() }
        XCTAssertTrue(edit.isHittable, app.debugDescription)
        edit.tap()
        let addSection = app.buttons["homeEditor.addSection"].firstMatch
        XCTAssertTrue(addSection.waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<8 where !addSection.isHittable { app.swipeUp() }
        addSection.tap()
        let rowLayout = app.buttons["homeNewSection.layout.row"].firstMatch
        XCTAssertTrue(rowLayout.waitForExistence(timeout: 5), app.debugDescription)
        rowLayout.tap()
        let source = app.buttons["homeSection.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5), app.debugDescription)
        source.tap()

        let module = app.buttons["homePicker.module.uitest.module"].firstMatch
        XCTAssertTrue(module.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 where !module.isHittable { app.swipeUp() }
        attach(app, "module-picker")
        module.tap()
        let list = app.buttons["homePicker.item.新書"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        list.tap()

        XCTAssertTrue(source.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(source.value as? String, "測試模組 › 新書")
        let book = NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "home.card.module.", "模組第一本")
        XCTAssertTrue(app.buttons.matching(book).firstMatch.waitForExistence(timeout: 15), "the preview loads the list")
        attach(app, "module-section-form")
        app.buttons["homeSection.add"].firstMatch.tap()

        XCTAssertTrue(addSection.waitForExistence(timeout: 5), app.debugDescription)
        let sectionCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                           "homeEditor.section.", "新書")).firstMatch
        XCTAssertTrue(sectionCard.exists, app.debugDescription)
        for _ in 0..<8 { app.swipeDown() }
        let done = app.buttons["home.editDoneBar"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), app.debugDescription)
        done.tap()

        let card = app.buttons.matching(book).firstMatch
        for _ in 0..<12 where !(card.exists && card.isHittable) { app.swipeUp() }
        XCTAssertTrue(card.isHittable, "the home shows the module's row")
        attach(app, "module-row-on-home")

        // 6f-2: its header leads to 查看全部, the whole list.
        let header = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "home.row.header.", "新書")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), app.debugDescription)
        header.tap()
        XCTAssertTrue(app.navigationBars["新書"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons.matching(book).firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["module.list.more"].exists, "a list with no paging has one page")
        attach(app, "module-list-page")
    }
}
