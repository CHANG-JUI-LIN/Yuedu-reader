import UIKit
import YueduCoreText

// MARK: - PageIndexProviding / CoreTextReadingPositionProviding

/// A UIViewController that tracks its position in the global page sequence.
@MainActor
protocol PageIndexProviding: AnyObject {
    var globalPageIndex: Int { get }
}

@MainActor
protocol CoreTextReadingPositionProviding: AnyObject {
    var coreTextReadingPosition: CoreTextReadingPosition? { get }
}

// MARK: - Capability-Based Reader Engine Contracts

@MainActor
protocol LayoutLifecycle: AnyObject {
    var totalPages: Int { get }
    var currentPage: Int { get }
    var layouts: [Int: CoreTextPaginator.ChapterLayout] { get }
    var renderSize: CGSize { get }
    var offsetStore: CharOffsetStore { get }

    func start(renderSize: CGSize, bookId: String) async
    func preloadChapter(at spineIndex: Int) async
    func invalidateLayout(newSize: CGSize) async
    func warmUpNext(currentGlobalPage: Int)
    func cancelPendingWork()
    func notifyChapterDataChanged(at spineIndex: Int) async

    var onChapterReady: ((Int?) -> Void)? { get set }
    var onNavigateToPage: ((Int) -> Void)? { get set }
}

@MainActor
protocol StablePositionResolving: AnyObject {
    /// Chapter + charOffset -> global page index.
    func pageIndex(forSpine spineIndex: Int, charOffset: Int) -> Int
    /// Stable position -> exact global page index when the layout is ready.
    func pageIndex(for position: CoreTextReadingPosition) -> Int?
    /// Stable position -> best available global page estimate.
    func estimatedGlobalPage(for position: CoreTextReadingPosition) -> Int?
    /// Global page -> stable position when the layout is ready.
    func readingPosition(forPage page: Int) -> CoreTextReadingPosition?
    /// Global page -> (spineIndex, charOffset).
    func charOffset(forPage page: Int) -> (spineIndex: Int, charOffset: Int)
    /// Char offset of an in-spine anchor (a TOC fragment / element id), or nil when the spine
    /// isn't laid out or the anchor is unknown. Lets callers fall back to the spine start.
    func charOffset(forSpine spineIndex: Int, fragment: String) -> Int?
    /// Global page -> (spineIndex, localPage).
    func localPosition(for globalPage: Int) -> (spineIndex: Int, localPage: Int)
    /// Global page index of the last page of a chapter.
    func lastPageIndex(ofChapter spineIndex: Int) -> Int?
}

extension StablePositionResolving {
    /// Default: engines without in-spine anchors fall back to the spine start.
    func charOffset(forSpine spineIndex: Int, fragment: String) -> Int? { nil }
}

/// Steps one page forward or backward in **position** space.
///
/// This is the identity the `UIPageViewController` data source walks. A global
/// page index is only meaningful inside the pagination that produced it — a
/// chapter laying out mid-turn renumbers every page after it — so handing UIKit
/// an index to hold on to is how "turned one page too far" keeps coming back.
/// `(spineIndex, charOffset)` survives repagination untouched.
///
/// Returns nil at the ends of the book, and whenever the engine cannot answer
/// honestly (the current page has no layout). UIKit reads nil as "no page that
/// way", which is the correct thing to show for an unmeasured neighbour.
@MainActor
protocol PagePositionWalking: AnyObject {
    func positionAfter(_ position: CoreTextReadingPosition) -> CoreTextReadingPosition?
    func positionBefore(_ position: CoreTextReadingPosition) -> CoreTextReadingPosition?
}

extension PagePositionWalking where Self: StablePositionResolving & LayoutLifecycle {
    /// Index-derived fallback for engines whose page space is not driven by
    /// `ChapterLayout.pageRanges` — today the fixed-layout and browser-layout
    /// engines. Fixed layout never renumbers, so the derivation is exact there.
    /// The result is still converted straight back to a position, so nothing
    /// outside this method ever holds an index.
    func positionAfter(_ position: CoreTextReadingPosition) -> CoreTextReadingPosition? {
        guard let page = pageIndex(for: position), page + 1 < totalPages else { return nil }
        return readingPosition(forPage: page + 1)
    }

    func positionBefore(_ position: CoreTextReadingPosition) -> CoreTextReadingPosition? {
        guard let page = pageIndex(for: position), page > 0 else { return nil }
        return readingPosition(forPage: page - 1)
    }
}

@MainActor
protocol ProgressResolving: AnyObject {
    func plainText(forPage page: Int) -> String
    func totalProgress(forSpine spineIndex: Int, charOffset: Int) -> Double
    func position(forProgress progress: Double) -> (spineIndex: Int, charOffset: Int)
    func contentMetrics(
        forSpine spineIndex: Int,
        charOffset: Int,
        currentChapterCharacterCount: Int?
    ) -> ReaderContentMetrics?
}

extension ProgressResolving {
    func contentMetrics(
        forSpine spineIndex: Int,
        charOffset: Int,
        currentChapterCharacterCount: Int?
    ) -> ReaderContentMetrics? {
        nil
    }
}

@MainActor
protocol InternalLinkResolving: AnyObject {
    func resolveInternalLink(_ href: String, fromSpineIndex spineIndex: Int) async -> Int?
}

/// Engines that surface link taps to the reader. The reader binds this callback
/// through this protocol (cast at CoreTextPagedView), so non-CoreText engines
/// (browser-layout) can drive link navigation too.
///
/// Footnotes are deliberately NOT here. A note is shown as a popover anchored to
/// the marker that was tapped, which only the view that owns the tap can do —
/// routing the text up to SwiftUI could only produce an unanchored sheet, and
/// that sheet was retired.
@MainActor
protocol LinkNavigationProviding: AnyObject {
    var onLinkNavigate: ((Int) -> Void)? { get set }
}

@MainActor
protocol ThemeUpdatable: AnyObject {
    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor)
    func updateRenderSettings(_ settings: ReaderRenderSettings)
}

@MainActor
protocol AnnotationApplying: AnyObject {
    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation])
}

/// Rasterised pixels of a page, for animation overlays only — the cover
/// transition's incoming/outgoing image views and the curl back face.
/// Deliberately NOT a way to stand in for a page in the data source: a page's
/// identity is its reading position, and an image cannot carry one.
@MainActor
protocol SnapshotRenderable: AnyObject {
    func renderSnapshot(forPage globalPage: Int) -> UIImage?
}

extension SnapshotRenderable {
    func renderSnapshot(forPage globalPage: Int) -> UIImage? { nil }
}

@MainActor
protocol PageViewControllerVending: AnyObject {
    func pageViewController(at index: Int) -> UIViewController
    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController
}

extension PageViewControllerVending where Self: StablePositionResolving {
    func pageViewController(for position: CoreTextReadingPosition) -> UIViewController {
        if let page = pageIndex(for: position) {
            return pageViewController(at: page)
        }
        return pageViewController(at: 0)
    }
}

typealias PagedReaderEngine =
    LayoutLifecycle
    & StablePositionResolving
    & PagePositionWalking
    & ProgressResolving
    & InternalLinkResolving
    & ThemeUpdatable
    & AnnotationApplying
    & SnapshotRenderable
    & PageViewControllerVending

typealias ScrollReaderEngine =
    ThemeUpdatable
    & AnnotationApplying

typealias PageRenderingProvider = PagedReaderEngine
