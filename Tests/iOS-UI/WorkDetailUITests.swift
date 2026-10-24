import XCTest

/// Unified library 5f: 作品詳情 opens the reader and takes it back, from the bookshelf's ••• and
/// the reader's own 選單; 探索's 繼續閱讀 card opens the reader itself. On iOS 17 a reader opened
/// through the shelf's card coordinator left the page's navigation bar off screen when it closed.
/// A book read before and opened again through 作品詳情 goes to the front of 繼續閱讀: that open
/// once left its date as the first open had stamped it.
///
/// The book is a text file the test writes, imported at launch (`-auto-import-epub` with an
/// absolute path, DEBUG); the test deletes it from the shelf at the end. Its sources are an empty
/// `-book-source-store-dir`: the page searches the enabled ones on opening, and another suite's
/// fixture sources left on the simulator, their server stopped, had its 來源 read 「書架，搜尋失敗」.
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
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-reset-explore-home",
                               "-auto-import-epub", folder.appendingPathComponent("\(title).txt").path,
                               "-auto-import-title", title, "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO",
                               "-yd_appearance_reader_interface", "classic",
                               "-book-source-store-dir", folder.appendingPathComponent("sources").path]
        app.launch()
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        XCTAssertTrue(shelfTab.waitForExistence(timeout: 30))
        shelfTab.tap()

        // The bookshelf: ••• → 作品詳情 → the reader → back to 作品詳情 → back to the shelf.
        openMenu(app)
        let menuItem = app.buttons["作品詳情"].firstMatch
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), app.debugDescription)
        menuItem.tap()
        let versions = app.descendants(matching: .any)["detail.info.source"].firstMatch
        XCTAssertTrue(versions.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(versions.value as? String, "書架", "The copy on the shelf is the version shown")
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

        // 探索: the book is in 繼續閱讀 now. A shelf copy's card goes straight back into its reader,
        // as the shelf's own cards do (maintainer, 2026-10-20), not through 作品詳情.
        app.tabBars.buttons["探索"].firstMatch.tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.card.library.' AND label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15), app.debugDescription)
        card.tap()
        let resumed = waitForReader(app)
        screenshot(app, "work-detail-explore-reader")
        leaveReader(app)
        XCTAssertTrue(resumed.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(card.waitForExistence(timeout: 10), "The reader closes onto the home.\n\(app.debugDescription)")

        // A book read before, opened again through 作品詳情, is the newest in 繼續閱讀. Taken out
        // of the row first, it comes back only if that open moved its date past the removal.
        let more = app.buttons[card.identifier.replacingOccurrences(of: "home.card.", with: "home.card.more.")].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), app.debugDescription)
        more.tap()
        let remove = app.buttons["從繼續閱讀移除"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), app.debugDescription)
        remove.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 10), app.debugDescription)
        shelfTab.tap()
        openMenu(app)
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), app.debugDescription)
        menuItem.tap()
        XCTAssertTrue(versions.waitForExistence(timeout: 10), app.debugDescription)
        let reread = app.buttons["繼續閱讀"].firstMatch
        XCTAssertTrue(reread.exists, "A book read before is continued.\n\(app.debugDescription)")
        reread.tap()
        let reopened = waitForReader(app)
        leaveReader(app)
        XCTAssertTrue(reopened.waitForNonExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(versions.waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(shelfBook(app).waitForExistence(timeout: 10))
        app.tabBars.buttons["探索"].firstMatch.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Reading it again puts it back in 繼續閱讀.\n\(app.debugDescription)")
        let newest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.card.library.'")).firstMatch
        XCTAssertEqual(newest.identifier, card.identifier, "It is the first card.\n\(app.debugDescription)")
        screenshot(app, "work-detail-reread-continue")

        // The reader's own 選單 → 作品詳情 (5f-4b): a local book has it too, and 繼續閱讀 there
        // returns to the reader it came from rather than opening a second one.
        shelfTab.tap()
        shelfBook(app).tap()
        let reader = waitForReader(app)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let menu = app.buttons["選單"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.tap()
        let fromReader = app.buttons["作品詳情"].firstMatch
        XCTAssertTrue(fromReader.waitForExistence(timeout: 5), app.debugDescription)
        fromReader.tap()
        XCTAssertTrue(versions.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(versions.value as? String, "書架", "The book being read is the version shown")
        screenshot(app, "work-detail-from-reader")
        let back = app.buttons["繼續閱讀"].firstMatch
        XCTAssertTrue(back.exists, app.debugDescription)
        back.tap()
        XCTAssertTrue(reader.waitForExistence(timeout: 10), "繼續閱讀 returns to the reader.\n\(app.debugDescription)")
        // The reader comes back with its controls as they were left: up.
        let close = app.buttons["reader_back_button"].firstMatch
        if !close.waitForExistence(timeout: 2) { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription)
        close.tap()
        XCTAssertTrue(shelfBook(app).waitForExistence(timeout: 10), "Back from the reader is the shelf.\n\(app.debugDescription)")
        XCTAssertTrue(shelfTab.isHittable, app.debugDescription)

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
