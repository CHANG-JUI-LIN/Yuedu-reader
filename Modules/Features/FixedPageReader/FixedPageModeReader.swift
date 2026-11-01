import UIKit

// MARK: - Reader protocols
//
// The container (`FixedPageReaderViewController`) drives one of several mode readers
// (paged / webtoon) through `FixedPageModeReader`, and they call back through
// `FixedPageReaderContainer`.

@MainActor
protocol FixedPageModeReader: UIViewController {
    var container: FixedPageReaderContainer? { get set }
    /// Replace the displayed chapter's pages and jump to `startPage`.
    func setPages(_ pages: [FixedPage], startPage: Int)
    /// Index of the page on screen among the pages the reader holds. The paged reader
    /// holds one chapter; the webtoon strip counts straight through every chapter it holds
    /// (the container maps it back with `FixedPageHeldChapters`).
    func currentPageIndex() -> Int
    /// Jump to a held page, counted as `currentPageIndex()` counts.
    func goToPage(_ index: Int, animated: Bool)
    /// The reader's controls came up or went away. Live Text's button on each page
    /// follows them (`FixedPageZoom.showsLiveTextButton`).
    func setControlsShown(_ shown: Bool)

    /// Auto-scroll toggle for webtoon mode.
    func stopAutoScroll()
    func toggleAutoScroll()
    var isAutoScrolling: Bool { get }
}

extension FixedPageModeReader {
    func stopAutoScroll() {}
    func toggleAutoScroll() {}
    var isAutoScrolling: Bool { false }
}

@MainActor
protocol FixedPageReaderContainer: AnyObject {
    /// The page on screen changed; `page` is a held page (see `currentPageIndex()`).
    func reader(didMoveToPage page: Int, total: Int)
    func readerRequestsNextChapter()
    func readerRequestsPreviousChapter()
    func readerAutoScrollStateChanged(_ isActive: Bool)
    /// The page started or stopped moving under a finger, a glide or auto-scroll.
    func readerContentScrollingChanged(_ isScrolling: Bool)
    /// A swipe, drag or turning tap: the controls go away. True when they were up;
    /// a tap then does only that and leaves the page where it is.
    @discardableResult
    func readerHideControlsForPageTurn() -> Bool
    func readerToggleControls()
    func readerToggleBookmark()
    func readerShowTableOfContents()

    /// Requests to fetch and append the next chapter seamlessly in infinite webtoon mode.
    func readerAppendNextChapter() async -> [FixedPage]?
    /// Requests to fetch and prepend the previous chapter seamlessly in infinite webtoon mode.
    func readerPrependPreviousChapter() async -> [FixedPage]?
    /// The page count of the chapter at the top (`atStart`) or bottom end of the strip when the
    /// strip holds more chapters than it keeps (`FixedPageHeldChapters.retainedLimit`).
    func readerSurplusChapterPageCount(atStart: Bool) -> Int?
    /// The strip let go of that chapter's pages.
    func readerDidDropChapter(atStart: Bool)
}

extension FixedPageReaderContainer {
    func readerAutoScrollStateChanged(_ isActive: Bool) {}
    func readerContentScrollingChanged(_ isScrolling: Bool) {}
    func readerAppendNextChapter() async -> [FixedPage]? { nil }
    func readerPrependPreviousChapter() async -> [FixedPage]? { nil }
    func readerSurplusChapterPageCount(atStart: Bool) -> Int? { nil }
    func readerDidDropChapter(atStart: Bool) {}
}
