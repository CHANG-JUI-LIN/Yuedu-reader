import XCTest

/// Unified library 5f: 作品詳情 opens the reader and takes it back, from both stacks that push
/// it — the bookshelf's ••• and 探索's 繼續閱讀 card. On iOS 17 a reader opened through the
/// shelf's card coordinator left the page's navigation bar off screen when it closed.
///
/// The book is a text file the test writes, imported at launch (`-auto-import-epub` with an
/// absolute path, DEBUG); the test deletes it from the shelf at the end.
final class WorkDetailUITests: XCTestCase {
    private let title = "作品詳情測試"
    private let body = "作品詳情測試正文，用來確認閱讀器打開了這本書。"
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("WorkDetail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "第一章 開始\n\n\(body)\n\n" + String(repeating: "\(body)\n", count: 20)
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(title).txt"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    @MainActor
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The book's shelf cell: grid and list both make it one element labelled with the title first.
    @MainActor
    private func shelfBook(_ app: XCUIApplication) -> XCUIElement {
        let cell = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30), app.debugDescription)
        return cell
    }

    /// The cell's •••: the list row's own 更多 button. A grid cell hides it from accessibility
    /// (its items are the cell's rotor actions, which XCUITest cannot perform), so there it is
    /// tapped where it is drawn, at the trailing end of the author line under the cover.
    @MainActor
    private func openMenu(_ app: XCUIApplication) {
        let cell = shelfBook(app)
        let more = cell.buttons["更多"].firstMatch
        if more.exists {
            more.tap()
        } else {
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.96)).tap()
        }
    }

    @MainActor
    private func waitForReader(_ app: XCUIApplication) -> XCUIElement {
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", body)).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), "The reader opens the book.\n\(app.debugDescription)")
        return content
    }

    /// Back out of the reader with the edge swipe every reader keeps.
    @MainActor
    private func leaveReader(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
    }

    @MainActor
    func testShelfAndExploreReadThroughWorkDetail() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-reset-explore-home",
                               "-auto-import-epub", folder.appendingPathComponent("\(title).txt").path,
                               "-auto-import-title", title, "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()

        // The bookshelf: ••• → 作品詳情 → the reader → back to 作品詳情 → back to the shelf.
        openMenu(app)
        let menuItem = app.buttons["作品詳情"].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), app.debugDescription)
        menuItem.tap()
        let versions = app.descendants(matching: .any)["work.versions"].firstMatch
        XCTAssertTrue(versions.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["work.version.shelf"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        screenshot(app, "work-detail-shelf")
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["開始閱讀", "繼續閱讀"])).firstMatch
        XCTAssertTrue(read.exists, app.debugDescription)
        read.tap()
        let content = waitForReader(app)
        screenshot(app, "work-detail-shelf-reader")
        leaveReader(app)
        XCTAssertTrue(content.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(versions.waitForExistence(timeout: 10), "The reader closes onto 作品詳情.\n\(app.debugDescription)")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(shelfBook(app).waitForExistence(timeout: 10))
        XCTAssertTrue(shelfTab.isHittable, "Back from 作品詳情 returns to the shelf")

        // 探索: the book is in 繼續閱讀 now; its card opens 作品詳情 too.
        app.tabBars.buttons["探索"].firstMatch.tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.card.library.' AND label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription)
        card.tap()
        XCTAssertTrue(versions.waitForExistence(timeout: 10), app.debugDescription)
        let resume = app.buttons["繼續閱讀"].firstMatch
        XCTAssertTrue(resume.exists, "The book was opened: 作品詳情 resumes it.\n\(app.debugDescription)")
        resume.tap()
        _ = waitForReader(app)
        screenshot(app, "work-detail-explore-reader")
        leaveReader(app)
        XCTAssertTrue(versions.waitForExistence(timeout: 10), "The reader closes onto 作品詳情.\n\(app.debugDescription)")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Back from 作品詳情 returns to the home")

        // The book leaves the shelf, so the next run starts from the same place.
        shelfTab.tap()
        let cell = shelfBook(app)
        openMenu(app)
        let delete = app.buttons["刪除書籍"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        delete.tap()
        let confirm = app.alerts.buttons["刪除"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), app.debugDescription)
        confirm.tap()
        XCTAssertTrue(cell.waitForNonExistence(timeout: 10))
    }
}
