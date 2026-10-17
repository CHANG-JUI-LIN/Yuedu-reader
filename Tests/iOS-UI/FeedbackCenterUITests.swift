import XCTest

/// 設定 → 回饋中心: each page it opens renders, and 我的回饋's status groups are a tab bar of
/// its own. Screenshots of every page land in the result bundle.
///
/// Works without the feedback rules deployed: 我的回饋 then shows its error state, and the
/// assertions here hold for both states.
final class FeedbackCenterUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["設定"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), app.debugDescription)
        tab.tap()
        return app
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    @MainActor
    func testFeedbackCenterPages() {
        let app = launch()

        let entry = app.buttons["settings_feedback_center"].firstMatch
        for _ in 0..<8 where !entry.exists {
            app.swipeUp()
        }
        XCTAssertTrue(entry.waitForExistence(timeout: 5), app.debugDescription)
        entry.tap()

        let compose = app.buttons["feedback_center_compose"].firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.navigationBars["回饋中心"].exists)
        XCTAssertTrue(app.switches.containing(
            NSPredicate(format: "label CONTAINS %@", "截圖後顯示意見回饋入口")
        ).firstMatch.exists, "the screenshot-prompt toggle should be on the hub")
        attach(app, "feedback-center")

        // 我的回饋: the status groups are the page's own tab bar.
        app.buttons["feedback_center_list"].firstMatch.tap()
        let groupTabs = ["處理中", "排隊中", "待補充", "已完成"].map { app.tabBars.buttons[$0].firstMatch }
        XCTAssertTrue(groupTabs[0].waitForExistence(timeout: 10), app.debugDescription)
        for tab in groupTabs {
            XCTAssertTrue(tab.isHittable, "\(tab.label) should be a reachable tab")
        }
        // The app's tab bar steps aside for the page's own (maintainer, 2026-10-17).
        let shelfTab = app.tabBars.buttons["書架"].firstMatch
        let rootTabBarGone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !(shelfTab.exists && shelfTab.isHittable)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rootTabBarGone], timeout: 5), .completed, app.debugDescription)
        groupTabs[2].tap()
        XCTAssertTrue(groupTabs[2].isSelected, "待補充 should become the selected group")
        // Loaded (empty group or rows) or the error state, whichever the backend gives.
        let settled = NSPredicate { _, _ in
            app.staticTexts["此分組暫無意見回報"].exists
                || app.descendants(matching: .any)["feedback_list"].exists
                || app.staticTexts["無法載入回饋"].exists
        }
        let wait = XCTNSPredicateExpectation(predicate: settled, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [wait], timeout: 20), .completed, app.debugDescription)
        XCTAssertFalse(app.staticTexts["Missing or insufficient permissions."].exists,
                       "Firebase's own English error text must not reach the screen")
        attach(app, "feedback-list")

        // The sort tab opens the sort choices and leaves the selected group alone.
        let sortTab = app.tabBars.buttons["排序"].firstMatch
        XCTAssertTrue(sortTab.exists, app.debugDescription)
        sortTab.tap()
        let oldestFirst = app.buttons["最早的在前"].firstMatch
        XCTAssertTrue(oldestFirst.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "feedback-list-sort")
        oldestFirst.tap()
        XCTAssertTrue(groupTabs[2].isSelected, "choosing a sort order should keep 待補充 selected")
        back(app)

        // 回饋與改進
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        compose.tap()
        let text = app.descendants(matching: .any)["feedback_compose_text"].firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.navigationBars["回饋與改進"].exists)
        XCTAssertTrue(app.staticTexts["反饋數據已準備就緒"].waitForExistence(timeout: 20),
                      "the log should finish preparing")
        attach(app, "feedback-compose")
        for _ in 0..<4 where !app.buttons["feedback_compose_submit"].exists {
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["feedback_compose_submit"].exists, app.debugDescription)
        attach(app, "feedback-compose-bottom")
    }
}
