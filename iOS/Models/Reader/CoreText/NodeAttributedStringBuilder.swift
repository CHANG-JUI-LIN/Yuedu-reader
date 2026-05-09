import Foundation
import UIKit

// MARK: - NodeAttributedStringBuilder
//
// 以 [UnifiedChapter] 為輸入，透過 RenderableNode IR 路徑產生 NSAttributedString。
// 實作 AttributedStringBuilding，可直接替換 TXTAttributedStringBuilder。
//
// 遷移策略（Phase 4/5）：
//   TXTPageEngine.init 根據 GlobalSettings.shared.useRenderableNodePipeline
//   決定建立 NodeAttributedStringBuilder 還是 TXTAttributedStringBuilder，
//   讓兩條管道在同一 session 內可切換比對。

struct NodeAttributedStringBuilder: AttributedStringBuilding {

    private let chapters: [UnifiedChapter]

    init(chapters: [UnifiedChapter]) {
        self.chapters = chapters
    }

    // MARK: - AttributedStringBuilding 基本資訊

    var chapterCount: Int { chapters.count }

    func chapterTitle(at index: Int) -> String {
        guard chapters.indices.contains(index) else { return "" }
        return chapters[index].title
    }

    func chapterSourceHref(at index: Int) -> String? {
        guard chapters.indices.contains(index) else { return nil }
        return chapters[index].sourceHref
    }

    func chapterIndex(for href: String) -> Int? {
        if let numericIndex = Int(href), chapters.indices.contains(numericIndex) {
            return numericIndex
        }
        let target = normalizedURLKey(href)
        guard !target.isEmpty else { return nil }
        return chapters.firstIndex { normalizedURLKey($0.sourceHref) == target }
    }

    func chapterDataSize(at index: Int) async -> Int {
        guard chapters.indices.contains(index) else { return 0 }
        return chapters[index].plainText.lengthOfBytes(using: .utf8)
    }

    // MARK: - buildChapter

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        guard chapters.indices.contains(index) else {
            throw AttributedStringBuildingError.chapterOutOfRange(index)
        }

        let chapter = chapters[index]

        // 1. Chapter → [RenderableNode]
        let nodes = TXTRenderableNodeConverter.convert(chapter: chapter)

        // 2. [RenderableNode] → NSAttributedString
        let rendererConfig = NodeAttributedStringRenderer.Config(from: settings, textColor: themeTextColor)
        let renderer = NodeAttributedStringRenderer(config: rendererConfig)
        let rendered = await renderer.render(nodes)

        return AttributedChapterBuildResult(
            attributedString: rendered,
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }

    // MARK: - 私有

    private func normalizedURLKey(_ raw: String?) -> String {
        guard let raw, var components = URLComponents(string: raw) else { return "" }
        components.fragment = nil
        components.queryItems = components.queryItems?.sorted { $0.name < $1.name }
        return (components.string ?? raw).lowercased()
    }
}

// MARK: - TXTRenderableNodeConverter
//
// 把 UnifiedChapter（TXT/Web 格式）轉成 [RenderableNode]。
//
// 行為與 TXTAttributedStringBuilder 相同：
//   - 章節標題 → heading level 2（置中）
//   - 每個段落 → paragraph，以全形空格 \u{3000}\u{3000} 開頭（等同 2em 首行縮排）
//     Phase 9 清理時可改成 RenderStyle.textIndent。

enum TXTRenderableNodeConverter {

    static func convert(chapter: UnifiedChapter) -> [RenderableNode] {
        var nodes: [RenderableNode] = []

        // ── 章節標題 ──
        let titleStyle = RenderStyle(
            fontSizeMultiplier: 1.0,   // heading level 2 → renderer 自動乘 1.5×
            bold: true,
            textAlign: .center,
            paragraphSpacingAfter: 24
        )
        nodes.append(.heading([.text(chapter.title)], level: 2, style: titleStyle))

        // ── 段落 ──
        for para in chapter.paragraphs {
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // 保留 \u{3000}\u{3000} 首行縮排以維持與舊管道完全相同的視覺輸出。
            // Phase 9 移除此前綴，改用 RenderStyle.textIndent。
            nodes.append(.paragraph([.text("\u{3000}\u{3000}" + trimmed)], style: .body))
        }

        return nodes
    }
}

// MARK: - OnlineNodeAttributedStringBuilder
//
// 線上小說章節的 AttributedStringBuilding 實作（Phase 6）。
// 從 BookSourceFetcher 讀取已快取的 ChapterPackage，
// 以 TXTRenderableNodeConverter 轉成 RenderableNode，再渲染成 NSAttributedString。
// 尚未快取的章節回傳空字串；fetch 完成後 CoreTextPageEngine 會重建頁面。

struct OnlineNodeAttributedStringBuilder: AttributedStringBuilding {

    let refs: [OnlineChapterRef]
    let bookId: UUID
    let fetcher: any BookSourceFetching

    // MARK: - AttributedStringBuilding

    var chapterCount: Int { refs.count }
    var prefersLazyByteScan: Bool { true }

    func chapterTitle(at index: Int) -> String {
        guard refs.indices.contains(index) else { return "" }
        return refs[index].title
    }

    func chapterSourceHref(at index: Int) -> String? {
        guard refs.indices.contains(index) else { return nil }
        return RuleEngine.sanitizeExtractedURL(refs[index].url)
    }

    func chapterIndex(for href: String) -> Int? {
        let target = normalizedURLKey(href)
        guard !target.isEmpty else { return nil }
        return refs.firstIndex { normalizedURLKey($0.url) == target }
    }

    func chapterDataSize(at index: Int) async -> Int {
        guard refs.indices.contains(index) else { return 0 }
        let ref = refs[index]
        let sanitizedURL = RuleEngine.sanitizeExtractedURL(ref.url)
        let pkg = fetcher.loadChapterPackageSync(
            bookId: bookId, chapterIndex: index,
            expectedSourceURL: sanitizedURL, expectedTOCTitle: ref.title)
        return pkg?.content.lengthOfBytes(using: .utf8) ?? 0
    }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        guard refs.indices.contains(index) else {
            throw AttributedStringBuildingError.chapterOutOfRange(index)
        }
        let ref = refs[index]
        let sanitizedURL = RuleEngine.sanitizeExtractedURL(ref.url)
        let pkg = fetcher.loadChapterPackageSync(
            bookId: bookId, chapterIndex: index,
            expectedSourceURL: sanitizedURL, expectedTOCTitle: ref.title)
        let content = pkg?.content ?? ""

        if content.isEmpty {
            throw AttributedStringBuildingError.contentNotCached(index)
        }

        // 壞快取（多章合併、異常超長）直接清掉並觸發重抓，避免永久卡在 128 頁
        if ChapterFetchManager.isSuspiciousChapterContent(content) {
            fetcher.clearChapterCache(bookId: bookId, chapterIndex: index)
            throw AttributedStringBuildingError.contentNotCached(index)
        }
        let paragraphs = ReaderHTMLUtilities.paragraphs(fromPlainText: content)

        let chapter = UnifiedChapter(
            index: index,
            title: ref.title,
            paragraphs: paragraphs,
            sourceHref: sanitizedURL
        )
        let nodes = TXTRenderableNodeConverter.convert(chapter: chapter)
        let rendererConfig = NodeAttributedStringRenderer.Config(from: settings, textColor: themeTextColor)
        let renderer = NodeAttributedStringRenderer(config: rendererConfig)
        return AttributedChapterBuildResult(
            attributedString: await renderer.render(nodes),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }

    // MARK: - Private

    private func normalizedURLKey(_ raw: String?) -> String {
        guard let raw, var components = URLComponents(string: raw) else { return "" }
        components.fragment = nil
        components.queryItems = components.queryItems?.sorted { $0.name < $1.name }
        return (components.string ?? raw).lowercased()
    }
}
