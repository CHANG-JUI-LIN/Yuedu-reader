import XCTest

/// 書架分組：左右滑在「全部」和各分組之間翻頁，分組列跟著選中；點分組翻到那一頁；一個字的
/// 分組名也不會讓膠囊窄過 44pt。「全部」把每個分組收成一個資料夾，點了推入那個分組的頁面。
///
/// Needs at least one group on the simulator's shelf; it does not create any.
final class BookshelfGroupsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Group bar

    @MainActor
    func testSwipingPagesBetweenGroups() throws {
        for isGrid in [false, true] {
            let app = launchShelf(grid: isGrid)
            let chips = groupChips(in: app)
            let all = chips.element(boundBy: 0)
            let firstGroup = chips.element(boundBy: 1)
            XCTAssertTrue(all.isSelected, "the shelf opens on 全部")

            shelf(in: app, grid: isGrid).swipeLeft()
            XCTAssertTrue(waitUntil(firstGroup, isSelected: true), "a swipe to the left pages to the first group")
            XCTAssertFalse(all.isSelected)
            assertOnePageInView(in: app, grid: isGrid)
            attachScreenshot(of: app, named: "Swiped to the first group, grid \(isGrid)")

            shelf(in: app, grid: isGrid).swipeRight()
            XCTAssertTrue(waitUntil(all, isSelected: true), "a swipe to the right pages back to 全部")
            XCTAssertFalse(firstGroup.isSelected)
            app.terminate()
        }
    }

    /// The last group is pages away from 全部: a tap goes straight there, without stopping
    /// on a page in between.
    @MainActor
    func testTappingAGroupPagesToIt() throws {
        let app = launchShelf(grid: false)
        let chips = groupChips(in: app)
        let lastGroup = chips.element(boundBy: chips.count - 1)
        lastGroup.tap()
        XCTAssertTrue(waitUntil(lastGroup, isSelected: true), "a tapped group is the page in view")
        XCTAssertFalse(chips.element(boundBy: 0).isSelected)
        for index in 1..<(chips.count - 1) {
            XCTAssertFalse(chips.element(boundBy: index).isSelected, "the page stopped on the way at group \(index)")
        }
        assertOnePageInView(in: app, grid: false)
        attachScreenshot(of: app, named: "Tapped the last group")
    }

    @MainActor
    func testGroupChipsKeepTheirMinimumWidth() throws {
        let app = launchShelf(grid: false)
        let chips = groupChips(in: app)
        for index in 0..<chips.count {
            let chip = chips.element(boundBy: index)
            XCTAssertGreaterThanOrEqual(chip.frame.width, 44, "\(chip.label) is narrower than 44pt")
            XCTAssertGreaterThanOrEqual(chip.frame.width, chip.frame.height, "\(chip.label) is narrower than it is tall")
        }
        attachScreenshot(of: app, named: "Group bar")
    }

    // MARK: - Folders

    /// 全部 shows one folder per group — the groups' books are inside them, not beside them.
    @MainActor
    func testAllFoldsEachGroupIntoOneFolder() throws {
        for isGrid in [false, true] {
            let app = launchShelf(grid: isGrid)
            let chips = groupChips(in: app)
            let shelf = shelf(in: app, grid: isGrid)
            let folders = shelf.descendants(matching: .any).matching(identifier: "home_group_folder")
            XCTAssertTrue(folders.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
            for index in 1..<chips.count {
                let group = chips.element(boundBy: index).label
                let folder = folders.matching(NSPredicate(format: "label BEGINSWITH %@", group + "，")).firstMatch
                XCTAssertTrue(folder.exists, "全部 has no folder for \(group): \(app.debugDescription)")
            }
            XCTAssertEqual(folders.count, chips.count - 1, "one folder per group")
            attachScreenshot(of: app, named: "全部 with folders, grid \(isGrid)")
            app.terminate()
        }
    }

    /// A folder opens its group's page: the group's name as the title, its books in the
    /// shelf's layout, and 書架's options; back is 全部 again.
    @MainActor
    func testFolderPushesItsGroupsPage() throws {
        for isGrid in [false, true] {
            let app = launchShelf(grid: isGrid)
            _ = groupChips(in: app)
            let folder = shelf(in: app, grid: isGrid)
                .descendants(matching: .any).matching(identifier: "home_group_folder").firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
            let parts = folder.label.components(separatedBy: "，")
            let group = try XCTUnwrap(parts.first)
            folder.tap()

            let page = app.descendants(matching: .any)[isGrid ? "home_folder_grid" : "home_folder_list"]
            XCTAssertTrue(page.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(app.navigationBars[group].exists, "the page is titled \(group): \(app.debugDescription)")
            XCTAssertTrue(app.buttons["home_options_menu"].exists, "the group's page has 書架's options")
            XCTAssertFalse(app.buttons["home_add_book"].exists, "adding books stays on 書架")
            XCTAssertEqual(
                page.descendants(matching: .any).matching(identifier: "home_group_folder").count, 0,
                "a group's page lists its books, not folders"
            )
            attachScreenshot(of: app, named: "Folder \(group), grid \(isGrid)")

            app.navigationBars[group].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(shelf(in: app, grid: isGrid).waitForExistence(timeout: 10), "back is 全部")
            XCTAssertTrue(groupChips(in: app).element(boundBy: 0).isSelected)
            app.terminate()
        }
    }

    // MARK: - Helpers

    @MainActor
    private func launchShelf(grid: Bool) -> XCUIApplication {
        // A simulator that never answered the notification prompt shows it at launch, and
        // SpringBoard's alert takes every touch meant for the shelf until it is answered.
        addUIInterruptionMonitor(withDescription: "System permission prompt") { alert in
            alert.buttons.element(boundBy: 0).tap()
            return true
        }
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-yd_root_tab_visible_ids", "(bookshelf, settings)",
                               "-bookLayoutIsGrid", grid ? "YES" : "NO",
                               "-bookSortOrder", "manual"]
        app.launch()
        return app
    }

    /// 全部 and then each group, in the bar's order.
    @MainActor
    private func groupChips(in app: XCUIApplication) -> XCUIElementQuery {
        let chips = app.buttons.matching(identifier: "home_group_chip")
        XCTAssertTrue(chips.firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertGreaterThanOrEqual(chips.count, 2, "the shelf needs at least one group")
        return chips
    }

    @MainActor
    private func shelf(in app: XCUIApplication, grid: Bool) -> XCUIElement {
        let shelf = app.descendants(matching: .any)[grid ? "home_book_grid" : "home_book_list"]
        XCTAssertTrue(shelf.waitForExistence(timeout: 10), app.debugDescription)
        return shelf
    }

    /// VoiceOver reads one page: the others are hidden from it.
    @MainActor
    private func assertOnePageInView(in app: XCUIApplication, grid: Bool) {
        let pages = app.descendants(matching: .any).matching(identifier: grid ? "home_book_grid" : "home_book_list")
        XCTAssertEqual(pages.count, 1, app.debugDescription)
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
