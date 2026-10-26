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

    /// `officialModules`: the bundled modules on, as a reader has them.
    @MainActor
    private func launchExplore(_ extraArguments: [String] = [], officialModules: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = (officialModules ? [] : ["-no-official-modules"]) + ["-onboarding.completed", "YES",
                               "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
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

    /// 熱門's own copy of `card`, the first below its header: 為你推薦 (Phase 7a-4), above it,
    /// can hold the same book.
    @MainActor
    private func popularCard(_ app: XCUIApplication, under header: XCUIElement) throws -> XCUIElement {
        let top = header.frame.maxY
        return try XCTUnwrap(app.buttons.matching(identifier: card).allElementsBoundByIndex
            .filter { $0.frame.minY >= top }.min { $0.frame.minY < $1.frame.minY }, app.debugDescription)
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
        // 完成 is the home's last button, and the bar's, which stays while the home is edited.
        XCTAssertTrue(app.buttons["home.editDone"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["home.editDoneBar"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.switches["瀏覽器"].exists, "the browser has no switch (maintainer, 2026-10-17)")
        for _ in 0..<8 { app.swipeDown() }
        attach(app, "home-editing")

        let mark = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                    "homeEditor.toggle.", listTitle)).firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(mark.value as? String, "顯示")
        // Clear of the bottom bar, the ＋'s, which takes the taps under it.
        let add = app.buttons["homeEditor.addSection"].firstMatch
        let window = app.windows.firstMatch
        for _ in 0..<4 where mark.frame.maxY > add.frame.minY {
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
                .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        }
        mark.tap()
        XCTAssertEqual(mark.value as? String, "已隱藏")
        // Dragged, the page no longer follows the end: the shorter card stays in view.
        XCTAssertTrue(window.frame.contains(mark.frame), "stays where it was dragged: \(app.debugDescription)")
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

    /// 編輯首頁 and 完成 hold the page at its end only while the sections morph: a scroll that is
    /// not a drag — the status bar's here, VoiceOver's alike — then goes where it was sent. And
    /// from the top, the bar's 完成 and ••• → 編輯首頁 still end at the end.
    @MainActor
    func testScrollsThatAreNotADragAfterEditing() {
        let app = launchExplore()
        let edit = app.buttons["home.edit"].firstMatch
        for _ in 0..<8 where !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.isHittable, app.debugDescription)
        edit.tap()
        let done = app.buttons["home.editDone"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(done.isHittable, "the page is at its end: \(app.debugDescription)")
        tapStatusBar(app)
        XCTAssertTrue(becomesUnhittable(done), "the status bar took the edited home to its top: \(app.debugDescription)")
        attach(app, "home-editing-top")
        XCTAssertFalse(done.isHittable, "and the page stays there: \(app.debugDescription)")
        // The content's size changing then, as a section's books arriving late would, leaves it
        // there too: 為你推薦's card, hidden, is its name alone.
        let mark = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                    "homeEditor.toggle.", "為你推薦")).firstMatch
        XCTAssertTrue(mark.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(mark.isHittable, app.debugDescription)
        mark.tap()
        XCTAssertEqual(mark.value as? String, "已隱藏")
        attach(app, "home-editing-top-hidden")
        XCTAssertFalse(done.isHittable, "a shorter card keeps the page where the status bar took it: \(app.debugDescription)")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(mark.frame), app.debugDescription)
        mark.tap()
        XCTAssertEqual(mark.value as? String, "顯示")
        XCTAssertFalse(done.isHittable, "and a taller one: \(app.debugDescription)")

        app.buttons["home.editDoneBar"].firstMatch.tap()
        let editAgain = app.buttons["home.edit"].firstMatch
        XCTAssertTrue(editAgain.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(editAgain.isHittable, "the page is at its end: \(app.debugDescription)")
        tapStatusBar(app)
        XCTAssertTrue(becomesUnhittable(editAgain), "the status bar took the home to its top: \(app.debugDescription)")
        attach(app, "home-top")
        XCTAssertFalse(editAgain.isHittable, "and the page stays there: \(app.debugDescription)")

        app.buttons["explore.more"].firstMatch.tap()
        let menuEdit = app.buttons.matching(NSPredicate(format: "(label == %@ OR label BEGINSWITH %@) AND identifier != %@",
                                                        "編輯首頁", "編輯首頁,", "home.edit")).firstMatch
        XCTAssertTrue(menuEdit.waitForExistence(timeout: 5), app.debugDescription)
        menuEdit.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(becomesHittable(done), "••• → 編輯首頁 from the top: the editor's end: \(app.debugDescription)")
    }

    /// The status bar's tap, which scrolls the page to its top: at the clock, clear of the island.
    @MainActor
    private func tapStatusBar(_ app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 15)).tap()
    }

    @MainActor
    private func becomesUnhittable(_ element: XCUIElement) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !element.isHittable }, object: nil)
        return XCTWaiter.wait(for: [gone], timeout: 5) == .completed
    }

    @MainActor
    private func becomesHittable(_ element: XCUIElement) -> Bool {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in element.isHittable }, object: nil)
        return XCTWaiter.wait(for: [shown], timeout: 5) == .completed
    }

    /// 完成 from an editor much taller than the home: hidden sections are a card each while the
    /// home is edited and nothing on the home, as on the maintainer's, whose hidden 來源配置
    /// sections left the home blank after 完成 (2026-10-22): its sections gone, 編輯首頁 alone
    /// above the bar. The home is drawn again, from the editor's 完成 and from the bar's.
    @MainActor
    func testDoneFromATallerEditorShowsTheHome() throws {
        func section(_ binding: [String: Any], layout: String, enabled: Bool = true) -> [String: Any] {
            ["binding": binding, "id": UUID().uuidString, "isEnabled": enabled, "layout": layout,
             "parameters": [String: Any](), "title": ""]
        }
        let hidden = (1...10).map { index in
            section(["type": "sourceCategories", "categories": [[
                "sourceURL": "http://localhost:9", "title": "Hidden \(index)", "url": "http://localhost:9/\(index)"]]],
                    layout: "coverGrid", enabled: false)
        }
        let sections = [section(["type": "continueReading"], layout: "compactReadingCard"),
                        section(["type": "gutenbergShelf", "id": "popular"], layout: "row")]
            + hidden + [section(["type": "gutenbergLists"], layout: "collection")]
        let home = directory.appendingPathComponent("explore_home.json")
        try JSONSerialization.data(withJSONObject: ["configurations": [Any](), "schemaVersion": 2, "sections": sections])
            .write(to: home)
        let app = launchExplore(["-explore-home-file", home.path])
        let edit = app.buttons["home.edit"].firstMatch
        let done = app.buttons["home.editDone"].firstMatch
        for doneButton in ["home.editDone", "home.editDoneBar"] {
            for _ in 0..<8 where !edit.isHittable { app.swipeUp() }
            XCTAssertTrue(edit.isHittable, app.debugDescription)
            edit.tap()
            XCTAssertTrue(done.waitForExistence(timeout: 10), app.debugDescription)
            XCTAssertTrue(becomesHittable(done), "the editor's end: \(app.debugDescription)")
            app.buttons[doneButton].firstMatch.tap()
            XCTAssertTrue(becomesHittable(edit), "\(doneButton): the home's end: \(app.debugDescription)")
            XCTAssertTrue(becomesHittable(app.buttons[listCard].firstMatch),
                          "\(doneButton): the last section is drawn above 編輯首頁: \(app.debugDescription)")
            attach(app, "home-after-\(doneButton)")
            XCTAssertGreaterThan(drawnShare(app, above: edit), 0.05, "\(doneButton): the home is drawn, not its background")
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeEditor.toggle."))
                .firstMatch.exists, "\(doneButton): no card is left: \(app.debugDescription)")
        }
    }

    /// How much of the page between the bar and `edge` is drawn: the share of sampled pixels
    /// unlike the commonest one. The page's background alone, as the maintainer's home was after
    /// 完成 (2026-10-22: its sections gone, 編輯首頁 left at the bottom), reads close to 0.
    @MainActor
    private func drawnShare(_ app: XCUIApplication, above edge: XCUIElement) -> Double {
        guard let image = app.screenshot().image.cgImage else { return 0 }
        let window = app.windows.firstMatch.frame
        let scale = CGFloat(image.width) / window.width
        let top = app.navigationBars.firstMatch.frame.maxY + 8
        let bottom = edge.frame.minY - 8
        guard bottom - top > 40 else { return 1 }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var counts: [UInt32: Int] = [:]
        var samples = 0
        for y in stride(from: top, to: bottom, by: 6) {
            for x in stride(from: window.minX + 4, to: window.maxX - 4, by: 6) {
                let index = (Int(y * scale) * width + Int(x * scale)) * 4
                // To 4 bits a channel: a gradient's neighbours count as one colour.
                let key = UInt32(pixels[index] >> 4) << 8 | UInt32(pixels[index + 1] >> 4) << 4 | UInt32(pixels[index + 2] >> 4)
                counts[key, default: 0] += 1
                samples += 1
            }
        }
        guard samples > 0, let commonest = counts.values.max() else { return 0 }
        return 1 - Double(commonest) / Double(samples)
    }

    /// 5d-3: 呈現方式, from the same long press, redraws the section: 圖文資訊清單 gives each book
    /// the width of the screen, and 顯示排名 puts its rank first in what VoiceOver reads. 熱門
    /// starts as a ranked row (2026-10-25, after Apple Books' charts), and its ranks go along.
    @MainActor
    func testLongPressChangesTheLayout() throws {
        let app = launchExplore()
        let header = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "home.row.header.", listTitle)).firstMatch
        var book = try popularCard(app, under: header)
        XCTAssertLessThan(book.frame.width, app.frame.width / 2, "橫向單排書架 shows several books to a screen")
        let ranked = NSPredicate(format: "label MATCHES %@", "^[0-9]+, .*")
        func readsRank(_ label: String) -> Bool { label.range(of: "^[0-9]+, ", options: .regularExpression) != nil }
        XCTAssertTrue(readsRank(book.label), "a ranked row reads its rank first: \(book.label)")
        attach(app, "home-section-ranked-row")

        header.press(forDuration: 1.0)
        let layouts = app.buttons["呈現方式"].firstMatch
        XCTAssertTrue(layouts.waitForExistence(timeout: 5), app.debugDescription)
        layouts.tap()
        let list = app.buttons["圖文資訊清單"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), app.debugDescription)
        attach(app, "home-section-layouts")
        list.tap()
        XCTAssertTrue(book.waitForExistence(timeout: 5))
        book = try popularCard(app, under: header)
        XCTAssertGreaterThan(book.frame.width, app.frame.width * 0.8, app.debugDescription)
        XCTAssertTrue(readsRank(book.label), "the ranks go along: \(book.label)")
        attach(app, "home-section-ranked-list")

        header.press(forDuration: 1.0)
        XCTAssertTrue(layouts.waitForExistence(timeout: 5))
        layouts.tap()
        let ranks = app.switches["顯示排名"].firstMatch.exists ? app.switches["顯示排名"].firstMatch : app.buttons["顯示排名"].firstMatch
        XCTAssertTrue(ranks.waitForExistence(timeout: 5), app.debugDescription)
        ranks.tap()
        expectation(for: NSCompoundPredicate(notPredicateWithSubpredicate: ranked), evaluatedWith: book)
        waitForExpectations(timeout: 5)
        attach(app, "home-section-list")
    }

    /// Decision 37: 精選 draws one book to a page, the whole card on screen with the next one
    /// showing past the edge; a swipe brings the next book in.
    @MainActor
    func testLongPressChoosesFeatured() throws {
        let app = launchExplore()
        let header = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "home.row.header.", listTitle)).firstMatch
        header.press(forDuration: 1.0)
        let layouts = app.buttons["呈現方式"].firstMatch
        XCTAssertTrue(layouts.waitForExistence(timeout: 5), app.debugDescription)
        layouts.tap()
        let featured = app.buttons["精選"].firstMatch
        XCTAssertTrue(featured.waitForExistence(timeout: 5), app.debugDescription)
        featured.tap()

        XCTAssertTrue(app.buttons[card].firstMatch.waitForExistence(timeout: 5))
        let book = try popularCard(app, under: header)
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

    /// 精選書單's lists, each read by its name: 分類卡片 for a new install (2026-10-25, after Apple
    /// Books' More to Explore), a card as wide as the page and the next one under it. Its long
    /// press offers the layouts of lists and no other; 專題集合 (decision 37) pages them by.
    @MainActor
    func testListsAreCollectionCards() {
        let app = launchExplore()
        let list = app.buttons[listCard].firstMatch
        // The whole card, above the tab bar.
        let tabBarTop = app.tabBars.firstMatch.frame.minY
        for _ in 0..<6 where !list.exists || list.frame.maxY > tabBarTop { app.swipeUp() }
        XCTAssertTrue(list.isHittable, app.debugDescription)
        XCTAssertEqual(list.label, "中文書籍")
        XCTAssertGreaterThan(list.frame.width, app.frame.width * 0.8, "a card as wide as the page: \(list.frame)")
        let fiction = app.buttons["home.collection.gutenberg.fiction"].firstMatch
        XCTAssertTrue(fiction.exists, "the next list follows")
        XCTAssertGreaterThanOrEqual(fiction.frame.minY, list.frame.maxY, "under it: \(fiction.frame) \(list.frame)")
        attach(app, "home-category-cards")

        // The header's long press: the three layouts of lists, no layout of books.
        // The name, then its line (`HomeSection.displaySubtitle`).
        let listsHeader = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                                                               "home.row.header.", listsTitle)).firstMatch
        for _ in 0..<6 where !listsHeader.isHittable {
            if listsHeader.exists, listsHeader.frame.minY < app.frame.midY { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(listsHeader.isHittable, app.debugDescription)
        XCTAssertEqual(listsHeader.elementType, .staticText, "no page lists the lists alone: no 查看全部")
        listsHeader.press(forDuration: 1.0)
        let layouts = app.buttons["呈現方式"].firstMatch
        XCTAssertTrue(layouts.waitForExistence(timeout: 5), app.debugDescription)
        layouts.tap()
        let collection = app.buttons["專題集合"].firstMatch
        XCTAssertTrue(collection.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["拼貼卡片"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["橫向單排書架"].exists, "lists are never drawn as books")
        attach(app, "home-collection-menu")
        collection.tap()
        // The cards move from one layout to the other as the menu closes; mid-move a card is
        // as wide as the page and not hittable.
        waitUntilSettled(list)

        // 專題集合: a list to a page, swiped by.
        for _ in 0..<6 where !list.exists || list.frame.maxY > tabBarTop { app.swipeUp() }
        XCTAssertTrue(list.isHittable, app.debugDescription)
        XCTAssertLessThan(list.frame.width, app.frame.width * 0.95, "the next page shows past the edge: \(list.frame)")
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
        // Its preview is the card at its real size (80pt, Apple Books' Continue), the name under it.
        XCTAssertGreaterThan(compact.frame.height, 100, "the name under a preview: \(compact.frame)")
        attach(app, "home-new-section-previews")

        let featured = app.buttons["homeNewSection.layout.featured"].firstMatch
        for _ in 0..<8 where !featured.isHittable { app.swipeUp() }
        attach(app, "home-new-section-previews-more")
        // The list's end: 精選 and 專題集合.
        app.swipeUp()
        attach(app, "home-new-section-previews-end")
        for _ in 0..<8 where !featured.isHittable { app.swipeDown() }
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
        // No source is chosen yet, so every layout is offered; a section of books leaving out
        // 專題集合 is `HomeLayoutStyleTests.choices`.
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

    /// Waits until `element` stops moving: a tap while the page still coasts from a swipe only
    /// stops the scroll (seen on iOS 27, 2026-10-15: 最新's card was tapped 3 s after a
    /// `swipeDown()` and its form never opened). The expectation polls about once a second, so
    /// two equal frames in a row mean the scroll has come to rest.
    @MainActor
    private func waitUntilSettled(_ element: XCUIElement, timeout: TimeInterval = 10) {
        var last = CGRect.null
        let settled = NSPredicate { _, _ in
            let frame = element.frame
            defer { last = frame }
            return frame == last
        }
        wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: timeout)
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
        // Wholly between the bars. A card under the navigation bar still counts as hittable and
        // the tap lands on the bar; under the ＋, it opens 新增欄目. 最新's card is as tall as its
        // row now, its books in it, and one swipe left it on either side (iOS 27 simulator).
        let add = app.buttons["homeEditor.addSection"].firstMatch
        let barBottom = app.navigationBars.firstMatch.frame.maxY
        func isBetweenTheBars() -> Bool {
            latest.exists && latest.frame.minY > barBottom && latest.frame.maxY < add.frame.minY
        }
        for _ in 0..<10 where !latest.exists { app.swipeDown() }
        // Dragged as far as it is off, then held: a swipe's momentum, even a slow one's, carried it
        // past the room between the bars, one way and then the other.
        let middle = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<6 where !isBetweenTheBars() {
            let shift = max(-300, min(300, barBottom + 24 - latest.frame.minY))
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: shift)),
                         withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        waitUntilSettled(latest)
        XCTAssertTrue(isBetweenTheBars(), app.debugDescription)
        latest.tap()
        let addLatest = app.buttons["homeSection.latest.add"].firstMatch
        // Under 顯示在最新's libraries (decision 36), at the screen's foot since 副標題 and
        // 顯示排名 joined a row's form. Checked once the form is in: mid-push it read as
        // hittable. A button cut by the screen's edge is hittable too, and a tap on its sliver
        // lands on the home indicator (iOS 18.6 simulator), so it must be wholly on screen.
        XCTAssertTrue(app.textFields["homeSection.title"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        let screen = app.windows.firstMatch.frame
        for _ in 0..<4 where !(addLatest.exists && addLatest.isHittable && screen.contains(addLatest.frame)) {
            app.swipeUp()
        }
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

    /// #51/#7 (iOS 26.4): as 資料來源's sheet came up, 新增欄目's form under it went back to the
    /// layouts, and the sheet went with it: no section could be added. The official modules on,
    /// as the reader had them. Fails on the iOS 26.4.1 simulator with the cover on the home's
    /// root, not on 26.5 or 18.6; `testAddSections`'s 頻道 menu, there, too.
    @MainActor
    func testPickerKeepsTheNewSectionForm() throws {
        try writeBookSource()
        let app = launchExplore(officialModules: true)
        let edit = app.buttons["home.edit"].firstMatch
        for _ in 0..<8 where !edit.isHittable { app.swipeUp() }
        edit.tap()

        startSection(app, layout: "compactReadingCard")
        attach(app, "home-new-section-picker-over-form")
        let choice = app.buttons["homePicker.item.書架"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5), app.debugDescription)
        choice.tap()
        let source = app.buttons["homeSection.source"].firstMatch
        XCTAssertTrue(source.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(source.value as? String, "App 資料 › 書架", app.debugDescription)
        XCTAssertTrue(app.buttons["homeSection.add"].firstMatch.isEnabled, app.debugDescription)
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
