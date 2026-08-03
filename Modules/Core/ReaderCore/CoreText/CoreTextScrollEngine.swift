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
    @Published private(set) var chunks: [CoreTextChunk] = []
    /// chapter → index range within chunks (inclusive start, exclusive end)
    @Published private(set) var chapterRanges: [Int: Range<Int>] = [:]
    @Published private(set) var isReady: Bool = false
    @Published var textAnnotations: [CoreTextTextAnnotation] = []

    /// UTF-16 character counts retained independently of rendered chunks so
    /// scroll positions can be converted to stable book-wide content units.
    private var chapterCharacterCounts: [Int: Int] = [:]

    /// Change event stream: VC subscribes to perform insertRows / contentOffset compensation
    enum Event {
        case reset(restorePosition: CoreTextReadingPosition?)
        case insertedAtBottom(count: Int, chapter: Int)
        case insertedAtTop(count: Int, addedHeight: CGFloat, chapter: Int)
    }
    let events = PassthroughSubject<Event, Never>()
    var onChapterContentRequired: ((Int) -> Void)?

    // MARK: - Inputs

    private let builder: any AttributedStringBuilding
    private let chapterDocumentStore: ChapterDocumentStore
    private(set) var renderSettings: ReaderRenderSettings
    private(set) var contentWidth: CGFloat = 0
    private var imageContentWidth: CGFloat?

    /// Chapters currently being sliced (deduplication)
    private var slicingChapters: Set<Int> = []
    /// Chapters that have been fully sliced
    private var loadedChapters: Set<Int> = []
    /// Chapters that could not be sliced because their online content was not cached yet.
    private var pendingMissingChapters: [Int: Bool] = [:]
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
        loadAdjacentChapters: Bool = true
    ) async {
        self.contentWidth = contentWidth
        self.imageContentWidth = imageContentWidth
        let clamped = max(0, min(initialChapter, max(0, builder.chapterCount - 1)))
        await loadChapter(clamped)
        isReady = true
        guard loadAdjacentChapters else { return }
        if clamped + 1 < builder.chapterCount {
            await loadChapter(clamped + 1)
        }
        if clamped - 1 >= 0 {
            await loadChapter(clamped - 1, prepend: true)
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
              pendingMissingChapters[next] == nil else { return }
        Task { await loadChapter(next) }
    }

    /// Called when near the top; prepends the previous chapter (caller must handle contentOffset compensation)
    func ensureChapterBehind(of chapterIndex: Int) {
        let prev = chapterIndex - 1
        guard prev >= 0,
              !loadedChapters.contains(prev),
              !slicingChapters.contains(prev),
              pendingMissingChapters[prev] == nil else { return }
        Task { await loadChapter(prev, prepend: true) }
    }

    /// Reslice (settings changed): clear all chunks and re-slice from the specified chapter
    func reslice(
        restoreAt chapterIndex: Int,
        contentWidth: CGFloat,
        imageContentWidth: CGFloat? = nil,
        restorePosition: CoreTextReadingPosition? = nil
    ) async {
        resliceGeneration &+= 1
        let generation = resliceGeneration
        let resolvedImageContentWidth = imageContentWidth ?? self.imageContentWidth

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
            loadAdjacentChapters: false
        )

        guard generation == resliceGeneration, !Task.isCancelled else { return }
        self.contentWidth = contentWidth
        self.imageContentWidth = resolvedImageContentWidth
        chunks = replacement.chunks
        chapterRanges = replacement.chapterRanges
        chapterCharacterCounts = replacement.chapterCharacterCounts
        loadedChapters = replacement.loadedChapters
        slicingChapters = []
        pendingMissingChapters = replacement.pendingMissingChapters
        placeholderChapters = replacement.placeholderChapters
        isReady = replacement.isReady
        events.send(.reset(restorePosition: restorePosition))
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
        await reslice(
            restoreAt: chapterIndex,
            contentWidth: contentWidth,
            imageContentWidth: imageContentWidth,
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
            dialogueHighlightColor: renderSettings.dialogueHighlightColor,
            dialogueBoxColor: renderSettings.dialogueBoxColor
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
        guard let prepend = pendingMissingChapters[chapterIndex],
              !loadedChapters.contains(chapterIndex),
              !slicingChapters.contains(chapterIndex)
        else { return false }

        await loadChapter(chapterIndex, prepend: prepend)
        return loadedChapters.contains(chapterIndex)
    }

    // MARK: - Internal load

    /// Loads and slices a single chapter, appending or prepending to chunks
    private func loadChapter(_ chapterIndex: Int, prepend: Bool = false) async {
        guard chapterIndex >= 0, chapterIndex < builder.chapterCount else { return }
        guard !loadedChapters.contains(chapterIndex), !slicingChapters.contains(chapterIndex) else { return }
        slicingChapters.insert(chapterIndex)
        defer { slicingChapters.remove(chapterIndex) }

        do {
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
            let attrStr: NSAttributedString
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
                    prepareAttributedString(result.attributedString)
                }
            } else {
                attrStr = prepareAttributedString(result.attributedString)
            }
            chapterCharacterCounts[chapterIndex] = attrStr.length
            let width = contentWidth
            let cIdx = chapterIndex
            // A user-selected reader background has the same precedence in scroll mode as it
            // does in paged mode. Otherwise retain both authored layers for correct alpha compositing.
            let usesReaderBackgroundImage = renderSettings.readerBackgroundImageURL != nil
            let pageBackgroundColor = usesReaderBackgroundImage ? nil : result.pageBackgroundColor
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
                insert(chunks: [chunk], chapterIndex: chapterIndex, prepend: prepend)
                if let range = chapterRanges[chapterIndex] {
                    warmChunks(around: range.lowerBound, radius: 4)
                }
                loadedChapters.insert(chapterIndex)
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
            let output: CoreTextChunkSlicer.Output = await Task.detached(priority: .userInitiated) {
                CoreTextChunkSlicer.slice(
                    attributedString: attrStr,
                    chapterIndex: cIdx,
                    contentWidth: width,
                    writingMode: writingMode,
                    pageBackgroundColor: pageBackgroundColor,
                    pageBackgroundImage: pageBackgroundImage
                )
            }.value
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

            // The placeholder occupies this chapter's slot at the same end of the list,
            // so dropping it here leaves `insert` appending/prepending into the position
            // it just vacated. The row-count change is what makes the collection view
            // reload through `reloadPreservingVisiblePosition`.
            let vacatedIndex = removeLoadingPlaceholder(for: chapterIndex)
            insert(
                chunks: output.chunks,
                chapterIndex: chapterIndex,
                prepend: prepend,
                at: vacatedIndex
            )
            if let range = chapterRanges[chapterIndex] {
                warmChunks(around: range.lowerBound, radius: 4)
            }
            loadedChapters.insert(chapterIndex)
            pendingMissingChapters.removeValue(forKey: chapterIndex)
        } catch AttributedStringBuildingError.contentNotCached(let missingChapter) {
            let requestedChapter = missingChapter == chapterIndex ? missingChapter : chapterIndex
            pendingMissingChapters[requestedChapter] = prepend
            AppLogger.render("[ScrollEngine] chapter content missing chapter=\(requestedChapter) prepend=\(prepend)")
            insertLoadingPlaceholder(for: requestedChapter, prepend: prepend)
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
    private func insertLoadingPlaceholder(for chapterIndex: Int, prepend: Bool) {
        guard contentWidth > 0,
              !placeholderChapters.contains(chapterIndex),
              !loadedChapters.contains(chapterIndex)
        else { return }
        let output = CoreTextChunkSlicer.slice(
            attributedString: makeLoadingPlaceholderString(for: chapterIndex),
            chapterIndex: chapterIndex,
            contentWidth: contentWidth,
            writingMode: renderSettings.writingMode
        )
        guard !output.chunks.isEmpty else { return }
        placeholderChapters.insert(chapterIndex)
        insert(chunks: output.chunks, chapterIndex: chapterIndex, prepend: prepend)
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

    private func insert(
        chunks newChunks: [CoreTextChunk],
        chapterIndex: Int,
        prepend: Bool,
        at vacatedIndex: Int? = nil
    ) {
        guard !newChunks.isEmpty else {
            chapterRanges[chapterIndex] = chunks.endIndex..<chunks.endIndex
            return
        }
        // Replacing a loading placeholder: this chapter's position in the list was already
        // decided when the placeholder went in. Re-deriving head/tail from `prepend` would
        // reorder chapters, because that flag records the direction the chapter was *first*
        // requested in, not where it ended up once neighbours were placed around it — which
        // is how a chapter's body could land below the next chapter's placeholder.
        if let vacatedIndex, vacatedIndex >= 0, vacatedIndex <= chunks.endIndex {
            chunks.insert(contentsOf: newChunks, at: vacatedIndex)
            let delta = newChunks.count
            var newRanges: [Int: Range<Int>] = [:]
            for (chapter, existing) in chapterRanges {
                newRanges[chapter] = existing.lowerBound >= vacatedIndex
                    ? (existing.lowerBound + delta)..<(existing.upperBound + delta)
                    : existing
            }
            newRanges[chapterIndex] = vacatedIndex..<(vacatedIndex + delta)
            chapterRanges = newRanges
            // The row count no longer matches what the collection view last displayed
            // (placeholder rows out, content rows in), so its desync guard reloads while
            // preserving the reader's position — the correct handling for a mid-list swap.
            events.send(.insertedAtBottom(count: delta, chapter: chapterIndex))
            return
        }
        if prepend {
            let insertAt = 0
            chunks.insert(contentsOf: newChunks, at: insertAt)
            let delta = newChunks.count
            let addedHeight = newChunks.reduce(CGFloat(0)) {
                $0 + (renderSettings.writingMode.isVertical ? $1.width : $1.height)
            }
            var newRanges: [Int: Range<Int>] = [:]
            for (k, r) in chapterRanges {
                newRanges[k] = (r.lowerBound + delta)..<(r.upperBound + delta)
            }
            newRanges[chapterIndex] = insertAt..<(insertAt + delta)
            chapterRanges = newRanges
            events.send(.insertedAtTop(count: delta, addedHeight: addedHeight, chapter: chapterIndex))
        } else {
            let insertAt = chunks.endIndex
            chunks.append(contentsOf: newChunks)
            chapterRanges[chapterIndex] = insertAt..<(insertAt + newChunks.count)
            events.send(.insertedAtBottom(count: newChunks.count, chapter: chapterIndex))
        }
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
