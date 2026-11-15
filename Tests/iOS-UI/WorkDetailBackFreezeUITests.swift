import StoreKitTest
import XCTest

/// FB-204 (iOS 17.0, build 151): after 作品詳情 → the reader → a swipe back from the edge, the
/// page's own back button lit up under the finger and the screen stayed where it was, until the
/// app had been to the app switcher and back; every later step needed another trip.
///
/// On iOS 17.0 an interactive pop between a page that hides the navigation bar and one that shows
/// it leaves UIKit's animator tracking on for the life of the process, and every transition after
/// it is built paused (`NavigationBackSwipeReservationController.popsWithoutInteractiveTransition`).
/// The test swipes across that boundary and then asks for an ordinary pop. It fails on the iOS 17.0
/// simulator without that branch and passes on iOS 17.5 and later either way. The boundary the
/// other way, 作品詳情 pushed over the reader from its book card, has no swipe back on iOS 17.
///
/// The book is a text file the test writes, imported at launch, as `WorkDetailUITests` does it,
/// with no sources for the page to search.
final class WorkDetailBackFreezeUITests: XCTestCase {
    private let title = "返回卡死測試"
    private let body = "返回卡死測試正文，用來確認閱讀器打開了這本書。"
    private var folder: URL!
    private var storeKitSession: SKTestSession?

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkDetailBack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "第一章 開始\n\n\(body)\n\n" + String(repeating: "\(body)\n", count: 20)
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(title).txt"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func launch() throws -> XCUIApplication {
        // iOS 17 asks for an Apple ID at launch without a StoreKit test session.
        storeKitSession = try StoreKitTestSessions.fresh(StoreKitTestSessions.yueduPro())
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-reset-explore-home",
                               "-auto-import-epub", folder.appendingPathComponent("\(title).txt").path,
                               "-auto-import-title", title, "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO",
                               "-book-source-store-dir", folder.appendingPathComponent("sources").path]
        app.launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()
        return app
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    private func shelfBook(_ app: XCUIApplication) -> XCUIElement {
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), app.debugDescription)
        return cell
    }

    /// The shelf's ••• → 作品詳情; returns the page's 來源 row, which only that page has.
    @MainActor
    private func openWorkDetail(_ app: XCUIApplication) -> XCUIElement {
        let cell = shelfBook(app)
        let more = cell.buttons["更多"].firstMatch
        if more.exists {
            more.tap()
        } else {
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.96)).tap()
        }
        let menuItem = app.buttons["作品詳情"].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), app.debugDescription)
        menuItem.tap()
        let versions = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(versions.waitForExistence(timeout: 10), app.debugDescription)
        return versions
    }

    @MainActor
    private func readerText(_ app: XCUIApplication) -> XCUIElement {
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), "The reader opens the book.\n\(app.debugDescription)")
        return content
    }

    @MainActor
    private func swipeBackFromTheEdge(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
    }

    /// The report's recipe: the reader, pushed by 作品詳情 with its bar hidden, is left by a swipe.
    @MainActor
    func testBackFromWorkDetailAfterSwipingOutOfItsReader() throws {
        let app = try launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        for round in 1...3 {
            let versions = openWorkDetail(app)
            let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["開始閱讀", "繼續閱讀"])).firstMatch
            XCTAssertTrue(read.exists, app.debugDescription)
            read.tap()
            let content = readerText(app)
            swipeBackFromTheEdge(app)
            XCTAssertTrue(content.waitForNonExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(versions.waitForExistence(timeout: 10), "The reader closes onto 作品詳情.\n\(app.debugDescription)")
            app.navigationBars.buttons.firstMatch.tap()
            XCTAssertTrue(versions.waitForNonExistence(timeout: 10), "Round \(round): back leaves 作品詳情.\n\(app.debugDescription)")
            XCTAssertTrue(shelfBook(app).waitForExistence(timeout: 10))
            XCTAssertTrue(shelfTab.isHittable, "Round \(round): back from 作品詳情 returns to the shelf")
            screenshot(app, "round-\(round)-shelf-after-back")
        }
    }
}
