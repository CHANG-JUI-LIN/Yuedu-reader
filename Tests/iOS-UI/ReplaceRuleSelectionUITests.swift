import XCTest

/// 設定 → 替換規則: 編輯 enters the bookshelf's selection layout — 全選／全不選 and done at
/// the top, delete at the bottom — and a tap on a row while selecting selects it instead of
/// opening the rule's editor. Nothing is deleted: the presets stay as they are.
final class ReplaceRuleSelectionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    private func openReplaceRules(_ app: XCUIApplication) {
        let settingsTab = app.tabBars.buttons["設定"].firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 30))
        settingsTab.tap()
        let row = app.buttons["替換規則"].firstMatch
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        XCTAssertTrue(app.navigationBars["替換規則"].waitForExistence(timeout: 8), app.debugDescription)
    }

    /// The sheet's rule rows — each has its 啟用 switch. `app.cells` alone also finds 設定's rows
    /// under the sheet.
    @MainActor
    private func ruleRows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.cells.containing(.switch, identifier: nil)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testEditSelectsAllAndRowTapSelects() {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-no-official-modules", "-onboarding.completed", "YES",
                               "-yd_source_disclaimer_accepted", "YES"]
        app.launch()
        openReplaceRules(app)

        let firstRow = ruleRows(app).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 5), "the presets are installed on first launch")
        attach(app, "replace-rules")

        let edit = app.navigationBars["替換規則"].buttons["編輯"]
        XCTAssertTrue(edit.exists, app.debugDescription)
        edit.tap()

        let selectAll = app.buttons["全選"].firstMatch
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5), app.debugDescription)
        let delete = app.toolbars.buttons["刪除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(delete.isEnabled, "nothing selected yet")
        XCTAssertFalse(app.navigationBars["替換規則"].buttons["編輯"].exists)

        // A tap on a row selects it; the editor stays closed.
        firstRow.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: firstRow)],
             timeout: 5)
        XCTAssertTrue(delete.isEnabled)
        XCTAssertFalse(app.textFields["規則名稱"].exists, "selecting must not open the editor")

        selectAll.tap()
        let deselectAll = app.buttons["全不選"].firstMatch
        XCTAssertTrue(deselectAll.waitForExistence(timeout: 5), app.debugDescription)
        // The rows take the selection a beat after the button's label changes.
        let selected = ruleRows(app).allElementsBoundByIndex.map {
            XCTNSPredicateExpectation(predicate: NSPredicate(format: "isSelected == true"), object: $0)
        }
        wait(for: selected, timeout: 5)
        attach(app, "replace-rules-all-selected")

        deselectAll.tap()
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled)

        app.navigationBars["替換規則"].buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["替換規則"].buttons["編輯"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["全選"].exists)

        // Outside selection a tap on a row still opens its editor.
        ruleRows(app).firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        XCTAssertTrue(app.textFields["規則名稱"].waitForExistence(timeout: 5), app.debugDescription)
    }
}
