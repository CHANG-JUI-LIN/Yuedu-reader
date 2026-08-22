import Combine
import CoreText
import Foundation
import UIKit
import YueduCoreText
import YueduCoreTextTypography

/// A lightweight value that captures where the reader stopped scrolling.
/// Committed once on scroll-end — never inside scrollViewDidScroll.
struct ScrollProgress {
    let chapter: Int
    let charOffset: Int
    let percentage: Double
}

/// Dedicated scroll-mode engine: slices each chapter's attributedString into a series of chunks for UICollectionView rendering.
/// Operates alongside the page-oriented `CoreTextPageEngine` without interfering with it.
@MainActor
final class CoreTextScrollEngine: ObservableObject, ScrollReaderEngine {

    // MARK: - Published

    /// Linear chunk array; UICollectionView maps 1:1 to cells
    @Published private(set) var chunks: [CoreTextChunk] = [] {
        didSet { geometryStoreIsStale = true }
    }
    /// chapter → index range within chunks (inclusive start, exclusive end)
    @Published private(set) var chapterRanges: [Int: Range<Int>] = [:]
    @Published private(set) var isReady: Bool = false
    @Published var textAnnotations: [CoreTextTextAnnotation] = []

    /// UTF-16 character counts retained independently of rendered chunks so
    /// scroll positions can be converted to stable book-wide content units.
    private var chapterCharacterCounts: [Int: Int] = [:]

    // MARK: - Scroll geometry

    /// Owner of every height the scroll view lays out with
    /// (`Technotes/ViewportScrollArchitecture.md` §5).
    ///
    /// At stage 1 it is populated from chunks that have *already* been laid out, so it reports
    /// exactly the numbers `CoreTextChunk.height` always did — the seam is in place, the
    /// behaviour is unchanged. Stage 3 is what lets estimates answer these queries instead, and
    /// it needs the collection view to have stopped asking chunks directly by then.
    private let geometryStore = FragmentGeometryStore()

    /// Derived, never incrementally maintained. `insert` alone has three branches that each
    /// re-derive the chunk list, and a store updated in lockstep with them would be a second
    /// bookkeeping path free to drift. The `didSet` on `chunks` makes it structurally impossible
    /// for a mutation to skip invalidation.
    ///
    /// Deliberately keyed off `chunks` only. It used to also watch `chapterRanges`, which was
    /// worse than redundant: the store *read* both, and the two are assigned one after the other,
    /// so a rebuild triggered in between saw a chunk list its ranges did not cover.
    private var geometryStoreIsStale = true

    private func rebuiltGeometryStore() -> FragmentGeometryStore {
        guard geometryStoreIsStale else { return geometryStore }
        geometryStoreIsStale = false
        geometryStore.removeAll()
        let isVertical = renderSettings.writingMode.isVertical

        // Grouped from `chunks` alone — see `ChapterOutline.grouped`.
        //
        // The first version derived the grouping from `chapterRanges` instead, and that was a
        // real defect: `chunks` and `chapterRanges` are two separately `@Published` properties
        // that `insert` assigns one after the other, so any observer running between the two
        // assignments — a SwiftUI update, a Combine subscriber, a layout pass — rebuilt the store
        // from ranges that no longer covered every chunk. The uncovered chunks fell off the end
        // of the flat index and reported an extent of zero, which the next pass then corrected.
        // That is what made a restored reading position visibly bounce before settling.
        for outline in ChapterOutline.grouped(chunks: chunks, extent: {
            isVertical ? $0.width : $0.height
        }) {
            geometryStore.setOutline(outline)
        }
        return geometryStore
    }

    /// Extent of the item at `index` along the scroll axis, as the geometry store reports it.
    ///
    /// `nil` means the index is past the end of the loaded content — the same condition the
    /// caller already has to handle when indexing `chunks`.
    func scrollExtent(at index: Int) -> CGFloat? {
        rebuiltGeometryStore().height(atFlatIndex: index)
    }

    /// Total extent of everything loaded. Stage 2's custom layout reads `contentSize` from here
    /// instead of summing `sizeForItemAt` over every item, which is what forces eager layout today.
    var loadedScrollExtent: CGFloat {
        rebuiltGeometryStore().totalHeight
    }

    /// Diagnostics only. Must always equal `chunks.count`; anything else means the geometry store
    /// and the chunk list disagree about how many items exist, which shows up on screen as items
    /// with zero extent and a reading position that lands in the wrong place.
    var geometryFragmentCount: Int {
        rebuiltGeometryStore().flatFragmentCount
    }

    /// Diagnostics only: chapter order as the geometry store sees it, which is the order the flat
    /// index walks. A mismatch with the on-screen chapter order misplaces every item after the
    /// first divergence.
    var geometryChapterOrder: [Int] {
        rebuiltGeometryStore().chapterOrder
    }

    /// Change event stream: VC subscribes to perform insertRows / contentOffset compensation
    enum Event {
        case reset(restorePosition: CoreTextReadingPosition?)
        /// Chunks landed at `range` in `chunks`. There is no top/bottom distinction any more:
        /// position is now re-derived from the reading position after every structural change,
        /// so the view never needs to know which side content arrived on in order to compensate.
        case chunksInserted(range: Range<Int>, chapter: Int)
    }
    let events = PassthroughSubject<Event, Never>()
    var onChapterContentRequired: ((Int) -> Void)?

    // MARK: - Inputs

    private let builder: any AttributedStringBuilding
    private let chapterDocumentStore: ChapterDocumentStore
    private(set) var renderSettings: ReaderRenderSettings
    private(set) var contentWidth: CGFloat = 0
    private var imageContentWidth: CGFloat?
    /// Along-scroll size of one viewport, used as the floor for a chapter that carries a
    /// publication-authored page backdrop image (see `CoreTextChunkSlicer.padForBackdrop`).
    private var viewportExtent: CGFloat = 0

    /// Chapters currently being sliced (deduplication)
    private var slicingChapters: Set<Int> = []
    /// Chapters that have been fully sliced
    private var loadedChapters: Set<Int> = []
    /// Chapters that could not be sliced because their online content was not cached yet.
    /// Was `[Int: Bool]`, where the Bool recorded a prepend direction that no longer decides
    /// anything now that `insert` places by chapter index.
    private var pendingMissingChapters: Set<Int> = []
    /// Chapters currently standing in for real content with a 載入中 placeholder chunk.
    /// Paged mode renders a placeholder page for these; scroll mode used to render
    /// nothing at all, which is why an uncached chapter appeared as a blank screen.
    private var placeholderChapters: Set<Int> = []
    /// Latest-wins guard for overlapping settings/content reslices.
    private var resliceGeneration: UInt64 = 0

    // MARK: - Init

    init(
        builder: any AttributedStringBuilding,
        renderSettings: ReaderRenderSettings,
        chapterDocumentStore: ChapterDocumentStore? = nil
    ) {
        self.builder = builder
        self.chapterDocumentStore = chapterDocumentStore
            ?? ChapterDocumentStore(builder: builder)
        self.renderSettings = renderSettings
    }

    var chapterCount: Int { builder.chapterCount }

    /// Returns the chapter title (delegates to builder)
    func chapterTitle(at index: Int) -> String { builder.chapterTitle(at: index) }

    // MARK: - Lifecycle

    /// Initial load: slices the starting chapter + adjacent chapters
    func start(
        initialChapter: Int,
        contentWidth: CGFloat,
        imageContentWidth: CGFloat? = nil,
        viewportExtent: CGFloat = 0,
        loadAdjacentChapters: Bool = true
    ) async {
        self.contentWidth = contentWidth
        self.imageContentWidth = imageContentWidth
        self.viewportExtent = viewportExtent
        let clamped = max(0, min(initialChapter, max(0, builder.chapterCount - 1)))
        await loadChapter(clamped)
        isReady = true
        guard loadAdjacentChapters else { return }
        if clamped + 1 < builder.chapterCount {
            await loadChapter(clamped + 1)
        }
        if clamped - 1 >= 0 {
            await loadChapter(clamped - 1)
        }
    }

    /// Called when near the bottom; appends the next chapter
    /// A chapter already known to be uncached is skipped: it is standing on a loading
    /// placeholder and its fetch is already requested, so `retryChapterIfNeeded` owns
    /// resuming it. Without this guard the caller — `scrollViewDidScroll`, i.e. every
    /// frame near a boundary — kept re-entering the build only to hit `contentNotCached`
    /// again, re-requesting the same chapter on every frame.
    func ensureChapterAhead(of chapterIndex: Int) {
        let next = chapterIndex + 1
        guard next < builder.chapterCount,
              !loadedChapters.contains(next),
              !slicingChapters.contains(next),
              !pendingMissingChapters.contains(next) else { return }
        Task { await loadChapter(next) }
    }

    /// Called when near the top; loads the previous chapter. The view re-applies the reading
    /// position afterwards, so there is no offset compensation for the caller to handle.
    func ensureChapterBehind(of chapterIndex: Int) {
        let prev = chapterIndex - 1
        guard prev >= 0,
              !loadedChapters.contains(prev),
              !slicingChapters.contains(prev),
              !pendingMissingChapters.contains(prev) else { return }
        Task { await loadChapter(prev) }
    }

    /// Reslice (settings changed): clear all chunks and re-slice from the specified chapter
    @discardableResult
    func reslice(
        restoreAt chapterIndex: Int,
        contentWidth: CGFloat,
        imageContentWidth: CGFloat? = nil,
        viewportExtent: CGFloat? = nil,
        restorePosition: CoreTextReadingPosition? = nil
    ) async -> Bool {
        resliceGeneration &+= 1
        let generation = resliceGeneration
        let resolvedImageContentWidth = imageContentWidth ?? self.imageContentWidth
        let resolvedViewportExtent = viewportExtent ?? self.viewportExtent

        let replacement = CoreTextScrollEngine(
            builder: builder,
            renderSettings: renderSettings,
            chapterDocumentStore: chapterDocumentStore
        )
        replacement.onChapterContentRequired = onChapterContentRequired
        await replacement.start(
            initialChapter: chapterIndex,
            contentWidth: contentWidth,
            imageContentWidth: resolvedImageContentWidth,
            viewportExtent: resolvedViewportExtent,
            loadAdjacentChapters: false
        )

        guard generation == resliceGeneration, !Task.isCancelled else {
            return false
        }
        self.contentWidth = contentWidth
        self.imageContentWidth = resolvedImageContentWidth
        self.viewportExtent = resolvedViewportExtent
        chunks = replacement.chunks
        chapterRanges = replacement.chapterRanges
        chapterCharacterCounts = replacement.chapterCharacterCounts
        loadedChapters = replacement.loadedChapters
        slicingChapters = []
        pendingMissingChapters = replacement.pendingMissingChapters
        placeholderChapters = replacement.placeholderChapters
        isReady = replacement.isReady
        events.send(.reset(restorePosition: restorePosition))
        return chapterRanges[chapterIndex]?.isEmpty == false
    }

    func updateRenderSettings(_ settings: ReaderRenderSettings) {
        renderSettings = settings
    }

    func refreshChapter(
        at chapterIndex: Int,
        restoreAt position: CoreTextReadingPosition
    ) async {
        guard chapterIndex >= 0,
              chapterIndex < builder.chapterCount,
              contentWidth > 0
        else { return }

        let restorePosition = position.spineIndex == chapterIndex
            ? position
            : .chapterStart(chapterIndex)
        chapterDocumentStore.invalidate(spineIndex: chapterIndex)
        _ = await reslice(
            restoreAt: chapterIndex,
            contentWidth: contentWidth,
            imageContentWidth: imageContentWidth,
            viewportExtent: viewportExtent,
            restorePosition: restorePosition
        )
    }

    func invalidateChapterDocument(at chapterIndex: Int) {
        guard chapterIndex >= 0, chapterIndex < builder.chapterCount else { return }
        chapterDocumentStore.invalidate(spineIndex: chapterIndex)
    }

    func applyThemeChange(textColor: UIColor, backgroundColor: UIColor) {
        renderSettings = ReaderRenderSettings(
            theme: renderSettings.theme,
            textColor: textColor,
            backgroundColor: backgroundColor,
            fontSize: renderSettings.fontSize,
            lineHeightMultiple: renderSettings.lineHeightMultiple,
            lineSpacing: renderSettings.lineSpacing,
            paragraphSpacing: renderSettings.paragraphSpacing,
            letterSpacing: renderSettings.letterSpacing,
            marginH: renderSettings.marginH,
            marginV: renderSettings.marginV,
            footerHeight: renderSettings.footerHeight,
            contentInsets: renderSettings.contentInsets,
            writingMode: renderSettings.writingMode,
            fontPostScriptName: renderSettings.fontPostScriptName,
            isBold: renderSettings.isBold,
            chapterTitleStyle: renderSettings.chapterTitleStyle,
            readerBackgroundImageURL: renderSettings.readerBackgroundImageURL,
            regexHighlightConfiguration: renderSettings.regexHighlightConfiguration,
            readerStyleAppearance: renderSettings.readerStyleAppearance,
            readerStyleAssetRevision: renderSettings.readerStyleAssetRevision
        )
    }

    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation]) {
        textAnnotations = annotations
    }

    func characterCount(forChapter chapterIndex: Int) -> Int? {
        chapterCharacterCounts[chapterIndex]
    }

    private func prepareAttributedString(_ raw: NSAttributedString) -> NSAttributedString {
        guard renderSettings.writingMode.isVertical, raw.length > 0 else { return raw }
        let advance = max(renderSettings.fontSize * 4, contentWidth - renderSettings.fontSize * 2)

        return CoreTextPaginator.preparedAttributedString(
            raw,
            writingMode: renderSettings.writingMode,
            fontSize: renderSettings.fontSize,
            maxInlineAnnotationAdvance: advance
        )
    }

    func warmChunks(around row: Int, radius: Int = 6) {
        guard !chunks.isEmpty else { return }
        let center = max(0, min(row, chunks.count - 1))
        let start = max(0, center - max(0, radius))
        let end = min(chunks.count - 1, center + max(0, radius))
        guard start <= end else { return }
        for index in start...end {
            chunks[index].materializeFrameIfNeeded()
        }
    }

    /// Materializes CTFrames around `row` off the main thread, then applies the
    /// result on the main thread. Used during scrolling so frame construction
    /// (the expensive part) does not hitch the main thread. willDisplay still
    /// materializes synchronously as a correctness fallback for chunks that
    /// scroll into view before the async warm completes.
    func warmChunksAhead(around row: Int, radius: Int = 2) {
        guard !chunks.isEmpty else { return }
        let center = max(0, min(row, chunks.count - 1))
        let start = max(0, center - max(0, radius))
        let end = min(chunks.count - 1, center + max(0, radius))
        guard start <= end else { return }
        let pending = (start...end)
            .map { chunks[$0] }
            .filter { !$0.isMaterialized }
        guard !pending.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            for chunk in pending {
                guard let built = chunk.buildFrameData() else { continue }
                await MainActor.run { chunk.applyBuiltFrame(built) }
            }
        }
    }

    /// Drops CTFrames far from the visible row so a long scroll session does not keep
    /// every chapter it has passed materialized. This is the engine's memory policy;
    /// cells must not evict frames on reuse, because the chunks cycling through the
    /// reuse pool are precisely the ones about to be shown again.
    ///
    /// `keepRadius` must stay comfortably wider than the warm radius, otherwise a chunk
    /// is evicted moments before it is displayed and the rebuild lands on the main
    /// thread in `willDisplay`.
    func trimMaterializedChunks(around row: Int, keepRadius: Int = 12) {
        guard !chunks.isEmpty, keepRadius >= 0 else { return }
        let center = max(0, min(row, chunks.count - 1))
        let lower = center - keepRadius
        let upper = center + keepRadius
        for index in chunks.indices where index < lower || index > upper {
            chunks[index].evictFrame()
        }
    }

    @discardableResult
    func retryChapterIfNeeded(_ chapterIndex: Int) async -> Bool {
        // Read, never consume: `loadChapter` clears this entry once the chapter is
        // actually sliced and re-arms it when the content is still uncached. Removing it
        // up front lost the chapter permanently whenever the load below threw for any
        // other reason, because nothing else records that it is still missing — and with
        // the loading placeholder in place that strands a visible 載入中 block.
        guard pendingMissingChapters.contains(chapterIndex),
              !loadedChapters.contains(chapterIndex),
              !slicingChapters.contains(chapterIndex)
        else { return false }

        // The boundary-order repair that used to live here is gone: `insert` now places by
        // chapter index, which is the general form of what it was approximating for the two
        // cases where the pending chapter had drifted outside the rendered range.
        ChapterRetryLog.record(
            .scrollPlaceholderStuck,
            chapter: chapterIndex,
            bookId: nil,
            detail: "still on its placeholder after the first load"
        )
        await loadChapter(chapterIndex)
        return loadedChapters.contains(chapterIndex)
    }

    // MARK: - Internal load

    /// Formats a `systemUptime` delta for the `⏱` breakdown fields.
    private static func ms(_ seconds: Double) -> String {
        String(format: "%.1fms", seconds * 1000)
    }

    /// Loads and slices a single chapter, placing it in chapter order (see `insertionIndex`).
    private func loadChapter(_ chapterIndex: Int) async {
        guard chapterIndex >= 0, chapterIndex < builder.chapterCount else { return }
        guard !loadedChapters.contains(chapterIndex), !slicingChapters.contains(chapterIndex) else { return }
        slicingChapters.insert(chapterIndex)
        defer { slicingChapters.remove(chapterIndex) }

        // Stage-0 baseline for `Technotes/ViewportScrollArchitecture.md`. The migration's only
        // success criterion is that this wall time decouples from chapter length, so the phases
        // are timed separately: `document` (HTML/CSS → NSAttributedString) is not something lazy
        // layout can improve, while `slice` is exactly what it removes from the critical path.
        let loadStart = CoreTextSliceMetrics.now
        do {
            let documentStart = CoreTextSliceMetrics.now
            let result = try await ReaderPerfTrace.spanAsync(
                .chapterLoad,
                metadata: ReaderPerfMetadata(
                    spineIndex: chapterIndex,
                    writingMode: String(describing: renderSettings.writingMode),
                    executor: Thread.isMainThread ? "main" : "background"
                )
            ) {
                try await chapterDocumentStore.document(
                    for: ChapterDocumentRequest(
                        spineIndex: chapterIndex,
                        settings: renderSettings,
                        themeTextColor: renderSettings.textColor,
                        themeBackgroundColor: renderSettings.backgroundColor
                    )
                )
            }
            let documentSeconds = CoreTextSliceMetrics.now - documentStart

            let prepareStart = CoreTextSliceMetrics.now
            let attrStr: NSAttributedString
            let appearanceResolvedDocument = CoreTextPaginator.scrollAppearanceRecolor(
                result.attributedString,
                appearance: renderSettings.readerStyleAppearance
            )
            if renderSettings.writingMode.isVertical {
                attrStr = ReaderPerfTrace.span(
                    .layoutVerticalPrepare,
                    metadata: ReaderPerfMetadata(
                        spineIndex: chapterIndex,
                        characterCount: result.attributedString.length,
                        writingMode: String(describing: renderSettings.writingMode),
                        executor: Thread.isMainThread ? "main" : "background"
                    )
                ) {
                    prepareAttributedString(appearanceResolvedDocument)
                }
            } else {
                attrStr = prepareAttributedString(appearanceResolvedDocument)
            }
            let prepareSeconds = CoreTextSliceMetrics.now - prepareStart
            chapterCharacterCounts[chapterIndex] = attrStr.length
            let width = contentWidth
            let cIdx = chapterIndex
            // A user-selected reader background has the same precedence in scroll mode as it
            // does in paged mode. Otherwise retain both authored layers for correct alpha compositing.
            let usesReaderBackgroundImage = renderSettings.readerBackgroundImageURL != nil
            let pageBackgroundColor: UIColor?
            if usesReaderBackgroundImage {
                pageBackgroundColor = nil
            } else if renderSettings.readerStyleAppearance == .dark {
                pageBackgroundColor = result.darkPageBackgroundColor ?? result.pageBackgroundColor
            } else {
                pageBackgroundColor = result.pageBackgroundColor
            }
            let pageBackgroundImage = usesReaderBackgroundImage ? nil : result.pageBackgroundImage

            // Single-image page (cover / chapter illustration): builder puts the image in result.imagePage while attrStr is just a placeholder.
            if let imagePage = result.imagePage, let img = imagePage.image {
                let chunk = makeImageOnlyChunk(
                    image: img,
                    chapterIndex: cIdx,
                    contentWidth: width,
                    fallbackAttrStr: attrStr,
                    pageBackgroundColor: pageBackgroundColor,
                    pageBackgroundImage: pageBackgroundImage
                )
                insert(chunks: [chunk], chapterIndex: chapterIndex)
                if let range = chapterRanges[chapterIndex] {
                    warmChunks(around: range.lowerBound, radius: 4)
                }
                loadedChapters.insert(chapterIndex)
                // Logged on this path too: an image-only chapter is the natural control for
                // "load time vs chapter length" — it does no slicing at any chapter size.
                SourcePerfTrace.record(
                    "coreText.scroll.loadChapter",
                    "spine=\(chapterIndex) chars=\(attrStr.length) chunks=1 kind=imagePage "
                        + "document=\(Self.ms(documentSeconds)) prepare=\(Self.ms(prepareSeconds))",
                    since: loadStart,
                    thresholdMs: 0
                )
                return
            }

            let writingMode = renderSettings.writingMode
            let slicingTrace = ReaderPerfTrace.begin(
                .layoutPageRanges,
                metadata: ReaderPerfMetadata(
                    spineIndex: chapterIndex,
                    characterCount: attrStr.length,
                    writingMode: String(describing: writingMode),
                    executor: "background"
                )
            )
            let backdropFloor = viewportExtent
            let sliceStart = CoreTextSliceMetrics.now
            let output: CoreTextChunkSlicer.Output = await Task.detached(priority: .userInitiated) {
                CoreTextChunkSlicer.slice(
                    attributedString: attrStr,
                    chapterIndex: cIdx,
                    contentWidth: width,
                    writingMode: writingMode,
                    pageBackgroundColor: pageBackgroundColor,
                    pageBackgroundImage: pageBackgroundImage,
                    minimumBackdropExtent: backdropFloor
                )
            }.value
            let sliceSeconds = CoreTextSliceMetrics.now - sliceStart
            ReaderPerfTrace.end(
                slicingTrace,
                metadata: ReaderPerfMetadata(
                    spineIndex: chapterIndex,
                    characterCount: attrStr.length,
                    chunkCount: output.chunks.count,
                    writingMode: String(describing: writingMode),
                    executor: "background"
                )
            )
            // `slice` measures itself; this stage measures the hop to the detached task as
            // well, so the two numbers together show what scheduling costs on top of layout.
            SourcePerfTrace.record(
                "coreText.scroll.slice",
                "spine=\(chapterIndex) writing=\(writingMode) \(output.metrics.logDetail)",
                since: sliceStart,
                thresholdMs: 0
            )

            // The placeholder already holds this chapter's slot, so the real content takes
            // exactly that index rather than being re-placed by chapter order.
            let insertStart = CoreTextSliceMetrics.now
            let vacatedIndex = removeLoadingPlaceholder(for: chapterIndex)
            insert(
                chunks: output.chunks,
                chapterIndex: chapterIndex,
                at: vacatedIndex
            )
            let insertSeconds = CoreTextSliceMetrics.now - insertStart
            let warmStart = CoreTextSliceMetrics.now
            if let range = chapterRanges[chapterIndex] {
                warmChunks(around: range.lowerBound, radius: 4)
            }
            let warmSeconds = CoreTextSliceMetrics.now - warmStart
            loadedChapters.insert(chapterIndex)
            pendingMissingChapters.remove(chapterIndex)

            SourcePerfTrace.record(
                "coreText.scroll.loadChapter",
                "spine=\(chapterIndex) chars=\(attrStr.length) chunks=\(output.chunks.count) "
                    + "kind=text document=\(Self.ms(documentSeconds)) prepare=\(Self.ms(prepareSeconds)) "
                    + "slice=\(Self.ms(sliceSeconds)) insert=\(Self.ms(insertSeconds)) "
                    + "warm=\(Self.ms(warmSeconds))",
                since: loadStart,
                thresholdMs: 0
            )
        } catch AttributedStringBuildingError.contentNotCached(let missingChapter) {
            let requestedChapter = missingChapter == chapterIndex ? missingChapter : chapterIndex
            pendingMissingChapters.insert(requestedChapter)
            AppLogger.render("[ScrollEngine] chapter content missing chapter=\(requestedChapter)")
            insertLoadingPlaceholder(for: requestedChapter)
            onChapterContentRequired?(requestedChapter)
        } catch {
            AppLogger.render("[ScrollEngine] buildChapter error chapter=\(chapterIndex) error=\(error)")
        }
    }

    // MARK: - Loading placeholder

    /// Stands a chapter up as "title + 載入中" while its content is fetched, matching what
    /// paged mode already does with a placeholder page. Without this a chapter whose
    /// content has not arrived contributes zero chunks, so jumping into it — or scrolling
    /// to a chapter boundary — showed a blank surface with nothing to indicate a fetch was
    /// running. Replaced in place by `loadChapter` as soon as the real content is sliced.
    private func insertLoadingPlaceholder(for chapterIndex: Int) {
        guard contentWidth > 0,
              !placeholderChapters.contains(chapterIndex),
              !loadedChapters.contains(chapterIndex)
        else { return }
        // Measured because this is the one synchronous, main-actor `slice()` in the engine
        // (`ViewportScrollArchitecture.md` §3.3). The placeholder string is short so it should
        // be near-free — this line is what proves that, and what would catch it if it stopped
        // being true before stage 5 removes the call.
        let placeholderStart = CoreTextSliceMetrics.now
        let output = CoreTextChunkSlicer.slice(
            attributedString: makeLoadingPlaceholderString(for: chapterIndex),
            chapterIndex: chapterIndex,
            contentWidth: contentWidth,
            writingMode: renderSettings.writingMode
        )
        SourcePerfTrace.record(
            "coreText.scroll.placeholderSlice",
            "spine=\(chapterIndex) \(output.metrics.logDetail)",
            since: placeholderStart,
            thresholdMs: 0
        )
        guard !output.chunks.isEmpty else { return }
        placeholderChapters.insert(chapterIndex)
        insert(chunks: output.chunks, chapterIndex: chapterIndex)
    }

    /// Removes a chapter's placeholder rows and closes the gap, returning the index the
    /// placeholder occupied so the real content can take exactly that slot. Deliberately
    /// does not publish an event: the caller inserts the real chunks immediately
    /// afterwards, and the resulting row-count mismatch routes the collection view
    /// through its position-preserving reload.
    @discardableResult
    private func removeLoadingPlaceholder(for chapterIndex: Int) -> Int? {
        guard placeholderChapters.remove(chapterIndex) != nil,
              let range = chapterRanges.removeValue(forKey: chapterIndex),
              !range.isEmpty
        else { return nil }
        chunks.removeSubrange(range)
        let delta = range.count
        var newRanges: [Int: Range<Int>] = [:]
        for (chapter, existing) in chapterRanges {
            newRanges[chapter] = existing.lowerBound >= range.upperBound
                ? (existing.lowerBound - delta)..<(existing.upperBound - delta)
                : existing
        }
        chapterRanges = newRanges
        return range.lowerBound
    }

    /// Never contributes to `chapterCharacterCounts`: this text is not book content and
    /// must not enter progress or TTS position math.
    private func makeLoadingPlaceholderString(for chapterIndex: Int) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let titleStyle = renderSettings.chapterTitleStyle
        let title = builder.chapterTitle(at: chapterIndex)
        if titleStyle.visible, !title.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = titleStyle.alignment.nsTextAlignment
            paragraph.paragraphSpacing = max(titleStyle.bottomSpacing, renderSettings.fontSize)
            result.append(NSAttributedString(
                string: title + "\n",
                attributes: [
                    .font: UserReaderFontResolver.titleFont(
                        size: titleStyle.size,
                        weight: titleStyle.weight,
                        postScriptName: titleStyle.nameFontName()
                    ),
                    .foregroundColor: renderSettings.textColor,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.alignment = .center
        result.append(NSAttributedString(
            string: localized("載入中…"),
            attributes: [
                .font: UserReaderFontResolver.bodyFont(
                    size: renderSettings.fontSize,
                    isBold: false
                ),
                .foregroundColor: renderSettings.textColor.withAlphaComponent(0.5),
                .paragraphStyle: bodyParagraph,
            ]
        ))
        return result
    }

    /// Where a chapter's chunks belong in `chunks` — decided by **chapter order**, never by
    /// arrival order.
    ///
    /// `loadChapter` runs concurrently and finishes out of order. A device log captured
    /// `order=[256, 258]` → `[256, 258, 257]` → `[256, 258, 257, 259]`: chapter 258's text sat
    /// physically above 257's, so scrolling down from 256 reached 258 and only then 257. The book
    /// itself was out of order.
    ///
    /// The cause was placing by a `prepend` flag that recorded the direction a chapter was first
    /// *requested* in, not where it belonged once its neighbours arrived. `retryChapterIfNeeded`
    /// carried a hand-rolled repair for the two boundary cases; deciding position from the chapter
    /// index covers those and every case between them, so that repair is gone.
    private func insertionIndex(forChapter chapterIndex: Int) -> Int {
        chunks.firstIndex { $0.chapterIndex > chapterIndex } ?? chunks.endIndex
    }

    private func insert(
        chunks newChunks: [CoreTextChunk],
        chapterIndex: Int,
        at vacatedIndex: Int? = nil
    ) {
        guard !newChunks.isEmpty else {
            let slot = insertionIndex(forChapter: chapterIndex)
            chapterRanges[chapterIndex] = slot..<slot
            return
        }
        // A loading placeholder already reserved this chapter's slot, so the real content takes
        // exactly that slot. Otherwise chapter order decides.
        let insertAt = vacatedIndex.map { min(max(0, $0), chunks.endIndex) }
            ?? insertionIndex(forChapter: chapterIndex)
        chunks.insert(contentsOf: newChunks, at: insertAt)
        let delta = newChunks.count
        var newRanges: [Int: Range<Int>] = [:]
        for (chapter, existing) in chapterRanges {
            newRanges[chapter] = existing.lowerBound >= insertAt
                ? (existing.lowerBound + delta)..<(existing.upperBound + delta)
                : existing
        }
        newRanges[chapterIndex] = insertAt..<(insertAt + delta)
        chapterRanges = newRanges
        events.send(.chunksInserted(range: insertAt..<(insertAt + delta), chapter: chapterIndex))
    }

    // MARK: - Single-image chunk

    /// Creates a single chunk for cover / full-page illustrations.
    private func makeImageOnlyChunk(
        image: UIImage,
        chapterIndex: Int,
        contentWidth: CGFloat,
        fallbackAttrStr: NSAttributedString,
        pageBackgroundColor: UIColor?,
        pageBackgroundImage: UIImage?
    ) -> CoreTextChunk {
        if renderSettings.writingMode.isVertical, let imageContentWidth, imageContentWidth > 0 {
            let container = CGRect(
                origin: .zero,
                size: CGSize(width: imageContentWidth, height: contentWidth)
            )
            let rect = Self.aspectFitRect(for: image.size, in: container)
            let attachment = CoreTextPaginator.RenderedAttachment(rect: rect, image: image, opacity: 1.0)
            let framesetter = CoreTextFramesetterFactory.make(for: fallbackAttrStr)
            return CoreTextChunk(
                chapterIndex: chapterIndex,
                charRange: CFRange(location: 0, length: max(fallbackAttrStr.length, 1)),
                size: container.size,
                framesetter: framesetter,
                attributedString: fallbackAttrStr,
                frame: nil,
                writingMode: renderSettings.writingMode,
                presetAttachments: [attachment],
                isImageOnly: true,
                pageBackgroundColor: pageBackgroundColor,
                pageBackgroundImage: pageBackgroundImage
            )
        }

        let aspect = image.size.height / max(image.size.width, 1)
        let naturalHeight = contentWidth * aspect
        let maxHeight = max(UIScreen.main.bounds.height - 80, contentWidth)
        let height = min(naturalHeight, maxHeight)
        let drawWidth = height < naturalHeight ? height / aspect : contentWidth
        let x = (contentWidth - drawWidth) / 2
        let rect = CGRect(x: x, y: 0, width: drawWidth, height: height)
        let attachment = CoreTextPaginator.RenderedAttachment(rect: rect, image: image, opacity: 1.0)
        let framesetter = CoreTextFramesetterFactory.make(for: fallbackAttrStr)
        return CoreTextChunk(
            chapterIndex: chapterIndex,
            charRange: CFRange(location: 0, length: max(fallbackAttrStr.length, 1)),
            size: CGSize(width: contentWidth, height: height),
            framesetter: framesetter,
            attributedString: fallbackAttrStr,
            frame: nil,
            writingMode: renderSettings.writingMode,
            presetAttachments: [attachment],
            isImageOnly: true,
            pageBackgroundColor: pageBackgroundColor,
            pageBackgroundImage: pageBackgroundImage
        )
    }

    private static func aspectFitRect(for imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let ratio = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * ratio, height: imageSize.height * ratio)
        return CGRect(
            x: bounds.minX + (bounds.width - size.width) / 2,
            y: bounds.minY + (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Lookup

    /// Finds the (chapterIndex, charOffsetInChapter) for a given chunk index
    func position(forChunkIndex idx: Int) -> (chapter: Int, charOffsetInChapter: Int)? {
        guard idx >= 0, idx < chunks.count else { return nil }
        let chunk = chunks[idx]
        return (chunk.chapterIndex, chunk.charRange.location)
    }

    /// Finds the chunk index for a given (chapterIndex, charOffset)
    func chunkIndex(forChapter chapter: Int, charOffset: Int) -> Int? {
        guard let range = chapterRanges[chapter] else { return nil }
        for i in range {
            let r = chunks[i].charRange
            if charOffset >= r.location && charOffset < r.location + r.length {
                return i
            }
        }
        return range.last
    }
}
