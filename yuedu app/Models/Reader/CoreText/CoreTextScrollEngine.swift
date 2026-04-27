import Combine
import CoreText
import Foundation
import UIKit

/// 捲動模式專用引擎：把每章 attributedString 切成一串 chunk，給 UICollectionView 渲染。
/// 與頁碼導向的 `CoreTextPageEngine` 並列、互不干擾。
@MainActor
final class CoreTextScrollEngine: ObservableObject {

    // MARK: - Published

    /// 線性 chunk 陣列，UICollectionView 直接 1:1 對應 cell
    @Published private(set) var chunks: [CoreTextChunk] = []
    /// chapter -> chunks 中的索引範圍（含起、不含止）
    @Published private(set) var chapterRanges: [Int: Range<Int>] = [:]
    @Published private(set) var isReady: Bool = false

    /// 變動事件流：VC 訂閱以做 insertRows / contentOffset 補償
    enum Event {
        case reset
        case insertedAtBottom(count: Int, chapter: Int)
        case insertedAtTop(count: Int, addedHeight: CGFloat, chapter: Int)
    }
    let events = PassthroughSubject<Event, Never>()

    // MARK: - Inputs

    private let builder: any AttributedStringBuilding
    private(set) var renderSettings: ReaderRenderSettings
    private(set) var contentWidth: CGFloat = 0

    /// 切片中的章節（去重抓取）
    private var slicingChapters: Set<Int> = []
    /// 已切完成的章節
    private var loadedChapters: Set<Int> = []

    // MARK: - Init

    init(builder: any AttributedStringBuilding, renderSettings: ReaderRenderSettings) {
        self.builder = builder
        self.renderSettings = renderSettings
    }

    var chapterCount: Int { builder.chapterCount }

    /// 取得章節標題（透傳給 builder）
    func chapterTitle(at index: Int) -> String { builder.chapterTitle(at: index) }

    // MARK: - Lifecycle

    /// 初始載入：切起始章 + 鄰章
    func start(initialChapter: Int, contentWidth: CGFloat) async {
        self.contentWidth = contentWidth
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

    /// 接近底部時呼叫：往後追加一章
    func ensureChapterAhead(of chapterIndex: Int) {
        let next = chapterIndex + 1
        guard next < builder.chapterCount,
              !loadedChapters.contains(next),
              !slicingChapters.contains(next) else { return }
        Task { await loadChapter(next) }
    }

    /// 接近頂部時呼叫：往前追加一章（會 prepend，呼叫端需自己處理 contentOffset 補償）
    func ensureChapterBehind(of chapterIndex: Int) {
        let prev = chapterIndex - 1
        guard prev >= 0,
              !loadedChapters.contains(prev),
              !slicingChapters.contains(prev) else { return }
        Task { await loadChapter(prev, prepend: true) }
    }

    /// 重切（設定變更）：清空所有 chunk，從指定章節重切
    func reslice(restoreAt chapterIndex: Int, contentWidth: CGFloat) async {
        self.contentWidth = contentWidth
        chunks = []
        chapterRanges = [:]
        loadedChapters = []
        slicingChapters = []
        isReady = false
        events.send(.reset)
        await start(initialChapter: chapterIndex, contentWidth: contentWidth)
    }

    func updateRenderSettings(_ settings: ReaderRenderSettings) {
        renderSettings = settings
    }

    // MARK: - Internal load

    /// 載入並切片單一章節，append 或 prepend 到 chunks
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
            let attrStr = result.attributedString
            let width = contentWidth
            let cIdx = chapterIndex
            print("[ScrollEngine] built chapter=\(cIdx) length=\(attrStr.length) width=\(width)")

            // 單圖頁（封面 / 章節插圖）：builder 把圖放進 result.imagePage 而 attrStr 只是 placeholder。
            // 直接造一個 synthetic chunk，把圖 aspect-fit 到 contentWidth。
            if let imagePage = result.imagePage, let img = imagePage.image {
                let chunk = makeImageOnlyChunk(
                    image: img,
                    chapterIndex: cIdx,
                    contentWidth: width,
                    fallbackAttrStr: attrStr
                )
                insert(chunks: [chunk], chapterIndex: chapterIndex, prepend: prepend)
                loadedChapters.insert(chapterIndex)
                return
            }

            let output: CoreTextChunkSlicer.Output = await Task.detached(priority: .userInitiated) {
                CoreTextChunkSlicer.slice(
                    attributedString: attrStr,
                    chapterIndex: cIdx,
                    contentWidth: width
                )
            }.value
            print("[ScrollEngine] sliced chapter=\(cIdx) chunks=\(output.chunks.count)")

            insert(chunks: output.chunks, chapterIndex: chapterIndex, prepend: prepend)
            loadedChapters.insert(chapterIndex)
        } catch {
            print("[ScrollEngine] buildChapter error chapter=\(chapterIndex) error=\(error)")
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
            let addedHeight = newChunks.reduce(CGFloat(0)) { $0 + $1.height }
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

    // MARK: - 單圖 chunk

    /// 把 cover / 整頁插圖造成單一 chunk。aspect-fit 到 contentWidth × min(naturalHeight, screenHeight)。
    private func makeImageOnlyChunk(
        image: UIImage,
        chapterIndex: Int,
        contentWidth: CGFloat,
        fallbackAttrStr: NSAttributedString
    ) -> CoreTextChunk {
        let aspect = image.size.height / max(image.size.width, 1)
        let naturalHeight = contentWidth * aspect
        let maxHeight = max(UIScreen.main.bounds.height - 80, contentWidth)
        let height = min(naturalHeight, maxHeight)
        let drawWidth = height < naturalHeight ? height / aspect : contentWidth
        let x = (contentWidth - drawWidth) / 2
        let rect = CGRect(x: x, y: 0, width: drawWidth, height: height)
        let attachment = CoreTextPaginator.RenderedAttachment(rect: rect, image: image, opacity: 1.0)
        let framesetter = CTFramesetterCreateWithAttributedString(fallbackAttrStr as CFAttributedString)
        return CoreTextChunk(
            chapterIndex: chapterIndex,
            charRange: CFRange(location: 0, length: max(fallbackAttrStr.length, 1)),
            size: CGSize(width: contentWidth, height: height),
            framesetter: framesetter,
            attributedString: fallbackAttrStr,
            frame: nil,
            presetAttachments: [attachment],
            isImageOnly: true
        )
    }

    // MARK: - Lookup

    /// 找出某 chunk index 對應的 (chapterIndex, charOffsetInChapter)
    func position(forChunkIndex idx: Int) -> (chapter: Int, charOffsetInChapter: Int)? {
        guard idx >= 0, idx < chunks.count else { return nil }
        let chunk = chunks[idx]
        return (chunk.chapterIndex, chunk.charRange.location)
    }

    /// 找出 (chapterIndex, charOffset) 對應的 chunk index
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
