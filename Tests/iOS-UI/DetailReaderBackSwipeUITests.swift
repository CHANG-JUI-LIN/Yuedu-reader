import XCTest
import StoreKitTest

/// Prepare with scripts/navigation_swipe_fixture.py and serve localhost:18765.
/// These tests deliver actual touches to the production Explore/detail/reader.
final class DetailReaderBackSwipeUITests: XCTestCase {
    private var storeKitSession: SKTestSession?

    @MainActor
    private func configureStoreKit() throws {
        let configuration = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Configuration/YueduPro.storekit")
        let session = try SKTestSession(contentsOf: configuration)
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        storeKitSession = session
    }

    @MainActor
    func testDetailReaderLoadsAndReturns() throws {
        try exerciseNativeEntry(fromSearch: false)
    }

    @MainActor
    func testSearchDetailReaderLoadsAndReturns() throws {
        try exerciseNativeEntry(fromSearch: true)
    }

    @MainActor
    private func exerciseNativeEntry(fromSearch: Bool) throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        if fromSearch {
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
            search.tap()
            search.typeText("navigation\n")
        }
        let book = app.staticTexts["Navigation Swipe Fixture"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read Now", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        for _ in 0..<2 {
            read.tap()
            let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
            XCTAssertTrue(content.waitForExistence(timeout: 30), "The reader must finish loading after a detail push.\n\(app.debugDescription)")
            XCTAssertFalse(read.exists, "Opening must stay in the reader")
            // iOS 17 uses UIKit's narrow physical-edge recognizer; the 30 pt
            // content-pop reservation is available starting with iOS 26.
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1, dy: app.frame.height * 0.5))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: end)
            XCTAssertTrue(read.waitForExistence(timeout: 8), app.debugDescription)
            XCTAssertFalse(content.exists)
        }
    }

    @MainActor
    func testDetailMangaReaderLoadsAndReturns() throws {
        try exerciseMangaEntry(fromSearch: false)
    }

    @MainActor
    func testSearchDetailMangaReaderLoadsAndReturns() throws {
        try exerciseMangaEntry(fromSearch: true)
    }

    /// A manga opens in FixedPageReaderView, pushed onto the detail's own stack.
    /// That reader once wrapped itself in a second NavigationStack there, and
    /// manga stopped opening from a book detail (Technotes/iOS17ReaderNavigationWatchdog.md).
    @MainActor
    private func exerciseMangaEntry(fromSearch: Bool) throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        // Search starts from the text source's Explore, where only search can reach the manga.
        let discoverSource = fromSearch ? "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4" : "42017D70-DAD6-4EDE-845E-C5DBAC606CA4"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", discoverSource]
        app.launch()
        if fromSearch {
            let search = app.searchFields.firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
            search.tap()
            search.typeText("manga fixture\n")
        }
        let book = app.staticTexts["Navigation Manga Fixture"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read Now", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        let progress = app.sliders["Progress"]
        for entry in 1...2 {
            // Read Now stays disabled until the detail has loaded the contents.
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: read)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
            read.tap()
            waitForMangaPage(app)
            XCTAssertFalse(read.exists, "Opening must stay in the reader")
            showMangaControls(app, expecting: "Page 1 / 3")
            attachScreenshot(app, named: "Manga reader - \(fromSearch ? "search" : "explore") detail - entry \(entry)")
            if entry == 1 {
                // With the controls up, a tap on a turning zone only puts them away.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
                waitForMangaControlsHidden(app, because: "A turning tap must put the controls away")
                showMangaControls(app, expecting: "Page 1 / 3")
                // A swipe turns the page and puts them away too. Right to left: the
                // next page comes in from the left, under a drag to the right.
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
                waitForMangaControlsHidden(app, because: "Turning the page must put the controls away")
                showMangaControls(app, expecting: "Page 2 / 3")
            }
            app.navigationBars.buttons["Back"].tap()
            XCTAssertTrue(read.waitForExistence(timeout: 8), "Back must return to the same detail.\n\(app.debugDescription)")
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: progress)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 8), .completed, app.debugDescription)
        }
    }

    /// The report's recipe on TestFlight build 5 (iOS 17, 2026-10-02): the 搜索 tab's own
    /// page in Simplified Chinese, a manga result, its detail, the manga reader and back,
    /// three times over. With 最近閱讀's reader as a second item destination on the search
    /// page, iOS 17.5 froze on the first tap of the result (Technotes/iOS17ReaderNavigationWatchdog.md);
    /// with that freeze removed, the second round's reader no longer left on Back.
    @MainActor
    func testSearchTabMangaResultOpensEveryTime() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
                               "-yd_root_tab_visible_ids", "(bookshelf, explore, settings, search)"]
        app.launch()
        let searchTab = app.tabBars.buttons["搜索"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 15), app.debugDescription)
        searchTab.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15), app.debugDescription)
        search.tap()
        search.typeText("manga fixture\n")
        // iOS 17 lists results in a UIKit table, later systems in a SwiftUI list.
        let result = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND (elementType == %d OR elementType == %d)",
                                  "Navigation Manga Fixture", XCUIElement.ElementType.cell.rawValue,
                                  XCUIElement.ElementType.button.rawValue)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), app.debugDescription)
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["立即阅读", "继续阅读"])).firstMatch
        let readerBack = app.navigationBars.buttons["返回"]
        for round in 1...3 {
            result.tap()
            XCTAssertTrue(read.waitForExistence(timeout: 15), "Round \(round): the result must open its detail.\n\(app.debugDescription)")
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: read)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
            read.tap()
            waitForMangaPage(app)
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(readerBack.waitForExistence(timeout: 8), app.debugDescription)
            if round == 1 {
                // The reported screenshot is a continuous image strip. Cover it as
                // well as the paged reader in the following entry rounds.
                app.buttons["阅读设定"].tap()
                let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "阅读模式")).firstMatch
                XCTAssertTrue(mode.waitForExistence(timeout: 5), app.debugDescription)
                let close = app.buttons["关闭"].firstMatch
                XCTAssertTrue(close.isHittable, app.debugDescription)
                attachScreenshot(app, named: "Manga reading settings - search detail")
                mode.tap()
                app.buttons["条漫"].firstMatch.tap()
                close.tap()
                let page = app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", "webtoon_page_")).firstMatch
                XCTAssertTrue(page.waitForExistence(timeout: 15), app.debugDescription)
            }
            let progress = app.sliders["阅读进度"]
            XCTAssertTrue(progress.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(progress.isHittable, "The search reader's native progress control must be usable")
            let bottomBar = app.toolbars.firstMatch
            XCTAssertTrue(bottomBar.exists, app.debugDescription)
            XCTAssertGreaterThanOrEqual(progress.frame.minY, bottomBar.frame.minY)
            XCTAssertLessThanOrEqual(progress.frame.maxY, bottomBar.frame.maxY)
            attachScreenshot(app, named: "Search tab manga - native bottom bar - round \(round)")
            if round == 1 {
                app.buttons["阅读设定"].tap()
                let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "阅读模式")).firstMatch
                XCTAssertTrue(mode.waitForExistence(timeout: 5), app.debugDescription)
                let close = app.buttons["关闭"].firstMatch
                XCTAssertTrue(close.isHittable, app.debugDescription)
                attachScreenshot(app, named: "Manga reading settings - search detail - webtoon")
                // Reading mode persists. Restore paged mode explicitly before
                // reopening the book in the following entries.
                mode.tap()
                app.buttons["从右到左"].firstMatch.tap()
                close.tap()
                XCTAssertTrue(app.images["fixed_page_image"].waitForExistence(timeout: 15), app.debugDescription)
            }
            readerBack.tap()
            XCTAssertTrue(read.waitForExistence(timeout: 8), "Round \(round): Back must return to the detail.\n\(app.debugDescription)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            let left = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: read)
            XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 8), .completed,
                           "Round \(round): Back must return to the results.\n\(app.debugDescription)")
        }
    }

    /// The shelf opens a manga with its card push, whose bar belongs to the shelf's
    /// UIKit navigation controller rather than to a SwiftUI stack. The book is added
    /// right before the app leaves the foreground and is killed: the shelf saves on a
    /// debounce, and leaving the foreground has to write it (it once lost the book).
    @MainActor
    func testShelfMangaOpensOnThePage() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "42017D70-DAD6-4EDE-845E-C5DBAC606CA4"]
        app.launch()
        let source = app.buttons["explore.source.Navigation Manga Fixture"]
        XCTAssertTrue(source.waitForExistence(timeout: 15), app.debugDescription)
        source.tap()
        let discovered = app.buttons["Navigation Manga Fixture, Regression"].firstMatch
        XCTAssertTrue(discovered.waitForExistence(timeout: 20), app.debugDescription)
        discovered.tap()
        let add = app.buttons["Bookmarked"]
        let remove = app.buttons["Remove from Library"]
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Bookmarked", "Remove from Library"])).firstMatch.waitForExistence(timeout: 15))
        if add.exists {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
            add.tap()
            XCTAssertTrue(remove.waitForExistence(timeout: 10), app.debugDescription)
        }
        XCUIDevice.shared.press(.home)
        let left = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed)
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings)", "-bookLayoutIsGrid", "NO"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Navigation Manga Fixture")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 15), app.debugDescription)
        book.tap()
        waitForMangaPage(app)
        showMangaControls(app, expecting: "Page 1 / 3")
        attachScreenshot(app, named: "Manga reader - shelf")
        app.buttons["Reading Settings"].tap()
        let mode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading Mode")).firstMatch
        XCTAssertTrue(mode.waitForExistence(timeout: 5), app.debugDescription)
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.isHittable, app.debugDescription)
        attachScreenshot(app, named: "Manga reading settings - shelf")
        close.tap()
        XCTAssertTrue(app.sliders["Progress"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons["Back"].tap()
        XCTAssertTrue(book.waitForExistence(timeout: 8), "Back must return to the shelf.\n\(app.debugDescription)")
    }

    /// A pinch zooms a fixed page in and back out, and a double tap zooms without its
    /// first tap doing anything else. Each page used to sit in a second, disabled zoom
    /// layer that still claimed the pinch, so a double tap was the only way to zoom —
    /// and the reader's single tap did not wait for it, so on a turning zone the first
    /// tap of a double tap turned the page. A zoomed page turned away from and back to
    /// is still zoomed, as in Aidoku.
    @MainActor
    func testMangaPageZoomsWithPinchAndDoubleTap() throws {
        let app = try openMangaFromExplore()
        let fitted = try XCTUnwrap(pageFrameOnScreen(app), app.debugDescription)
        let isFitted = { (frame: CGRect) in
            abs(frame.width - fitted.width) < 2 && abs(frame.minX - fitted.minX) < 2 && abs(frame.minY - fitted.minY) < 2
        }
        app.pinch(withScale: 2.5, velocity: 1)
        waitForPageOnScreen(app, because: "A pinch out must zoom the page in") { $0.width > fitted.width * 1.5 }
        attachScreenshot(app, named: "Manga reader - pinched in")
        app.pinch(withScale: 0.3, velocity: -1)
        waitForPageOnScreen(app, because: "A pinch in must bring the page back to its fitted size and place", isFitted)

        // Right to left: the left side is the next-page zone.
        let nextZone = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let previousZone = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        nextZone.doubleTap()
        waitForPageOnScreen(app, because: "A double tap on a turning zone must zoom in") { $0.width > fitted.width * 1.5 }
        let zoomed = try XCTUnwrap(pageFrameOnScreen(app))
        let isZoomedAsLeft = { (frame: CGRect) in
            abs(frame.width - zoomed.width) < 2 && abs(frame.minX - zoomed.minX) < 2 && abs(frame.minY - zoomed.minY) < 2
        }
        nextZone.tap()
        waitForPageOnScreen(app, because: "The next page must open at its fitted size", isFitted)
        previousZone.tap()
        waitForPageOnScreen(app, because: "The page turned back to must still be zoomed where it was left", isZoomedAsLeft)
        // It is the first page again — and bringing the controls up leaves its zoom alone.
        showMangaControls(app, expecting: "Page 1 / 3")
        waitForPageOnScreen(app, because: "Bringing up the controls must leave the zoom alone", isZoomedAsLeft)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForMangaControlsHidden(app, because: "A tap in the middle must put the controls away")
        nextZone.doubleTap()
        waitForPageOnScreen(app, because: "A second double tap must zoom back out", isFitted)
        leaveMangaReader(app)
    }

    /// With double-tap zoom switched off in settings, a double tap is just two taps and
    /// zooms nothing; a pinch still zooms.
    @MainActor
    func testMangaDoubleTapZoomCanBeTurnedOff() throws {
        let app = try openMangaFromExplore(extraArguments: ["-yd_fixed_page_double_tap_zoom", "NO"])
        let fitted = try XCTUnwrap(pageFrameOnScreen(app), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        let zoomed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (self.pageFrameOnScreen(app)?.width ?? 0) > fitted.width * 1.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [zoomed], timeout: 2), .timedOut,
                       "With double-tap zoom off, a double tap must not zoom.\n\(app.debugDescription)")
        app.pinch(withScale: 2.5, velocity: 1)
        waitForPageOnScreen(app, because: "A pinch must still zoom") { $0.width > fitted.width * 1.5 }
        leaveMangaReader(app)
    }

    /// The webtoon strip zooms through its layout: a pinch grows the pages, a zoomed strip
    /// pans sideways, and a double tap zooms in and back out. The strip used to be scaled
    /// as one view around the middle of the screen, its sides out of reach. The reading
    /// mode is kept with the book when it is closed and opened again, and the auto-scroll
    /// button stays away until switched on in settings.
    /// The book goes on the shelf first: a book only browsed from a detail page keeps
    /// nothing once closed, its settings included.
    /// The test puts the mode back to right to left and leaves the book on the shelf, as
    /// `testShelfMangaOpensOnThePage` does; the next run needs `navigation_swipe_fixture.py`
    /// `clean` and `prepare`.
    @MainActor
    func testWebtoonStripZoomsAndPansSideways() throws {
        let app = try openMangaFromExplore(addingToLibrary: true)
        setMangaReadingMode("Webtoon", in: app)
        XCTAssertFalse(app.buttons["Start Auto-Scroll"].exists,
                       "The auto-scroll button stays away until it is switched on.\n\(app.debugDescription)")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.sliders["Progress"].waitForExistence(timeout: 5), app.debugDescription)
        app.navigationBars.buttons["Back"].tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read Now", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8), app.debugDescription)
        read.tap()
        let strip = "webtoon_page_"
        XCTAssertTrue(app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", strip))
            .firstMatch.waitForExistence(timeout: 15),
                      "Opened again, the book must still read as a webtoon.\n\(app.debugDescription)")
        // Measured on whichever page covers the middle of the screen: the book may open on
        // any page, and chapters loading around it renumber the pages.
        let fitted = try XCTUnwrap(pageFrameOnScreen(app, identifier: strip), app.debugDescription)

        app.pinch(withScale: 2.5, velocity: 1)
        waitForPageOnScreen(app, identifier: strip, because: "A pinch out must zoom the strip in") {
            $0.width > fitted.width * 1.5
        }
        attachScreenshot(app, named: "Webtoon - pinched in")
        let zoomed = try XCTUnwrap(pageFrameOnScreen(app, identifier: strip))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)))
        waitForPageOnScreen(app, identifier: strip, because: "A zoomed strip must pan sideways") {
            $0.minX < zoomed.minX - 50
        }
        app.pinch(withScale: 0.2, velocity: -1)
        waitForPageOnScreen(app, identifier: strip, because: "A pinch in must bring the strip back to the screen's width") {
            abs($0.width - fitted.width) < 2 && abs($0.minX - fitted.minX) < 2
        }

        let tapPoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4))
        tapPoint.doubleTap()
        waitForPageOnScreen(app, identifier: strip, because: "A double tap must zoom the strip to 2x") {
            abs($0.width - fitted.width * 2) < 4
        }
        tapPoint.doubleTap()
        waitForPageOnScreen(app, identifier: strip, because: "A second double tap must zoom it back out") {
            abs($0.width - fitted.width) < 2
        }

        // The three-page chapter has long pulled the next one in below. Back at its top, the
        // strip still holds each chapter once — the first page is still page 0, where a
        // second copy of this chapter used to be prepended — and the controls speak for the
        // chapter on screen, with its own page count and title.
        XCTAssertTrue(app.images["webtoon_page_0"].exists,
                      "The chapter must not be loaded above itself.\n\(app.debugDescription)")
        showMangaControls(app, expecting: "Page 1 / 3")
        XCTAssertTrue(app.navigationBars["Chapter 1"].exists,
                      "The title must stay on the chapter being read.\n\(app.debugDescription)")
        setMangaReadingMode("Right to Left", in: app)
        leaveMangaReader(app)
    }

    /// Switches the open manga's reading mode in its settings sheet, and puts the
    /// controls away again.
    @MainActor
    private func setMangaReadingMode(_ mode: String, in app: XCUIApplication,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let settings = app.buttons["Reading Settings"]
        if !settings.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(settings.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        settings.tap()
        let picker = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Reading Mode")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        picker.tap()
        let option = app.buttons[mode].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        option.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        close.tap()
        XCTAssertTrue(app.sliders["Progress"].waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        waitForMangaControlsHidden(app, because: "A tap in the middle must put the controls away", file: file, line: line)
    }

    /// Opens the manga fixture from its Explore list, on its first page — first putting it
    /// on the shelf when asked.
    @MainActor
    private func openMangaFromExplore(extraArguments: [String] = [],
                                      addingToLibrary: Bool = false) throws -> XCUIApplication {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "42017D70-DAD6-4EDE-845E-C5DBAC606CA4"]
            + extraArguments
        app.launch()
        let book = app.staticTexts["Navigation Manga Fixture"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()
        if addingToLibrary {
            let add = app.buttons["Bookmarked"]
            let remove = app.buttons["Remove from Library"]
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Bookmarked", "Remove from Library"]))
                .firstMatch.waitForExistence(timeout: 15), app.debugDescription)
            if add.exists {
                let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
                XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
                add.tap()
                XCTAssertTrue(remove.waitForExistence(timeout: 10), app.debugDescription)
            }
        }
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read Now", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: read)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
        read.tap()
        waitForMangaPage(app)
        return app
    }

    /// Leaves the reader for the detail it came from, and sends the app to the background.
    /// A book read from a detail without being shelved is a temporary one, deleted when the
    /// reader closes — but the shelf saves on a 2-second debounce, so a test that ends right
    /// after would be killed before the deletion is written, and the next test would find
    /// the book kept, opening on its last page. Leaving the foreground writes at once.
    @MainActor
    private func leaveMangaReader(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let slider = app.sliders["Progress"]
        if !slider.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(slider.waitForExistence(timeout: 5), app.debugDescription, file: file, line: line)
        app.navigationBars.buttons["Back"].tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read Now", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 8), "Back must return to the detail.\n\(app.debugDescription)",
                      file: file, line: line)
        XCUIDevice.shared.press(.home)
        let left = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [left], timeout: 10), .completed, file: file, line: line)
    }

    /// The frame of the page covering the middle of the screen, among the images whose
    /// identifier starts with `identifier`. The paged reader keeps its neighbours in the
    /// hierarchy, off screen, under the same identifier; the webtoon strip numbers its pages.
    @MainActor
    private func pageFrameOnScreen(_ app: XCUIApplication, identifier: String = "fixed_page_image") -> CGRect? {
        let middle = CGPoint(x: app.frame.midX, y: app.frame.midY)
        return app.images.matching(NSPredicate(format: "identifier BEGINSWITH %@", identifier)).allElementsBoundByIndex
            .map(\.frame)
            .first { $0.contains(middle) }
    }

    @MainActor
    private func waitForPageOnScreen(_ app: XCUIApplication, identifier: String = "fixed_page_image",
                                     because reason: String,
                                     file: StaticString = #filePath, line: UInt = #line,
                                     _ condition: @escaping (CGRect) -> Bool) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.pageFrameOnScreen(app, identifier: identifier).map(condition) ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed,
                       "\(reason); the page on screen is at \(String(describing: pageFrameOnScreen(app, identifier: identifier))).\n\(app.debugDescription)",
                       file: file, line: line)
    }

    /// The fixed-page reader opens on the page, with no controls over it.
    @MainActor
    private func waitForMangaPage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.images["fixed_page_image"].waitForExistence(timeout: 30),
                      "The first page's image must be on screen.\n\(app.debugDescription)", file: file, line: line)
        XCTAssertFalse(app.sliders["Progress"].exists,
                       "The manga reader must open on the page, without its controls", file: file, line: line)
    }

    /// A tap in the middle brings the controls up. The progress slider speaks the
    /// page indicator (第 %d / %d 頁); chapter 1 has three pages.
    @MainActor
    private func showMangaControls(_ app: XCUIApplication, expecting indicator: String,
                                   file: StaticString = #filePath, line: UInt = #line) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // `exists` first: reading `value` of a missing element fails the test outright.
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND value == %@", indicator), object: app.sliders["Progress"])
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 10), .completed,
                       "The controls must show \(indicator).\n\(app.debugDescription)", file: file, line: line)
    }

    @MainActor
    private func waitForMangaControlsHidden(_ app: XCUIApplication, because reason: String,
                                            file: StaticString = #filePath, line: UInt = #line) {
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.sliders["Progress"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed,
                       "\(reason).\n\(app.debugDescription)", file: file, line: line)
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// With the menu up, a tap on a page-turn zone only puts the menu away, as in
    /// Apple Books and legado; the next tap turns the page.
    @MainActor
    func testTapWithMenuUpOnlyPutsMenuAway() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_appearance_reader_interface", "classic",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        let book = app.staticTexts["Navigation Swipe Fixture"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read Now", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: read)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        let originalPage = content.label
        let menu = app.buttons["reader_back_button"]
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        // The middle row's right third turns to the next page.
        let nextPageZone = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        nextPageZone.tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed, app.debugDescription)
        XCTAssertEqual(content.label, originalPage, "The tap that puts the menu away must not also turn the page")
        nextPageZone.tap()
        let pageChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            content.exists && content.label != originalPage
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pageChanged], timeout: 5), .completed, "With the menu away, the tap turns the page")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.tap()
        XCTAssertTrue(read.waitForExistence(timeout: 8), app.debugDescription)
    }

    @MainActor func testSlideTurnHidesMenu() throws { try exerciseMenuHidesOnPageTurn(style: "滑動") }
    @MainActor func testCoverTurnHidesMenu() throws { try exerciseMenuHidesOnPageTurn(style: "覆蓋翻頁") }
    @MainActor func testCurlTurnHidesMenu() throws { try exerciseMenuHidesOnPageTurn(style: "仿真翻書") }
    @MainActor func testInstantTurnHidesMenu() throws { try exerciseMenuHidesOnPageTurn(style: "無動畫") }
    @MainActor func testScrollHidesMenu() throws { try exerciseMenuHidesOnPageTurn(style: "滑動", scroll: true) }

    /// Turning the page with the menu up puts the menu away, whichever gesture
    /// turned it: each page-turn style has its own (UIKit's swipe, the cover pan,
    /// the instant pan), and scroll mode turns by dragging.
    @MainActor
    private func exerciseMenuHidesOnPageTurn(style: String, scroll: Bool = false) throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_appearance_reader_interface", "classic",
                               "-yd_page_turn_style", style, "-yd_scroll_mode", scroll ? "YES" : "NO"]
        app.launch()
        let book = app.staticTexts["Navigation Swipe Fixture"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read Now", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: read)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed, app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        let originalPage = content.label
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let menu = app.buttons["reader_back_button"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        // Across the middle of the page, clear of the menu's bars and the back-swipe edge.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: scroll ? 0.5 : 0.8, dy: scroll ? 0.6 : 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: scroll ? 0.5 : 0.2, dy: scroll ? 0.4 : 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed,
                       "Turning the page must put the menu away.\n\(app.debugDescription)")
        if !scroll {
            let pageChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                content.exists && content.label != originalPage
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [pageChanged], timeout: 5), .completed, "The drag must also turn the page")
        }
        // The menu still comes back on a tap; leaving through it releases the trial book.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
        menu.tap()
        XCTAssertTrue(read.waitForExistence(timeout: 8), app.debugDescription)
    }

    @MainActor
    func testClassicReaderControlsFromExploreAreAccessible() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_appearance_reader_interface", "classic",
                               "-yd_page_turn_style", "滑動", "-yd_scroll_mode", "NO"]
        app.launch()
        let book = app.staticTexts["Navigation Swipe Fixture"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read Now", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader_back_button"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertFalse(app.textFields["Enter URL or search"].exists, "The covered browser must leave the accessibility tree")
        for label in ["Contents", "Settings", "Next"] {
            let button = app.buttons[label].firstMatch
            XCTAssertTrue(button.exists, app.debugDescription)
            XCTAssertTrue(button.isHittable, app.debugDescription)
        }
        app.buttons["Contents"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Chapter 2"].firstMatch.waitForExistence(timeout: 5), app.debugDescription)
    }

    @MainActor
    func testShelfListExposesOneBookButtonAndOpensReader() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4"]
        app.launch()
        let discovered = app.staticTexts["Navigation Swipe Fixture"].firstMatch
        XCTAssertTrue(discovered.waitForExistence(timeout: 20), app.debugDescription)
        discovered.tap()
        let remove = app.buttons["Remove from Library"]
        let add = app.buttons["Bookmarked"]
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label IN %@", ["Bookmarked", "Remove from Library"])).firstMatch.waitForExistence(timeout: 15))
        if add.exists {
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: add)
            XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 15), .completed)
            add.tap()
            XCTAssertTrue(remove.waitForExistence(timeout: 10), app.debugDescription)
        }
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings)",
                               "-bookLayoutIsGrid", "NO", "-yd_appearance_reader_interface", "classic"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Navigation Swipe Fixture，Regression"))
        XCTAssertTrue(book.firstMatch.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertEqual(book.count, 1, "A list book must expose one combined activation target")
        book.firstMatch.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
    }

    @MainActor
    func testListeningStartsCapsuleAndRolePanelRemainsAvailable() throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_tts_use_system_voice", "YES",
                               "-yd_appearance_reader_interface", "classic"]
        app.launch()
        let source = app.buttons["explore.source.Navigation Swipe Fixture"]
        XCTAssertTrue(source.waitForExistence(timeout: 15), app.debugDescription)
        source.tap()
        let book = app.buttons["Navigation Swipe Fixture, Regression"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read Now", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let listen = app.buttons["Audiobook"].firstMatch
        XCTAssertTrue(listen.waitForExistence(timeout: 5), app.debugDescription)
        listen.tap()
        let playback = app.buttons["now_playing_reader_play_pause"]
        let panelPlayback = app.buttons["tts_panel_play_pause"]
        XCTAssertTrue(playback.waitForExistence(timeout: 15), "Listening must show the floating capsule.\n\(app.debugDescription)")
        func awaitPlaybackLabel(_ label: String, line: UInt = #line) {
            let state = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: playback)
            XCTAssertEqual(XCTWaiter.wait(for: [state], timeout: 10), .completed, app.debugDescription, line: line)
            XCTAssertFalse(panelPlayback.exists, "Listening must keep the full TTS panel closed", line: line)
        }
        awaitPlaybackLabel("Pause")
        XCTAssertTrue(playback.isHittable, app.debugDescription)
        playback.tap()
        awaitPlaybackLabel("Play")
        XCTAssertTrue(listen.waitForExistence(timeout: 5), app.debugDescription)
        listen.tap()
        awaitPlaybackLabel("Pause")
        XCTAssertTrue(listen.waitForExistence(timeout: 5), app.debugDescription)
        listen.tap()
        awaitPlaybackLabel("Pause")
        attachScreenshot(app, named: "Listening starts the floating capsule")
        app.buttons["now_playing_reader_open_panel"].tap()
        XCTAssertTrue(panelPlayback.waitForExistence(timeout: 5), "The capsule must still open the full controls on demand.\n\(app.debugDescription)")
        let roles = app.buttons["Multi-voice narration"].firstMatch
        XCTAssertTrue(roles.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(roles.isHittable)
        roles.tap()
        XCTAssertTrue(app.navigationBars["Multi-voice narration"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(app.buttons["Reset"].firstMatch.exists, app.debugDescription)
    }

    @MainActor func testSlideEdgeBack() throws { try exerciseReader(style: "滑動") }
    @MainActor func testCoverEdgeBack() throws { try exerciseReader(style: "覆蓋翻頁") }
    @MainActor func testCurlEdgeBack() throws { try exerciseReader(style: "仿真翻書") }
    @MainActor func testInstantEdgeBack() throws { try exerciseReader(style: "無動畫") }
    @MainActor func testScrollEdgeBack() throws { try exerciseReader(style: "滑動", scroll: true) }

    @MainActor
    private func exerciseReader(style: String, scroll: Bool = false) throws {
        continueAfterFailure = false
        try configureStoreKit()
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(explore, settings)",
                               "-discover.selectedSourceId", "C5DED179-61D0-49C4-BDB7-93A7B3DAD8F4",
                               "-yd_page_turn_style", style, "-yd_scroll_mode", scroll ? "YES" : "NO"]
        app.launch()
        let book = app.staticTexts["Navigation Swipe Fixture"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), app.debugDescription)
        book.tap()
        let read = app.buttons.matching(NSPredicate(format: "label IN %@", ["Read Now", "Continue Reading"])).firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 15), app.debugDescription)
        read.tap()
        let content = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Reserved edge navigation")).firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 30), app.debugDescription)
        let originalPage = content.label
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5))
        let shortDrag = app.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
        // The hold belongs to the user's gesture: releasing a short, stationary
        // drag must cancel, preserving the same reader and reading position.
        edge.press(forDuration: 0.05, thenDragTo: shortDrag, withVelocity: .slow, thenHoldForDuration: 0.3)
        XCTAssertTrue(content.waitForExistence(timeout: 5))
        XCTAssertEqual(content.label, originalPage)
        XCTAssertFalse(read.exists)

        // Interior pans must still turn pages / scroll, without navigating back.
        let interior = app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.7))
        let next = app.coordinate(withNormalizedOffset: CGVector(dx: scroll ? 0.8 : 0.2, dy: scroll ? 0.35 : 0.7))
        interior.press(forDuration: 0.05, thenDragTo: next)
        XCTAssertFalse(read.exists)
        if !scroll {
            let pageChanged = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                content.exists && content.label != originalPage
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [pageChanged], timeout: 5), .completed, "Interior pan must turn the page")
        }

        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        // Also exercise the reserved strip away from the physical screen edge.
        let reservedStrip = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 28, dy: app.frame.height * 0.5))
        reservedStrip.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(read.waitForExistence(timeout: 8), "Edge drag must pop to the original detail.\n\(app.debugDescription)")
        XCTAssertFalse(content.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Returned to detail - \(style) - scroll \(scroll)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // SwiftUI's route must also be reconciled, so reopening works normally.
        read.tap()
        XCTAssertTrue(content.waitForExistence(timeout: 15))
        edge.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(read.waitForExistence(timeout: 8))
    }
}
