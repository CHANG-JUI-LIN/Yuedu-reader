import UIKit
import YueduCoreText

/// Why every laid-out chapter is about to be discarded.
///
/// Bumping the layout generation is the most expensive thing the paging engines do — it
/// throws away every finished layout and cancels every preload in flight. A blind user's
/// export showed the generation climbing 3 → 9 in 53 seconds, with one chapter re-preloaded
/// four times inside a single second; the retries were visible but the cause was not.
/// Naming the caller is what makes that log answerable.
enum LayoutInvalidationCause: String {
    case refreshTransaction
    case engineModeSwitch
    case renderSizeChange
    case fontOrMarginChange
    case cjkFontInstalled
    /// The app changed lifecycle phase and nothing was narrating.
    case appPhaseChange
    case unspecified
}

/// How one attempt to lay a chapter out ended.
///
/// `preloadChapter` used to return `Void` through six different exits, five of them
/// silent. Every caller therefore saw the same thing when a chapter failed to
/// appear — the 載入中 page on screen, the TTS session waiting for text,
/// `notifyChapterDataChanged` — namely "there is no layout", with nothing to say why.
///
/// That is the shape behind three long-standing intermittent reports that are really
/// one bug: 朗讀斷在章末, 劃到下一章卡住轉圈圈, and 往回劃一次再往前就正常了. The
/// last of those is the tell: the second attempt succeeds, so the layout was always
/// buildable and the first attempt died somewhere unrecorded.
///
/// Only `CoreTextPageEngine` distinguishes all of these today; the other engines
/// answer with the two they can actually tell apart.
enum ChapterLayoutOutcome: String, Sendable {
    /// A full (non-partial) layout was already installed.
    case alreadyLaidOut
    /// This attempt built and installed one.
    case laidOut
    /// The generation moved on mid-flight, so this attempt's work was discarded.
    /// Someone called `cancelPendingWork` — its `cause` names who.
    case supersededByGeneration
    /// The task was cancelled.
    case cancelled
    /// The chapter's document could not be built: for an online book, content that
    /// has not been fetched yet. Not an error — but also not something that resolves
    /// on its own for a local book, where no fetch will follow.
    case contentUnavailable
    /// Building the document threw. The error is logged at the point it was caught.
    case buildFailed
    case outOfRange

    /// True when the chapter is renderable now. The three consumers of `layouts` all
    /// branch on exactly this, and everything else is a reason for the log.
    var isReady: Bool { self == .alreadyLaidOut || self == .laidOut }
}

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
    @discardableResult
    func preloadChapter(at spineIndex: Int) async -> ChapterLayoutOutcome
    func invalidateLayout(newSize: CGSize) async
    func warmUpNext(currentGlobalPage: Int)
    func cancelPendingWork(cause: LayoutInvalidationCause)
    func notifyChapterDataChanged(at spineIndex: Int) async
    func notifyChapterDataAvailable(at spineIndex: Int) async -> ChapterLayoutOutcome
    /// The reader's authoritative stable destination/settled position, before loading.
    func updateReadingPosition(_ position: CoreTextReadingPosition)

    var onChapterReady: ((Int?) -> Void)? { get set }
    var onNavigateToPage: ((Int) -> Void)? { get set }

    /// An attempt to lay a chapter out ended without one, while a placeholder for that
    /// chapter is what the reader is looking at.
    ///
    /// The counterpart to `onChapterReady`, and needed for the same reason: a layout
    /// that never arrives is as much a fact about the chapter as one that does, and
    /// without this the paged view could see the 載入中 page but never learn that the
    /// attempt behind it had already given up.
    var onChapterLayoutUnresolved: ((Int, ChapterLayoutOutcome) -> Void)? { get set }
}

extension LayoutLifecycle {
    func updateReadingPosition(_ position: CoreTextReadingPosition) {}

    func notifyChapterDataAvailable(at spineIndex: Int) async -> ChapterLayoutOutcome {
        await preloadChapter(at: spineIndex)
    }
}

/// Where a char offset sits inside its own chapter, and how many pages that
/// chapter has.
///
/// The reader used to read both straight off `layouts[spine]`. `layouts` is the
/// **legacy paginator's** dictionary: the browser engine renders chapters that
/// never appear in it, so every caller that reached in there saw a chapter with
/// no layout at all — an empty `1/N` footer, "0 pages left", a progress save
/// that silently skipped, and a TTS follow that gave up before it started.
struct ChapterPagination: Equatable {
    /// 0-based page index, within the chapter, of the requested char offset.
    let localPageIndex: Int
    /// Page count for progress math: exact once the chapter is fully
    /// paginated, the extrapolated estimate while it is still partial.
    let displayPageCount: Int
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

    /// Where `charOffset` sits in its chapter's pages — and, by returning nil,
    /// the single honest answer to "is this chapter laid out yet".
    ///
    /// Ask this instead of testing `layouts[spineIndex] != nil`: an engine is
    /// free to keep its layouts somewhere other than the legacy paginator's
    /// dictionary, and the browser engine does.
    func chapterPagination(forSpine spineIndex: Int, charOffset: Int) -> ChapterPagination?

    /// The chapter's plain text in the same offset space as `charOffset`, or
    /// nil when the chapter is not laid out.
    ///
    /// Materialises the whole chapter, so callers that only need "is it laid
    /// out" or a page number must use `chapterPagination` instead.
    func chapterText(forSpine spineIndex: Int) -> String?
    func chapterPronunciationHints(forSpine spineIndex: Int) -> [TTSPronunciationHint]

    /// Element id → char offset for one chapter (TOC fragments, EPUB CFI), or
    /// nil when the chapter is not laid out.
    func chapterAnchorOffsets(forSpine spineIndex: Int) -> [String: Int]?
}

extension StablePositionResolving {
    func chapterPronunciationHints(forSpine spineIndex: Int) -> [TTSPronunciationHint] { [] }
    /// Default: engines without in-spine anchors fall back to the spine start.
    func charOffset(forSpine spineIndex: Int, fragment: String) -> Int? { nil }
}

extension StablePositionResolving where Self: LayoutLifecycle {
    /// Default for every engine whose page space IS `layouts` — the CoreText
    /// paged, TXT and fixed-layout engines. `BrowserLayoutPageEngine` overrides
    /// all three, because its chapters live outside that dictionary.
    func chapterPagination(forSpine spineIndex: Int, charOffset: Int) -> ChapterPagination? {
        guard let layout = layouts[spineIndex], !layout.pageRanges.isEmpty else { return nil }
        return ChapterPagination(
            localPageIndex: layout.pageIndex(for: charOffset),
            displayPageCount: layout.displayPageCount
        )
    }

    func chapterText(forSpine spineIndex: Int) -> String? {
        layouts[spineIndex]?.attributedString.string
    }

    func chapterAnchorOffsets(forSpine spineIndex: Int) -> [String: Int]? {
        layouts[spineIndex]?.anchorOffsets
    }
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
