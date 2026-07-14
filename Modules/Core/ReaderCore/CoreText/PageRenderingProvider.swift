import UIKit

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

@MainActor
protocol ThemeUpdatable: AnyObject {
    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor)
    func updateRenderSettings(_ settings: ReaderRenderSettings)
}

@MainActor
protocol AnnotationApplying: AnyObject {
    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation])
}

@MainActor
protocol SnapshotRenderable: AnyObject {
    func snapshotViewController(at index: Int) -> UIViewController?
    func renderSnapshot(forPage globalPage: Int) -> UIImage?
}

extension SnapshotRenderable {
    func snapshotViewController(at index: Int) -> UIViewController? { nil }
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
