import XCTest

/// 書架「選取」：格狀模式點書是選書、不是開書；底部「加入分組」在每種語言都是同一個寬度。
///
/// Needs at least two books on the simulator's shelf; it does not import any.
final class BookshelfGridSelectionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testGridSelectionTogglesBooksInsteadOfOpeningThem() throws {
        let app = launchShelf(language: "en")
        let grid = app.scrollViews["home_book_grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 20), app.debugDescription)
        // Books, not the folders 全部 folds each group into: 選取 takes books only.
        let books = grid.buttons.matching(NSPredicate(format: "identifier != %@", "home_group_folder"))
        let first = books.element(boundBy: 0)
        let second = books.element(boundBy: 1)
        XCTAssertTrue(second.waitForExistence(timeout: 10), "the shelf needs at least two books outside a group")

        let addToGroup = enterSelection(in: app, selectTitle: "Select")
        XCTAssertFalse(addToGroup.isEnabled)
        XCTAssertFalse(first.isSelected)
        attachScreenshot(of: app, named: "Grid selecting, none selected")

        first.tap()
        XCTAssertTrue(first.isSelected, "a tap while selecting must select the book")
        XCTAssertTrue(grid.exists, "a tap while selecting must not open the book")
        XCTAssertTrue(addToGroup.isEnabled)
        attachScreenshot(of: app, named: "Grid selecting, one selected")

        second.tap()
        XCTAssertTrue(second.isSelected)
        XCTAssertTrue(first.isSelected)
        attachScreenshot(of: app, named: "Grid selecting, two neighbours selected")

        first.tap()
        second.tap()
        XCTAssertFalse(first.isSelected, "a second tap must take the book out of the selection")
        XCTAssertFalse(second.isSelected)
        XCTAssertFalse(addToGroup.isEnabled)
    }

    /// 加入分組 keeps one width whatever its title's length; a long title is cut short.
    @MainActor
    func testAddToGroupKeepsOneWidthInEveryLanguage() throws {
        // (language, the shelf menu's 選取 in it)
        let languages = [("zh-Hant", "選取"), ("ja", "選択"), ("en", "Select")]
        var widths: [String: CGFloat] = [:]
        for (language, selectTitle) in languages {
            let app = launchShelf(language: language)
            let addToGroup = enterSelection(in: app, selectTitle: selectTitle)
            widths[language] = addToGroup.frame.width
            attachScreenshot(of: app, named: "Bottom bar, \(language)")
            app.terminate()
        }
        let distinct = Set(widths.values.map { ($0 * 2).rounded() })
        XCTAssertEqual(distinct.count, 1, "加入分組 changed width with the language: \(widths)")
    }

    // MARK: - Helpers

    @MainActor
    private func launchShelf(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(\(language))",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings)",
                               "-bookLayoutIsGrid", "YES"]
        app.launch()
        return app
    }

    /// Turns on 選取 from the shelf's options menu; returns the bottom bar's 加入分組.
    @MainActor
    private func enterSelection(in app: XCUIApplication, selectTitle: String) -> XCUIElement {
        let options = app.buttons["home_options_menu"]
        XCTAssertTrue(options.waitForExistence(timeout: 20), app.debugDescription)
        options.tap()
        let select = app.buttons[selectTitle]
        XCTAssertTrue(select.waitForExistence(timeout: 5), app.debugDescription)
        select.tap()
        let addToGroup = app.buttons["home_add_to_group"]
        XCTAssertTrue(addToGroup.waitForExistence(timeout: 5), app.debugDescription)
        return addToGroup
    }

    @MainActor
    private func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
