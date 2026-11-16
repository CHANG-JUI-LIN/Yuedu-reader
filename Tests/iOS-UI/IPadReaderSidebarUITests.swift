import StoreKitTest
import UIKit
import XCTest

/// FB-206: on an iPad the root tabs are `.sidebarAdaptable`, and a reader pushed in a tab's
/// stack hid the tab bar while the tabs' sidebar still slid in over the page from a swipe at
/// the leading edge — where the reader's swipe back is. A reader now takes the sidebar away
/// for as long as it is on screen (`keepsRootTabSidebarAway()`), so that swipe leaves it.
///
/// The reader is pushed from 作品詳情, as every detail page pushes one; a book tapped on an
/// iPad's shelf opens in a cover over the tabs, where there is no sidebar to pull.
/// `-seed-shelf` books have no content file: the reader that opens has nothing to show, and
/// asks for the sidebar all the same (`BookReaderView`).
final class IPadReaderSidebarUITests: XCTestCase {
    private var storeKitSession: SKTestSession?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLeadingEdgeSwipeLeavesAPushedReaderWithoutOpeningTheSidebar() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the sidebar is an iPad's")
        if #unavailable(iOS 18.0) { throw XCTSkip("the root tabs have a sidebar from iOS 18") }

        storeKitSession = try StoreKitTestSessions.fresh(StoreKitTestSessions.yueduPro())
        addUIInterruptionMonitor(withDescription: "System permission prompt") { alert in
            alert.buttons.element(boundBy: 0).tap()
            return true
        }
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES",
                               "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings)",
                               "-bookLayoutIsGrid", "NO", "-bookSortOrder", "manual",
                               "-seed-shelf", "ungrouped"]
        app.launch()

        // 書架 → the first book's ••• → 作品詳情 → its reading button.
        let list = app.descendants(matching: .any)["home_book_list"]
        XCTAssertTrue(list.waitForExistence(timeout: 30), app.debugDescription)
        let more = list.buttons.matching(NSPredicate(format: "label == %@", "更多")).firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), app.debugDescription)
        more.tap()
        let showWork = app.buttons["作品詳情"].firstMatch
        XCTAssertTrue(showWork.waitForExistence(timeout: 10), app.debugDescription)
        showWork.tap()

        let read = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["繼續閱讀", "立即閱讀", "開始閱讀"])
        ).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 20), app.debugDescription)
        // The sidebar's own rows, which are in the tree only while it is open.
        let sidebarRow = app.cells.containing(NSPredicate(format: "label == %@", "設定")).firstMatch
        XCTAssertFalse(sidebarRow.exists, "the sidebar is closed on 作品詳情\n\(app.debugDescription)")
        read.tap()
        XCTAssertTrue(waitUntilGone(read), "the reader covers 作品詳情\n\(app.debugDescription)")
        // The seeded book has no file, which the reader says in an alert over the page.
        let noFile = app.alerts.buttons["確定"].firstMatch
        if noFile.waitForExistence(timeout: 10) { noFile.tap() }
        XCTAssertTrue(waitUntilGone(noFile), app.debugDescription)
        attachScreenshot(of: app, named: "reader pushed from 作品詳情")

        // From the leading edge, as far as a swipe back goes.
        let window = app.windows.firstMatch
        let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
            .withOffset(CGVector(dx: 1, dy: 0))
        edge.press(forDuration: 0.05,
                   thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5)),
                   withVelocity: 900, thenHoldForDuration: 0)

        attachScreenshot(of: app, named: "after the leading-edge swipe")
        XCTAssertFalse(sidebarRow.waitForExistence(timeout: 3),
                       "the swipe opened the tabs' sidebar over the reader\n\(app.debugDescription)")
        XCTAssertTrue(read.waitForExistence(timeout: 10),
                      "the swipe left the reader for 作品詳情\n\(app.debugDescription)")
    }

    @MainActor
    private func waitUntilGone(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == NO"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: 20) == .completed
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
