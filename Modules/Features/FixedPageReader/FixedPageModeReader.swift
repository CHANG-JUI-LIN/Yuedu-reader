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
    /// Current page index within the chapter.
    func currentPageIndex() -> Int
    /// Jump to a page (e.g. from the slider).
    func goToPage(_ index: Int, animated: Bool)
}

@MainActor
protocol FixedPageReaderContainer: AnyObject {
    func reader(didMoveToPage page: Int, total: Int)
    func readerRequestsNextChapter()
    func readerRequestsPreviousChapter()
    func readerToggleControls()
    func readerToggleBookmark()
    func readerShowTableOfContents()
}
