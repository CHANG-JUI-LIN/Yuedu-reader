import XCTest

/// 分類卡片 of a 來源配置's section (maintainer, 2026-10-26): a card per category the section keeps,
/// each read by VoiceOver as its category's name, opening that category's whole list; the section
/// is switched to it from its long press, and its form's 加入清單 adds more (2026-10-27).
///
/// Needs `python3 -I scripts/source_category_cards_fixture.py` (port 18773).
final class SourceCategoryCardsUITests: XCTestCase {
    // `localhost`, not 127.0.0.1: a request to a reserved address is refused (`safeURL`).
    private static let fixture = "http://localhost:18773"
    private static let sourceName = "分類卡片測試來源"
    private var directory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SourceCategoryCards-\(UUID().uuidString)")
        let sources = directory.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let categories = [("玄幻", 1), ("都市", 2), ("仙俠", 3), ("歷史", 4)]
            .map { "\($0.0)::\(Self.fixture)/cat/\($0.1)" }.joined(separator: "\n")
        let source: [String: Any] = [
            "bookSourceName": Self.sourceName,
            "bookSourceUrl": Self.fixture,
            "exploreUrl": categories,
            "ruleExplore": ["bookList": "class.book", "name": "class.name@text", "author": "class.author@text",
                            "coverUrl": "tag.img@src", "bookUrl": "tag.a@href"],
            "enabled": true,
            "enabledExplore": true,
        ]
        try JSONSerialization.data(withJSONObject: [source]).write(to: sources.appendingPathComponent("book_sources.json"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func category(_ title: String, _ number: Int) -> [String: Any] {
        ["sourceURL": Self.fixture, "title": title, "url": "\(Self.fixture)/cat/\(number)"]
    }

    /// A home of one section, the source's `categories` in `layout`.
    private func home(_ categories: [[String: Any]], layout: String) throws -> URL {
        let section: [String: Any] = ["binding": ["type": "sourceCategories", "categories": categories],
                                      "id": UUID().uuidString, "isEnabled": true, "layout": layout,
                                      "parameters": [String: Any](), "title": ""]
        let url = directory.appendingPathComponent("explore_home.json")
        try JSONSerialization.data(withJSONObject: ["configurations": [Any](), "schemaVersion": 3, "sections": [section]])
            .write(to: url)
        return url
    }

    @MainActor
    private func launchExplore(home: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES",
                               "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.appendingPathComponent("sources").path,
                               "-reset-public-library-explore", "-reset-explore-home", "-explore-home-file", home.path]
        app.launch()
        let tab = app.tabBars.buttons["探索"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30))
        tab.tap()
        return app
    }

    @MainActor
    private func card(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons["home.collection.sourceCategory.\(title)"].firstMatch
    }

    @MainActor
    private func header(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.row.header.' AND label CONTAINS %@",
                                         Self.sourceName)).firstMatch
    }

    /// The paths asked of the fixture since it started.
    private func fixtureLog() throws -> [String] {
        try String(contentsOf: URL(string: "\(Self.fixture)/log")!, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @MainActor
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The section's long press offers 設定 in a menu; not the 設定 tab, which iOS 17 lists first.
    @MainActor
    private func openSettings(_ app: XCUIApplication) throws {
        header(app).press(forDuration: 1.0)
        let tabBar = app.tabBars.firstMatch
        func menuSettings() -> XCUIElement? {
            app.buttons.matching(NSPredicate(format: "label == %@", "設定")).allElementsBoundByIndex
                .first { !tabBar.exists || !tabBar.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        }
        let shown = expectation(for: NSPredicate { _, _ in menuSettings() != nil }, evaluatedWith: nil)
        wait(for: [shown], timeout: 5)
        try XCTUnwrap(menuSettings(), app.debugDescription).tap()
    }

    /// Each category is a card read as its name, titled by the source, one request each; a card
    /// opens its category's whole list.
    @MainActor
    func testCardsReadTheirCategoriesAndOpenThem() throws {
        let before = try fixtureLog().count
        let app = launchExplore(home: try home([category("玄幻", 1), category("都市", 2), category("仙俠", 3)],
                                               layout: "categoryCards"))
        let first = card(app, "玄幻")
        XCTAssertTrue(first.waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(header(app).exists, "the section is titled by its source: \(app.debugDescription)")
        for title in ["玄幻", "都市", "仙俠"] {
            let element = card(app, title)
            XCTAssertTrue(element.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertEqual(element.label, title, "VoiceOver reads the category's name alone")
        }
        XCTAssertLessThan(first.frame.maxY, card(app, "都市").frame.minY, "the cards go down the page")
        attach(app, "source-category-cards")

        let pages = try fixtureLog().dropFirst(before).filter { $0.hasPrefix("/cat/") }
        XCTAssertEqual(pages.sorted(), ["/cat/1", "/cat/2", "/cat/3"], "one first page per category")

        first.tap()
        func book(_ title: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
        }
        XCTAssertTrue(book("玄幻之書1").waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(book("都市之書1").exists, "the card opens its own category")
        attach(app, "source-category-opened")
    }

    /// A category row switched to 分類卡片 from its long press is one card; its form's 加入清單 opens
    /// 選擇內容來源, where the source's 全部清單 adds every category it lists, a card each.
    @MainActor
    func testLongPressChoosesCardsAndTheFormAddsAllCategories() throws {
        let app = launchExplore(home: try home([category("玄幻", 1)], layout: "row"))
        let sectionHeader = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'home.row.header.' AND label CONTAINS %@",
                                                             "玄幻")).firstMatch
        XCTAssertTrue(sectionHeader.waitForExistence(timeout: 20), app.debugDescription)
        sectionHeader.press(forDuration: 1.0)
        let layouts = app.buttons["呈現方式"].firstMatch
        XCTAssertTrue(layouts.waitForExistence(timeout: 5), app.debugDescription)
        layouts.tap()
        let cards = app.buttons["分類卡片"].firstMatch
        XCTAssertTrue(cards.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["拼貼卡片"].exists, "every layout of lists: \(app.debugDescription)")
        cards.tap()
        XCTAssertTrue(card(app, "玄幻").waitForExistence(timeout: 20), app.debugDescription)

        try openSettings(app)
        let add = app.buttons["homeSection.lists.add"].firstMatch
        for _ in 0..<4 where !(add.exists && add.isHittable) { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        let first = app.buttons["homeSection.listCard.0"].firstMatch
        XCTAssertTrue(first.exists, app.debugDescription)
        XCTAssertTrue(first.label.contains("玄幻") && first.label.contains(Self.sourceName),
                      "a card reads its list and where it is from: \(first.label)")
        add.tap()

        let sources = app.buttons["homePicker.bookSources"].firstMatch
        XCTAssertTrue(sources.waitForExistence(timeout: 10), app.debugDescription)
        sources.tap()
        let source = app.buttons["homePicker.source.\(Self.sourceName)"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        source.tap()
        let all = app.buttons["homePicker.allLists"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(all.label, "全部清單")
        attach(app, "source-category-all-lists")
        all.tap()

        // The cards side by side, then 加入清單 (2026-10-27): every card is there with the first.
        XCTAssertTrue(first.waitForExistence(timeout: 5), app.debugDescription)
        let last = app.buttons["homeSection.listCard.3"].firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 5), "全部清單 adds the other three categories once: \(app.debugDescription)")
        XCTAssertTrue(last.label.contains("歷史"), last.label)
        XCTAssertFalse(app.buttons["homeSection.listCard.4"].exists, "玄幻 is not added twice")
        attach(app, "source-category-form")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for title in ["都市", "仙俠", "歷史"] {
            XCTAssertTrue(card(app, title).waitForExistence(timeout: 20), app.debugDescription)
        }
        XCTAssertTrue(card(app, "玄幻").exists)
        attach(app, "source-category-four-cards")
    }
}
