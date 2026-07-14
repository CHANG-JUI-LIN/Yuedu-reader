import Combine
import CoreText
import Foundation
import UIKit

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

    /// Change event stream: VC subscribes to perform insertRows / contentOffset compensation
    enum Event {
        case reset
        case insertedAtBottom(count: Int, chapter: Int)
        case insertedAtTop(count: Int, addedHeight: CGFloat, chapter: Int)
    }
    let events = PassthroughSubject<Event, Never>()
    var onChapterContentRequired: ((Int) -> Void)?

    // MARK: - Inputs

    private let builder: any AttributedStringBuilding
    private(set) var renderSettings: ReaderRenderSettings
    private(set) var contentWidth: CGFloat = 0
    private var imageContentWidth: CGFloat?

    /// Chapters currently being sliced (deduplication)
    private var slicingChapters: Set<Int> = []
    /// Chapters that have been fully sliced
    private var loadedChapters: Set<Int> = []
    /// Chapters that could not be sliced because their online content was not cached yet.
    private var pendingMissingChapters: [Int: Bool] = [:]

    // MARK: - Init

    init(builder: any AttributedStringBuilding, renderSettings: ReaderRenderSettings) {
        self.builder = builder
        self.renderSettings = renderSettings
    }

    var chapterCount: Int { builder.chapterCount }

    /// Returns the chapter title (delegates to builder)
    func chapterTitle(at index: Int) -> String { builder.chapterTitle(at: index) }

    // MARK: - Lifecycle

    /// Initial load: slices the starting chapter + adjacent chapters
    func start(initialChapter: Int, contentWidth: CGFloat, imageContentWidth: CGFloat? = nil) async {
        self.contentWidth = contentWidth
        self.imageContentWidth = imageContentWidth
        let clamped = max(0, min(initialChapter, max(0, builder.chapterCount - 1)))
        await loadChapter(clamped)
        isReady = true
        if clamped + 1 < builder.chapterCount {
            await loadChapter(clamped + 1)
        }
        if clamped - 1 >= 0 {
            await loadChapter(clamped - 1, prepend: true)
        }
    }

    /// Called when near the bottom; appends the next chapter
    func ensureChapterAhead(of chapterIndex: Int) {
        let next = chapterIndex + 1
        guard next < builder.chapterCount,
              !loadedChapters.contains(next),
              !slicingChapters.contains(next) else { return }
        Task { await loadChapter(next) }
    }

    /// Called when near the top; prepends the previous chapter (caller must handle contentOffset compensation)
    func ensureChapterBehind(of chapterIndex: Int) {
        let prev = chapterIndex - 1
        guard prev >= 0,
              !loadedChapters.contains(prev),
              !slicingChapters.contains(prev) else { return }
        Task { await loadChapter(prev, prepend: true) }
    }

    /// Reslice (settings changed): clear all chunks and re-slice from the specified chapter
    func reslice(restoreAt chapterIndex: Int, contentWidth: CGFloat, imageContentWidth: CGFloat? = nil) async {
        let resolvedImageContentWidth = imageContentWidth ?? self.imageContentWidth

        let replacement = CoreTextScrollEngine(builder: builder, renderSettings: renderSettings)
        replacement.onChapterContentRequired = onChapterContentRequired
        await replacement.start(
            initialChapter: chapterIndex,
            contentWidth: contentWidth,
            imageContentWidth: resolvedImageContentWidth
        )

        self.contentWidth = contentWidth
        self.imageContentWidth = resolvedImageContentWidth
        chunks = replacement.chunks
        chapterRanges = replacement.chapterRanges
        loadedChapters = replacement.loadedChapters
        slicingChapters = []
        pendingMissingChapters = replacement.pendingMissingChapters
        isReady = replacement.isReady
        events.send(.reset)
    }

    func updateRenderSettings(_ settings: ReaderRenderSettings) {
        renderSettings = settings
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
            titleVisible: renderSettings.titleVisible,
            titleSize: renderSettings.titleSize,
            titleTopSpacing: renderSettings.titleTopSpacing,
            titleBottomSpacing: renderSettings.titleBottomSpacing,
            readerBackgroundImageURL: renderSettings.readerBackgroundImageURL,
            dialogueHighlightColor: renderSettings.dialogueHighlightColor,
            dialogueBoxColor: renderSettings.dialogueBoxColor
        )
    }

    func setTextAnnotations(_ annotations: [CoreTextTextAnnotation]) {
        textAnnotations = annotations
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

    @discardableResult
    func retryChapterIfNeeded(_ chapterIndex: Int) async -> Bool {
        guard let prepend = pendingMissingChapters.removeValue(forKey: chapterIndex),
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
            let result = try await builder.buildChapter(
                at: chapterIndex,
                settings: renderSettings,
                themeTextColor: renderSettings.textColor,
                themeBackgroundColor: renderSettings.backgroundColor
            )
            let attrStr = prepareAttributedString(result.attributedString)
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

            insert(chunks: output.chunks, chapterIndex: chapterIndex, prepend: prepend)
            if let range = chapterRanges[chapterIndex] {
                warmChunks(around: range.lowerBound, radius: 4)
            }
            loadedChapters.insert(chapterIndex)
            pendingMissingChapters.removeValue(forKey: chapterIndex)
        } catch AttributedStringBuildingError.contentNotCached(let missingChapter) {
            let requestedChapter = missingChapter == chapterIndex ? missingChapter : chapterIndex
            pendingMissingChapters[requestedChapter] = prepend
            AppLogger.render("[ScrollEngine] chapter content missing chapter=\(requestedChapter) prepend=\(prepend)")
            onChapterContentRequired?(requestedChapter)
        } catch {
            AppLogger.render("[ScrollEngine] buildChapter error chapter=\(chapterIndex) error=\(error)")
        }
    }

    private func insert(chunks newChunks: [CoreTextChunk], chapterIndex: Int, prepend: Bool) {
        guard !newChunks.isEmpty else {
            chapterRanges[chapterIndex] = chunks.endIndex..<chunks.endIndex
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
