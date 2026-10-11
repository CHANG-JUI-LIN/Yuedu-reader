import XCTest

/// Unified library 5d-2: 編輯首頁 from the bottom of the home, and a section name's long press.
/// Each launch starts from the defaults (`-reset-explore-home`) and an empty book-source
/// library of its own; Gutenberg's feeds answer from fixtures.
final class HomeEditorUITests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("HomeEditorUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Latest</title></feed>".utf8)
            .write(to: directory.appendingPathComponent("ebooks_search.opds.xml"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// 精選's first list, 中文書籍, and one of its cards.
    private let listTitle = "中文書籍"
    private let card = "home.card.gutenberg.24264"

    @MainActor
    private func launchExplore() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.appendingPathComponent("sources").path,
                               "-reset-public-library-explore", "-reset-explore-home"]
        app.launchEnvironment["YUEDU_PUBLIC_LIBRARY_FIXTURES"] = directory.path
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        XCTAssertTrue(app.buttons[card].firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        return app
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The bottom of the home turns the sections into cards: a card's mark hides it, a tap
    /// opens its page, and 完成 shows the home without it.
    @MainActor
    func testEditHomeInPlace() {
        let app = launchExplore()
        let edit = app.buttons["home.edit"].firstMatch
        for _ in 0..<8 where !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.isHittable, app.debugDescription)
        edit.tap()
        // At the bottom the minimized bar hides its buttons; 完成 is the home's last button.
        XCTAssertTrue(app.buttons["home.editDone"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.switches["瀏覽器"].firstMatch.waitForExistence(timeout: 5), "範圍's card holds the browser's switch")
        for _ in 0..<8 { app.swipeDown() }
        XCTAssertTrue(app.buttons["home.editDoneBar"].waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "home-editing")

        let mark = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                    "homeEditor.toggle.", listTitle)).firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(mark.value as? String, "顯示")
        mark.tap()
        XCTAssertEqual(mark.value as? String, "已隱藏")
        attach(app, "home-editing-hidden")

        // The card opens the section's page.
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                         "homeEditor.section.", listTitle)).firstMatch.tap()
        let shown = app.switches["在首頁顯示"].firstMatch
        XCTAssertTrue(shown.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(shown.value as? String, "0")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["home.editDoneBar"].firstMatch.tap()
        XCTAssertTrue(app.buttons["home.edit"].firstMatch.waitForExistence(timeout: 5) || !app.buttons["home.editDoneBar"].exists)
        XCTAssertFalse(app.buttons[card].firstMatch.waitForExistence(timeout: 3), "a hidden section has no row")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                        "home.row.header.", listTitle)).firstMatch.exists)
    }

    /// 5d-3: 呈現方式, from the same long press, redraws the section: 圖文資訊清單 gives each book
    /// the width of the screen, and 顯示排名 puts its rank first in what VoiceOver reads.
    @MainActor
    func testLongPressChangesTheLayout() {
        let app = launchExplore()
        let header = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "home.row.header.", listTitle)).firstMatch
        let book = app.buttons[card].firstMatch
        XCTAssertLessThan(book.frame.width, app.frame.width / 2, "橫向單排書架 shows several books to a screen")

        header.press(forDuration: 1.0)
        let layouts = app.buttons["呈現方式"].firstMatch
        XCTAssertTrue(layouts.waitForExistence(timeout: 5), app.debugDescription)
        layouts.tap()
        let list = app.buttons["圖文資訊清單"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "home-section-layouts")
        list.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(book.frame.width, app.frame.width * 0.8, app.debugDescription)
        XCTAssertFalse(book.label.first?.isNumber ?? true, "an unranked list reads no rank")
        attach(app, "home-section-list")

        header.press(forDuration: 1.0)
        XCTAssertTrue(layouts.waitForExistence(timeout: 5))
        layouts.tap()
        let ranks = app.switches["顯示排名"].firstMatch.exists ? app.switches["顯示排名"].firstMatch : app.buttons["顯示排名"].firstMatch
        XCTAssertTrue(ranks.waitForExistence(timeout: 5), app.debugDescription)
        ranks.tap()
        let ranked = NSPredicate(format: "label MATCHES %@", "^[0-9]+, .*")
        expectation(for: ranked, evaluatedWith: book)
        waitForExpectations(timeout: 5)
        attach(app, "home-section-ranked-list")
    }

    /// Long-pressing a section's name offers 隱藏, 設定 and 刪除; 刪除 asks first.
    @MainActor
    func testLongPressDeletesASection() {
        let app = launchExplore()
        let header = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "home.row.header.", listTitle)).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 10), app.debugDescription)
        header.press(forDuration: 1.0)
        let delete = app.buttons["刪除"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["隱藏"].exists)
        XCTAssertTrue(app.buttons["設定"].exists)
        attach(app, "home-section-menu")
        delete.tap()

        let confirm = app.buttons.matching(NSPredicate(format: "label == %@", "刪除")).firstMatch
        XCTAssertTrue(app.staticTexts["刪除「\(listTitle)」？"].waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "home-section-delete-confirmation")
        confirm.tap()
        XCTAssertTrue(app.buttons[card].firstMatch.waitForNonExistence(timeout: 10), "a deleted section has no row")
    }
}
