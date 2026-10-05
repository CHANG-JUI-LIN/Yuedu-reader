import XCTest

/// 搜索's 最近閱讀 list shows while the search field is active. Pushed onto the search
/// page's stack from there, the reader kept a navigation bar it had hidden: the active
/// `UISearchController` puts back the bar it collapsed as the push starts, so the classic
/// top bar sat a bar's height (54pt) below where the shelf puts it (reported 2026-10-05
/// with a TXT and an EPUB). 最近閱讀 now opens the book full screen.
///
/// Uses the books already on the simulator's shelf, like `ReaderCloseRecentSortUITests`.
final class RecentReadingReaderChromeUITests: XCTestCase {
    private static let bookTitles = ["Alice", "紅樓夢", "こころ", "운수 좋은 날"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRecentReadingReaderTopBarSitsWhereTheShelfPutsIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings, search)",
                               "-bookSortOrder", "recentlyRead",
                               "-bookLayoutIsGrid", "NO",
                               "-yd_appearance_reader_interface", "classic"]
        app.launch()

        let shelfBook = app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@ OR label BEGINSWITH[c] %@",
            Self.bookTitles[0], Self.bookTitles[1], Self.bookTitles[2], Self.bookTitles[3]
        )).firstMatch
        XCTAssertTrue(shelfBook.waitForExistence(timeout: 20), app.debugDescription)
        let title = try XCTUnwrap(Self.bookTitles.first { shelfBook.label.hasPrefix($0) })
        shelfBook.tap()
        let fromShelf = try readerBackButtonFrame(in: app)
        app.buttons["reader_back_button"].tap()

        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 10), app.debugDescription)
        searchTab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
        field.tap()
        let recentBook = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        XCTAssertTrue(recentBook.waitForExistence(timeout: 10), app.debugDescription)
        recentBook.tap()
        let fromRecents = try readerBackButtonFrame(in: app)
        attachScreenshot(app, named: "Reader menu - from 最近閱讀")

        XCTAssertEqual(fromRecents.minY, fromShelf.minY, accuracy: 1,
                       "最近閱讀's reader top bar moved: shelf \(fromShelf), recents \(fromRecents)")

        // Closing comes back to 最近閱讀 as it was left.
        app.buttons["reader_back_button"].tap()
        XCTAssertTrue(recentBook.waitForExistence(timeout: 10), app.debugDescription)
    }

    /// Opens the reader's menu and returns its back button's frame.
    @MainActor
    private func readerBackButtonFrame(in app: XCUIApplication) throws -> CGRect {
        let back = app.buttons["reader_back_button"]
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if back.exists, back.isHittable { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 30), .completed, app.debugDescription)
        return back.frame
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
