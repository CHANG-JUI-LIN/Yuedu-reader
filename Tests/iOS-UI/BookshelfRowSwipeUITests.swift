import StoreKitTest
import XCTest

/// 書架列表左滑出「置頂」「刪除」（feedback #17），從書名中間開始滑也要出來（FB-184）：
/// 有分組時每一頁都在橫向翻頁的捲動視圖裡，往左拖曾整個被翻頁拿走——只有從 ••• 上開始的
/// 滑動才會開出動作。所以這裡從書名中間往左滑，動作要出來、分組膠囊不能換。
/// 沒有分組的書架只有一頁、不翻頁，當對照組。
///
/// `-seed-shelf` writes the test's own shelf (`BookStoreTestSeed`) before the store reads it.
final class BookshelfRowSwipeUITests: XCTestCase {
    /// An erased simulator has no Apple ID, and the app's StoreKit check at launch asks for
    /// one again and again over the shelf; the local session answers it instead.
    private var storeKitSession: SKTestSession?

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// 全部 with two groups: two folders, then book rows, on the first of three pages.
    @MainActor
    func testRowSwipeOpensActionsOnAllWithGroups() throws {
        let app = try launchShelf(seed: "grouped")
        let chips = app.buttons.matching(identifier: "home_group_chip")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertEqual(chips.count, 3, "全部 and two groups")
        XCTAssertTrue(chips.element(boundBy: 0).isSelected, "the shelf opens on 全部")

        assertSwipeOpensActions(on: "測試書1", in: app)
        XCTAssertTrue(chips.element(boundBy: 0).isSelected, "the swipe paged away from 全部")
    }

    /// The last group's page, as in the report's video: there the pager has no page further
    /// on, and the drag only bounced it.
    @MainActor
    func testRowSwipeOpensActionsOnAGroupsPage() throws {
        let app = try launchShelf(seed: "grouped")
        let chips = app.buttons.matching(identifier: "home_group_chip")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let last = chips.element(boundBy: chips.count - 1)
        last.tap()
        XCTAssertTrue(waitUntil(last, isSelected: true), app.debugDescription)

        assertSwipeOpensActions(on: "\(last.label)書1", in: app)
        XCTAssertTrue(last.isSelected, "the swipe paged away from the group")
    }

    /// Paging by a swipe still works where no row's actions want the drag: below a group's
    /// two rows, back to 全部.
    @MainActor
    func testSwipeBelowTheRowsStillPages() throws {
        let app = try launchShelf(seed: "grouped")
        let chips = app.buttons.matching(identifier: "home_group_chip")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let first = chips.element(boundBy: 1)
        first.tap()
        XCTAssertTrue(waitUntil(first, isSelected: true), app.debugDescription)
        let list = app.descendants(matching: .any)["home_book_list"]
        XCTAssertTrue(list.waitForExistence(timeout: 10), app.debugDescription)
        flick(list.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.85)),
              to: list.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)))
        XCTAssertTrue(waitUntil(chips.element(boundBy: 0), isSelected: true), "a swipe under the rows pages back to 全部")
    }

    /// A book row has no leading actions, so a swipe to the right on it still pages back.
    @MainActor
    func testRightSwipeOnABookRowStillPagesBack() throws {
        let app = try launchShelf(seed: "grouped")
        let chips = app.buttons.matching(identifier: "home_group_chip")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let first = chips.element(boundBy: 1)
        first.tap()
        XCTAssertTrue(waitUntil(first, isSelected: true), app.debugDescription)
        let row = bookRow("\(first.label)書1", in: app)
        let frame = row.frame
        let start = row.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width * 0.3, dy: frame.height * 0.3))
        flick(start, to: start.withOffset(CGVector(dx: frame.width * 0.6, dy: 0)))
        XCTAssertTrue(waitUntil(chips.element(boundBy: 0), isSelected: true), "a swipe right on a book row pages back to 全部")
    }

    /// A folder row has no swipe actions: a swipe to the left on it pages.
    @MainActor
    func testLeftSwipeOnAFolderRowPages() throws {
        let app = try launchShelf(seed: "grouped")
        let chips = app.buttons.matching(identifier: "home_group_chip")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let folder = app.descendants(matching: .any).matching(identifier: "home_group_folder").firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
        let frame = folder.frame
        let start = folder.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width * 0.6, dy: frame.height * 0.3))
        flick(start, to: start.withOffset(CGVector(dx: -frame.width * 0.5, dy: 0)))
        XCTAssertTrue(waitUntil(chips.element(boundBy: 1), isSelected: true), "a swipe left on a folder pages to the first group")
    }

    /// With a row's actions open, a swipe to the right closes them and stays on the page.
    @MainActor
    func testRightSwipeClosesOpenActionsWithoutPaging() throws {
        let app = try launchShelf(seed: "grouped")
        let chips = app.buttons.matching(identifier: "home_group_chip")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let last = chips.element(boundBy: chips.count - 1)
        last.tap()
        XCTAssertTrue(waitUntil(last, isSelected: true), app.debugDescription)
        assertSwipeOpensActions(on: "\(last.label)書1", in: app)

        let row = bookRow("\(last.label)書1", in: app)
        let frame = row.frame
        let start = row.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width * 0.2, dy: frame.height * 0.3))
        flick(start, to: start.withOffset(CGVector(dx: frame.width * 0.4, dy: 0)))
        XCTAssertTrue(app.buttons["刪除"].waitForNonExistence(timeout: 5), "the actions stay open: \(app.debugDescription)")
        XCTAssertTrue(last.isSelected, "closing the actions paged away from the group")
    }

    /// In 選取 the list adds its multi-select pan, which the pager also waits on: a swipe on a
    /// folder row and one on a book row still page.
    @MainActor
    func testSwipesStillPageWhileSelecting() throws {
        let app = try launchShelf(seed: "grouped")
        let chips = app.buttons.matching(identifier: "home_group_chip")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        app.buttons["home_options_menu"].tap()
        let select = app.buttons["選取"]
        XCTAssertTrue(select.waitForExistence(timeout: 5), app.debugDescription)
        select.tap()

        let folder = app.descendants(matching: .any).matching(identifier: "home_group_folder").firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
        var frame = folder.frame
        var start = folder.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width * 0.6, dy: frame.height * 0.3))
        flick(start, to: start.withOffset(CGVector(dx: -frame.width * 0.5, dy: 0)))
        let first = chips.element(boundBy: 1)
        XCTAssertTrue(waitUntil(first, isSelected: true), "in 選取 a swipe left on a folder pages: \(app.debugDescription)")

        let row = bookRow("\(first.label)書1", in: app)
        frame = row.frame
        start = row.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width * 0.3, dy: frame.height * 0.3))
        flick(start, to: start.withOffset(CGVector(dx: frame.width * 0.6, dy: 0)))
        XCTAssertTrue(waitUntil(chips.element(boundBy: 0), isSelected: true), "in 選取 a swipe right on a book row pages back")
    }

    /// The control: no groups, one page, nothing to page.
    @MainActor
    func testRowSwipeOpensActionsWithoutGroups() throws {
        let app = try launchShelf(seed: "ungrouped")
        assertSwipeOpensActions(on: "測試書1", in: app)
    }

    // MARK: - Helpers

    /// A finger's quick horizontal flick, not XCUITest's slow default drag.
    @MainActor
    private func flick(_ start: XCUICoordinate, to end: XCUICoordinate) {
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 1200, thenHoldForDuration: 0)
    }

    /// A book row on the page in view (the others are hidden from accessibility).
    @MainActor
    private func bookRow(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let list = app.descendants(matching: .any)["home_book_list"]
        XCTAssertTrue(list.waitForExistence(timeout: 20), app.debugDescription)
        let row = list.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), app.debugDescription)
        return row
    }

    @MainActor
    private func assertSwipeOpensActions(on title: String, in app: XCUIApplication) {
        let row = bookRow(title, in: app)
        // From the middle of the title, the way a finger starts it — not from the •••.
        let frame = row.frame
        let start = row.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.width * 0.5, dy: frame.height * 0.3))
        flick(start, to: start.withOffset(CGVector(dx: -frame.width * 0.45, dy: 0)))
        let delete = app.buttons["刪除"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "左滑沒有開出刪除：\(app.debugDescription)")
        XCTAssertTrue(app.buttons["置頂"].exists, app.debugDescription)
        attachScreenshot(of: app, named: "Swiped \(title)")
    }

    @MainActor
    private func launchShelf(seed: String) throws -> XCUIApplication {
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
                               "-seed-shelf", seed]
        app.launch()
        return app
    }

    @MainActor
    private func waitUntil(_ element: XCUIElement, isSelected: Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isSelected == %@", NSNumber(value: isSelected)),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
