import UIKit

// MARK: - Reader protocols
//
// The container (`MangaReaderViewController`) drives one of several mode readers
// (paged / webtoon) through `MangaModeReader`, and they call back through
// `MangaReaderContainer`.

@MainActor
protocol MangaModeReader: UIViewController {
    var container: MangaReaderContainer? { get set }
    /// Replace the displayed chapter's pages and jump to `startPage`.
    func setPages(_ pages: [MangaPage], startPage: Int)
    /// Current page index within the chapter.
    func currentPageIndex() -> Int
    /// Jump to a page (e.g. from the slider).
    func goToPage(_ index: Int, animated: Bool)
}

@MainActor
protocol MangaReaderContainer: AnyObject {
    func reader(didMoveToPage page: Int, total: Int)
    func readerRequestsNextChapter()
    func readerRequestsPreviousChapter()
    func readerToggleControls()
}
