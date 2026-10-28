import XCTest

/// A tab keeps its one navigation controller when a tab before it is shown or hidden.
///
/// iOS 17's TabView rebuilt the selected tab whenever a tab before it came or went, and the
/// rebuilt NavigationStack got a second navigation controller while the first still held
/// its root (traced on iOS 17.5 with lldb: the old controller stayed in the hierarchy,
/// popped to its root, and the new one in the window had no view controllers). iOS 17.5
/// left the tab blank; iOS 17.0 crashed with "Layout requested for visible navigation bar …
/// top item belongs to a different navigation bar" (Crashlytics
/// fe741015e1cc320abea6275cd5f79a02, on 书架). 设置 is the tab on screen while 探索 is hidden
/// from 底部标签栏, so it is the one checked here; 书架, after 探索 too, must still draw.
final class RootTabNavigationOwnershipUITests: XCTestCase {
    /// Every tab shown. Passed at each launch, so a run starts from the full bar whatever an
    /// earlier run left saved.
    private static let allTabs = "(explore, bookshelf, library, settings, search)"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // XCTest runs a UI test's teardown on the main thread.
    override func tearDownWithError() throws {
        try MainActor.assumeIsolated { try Self.restoreSavedTabs() }
    }

    @MainActor
    func testTabsStillDrawAfterATabBeforeThemIsHidden() throws {
        let app = try Self.launch()
        // Visit 书架 first: a tab's stack is only built when the tab is first shown.
        Self.tab("书架", in: app).tap()
        XCTAssertTrue(Self.shelfOptions(in: app).waitForExistence(timeout: 10), "书架 never showed")

        Self.openTabCustomization(in: app)
        Self.flip("探索", in: app)
        XCTAssertFalse(Self.tab("探索", in: app).exists, "探索 is still on the tab bar")

        // 设置 was rebuilt with the tab set: its root or the page left open, not a blank bar.
        let settingsRoot = app.buttons["settings_account_row"].firstMatch
        let tabsPage = app.switches["搜索"].firstMatch
        let drawn = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in settingsRoot.exists || tabsPage.exists }, object: nil
        )
        XCTAssertEqual(XCTWaiter().wait(for: [drawn], timeout: 10), .completed,
                       "设置 is blank after 探索 was hidden: \(app.debugDescription)")

        Self.tab("书架", in: app).tap()
        XCTAssertTrue(
            Self.shelfOptions(in: app).waitForExistence(timeout: 10),
            "书架 is blank after 探索 was hidden: \(app.debugDescription)"
        )
    }

    // MARK: - Helpers

    /// Under a StoreKit test session: without one, iOS 17.5 puts a system Apple ID sign-in over
    /// the app on every launch.
    @MainActor
    private static func launch() throws -> XCUIApplication {
        _ = try StoreKitTestSessions.fresh(StoreKitTestSessions.yueduPro())
        let app = XCUIApplication()
        // Pro: 底部标签栏 is a Pro setting.
        app.launchArguments = ["-onboarding.completed", "YES", "-debug-force-pro",
                               "-yd_root_tab_visible_ids", Self.allTabs,
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(tab("书架", in: app).waitForExistence(timeout: 20), "no tab bar")
        return app
    }

    @MainActor
    private static func tab(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.tabBars.buttons[title].firstMatch
    }

    /// In 書架's own navigation bar, so it exists only while the shelf is drawn.
    @MainActor
    private static func shelfOptions(in app: XCUIApplication) -> XCUIElement {
        app.buttons["home_options_menu"].firstMatch
    }

    /// 设置 → 外观主题 → 底部标签栏, unless it is already open.
    @MainActor
    private static func openTabCustomization(in app: XCUIApplication) {
        guard !app.switches["搜索"].firstMatch.exists else { return }
        tab("设置", in: app).tap()
        let appearance = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "外观主题")).firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 10), "no 外观主题 row")
        appearance.tap()
        let tabsRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "底部标签栏")).firstMatch
        XCTAssertTrue(tabsRow.waitForExistence(timeout: 10), "no 底部标签栏 row")
        for _ in 0..<8 where !tabsRow.isHittable { app.swipeUp() }
        tabsRow.tap()
        XCTAssertTrue(app.switches["搜索"].firstMatch.waitForExistence(timeout: 10), "no 显示页面 switches")
    }

    /// A Form toggle's row is the switch element; the knob sits at its trailing edge. On
    /// iOS 17 a new tab set rebuilds every tab, so the row may be gone once it has flipped.
    @MainActor
    private static func flip(_ title: String, in app: XCUIApplication) {
        let row = app.switches[title].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "no \(title) switch")
        let before = row.value as? String
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in !row.exists || row.value as? String != before }, object: nil
        )
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 10), .completed, "\(title) did not flip")
    }

    /// Hiding 探索 is saved on the simulator; every later test would start without it.
    /// Relaunched with every tab shown, then 搜索 is switched off and on, which saves the
    /// whole list again.
    @MainActor
    private static func restoreSavedTabs() throws {
        let app = try launch()
        openTabCustomization(in: app)
        flip("搜索", in: app)
        openTabCustomization(in: app)
        flip("搜索", in: app)
        app.terminate()
    }
}
