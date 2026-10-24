import XCTest

/// Sorted by 最近閱讀, opening a book from low on the shelf moves it to the front. Closing
/// it must bring the shelf back to the top, where the book now is, so the closing card has
/// somewhere to land — before, it shrank into a stand-in card in the middle of the shelf.
///
/// Needs EPUB books on the simulator's shelf, enough of them to scroll in two columns. The
/// list takes the same path (`HomeView.shelfScrollToTopRequest`), but a portrait-only
/// iPhone shelf needs more books than the test simulator holds before a list scrolls.
final class ReaderCloseRecentSortUITests: XCTestCase {

    /// Reflowable books on the test simulator's shelf; they open with the card transition.
    /// PDFs and comics open modally and cannot exercise it.
    private static let cardTitles = ["Alice", "紅樓夢", "こころ", "운수 좋은 날"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testClosingABookThatMovedToTheFrontShowsItAtTheTopOfTheGrid() throws {
        // Two columns, so a few books are enough to scroll.
        let app = launchShelf(["-bookLayoutIsGrid", "YES",
                               "-yd_bookshelf_grid_column_count", "<integer>2</integer>"])
        try closeBookFromBottom(of: app.scrollViews["home_book_grid"], in: app)
    }

    // MARK: - Helpers

    @MainActor
    private func launchShelf(_ layout: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-no-official-modules", "-onboarding.completed", "YES", "-AppleLanguages", "(en)",
                               "-yd_root_tab_visible_ids", "(bookshelf, settings)",
                               "-bookSortOrder", "recentlyRead",
                               "-yd_appearance_reader_interface", "classic"] + layout
        app.launch()
        return app
    }

    /// Scrolls `shelf` down, opens its lowest reflowable book, closes it, and checks the
    /// shelf came back to its top with that book leading it.
    @MainActor
    private func closeBookFromBottom(of shelf: XCUIElement, in app: XCUIApplication) throws {
        XCTAssertTrue(shelf.waitForExistence(timeout: 20), app.debugDescription)
        let topBook = shelf.buttons.element(boundBy: 0)
        XCTAssertTrue(topBook.waitForExistence(timeout: 10), app.debugDescription)
        let topLabel = topBook.label
        shelf.swipeUp()
        shelf.swipeUp()
        let formerTop = shelf.buttons[topLabel]
        XCTAssertFalse(formerTop.exists && formerTop.isHittable, "the shelf should be scrolled past its first book")

        let books = shelf.buttons.allElementsBoundByIndex
        guard let target = books.last(where: { book in
            Self.cardTitles.contains { book.label.hasPrefix($0) }
        }), target.label != topLabel,
              let title = Self.cardTitles.first(where: { target.label.hasPrefix($0) }) else {
            XCTFail("no reflowable book below the first one: \(books.map(\.label))")
            return
        }
        target.tap()

        // In the reader: bring up its chrome and leave through the back button.
        let back = app.buttons["reader_back_button"]
        let readerShown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if back.exists { return true }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [readerShown], timeout: 30), .completed, app.debugDescription)
        back.tap()

        XCTAssertTrue(shelf.waitForExistence(timeout: 10), app.debugDescription)
        let first = shelf.buttons.element(boundBy: 0)
        XCTAssertTrue(first.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(first.label.hasPrefix(title), "the book just read should lead the shelf: \(first.label)")
        XCTAssertTrue(first.isHittable, "the shelf should be back at the top, where the book now is")
    }
}
