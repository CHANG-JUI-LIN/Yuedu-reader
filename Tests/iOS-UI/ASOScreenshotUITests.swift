import XCTest

/// App Store screenshots for 3.0: 閱讀器, 書架, 探索, 編輯首頁, 搜尋, 作品詳情 and 資源庫 in one
/// locale per test. Runs only when the driver sets `TEST_RUNNER_ASO_OUT` (the folder the PNGs are
/// written to), so the regular suite skips it.
///
/// Preconditions, set up by the driver: the public-domain books on the shelf and a home of
/// public-domain lists passed as `ASO_HOME` (`-explore-home-file`).
final class ASOScreenshotUITests: XCTestCase {
    private struct Locale {
        let code: String
        let region: String
        let explore: String
        let shelf: String
        let library: String
        let search: String
        let book: String
        let query: String
        /// A book that opens on its title page: the 目錄 button and the first chapter's row.
        var chapter: (contents: String, title: String)? = nil
        /// The work 作品詳情 opens from the results, when the query is not its title.
        var detail: String? = nil
    }

    private var out: String!

    override func setUpWithError() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["ASO_OUT"], !folder.isEmpty else { throw XCTSkip("ASO_OUT not set") }
        out = folder
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    @MainActor func testTraditionalChinese() throws {
        try walk(Locale(code: "zh-Hant", region: "zh_TW", explore: "探索", shelf: "書架", library: "資源庫", search: "搜尋",
                        book: "紅樓夢", query: "曹雪芹", detail: "紅樓夢"))
    }

    @MainActor func testSimplifiedChinese() throws {
        try walk(Locale(code: "zh-Hans", region: "zh_SG", explore: "探索", shelf: "书架", library: "资源库", search: "搜索",
                        book: "西游记", query: "西", detail: "西游记"))
    }

    @MainActor func testEnglish() throws {
        try walk(Locale(code: "en", region: "en_US", explore: "Explore", shelf: "Library", library: "Sources", search: "Search",
                        book: "Pride and Prejudice", query: "Pride and Prejudice", chapter: ("Contents", "I")))
    }

    @MainActor func testJapanese() throws {
        try walk(Locale(code: "ja", region: "ja_JP", explore: "見つける", shelf: "本棚", library: "ソース", search: "検索",
                        book: "こころ", query: "こころ"))
    }

    @MainActor func testKorean() throws {
        try walk(Locale(code: "ko", region: "ko_KR", explore: "탐색", shelf: "서재", library: "소스", search: "검색",
                        book: "운수 좋은 날", query: "Alice"))
    }

    // MARK: - Walk

    @MainActor
    private func walk(_ locale: Locale) throws {
        let env = ProcessInfo.processInfo.environment
        let only = Set((env["ASO_ONLY"] ?? "").split(separator: ",").map(String.init))
        func wanted(_ shot: String) -> Bool { only.isEmpty || only.contains(shot) }

        let app = XCUIApplication()
        app.launchArguments = ["-onboarding.completed", "YES", "-yd_source_disclaimer_accepted", "YES",
                               "-bookLayoutIsGrid", "<true/>",
                               "-AppleLanguages", "(\(locale.code))", "-AppleLocale", locale.region]
        if let home = env["ASO_HOME_\(locale.code)"] ?? env["ASO_HOME"] {
            app.launchArguments += ["-explore-home-file", home]
        }
        // 搜尋來源 without the catalogues of modern editions: their covers are other people's
        // artwork (a film soundtrack, a webtoon) and their titles other people's works, which a
        // store listing must not show. What is left is the shelf and the public libraries.
        let modules = ["bangumi", "anilist", "openbd", "openlibrary", "narou", "trends", "rakuten-books"]
        let settings = try JSONSerialization.data(withJSONObject: [
            "hiddenFromSearch": modules.map { ["type": "module", "id": $0] },
        ])
        app.launchArguments += ["-yd_aggregation_settings", "<\(settings.map { String(format: "%02x", $0) }.joined())>"]
        app.launch()
        allowSystemAlerts()

        // 閱讀器, from 書架, which also puts the book first in 繼續閱讀.
        tab(app, locale.shelf).tap()
        // 探索, the launch tab, stays in the tree, so its 繼續閱讀 card can be the first match for
        // the title; only the shelf's own copy is hittable.
        let titles = app.staticTexts.matching(NSPredicate(format: "label == %@", locale.book))
        func onShelf() -> XCUIElement? { titles.allElementsBoundByIndex.first { $0.isHittable } }
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in onShelf() != nil }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 30), .completed, "[\(locale.code)] \(locale.book) on the shelf")
        if wanted("reader") || wanted("shelf") || wanted("explore") {
            // The grid reorders once the covers and the import list settle; tap where the book ends up.
            // The title under the cover is not the button; the cover above it opens the book.
            pause(3)
            onShelf()?.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .withOffset(CGVector(dx: 0, dy: -100)).tap()
            pause(6)
            XCTAssertTrue(app.buttons["reader_back_button"].exists || onShelf() == nil, "[\(locale.code)] the reader opens")
            // A tap on the page toggles the bars, which may already be up when the book opens.
            let back = app.buttons["reader_back_button"]
            func showBars() {
                for _ in 0..<3 where !(back.exists && back.isHittable) && onShelf() == nil {
                    app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                    _ = back.waitForExistence(timeout: 4)
                    pause(1.5)
                }
            }
            showBars()
            if let chapter = locale.chapter {
                app.buttons[chapter.contents].firstMatch.tap()
                let row = app.staticTexts.matching(NSPredicate(format: "label == %@", chapter.title)).firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 10), "[\(locale.code)] \(chapter.title) in \(chapter.contents)")
                row.tap()
                pause(4)
                showBars()
            }
            XCTAssertTrue(back.exists && back.isHittable, "[\(locale.code)] the reader's bars")
            if wanted("reader") { shoot("reader") }
            if !back.exists {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                _ = back.waitForExistence(timeout: 4)
            }
            back.tap()
            pause(2)
            dismissAddToShelfIfAsked(app)
        }
        if wanted("shelf") {
            tab(app, locale.shelf).tap()
            pause(3)
            shoot("shelf")
        }

        // 探索, its 頂部輪播圖 loaded.
        tab(app, locale.explore).tap()
        pause(1)
        tab(app, locale.explore).tap()   // a second tap scrolls the home to its top
        pause(Double(env["ASO_EXPLORE_WAIT"] ?? "8") ?? 8)
        if wanted("explore") { shoot("explore") }

        // 編輯首頁, as it opens: at the foot of the home, with the sections' previews and 新增.
        if wanted("editor") {
            let edit = app.buttons["home.edit"].firstMatch
            for _ in 0..<12 where !(edit.exists && edit.isHittable) { app.swipeUp(velocity: .fast) }
            if edit.exists {
                edit.tap()
                pause(4)
                shoot("editor")
                let done = app.buttons["home.editDoneBar"].firstMatch
                if done.waitForExistence(timeout: 5) { done.tap() }
                pause(2)
            } else {
                XCTFail("[\(locale.code)] 編輯首頁 not found\n\(app.debugDescription)")
            }
        }

        // 資源庫, before 作品詳情: a pushed page hides the tab bar.
        if wanted("library") {
            tab(app, locale.library).tap()
            pause(4)
            shoot("library")
        }

        // 搜尋, then the first work's 作品詳情.
        if wanted("search") || wanted("detail") {
            tab(app, locale.search).tap()
            let field = app.searchFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 10), "[\(locale.code)] search field")
            field.tap()
            field.typeText(locale.query + "\n")
            pause(Double(env["ASO_SEARCH_WAIT"] ?? "16") ?? 16)
            // The keyboard off the results.
            if app.keyboards.firstMatch.exists { app.swipeDown(velocity: .slow) ; pause(1) }
            if wanted("search") { shoot("search") }
            if wanted("detail") {
                let title = locale.detail ?? locale.query
                let work = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@", title + "，")).firstMatch
                let plain = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label BEGINSWITH %@ AND elementType == %d", title,
                                          XCUIElement.ElementType.button.rawValue)).firstMatch
                let target = work.exists ? work : plain
                if target.waitForExistence(timeout: 10) {
                    target.tap()
                    pause(Double(env["ASO_DETAIL_WAIT"] ?? "8") ?? 8)
                    shoot("detail")
                } else {
                    XCTFail("[\(locale.code)] no work for \(title)\n\(app.debugDescription)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// A root tab's button: the bottom bar on iPhone, the floating top bar on iPad, the side
    /// rail on a wide window. Only the first is a `tabBars` element.
    @MainActor
    private func tab(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let inBar = app.tabBars.buttons[label].firstMatch
        let anywhere = app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
        let found = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in inBar.exists || anywhere.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 30), .completed, "tab \(label)\n\(app.debugDescription)")
        return inBar.exists ? inBar : anywhere
    }

    /// The notification prompt a new install asks for on its first launch: allowed, so it never
    /// lands in a shot.
    @MainActor
    private func allowSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        if alert.waitForExistence(timeout: 6) {
            let buttons = alert.buttons.allElementsBoundByIndex
            (buttons.last ?? alert.buttons.firstMatch).tap()
            pause(1)
        }
    }

    @MainActor
    private func dismissAddToShelfIfAsked(_ app: XCUIApplication) {
        let alert = app.alerts.firstMatch
        if alert.waitForExistence(timeout: 2) { alert.buttons.firstMatch.tap() }
    }

    private func pause(_ seconds: Double) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @MainActor
    private func shoot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let url = URL(fileURLWithPath: out).appendingPathComponent("\(name).png")
        do {
            try png.write(to: url)
        } catch {
            XCTFail("\(name): \(error)")
        }
        print("ASO-SHOT \(url.path)")
    }
}
