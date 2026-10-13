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
        // 熱門, by downloads: the home's row of books since its bundled lists became 精選書單's
        // cards (decision 37). Books of no bundled list, so a list's preview is told apart.
        let books = [(2701, "Moby Dick", "Herman Melville"), (1513, "Romeo and Juliet", "William Shakespeare"),
                     (2641, "A Room with a View", "E. M. Forster"), (145, "Middlemarch", "George Eliot")]
        let entries = books.map { number, title, author in
            "<entry><id>https://www.gutenberg.org/ebooks/\(number).opds</id><title>\(title)</title><content>\(author)</content>"
                + "<link rel=\"subsection\" type=\"application/atom+xml\" href=\"/ebooks/\(number).opds\"/></entry>"
        }.joined()
        try Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"><title>Popular</title>\(entries)</feed>".utf8)
            .write(to: directory.appendingPathComponent("ebooks_search.opds@sort_order=downloads.xml"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// 熱門, a new install's row of books, and its first card.
    private let listTitle = "熱門"
    private let card = "home.card.gutenberg.2701"
    /// 精選書單, the bundled lists as 專題集合's cards, and 中文書籍's.
    private let listsTitle = "精選書單"
    private let listCard = "home.collection.gutenberg.chinese"

    @MainActor
    private func launchExplore(_ extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-yd_source_disclaimer_accepted", "YES",
                               "-book-source-store-dir", directory.appendingPathComponent("sources").path,
                               "-reset-public-library-explore", "-reset-explore-home"] + extraArguments
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
        XCTAssertTrue(app.switches["瀏覽器"].firstMatch.waitForExistence(timeout: 5), "更多's card holds the browser's switch")
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

    /// Decision 37: 精選 draws one book to a page, the whole card on screen with the next one
    /// showing past the edge; a swipe brings the next book in.
    @MainActor
    func testLongPressChoosesFeatured() {
        let app = launchExplore()
        let header = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "home.row.header.", listTitle)).firstMatch
        let book = app.buttons[card].firstMatch
        header.press(forDuration: 1.0)
        let layouts = app.buttons["呈現方式"].firstMatch
        XCTAssertTrue(layouts.waitForExistence(timeout: 5), app.debugDescription)
        layouts.tap()
        let featured = app.buttons["精選"].firstMatch
        XCTAssertTrue(featured.waitForExistence(timeout: 5), app.debugDescription)
        featured.tap()

        XCTAssertTrue(book.waitForExistence(timeout: 5))
        let screen = app.frame
        XCTAssertGreaterThan(book.frame.width, screen.width * 0.6, "one book to a page: \(book.frame)")
        XCTAssertGreaterThanOrEqual(book.frame.minX, 0, "the first page is whole: \(book.frame)")
        XCTAssertLessThan(book.frame.maxX, screen.maxX, "the next page shows past the edge: \(book.frame)")
        XCTAssertTrue(book.isHittable)
        // One VoiceOver stop: the title, then the author; 查看作品 is drawn, not read.
        XCTAssertEqual(book.label, "Moby Dick")
        XCTAssertTrue((book.value as? String)?.contains("Herman Melville") ?? false, "\(book.value ?? "")")
        XCTAssertFalse("\(book.label) \(book.value ?? "")".contains("查看作品"))
        attach(app, "home-section-featured")

        // The next book: the card that starts right of the first one, on the same line.
        let rowY = book.frame.midY
        let next = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@",
                                                    "home.card.gutenberg.", card))
            .allElementsBoundByIndex.first { abs($0.frame.midY - rowY) < 4 && $0.frame.minX > book.frame.minX }
        XCTAssertNotNil(next, app.debugDescription)
        book.swipeLeft()
        if let nextCard = next {
            let settled = NSPredicate { _, _ in nextCard.frame.minX >= 0 && nextCard.frame.minX < screen.width / 4 }
            expectation(for: settled, evaluatedWith: nil)
            waitForExpectations(timeout: 5)
            XCTAssertTrue(nextCard.isHittable)
        }
        attach(app, "home-section-featured-next")
    }

    /// Decision 37: 精選書單's lists are 專題集合's cards, a list to a page, each read by its name;
    /// its long press offers no 呈現方式, since lists have one layout.
    @MainActor
    func testListsAreCollectionCards() {
        let app = launchExplore()
        let list = app.buttons[listCard].firstMatch
        // The whole card, above the tab bar.
        let tabBarTop = app.tabBars.firstMatch.frame.minY
        for _ in 0..<6 where !list.exists || list.frame.maxY > tabBarTop { app.swipeUp() }
        XCTAssertTrue(list.isHittable, app.debugDescription)
        XCTAssertEqual(list.label, "中文書籍")
        XCTAssertGreaterThan(list.frame.width, app.frame.width * 0.6, "a list to a page: \(list.frame)")
        XCTAssertTrue(app.buttons["home.collection.gutenberg.fiction"].firstMatch.exists, "the next list follows")
        attach(app, "home-collection-cards")

        // Swiped, the lists page by; 兒童與青少年 holds two books, so two covers.
        let rowY = list.frame.midY / app.frame.height
        func drag(from start: CGFloat, to end: CGFloat) {
            app.coordinate(withNormalizedOffset: CGVector(dx: start, dy: rowY))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: end, dy: rowY)))
        }
        let children = app.buttons["home.collection.gutenberg.children"].firstMatch
        for _ in 0..<4 where !(children.exists && children.frame.minX >= 0 && children.frame.minX < app.frame.width / 4) {
            drag(from: 0.85, to: 0.15)
        }
        XCTAssertTrue(children.isHittable, app.debugDescription)
        attach(app, "home-collection-two-books")
        for _ in 0..<4 where !(list.exists && list.frame.minX >= 0) { drag(from: 0.15, to: 0.85) }
        XCTAssertTrue(list.isHittable, app.debugDescription)

        // A tap opens the whole list.
        list.tap()
        XCTAssertTrue(app.navigationBars["中文書籍"].waitForExistence(timeout: 10), app.debugDescription)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(list.waitForExistence(timeout: 10), app.debugDescription)

        // No page lists the lists alone, so the name is text, not a 查看全部 button.
        let header = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                                          "home.row.header.", listsTitle)).firstMatch
        for _ in 0..<6 where !header.isHittable {
            if header.exists, header.frame.minY < app.frame.midY { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(header.isHittable, app.debugDescription)
        XCTAssertEqual(header.elementType, .staticText)
        header.press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["隱藏"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.buttons["呈現方式"].exists, "lists have one layout")
        attach(app, "home-collection-menu")
    }

    /// Decision 34: 新增欄目 shows each layout drawn small with real covers, read by its name; the
    /// form's 呈現方式 opens the same previews with the section's own books, the current one
    /// selected, and a choice comes back to the form.
    @MainActor
    func testLayoutPreviews() {
        let app = launchExplore()
        let add = app.buttons["homeEditor.addSection"].firstMatch
        let edit = app.buttons["home.edit"].firstMatch
        for _ in 0..<8 where !edit.isHittable { app.swipeUp() }
        edit.tap()
        for _ in 0..<8 where !add.isHittable { app.swipeUp() }
        add.tap()
        let compact = app.buttons["homeNewSection.layout.compactReadingCard"].firstMatch
        XCTAssertTrue(compact.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(compact.label, "精簡閱讀卡片")
        XCTAssertGreaterThan(compact.frame.height, 120, "the name over a preview: \(compact.frame)")
        attach(app, "home-new-section-previews")

        let featured = app.buttons["homeNewSection.layout.featured"].firstMatch
        for _ in 0..<8 where !featured.isHittable { app.swipeUp() }
        attach(app, "home-new-section-previews-more")
        featured.tap()
        let layout = app.buttons["homeSection.layout"].firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(layout.value as? String, "精選")
        layout.tap()
        XCTAssertTrue(app.buttons["homeSection.layoutChoice.readingCard"].firstMatch.waitForExistence(timeout: 5),
                      app.debugDescription)
        attach(app, "home-section-layout-previews")
        // 精選 is far down the list; its row is built once it scrolls near.
        let current = app.buttons["homeSection.layoutChoice.featured"].firstMatch
        for _ in 0..<8 where !current.isHittable { app.swipeUp() }
        XCTAssertTrue(current.exists, app.debugDescription)
        XCTAssertTrue(current.isSelected, "the current layout is selected")
        XCTAssertFalse(app.buttons["homeSection.layoutChoice.collection"].exists, "a section of books has no 專題集合")
        let list = app.buttons["homeSection.layoutChoice.list"].firstMatch
        for _ in 0..<8 where !list.isHittable { app.swipeUp() }
        list.tap()
        XCTAssertTrue(layout.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(layout.value as? String, "圖文資訊清單")
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

    // MARK: 新增欄目 (5d-5)

    /// One book source whose discover page lists one category, 排行榜 (not 熱門: Gutenberg's 熱門 is a
    /// default section since 5d-6a), under one filter, 頻道, that
    /// its rule reads from the source's variable as 光遇's does. Its host answers nothing: the
    /// row it gives the home fails to load, which still draws its name.
    private func writeBookSource() throws {
        let sources = directory.appendingPathComponent("sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let source: [String: Any] = [
            "bookSourceName": "介面測試書源",
            "bookSourceUrl": "https://ui-test-explore.example",
            "exploreUrl": #"""
                <js>var v = JSON.parse(source.getVariable() || '{}'); var c = v['頻道'] || '男';
                JSON.stringify([{title: '頻道', type: 'select', chars: ['男', '女'], 'default': c, action: "show(c,'頻道')"},
                {title: '排行榜', url: 'https://ui-test-explore.example/hot?c=' + c}]);</js>
                """#,
            "enabled": true,
            "enabledExplore": true,
        ]
        try JSONSerialization.data(withJSONObject: [source]).write(to: sources.appendingPathComponent("book_sources.json"))
    }

    /// The cards of the sections named `title` in 編輯首頁.
    @MainActor
    private func sectionCards(_ app: XCUIApplication, named title: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "homeEditor.section.", title))
    }

    /// Picks `layout`, then 資料來源, in 新增欄目's sheet.
    @MainActor
    private func startSection(_ app: XCUIApplication, layout: String) {
        let add = app.buttons["homeEditor.addSection"].firstMatch
        for _ in 0..<8 where !add.isHittable { app.swipeUp() }
        add.tap()
        let style = app.buttons["homeNewSection.layout.\(layout)"].firstMatch
        // Each layout is a row with its preview (decision 34): scrolled to.
        XCTAssertTrue(app.buttons["homeNewSection.layout.row"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<8 where !style.isHittable { app.swipeUp() }
        XCTAssertTrue(style.isHittable, app.debugDescription)
        style.tap()
        let addButton = app.buttons["homeSection.add"].firstMatch
        XCTAssertTrue(addButton.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(addButton.isEnabled, "nothing to add before 資料來源")
        app.buttons["homeSection.source"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["App 資料"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    /// 新增欄目 from 編輯首頁: a layout, then the form, whose 資料來源 opens 選擇內容來源. A library's
    /// list and a book source's category each become a section at the end of the home.
    @MainActor
    func testAddSections() throws {
        try writeBookSource()
        let app = launchExplore()
        let edit = app.buttons["home.edit"].firstMatch
        for _ in 0..<8 where !edit.isHittable { app.swipeUp() }
        edit.tap()
        XCTAssertEqual(sectionCards(app, named: "兒童與青少年").count, 0, "a new install has 精選書單, not a row per list")

        // A library: Gutenberg's bundled list.
        startSection(app, layout: "coverGrid")
        attach(app, "home-new-section-picker")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Project Gutenberg")).firstMatch.tap()
        let list = app.buttons["homePicker.item.兒童與青少年"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        list.tap()
        let source = app.buttons["homeSection.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(source.value as? String, "Project Gutenberg › 兒童與青少年")
        XCTAssertTrue(app.buttons["home.card.gutenberg.11"].firstMatch.waitForExistence(timeout: 10), "the preview loads the list")
        attach(app, "home-new-section-form")
        app.buttons["homeSection.add"].firstMatch.tap()
        // The home brings the new section, at its end, into view.
        XCTAssertTrue(app.buttons["homeEditor.addSection"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(sectionCards(app, named: "兒童與青少年").count, 1, app.debugDescription)
        attach(app, "home-new-section-added")

        // A book source's category.
        startSection(app, layout: "row")
        app.buttons["homePicker.bookSources"].firstMatch.tap()
        let sourceRow = app.buttons["homePicker.source.介面測試書源"].firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10), app.debugDescription)
        sourceRow.tap()
        let category = app.buttons["homePicker.item.排行榜"].firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription)
        // The section's own filter: the categories list again under it.
        let channel = app.descendants(matching: .any)["homePicker.filter.頻道"].firstMatch
        XCTAssertTrue(channel.waitForExistence(timeout: 5), app.debugDescription)
        channel.tap()
        let female = app.buttons["女"].firstMatch
        XCTAssertTrue(female.waitForExistence(timeout: 5), app.debugDescription)
        female.tap()
        // A menu picker reads its choice in its label (「頻道、女」).
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "女"), evaluatedWith: channel)], timeout: 15)
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription)
        attach(app, "home-new-section-categories")
        category.tap()
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertEqual(source.value as? String, "介面測試書源 › 排行榜")
        XCTAssertEqual(app.buttons["homeSection.filters"].firstMatch.value as? String, "女", app.debugDescription)
        app.buttons["homeSection.add"].firstMatch.tap()
        XCTAssertTrue(sectionCards(app, named: "排行榜").firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        // The same form edits it: its card pushes it, its title shows on the home.
        sectionCards(app, named: "排行榜").firstMatch.tap()
        let title = app.textFields["homeSection.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        title.tap()
        title.typeText("本週排行")
        XCTAssertEqual(app.buttons["homeSection.filters"].firstMatch.value as? String, "女", "the section keeps its filter")
        attach(app, "home-section-form")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(sectionCards(app, named: "本週排行").firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        // 最新's parameters: the category that stands for the book source in it.
        let latest = sectionCards(app, named: "最新").firstMatch
        for _ in 0..<10 where !(latest.exists && latest.isHittable) { app.swipeDown() }
        latest.tap()
        let addLatest = app.buttons["homeSection.latest.add"].firstMatch
        // Under 顯示在最新's libraries (decision 36).
        for _ in 0..<4 where !(addLatest.exists && addLatest.isHittable) { app.swipeUp() }
        XCTAssertTrue(addLatest.waitForExistence(timeout: 5), app.debugDescription)
        addLatest.tap()
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10), app.debugDescription)
        sourceRow.tap()
        XCTAssertTrue(category.waitForExistence(timeout: 15), app.debugDescription)
        category.tap()
        let picked = app.buttons["homeSection.latest.介面測試書源"].firstMatch
        XCTAssertTrue(picked.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(picked.label.contains("排行榜"), picked.label)
        attach(app, "home-section-latest-parameters")

        // 刪除 leaves the form, and the section the home.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let renamed = sectionCards(app, named: "本週排行").firstMatch
        for _ in 0..<10 where !(renamed.exists && renamed.isHittable) { app.swipeUp() }
        renamed.tap()
        let delete = app.buttons["homeSection.delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 5), app.debugDescription)
        for _ in 0..<5 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        XCTAssertTrue(app.staticTexts["刪除「本週排行」？"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "刪除", "homeSection.delete")).firstMatch.tap()
        XCTAssertTrue(delete.waitForNonExistence(timeout: 10), "the form left")
        XCTAssertTrue(renamed.waitForNonExistence(timeout: 5), app.debugDescription)
    }

    /// 訂閱的最新文章 (5g): App 資料's section of the RSS tab's articles. An article opens the
    /// RSS tab's article page, not 作品詳情, and reads as read when the home shows again.
    /// `-seed-rss-articles` stores a feed of two unread articles, the newest of all.
    @MainActor
    func testSubscriptionArticles() {
        let app = launchExplore(["-seed-rss-articles"])
        let edit = app.buttons["home.edit"].firstMatch
        for _ in 0..<8 where !edit.isHittable { app.swipeUp() }
        edit.tap()

        startSection(app, layout: "list")
        let choice = app.buttons["homePicker.item.訂閱的最新文章"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        let newest = app.buttons["home.article.yuedu-home-subscription-test-1"].firstMatch
        XCTAssertTrue(newest.waitForExistence(timeout: 10), "the preview shows the articles\n\(app.debugDescription)")
        attach(app, "home-subscription-form")
        app.buttons["homeSection.add"].firstMatch.tap()
        XCTAssertTrue(sectionCards(app, named: "訂閱的最新文章").firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let done = app.buttons["home.editDone"].firstMatch
        for _ in 0..<8 where !done.isHittable { app.swipeUp() }
        done.tap()

        // On the home, at its end: the title is the label, the feed and 未讀 the value.
        for _ in 0..<10 where !(newest.exists && newest.isHittable) { app.swipeUp() }
        XCTAssertTrue(newest.isHittable, app.debugDescription)
        XCTAssertEqual(newest.label, "首頁訂閱測試文章一")
        XCTAssertTrue((newest.value as? String)?.contains("首頁訂閱測試") == true, String(describing: newest.value))
        XCTAssertTrue((newest.value as? String)?.contains("未讀") == true, String(describing: newest.value))
        XCTAssertTrue(app.buttons["home.article.yuedu-home-subscription-test-2"].firstMatch.exists)
        attach(app, "home-subscription-section")

        // The RSS tab's article page, not 作品詳情.
        newest.tap()
        let body = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "首頁訂閱測試的文章內文")).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any)["detail.info.source"].exists, "an article has no 作品詳情")
        attach(app, "home-subscription-article")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Back on the home, the article reads as read.
        XCTAssertTrue(newest.waitForExistence(timeout: 10), app.debugDescription)
        wait(for: [expectation(for: NSPredicate(format: "NOT (value CONTAINS %@)", "未讀"), evaluatedWith: newest)], timeout: 10)
        attach(app, "home-subscription-read")

        // A sideways layout draws landscape article cards, several to a screen, not book covers.
        let header = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "home.row.header.", "訂閱的最新文章")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5), app.debugDescription)
        header.press(forDuration: 1.0)
        let layouts = app.buttons["呈現方式"].firstMatch
        XCTAssertTrue(layouts.waitForExistence(timeout: 5), app.debugDescription)
        layouts.tap()
        let row = app.buttons["橫向單排書架"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), app.debugDescription)
        row.tap()
        let narrow = NSPredicate { _, _ in newest.frame.width < app.frame.width * 0.8 }
        wait(for: [XCTNSPredicateExpectation(predicate: narrow, object: nil)], timeout: 5)
        XCTAssertEqual(newest.label, "首頁訂閱測試文章一")
        for _ in 0..<5 where !newest.isHittable { app.swipeUp() }
        attach(app, "home-subscription-row")

        // 查看全部 is RSS 訂閱 (decision 29), pushed since RSS left the tabs (5h).
        header.tap()
        XCTAssertTrue(app.navigationBars["RSS 訂閱"].waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "home-subscription-show-all")
    }
}
