import XCTest

/// Feedback #15 (iOS 27.2): a VoiceOver user opened an online book from 資源庫, tapped 立即閱讀,
/// and could not reach anything on the reader's bottom bar — 目錄, 書籤, 深色, 設置 and the
/// progress slider — while the top bar worked.
///
/// The same book is opened from 資源庫 (pushed onto that tab's stack, reached by its list or its
/// search), from 搜尋 (also a push onto the tab's stack) and from 書架 (the shelf's own reader), and on
/// each the bottom bar's controls must be in the accessibility tree, hittable, and clean in an
/// accessibility audit scoped to the bar.
///
/// 探索 was added from the maintainer's recording (2026-10-20), where VoiceOver's cursor took the
/// whole screen over the bottom bar and read the chapter.
///
/// These passed on every route while the bug was live, and could not have failed: `isHittable`
/// is no occlusion test, and XCUITest's tree has an order of its own, not the order VoiceOver's
/// touch tries elements in. The cause was the back-swipe reservation behind every reader pushed
/// from a detail page, which put the full-screen page ahead of the bottom bar in that order
/// (`reservingNavigationBackSwipe`); `NavigationBackSwipeReservationTests` checks that the way
/// VoiceOver does. What these still check is that each route's bar is in the tree, named, and
/// clean in an audit. The 書架 route leaves each run's book on the simulator's shelf.
///
/// The book is served from outside the simulator, from the repo root:
/// `python3 -I scripts/reader_chrome_fixture.py` (port 18771). Its source lives in a scratch
/// `-book-source-store-dir`, so the simulator's own sources are never touched.
final class ReaderChromeAccessibilityUITests: XCTestCase {
    // `localhost`, not 127.0.0.1: a request to a reserved address is refused (`safeURL`).
    private static let fixture = "http://localhost:18771"
    private static let sourceName = "Chrome Source"
    private static let toolIDs = ["reader_tool_tableOfContents", "reader_tool_bookmarks",
                                  "reader_tool_nightMode", "reader_tool_settings"]
    private var directory: URL!
    /// This run's book: one no earlier run read, so its page offers 立即閱讀, not 繼續閱讀.
    private let token = String(Int.random(in: 1000...9999))
    private var title: String { "Chrome Fixture \(token)" }

    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderChromeAccessibility-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source: [String: Any] = [
            "bookSourceName": Self.sourceName,
            "bookSourceUrl": Self.fixture,
            "bookSourceType": 0,
            "enabled": true,
            "enabledExplore": true,
            "exploreUrl": "熱門::\(Self.fixture)/explore?page={{page}}",
            "searchUrl": "\(Self.fixture)/search?q={{key}}&page={{page}}",
            "ruleExplore": ["bookList": "class.book", "name": "tag.h3@text", "author": "class.author@text",
                            "bookUrl": "tag.a@href"],
            "ruleSearch": ["bookList": "class.book", "name": "tag.h3@text", "author": "class.author@text",
                           "bookUrl": "tag.a@href"],
            "ruleToc": ["chapterList": "class.chapter", "chapterName": "tag.a@text", "chapterUrl": "tag.a@href"],
            "ruleContent": ["content": "id.content@html"],
            // A new search cache key each run (it includes this): no earlier run's results.
            "lastUpdateTime": Int(Date().timeIntervalSince1970 * 1000),
        ]
        try JSONSerialization.data(withJSONObject: [source])
            .write(to: directory.appendingPathComponent("book_sources.json"))
        _ = try Data(contentsOf: URL(string: "\(Self.fixture)/reset?token=\(token)")!)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.path,
                               "-yd_appearance_reader_interface", "classic"] + extra
        app.launch()
        return app
    }

    // MARK: Routes

    /// The reported route: 資源庫 › 所有來源配置 › the source › the book › 立即閱讀.
    @MainActor
    func testLibraryReaderBottomBarReachesVoiceOver() throws {
        let app = launch()
        try openFromLibrary(app)
        let problems = try bottomBarProblems(app, route: "資源庫")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n") + "\n" + app.debugDescription)
    }

    /// 探索 › a section of the home › the book's page › 立即閱讀: the reader pushed onto 探索's stack
    /// (the maintainer's recording, 2026-10-20).
    @MainActor
    func testExploreReaderBottomBarReachesVoiceOver() throws {
        let app = launch(extra: ["-explore.mode", "sources", "-reset-explore-home"])
        openFromExplore(app)
        tapRead(app)
        let problems = try bottomBarProblems(app, route: "探索")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n") + "\n" + app.debugDescription)
    }

    /// The book's page from 搜尋: also a reader pushed onto the tab's own stack.
    @MainActor
    func testSearchReaderBottomBarReachesVoiceOver() throws {
        let app = launch()
        rootTab(app, "搜尋").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        // Latin letters only: typing CJK submits the field (XCUITest).
        field.typeText("Chrome\n")
        let work = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 30), app.debugDescription)
        work.tap()
        tapRead(app)
        let problems = try bottomBarProblems(app, route: "搜尋")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n") + "\n" + app.debugDescription)
    }

    /// The control: the same book, added to 書架 on leaving, opened from the shelf.
    @MainActor
    func testShelfReaderBottomBarReachesVoiceOver() throws {
        let app = launch()
        try openFromLibrary(app)
        try showChrome(app)
        app.buttons["reader_back_button"].tap()
        // A book read from its page is on the shelf already (移除書架); one that is not yet
        // asks on leaving (加入書架).
        let add = app.buttons["加入書架"].firstMatch
        let onShelf = app.buttons["移除書架"].firstMatch
        let left = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in add.exists || onShelf.exists },
                                             object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 15), .completed, app.debugDescription)
        if add.exists { add.tap() }

        // Back to 資源庫's root, where the tab bar is, then 書架.
        let tabButton = app.tabBars.buttons["書架"].firstMatch
        let railButton = app.buttons["書架"].firstMatch
        for _ in 0..<6 where !(tabButton.exists || railButton.exists) {
            // In the navigation bar on an iPhone; in the toolbar's side rail on the Duo.
            let back = app.buttons["BackButton"].firstMatch
            guard back.waitForExistence(timeout: 5) else { break }
            back.tap()
        }
        rootTab(app, "書架").tap()
        let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()
        let problems = try bottomBarProblems(app, route: "書架")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n") + "\n" + app.debugDescription)
    }

    /// 資源庫's own search finds the source by name, as a VoiceOver user is likely to reach it.
    @MainActor
    func testLibrarySearchReaderBottomBarReachesVoiceOver() throws {
        let app = launch()
        rootTab(app, "資源庫").tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        field.typeText("Chrome")
        let source = app.buttons["library.source.\(Self.sourceName)"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        source.tap()
        openBook(app)
        let problems = try bottomBarProblems(app, route: "資源庫搜尋")
        XCTAssertTrue(problems.isEmpty, problems.joined(separator: "\n") + "\n" + app.debugDescription)
    }

    /// A root tab's button: in the tab bar on an iPhone, in the side rail on wider windows.
    @MainActor
    private func rootTab(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let inBar = app.tabBars.buttons[name].firstMatch
        let anywhere = app.buttons[name].firstMatch
        let found = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in inBar.exists || anywhere.exists },
                                              object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 30), .completed, app.debugDescription)
        return inBar.exists ? inBar : anywhere
    }

    @MainActor
    private func openFromLibrary(_ app: XCUIApplication) throws {
        rootTab(app, "資源庫").tap()
        let all = app.buttons["library.sources.all"].firstMatch
        for _ in 0..<6 where !all.exists { app.scrollViews.firstMatch.swipeUp(velocity: .slow) }
        XCTAssertTrue(all.waitForExistence(timeout: 10), app.debugDescription)
        all.tap()
        let source = app.buttons["library.source.\(Self.sourceName)"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 10), app.debugDescription)
        source.tap()
        openBook(app)
    }

    /// The source's 熱門 added to 探索's home as a row (編輯首頁 › 新增欄目), then the run's book
    /// from it — the way `DetailReaderBackSwipeUITests` reaches a source's book from 探索.
    @MainActor
    private func openFromExplore(_ app: XCUIApplication) {
        rootTab(app, "探索").tap()
        XCTAssertTrue(app.buttons["explore.more"].firstMatch.waitForExistence(timeout: 20), app.debugDescription)
        let edit = app.buttons["home.edit"].firstMatch
        for _ in 0..<12 where !(edit.exists && edit.isHittable) { app.swipeUp() }
        XCTAssertTrue(edit.waitForExistence(timeout: 5), app.debugDescription)
        edit.tap()
        let add = app.buttons["homeEditor.addSection"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 where !add.isHittable { app.swipeUp() }
        add.tap()
        let layout = app.buttons["homeNewSection.layout.row"].firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<4 where !layout.isHittable { app.swipeUp() }
        layout.tap()
        for id in ["homeSection.source", "homePicker.bookSources", "homePicker.source.\(Self.sourceName)",
                   "homePicker.item.熱門", "homeSection.add", "home.editDone"] {
            let button = app.buttons[id].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 15), "\(id)\n\(app.debugDescription)")
            button.tap()
        }
        let card = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH 'home.card.bookSource.' AND label BEGINSWITH %@", title)).firstMatch
        for _ in 0..<12 where !(card.exists && card.isHittable) { app.swipeUp() }
        XCTAssertTrue(card.waitForExistence(timeout: 20), app.debugDescription)
        // The whole card above the tab bar: XCUITest counts a card under it as hittable.
        let tabBar = app.tabBars.firstMatch
        for _ in 0..<3 where tabBar.exists && card.frame.maxY > tabBar.frame.minY { app.swipeUp(velocity: .slow) }
        card.tap()
    }

    /// From the source's discover page: the run's book, then 立即閱讀 on its page.
    @MainActor
    private func openBook(_ app: XCUIApplication) {
        let book = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30), app.debugDescription)
        book.tap()
        tapRead(app)
    }

    /// The book page's read button: 立即閱讀 on a source's book page, 開始閱讀 on 作品詳情.
    @MainActor
    private func tapRead(_ app: XCUIApplication) {
        let read = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '立即閱讀' OR label BEGINSWITH '開始閱讀'"))
            .firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 30), app.debugDescription)
        for _ in 0..<6 where !read.isHittable { app.swipeDown(velocity: .slow) }
        read.tap()
    }

    // MARK: Checks

    /// Taps the page until the reader's chrome is up (its top bar's back button hittable).
    @MainActor
    private func showChrome(_ app: XCUIApplication) throws {
        let back = app.buttons["reader_back_button"]
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if back.exists, back.isHittable { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 60), .completed, app.debugDescription)
    }

    /// What keeps VoiceOver off the bottom bar on this route; empty when nothing does.
    @MainActor
    private func bottomBarProblems(_ app: XCUIApplication, route: String) throws -> [String] {
        // Checked over the chapter's page, not its loading placeholder: the page is the
        // reader's own UIKit view, which the bar is drawn over.
        let text = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "測試閱讀器工具列")).firstMatch
        XCTAssertTrue(text.waitForExistence(timeout: 60), "\(route): the chapter never showed\n\(app.debugDescription)")
        try showChrome(app)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "reader chrome — \(route)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "accessibility tree — \(route)"
        tree.lifetime = .keepAlways
        add(tree)

        var problems: [String] = []
        var barFrame = CGRect.null
        for id in Self.toolIDs {
            let button = app.buttons[id]
            if !button.exists {
                problems.append("\(route): \(id) is not in the accessibility tree")
            } else if !button.isHittable {
                problems.append("\(route): \(id) is in the tree but not hittable at \(button.frame)")
                barFrame = barFrame.union(button.frame)
            } else {
                barFrame = barFrame.union(button.frame)
            }
        }
        let slider = app.sliders["閱讀進度"]
        if !slider.exists {
            problems.append("\(route): 閱讀進度 slider is not in the accessibility tree")
        } else {
            if !slider.isHittable { problems.append("\(route): 閱讀進度 slider is not hittable at \(slider.frame)") }
            barFrame = barFrame.union(slider.frame)
        }
        // Where the bar is drawn even if none of it reached the tree: the screen's bottom fifth.
        if barFrame.isNull {
            let window = app.windows.firstMatch.frame
            barFrame = CGRect(x: window.minX, y: window.maxY - window.height / 5, width: window.width, height: window.height / 5)
        }

        // Scoped to the bar: the page's own text is drawn by CoreText, and its contrast and
        // Dynamic Type findings say nothing about whether the bar is reachable.
        var dropped: [String] = []
        try app.performAccessibilityAudit(for: [.elementDetection, .hitRegion, .sufficientElementDescription]) { issue in
            let description = "\(issue.auditType): \(issue.compactDescription) — \(issue.element?.debugDescription ?? "no element")"
            if let element = issue.element, element.exists, element.frame.intersects(barFrame) {
                problems.append("\(route): audit — \(description)")
            } else {
                dropped.append(description)
            }
            return true
        }
        if !dropped.isEmpty {
            let attachment = XCTAttachment(string: dropped.joined(separator: "\n"))
            attachment.name = "audit issues outside the bottom bar — \(route)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return problems
    }
}
