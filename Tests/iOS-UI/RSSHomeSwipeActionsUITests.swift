import XCTest

/// RSS 訂閱's rows sit in a ScrollView, not a List, and their `swipeActions` never opened
/// there (feedback #77's follow-up): outside a List a row's swipe actions open only in a
/// container marked `swipeActionsContainer()`, which is iOS 27's. This runs each one — a
/// feed's 標記全部已讀, 編輯訂閱 and 刪除, a folder's 重新命名 and 刪除 — from its swipe on
/// iOS 27, and before it from the row's context menu, which carries the same actions. The
/// folder is the test's own, made through 新增資料夾 and deleted by its own action.
/// Each revealed swipe button is found by its exact label: VoiceOver read them twice over
/// (「編輯訂閱、編輯訂閱」) until they named themselves.
///
/// `-seed-rss-articles` stores a feed of two unread articles, 首頁訂閱測試.
final class RSSHomeSwipeActionsUITests: XCTestCase {
    private static let folderName = "SwipeFolder"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRowActionsRun() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES",
                               "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES", "-seed-rss-articles"]
        app.launch()
        openRSSHome(app)

        let feed = feedRow(app)
        XCTAssertTrue(feed.waitForExistence(timeout: 10), app.debugDescription)
        // A tap still opens the feed: the swipe container, iOS 27's, takes the drags, not the
        // taps. Not checked before it: there is no container, and on iOS 17.5 coming back from
        // the feed leaves the app busy for over a minute, main's RSSListView alike (2026-10-26).
        if #available(iOS 27.0, *) {
            feed.tap()
            let article = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "首頁訂閱測試文章一")).firstMatch
            XCTAssertTrue(article.waitForExistence(timeout: 10), app.debugDescription)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["RSS 訂閱"].waitForExistence(timeout: 10), app.debugDescription)
        }

        // Its trailing actions: 編輯訂閱 presents its sheet, 刪除 asks first.
        reveal(feed, .trailing)
        tapAction("編輯訂閱", in: app)
        let editBar = app.navigationBars["編輯訂閱"]
        XCTAssertTrue(editBar.waitForExistence(timeout: 5), app.debugDescription)
        closeSheet(editBar)
        waitForDisappearance(editBar)

        reveal(feed, .trailing)
        tapAction("刪除", in: app)
        let deleteAlert = app.alerts.firstMatch
        XCTAssertTrue(deleteAlert.waitForExistence(timeout: 5), app.debugDescription)
        deleteAlert.buttons["取消"].tap()
        waitForDisappearance(deleteAlert)

        // Its leading action: 標記全部已讀 takes the unread count off the row.
        XCTAssertNotEqual(feed.label, "首頁訂閱測試", "the seeded feed has unread articles")
        reveal(feed, .leading)
        tapAction("標記全部已讀", in: app)
        let read = expectation(for: NSPredicate(format: "label == %@", "首頁訂閱測試"), evaluatedWith: feed)
        wait(for: [read], timeout: 5)

        // A folder's: 重新命名 presents its sheet, 刪除 removes it once confirmed.
        addFolder(app)
        let folder = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", Self.folderName)).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5), app.debugDescription)
        reveal(folder, .trailing)
        tapAction("重新命名", in: app)
        let renameBar = app.navigationBars["重新命名"]
        XCTAssertTrue(renameBar.waitForExistence(timeout: 5), app.debugDescription)
        closeSheet(renameBar)
        waitForDisappearance(renameBar)

        reveal(folder, .trailing)
        tapAction("刪除", in: app)
        let folderAlert = app.alerts.firstMatch
        XCTAssertTrue(folderAlert.waitForExistence(timeout: 5), app.debugDescription)
        folderAlert.buttons["刪除"].tap()
        waitForDisappearance(folder)
    }

    // MARK: - Route

    /// 資源庫 › 訂閱 › RSS 訂閱. The RSS 訂閱 tile reads as a 0×0 element with no identifier
    /// (`SwipeActionAccentContrastUITests`), so it is tapped where it is drawn.
    @MainActor
    private func openRSSHome(_ app: XCUIApplication) {
        let library = app.tabBars.buttons["資源庫"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 30), app.debugDescription)
        library.tap()
        let header = app.staticTexts["訂閱"].firstMatch
        for _ in 0..<6 { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
        header.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1)).withOffset(CGVector(dx: 60, dy: 50)).tap()
        XCTAssertTrue(app.navigationBars["RSS 訂閱"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @MainActor
    private func feedRow(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "首頁訂閱測試")).firstMatch
    }

    /// ＋ › 新增資料夾, named in ASCII: typing CJK through XCUITest submits the field.
    @MainActor
    private func addFolder(_ app: XCUIApplication) {
        app.navigationBars["RSS 訂閱"].buttons["新增或匯入"].tap()
        let item = app.buttons["新增資料夾"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
        item.tap()
        let bar = app.navigationBars["新增資料夾"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10), app.debugDescription)
        let field = app.textFields.firstMatch
        field.tap()
        field.typeText(Self.folderName)
        bar.buttons.allElementsBoundByIndex.max { $0.frame.minX < $1.frame.minX }?.tap()
        waitForDisappearance(bar)
    }

    /// The sheet's leading ✕.
    @MainActor
    private func closeSheet(_ bar: XCUIElement) {
        bar.buttons.allElementsBoundByIndex.min { $0.frame.minX < $1.frame.minX }?.tap()
    }

    // MARK: - Revealing

    private enum Edge { case leading, trailing }

    /// iOS 27: a swipe from `edge`. Before it, the row's context menu.
    @MainActor
    private func reveal(_ row: XCUIElement, _ edge: Edge) {
        if #available(iOS 27.0, *) {
            switch edge {
            case .trailing: drag(row, from: 0.92, to: 0.4)
            // From well inside the row, clear of the screen edge's back gesture.
            case .leading: drag(row, from: 0.2, to: 0.75)
            }
        } else {
            row.press(forDuration: 1.2)
        }
    }

    /// A slow horizontal drag across `row` between two fractions of its width — short of a
    /// full swipe, which these rows do not allow anyway.
    @MainActor
    private func drag(_ row: XCUIElement, from start: CGFloat, to end: CGFloat) {
        row.coordinate(withNormalizedOffset: CGVector(dx: start, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: end, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    /// Taps the revealed action once it has stopped sliding in.
    @MainActor
    private func tapAction(_ name: String, in app: XCUIApplication) {
        let button = app.buttons[name].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(name) was not revealed\n\(app.debugDescription)")
        var last = button.frame
        for _ in 0..<30 {
            Thread.sleep(forTimeInterval: 0.1)
            if button.frame == last, button.isHittable { break }
            last = button.frame
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "revealed \(name)"
        shot.lifetime = .keepAlways
        add(shot)
        button.tap()
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement) {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        wait(for: [gone], timeout: 5)
    }
}
