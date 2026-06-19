import Foundation
import UIKit

// MARK: - NodeAttributedStringBuilder
//
// Takes [UnifiedChapter] as input, produces NSAttributedString via the RenderableNode IR path.
// Implements AttributedStringBuilding, directly replacing TXTAttributedStringBuilder.
//
// TXTPageEngine uses this builder directly so TXT/Markdown content shares the same IR renderer.

struct NodeAttributedStringBuilder: AttributedStringBuilding {

    private let chapters: [UnifiedChapter]

    init(chapters: [UnifiedChapter]) {
        self.chapters = chapters
    }

    // MARK: - AttributedStringBuilding Basic Info

    var chapterCount: Int { chapters.count }

    func chapterTitle(at index: Int) -> String {
        guard chapters.indices.contains(index) else { return "" }
        return ReaderHTMLUtilities.displayText(fromHTMLFragment: chapters[index].title)
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
        let nodes = TXTRenderableNodeConverter.convert(chapter: chapter, firstLineIndent: settings.fontSize * 2)

        // 2. [RenderableNode] → NSAttributedString
        let rendererConfig = NodeAttributedStringRenderer.Config(
            from: settings,
            textColor: themeTextColor,
            fontFamily: UserReaderFontResolver.selectedPostScriptName
        )
        let renderer = NodeAttributedStringRenderer(config: rendererConfig)
        let rendered = await renderer.render(nodes)

        return AttributedChapterBuildResult(
            attributedString: rendered,
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

// MARK: - TXTRenderableNodeConverter
//
// Converts UnifiedChapter (TXT/Web format) into [RenderableNode].
//
// Behavior matches TXTAttributedStringBuilder:
//   - Chapter title → heading level 2 (centered)
//   - Each paragraph → paragraph, prefixed with \u{3000}\u{3000} for 2em first-line indent
//     Can be replaced with RenderStyle.textIndent in a future cleanup.

enum TXTRenderableNodeConverter {

    static func convert(chapter: UnifiedChapter, firstLineIndent: CGFloat) -> [RenderableNode] {
        var nodes: [RenderableNode] = []

        // ── Chapter title ──
        let titleStyle = RenderStyle(
            fontSizeMultiplier: 1.0,   // heading level 2 → renderer auto-scales to 1.5×
            bold: true,
            textAlign: .center,
            paragraphSpacingAfter: 24
        )
        nodes.append(.heading([.text(chapter.title.trimmingCharacters(in: .whitespacesAndNewlines))], level: 2, style: titleStyle))

        // ── Paragraphs ──
        // Indent via paragraph firstLineHeadIndent (textIndent), NOT a literal U+3000 prefix:
        // a user font that lacks the ideographic-space glyph (e.g. WeRead/楷) would make CoreText
        // resolve the whole paragraph run starting from that space → fall back to PingFang for the
        // entire line. Real CJK text as the run's first glyph keeps the user font.
        let bodyStyle = RenderStyle(textIndent: firstLineIndent)
        for para in chapter.paragraphs {
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            nodes.append(.paragraph([.text(trimmed)], style: bodyStyle))
        }

        return nodes
    }

    /// Like `convert`, but each paragraph may carry a trailing paragraph-review (段評) badge.
    /// Layout matches `convert` exactly so review chapters look identical to ordinary chapters,
    /// with the tappable count bubble inlined at the end of its paragraph.
    static func convertReview(
        title: String,
        paragraphs: [ReaderHTMLUtilities.ReviewParagraph],
        firstLineIndent: CGFloat
    ) -> [RenderableNode] {
        var nodes: [RenderableNode] = []

        let titleStyle = RenderStyle(
            fontSizeMultiplier: 1.0,   // heading level 2 → renderer auto-scales to 1.5×
            bold: true,
            textAlign: .center,
            paragraphSpacingAfter: 24
        )
        nodes.append(.heading([.text(title.trimmingCharacters(in: .whitespacesAndNewlines))], level: 2, style: titleStyle))

        // Indent via paragraph firstLineHeadIndent (textIndent), NOT a literal U+3000 prefix —
        // see `convert` above: a leading ideographic space the user font lacks poisons the whole
        // paragraph run's font (→ PingFang fallback for narration). Real CJK first glyph keeps WeRead.
        let bodyStyle = RenderStyle(textIndent: firstLineIndent)
        for para in paragraphs {
            var inlines: [RenderableNode] = []
            let trimmed = para.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                inlines.append(.text(trimmed))
            }
            if let href = para.reviewHref,
               let marker = ReaderHTMLUtilities.decodeReviewHref(href) {
                inlines.append(
                    .commentBadge(count: marker.count, reviewURL: href, title: marker.title)
                )
            }
            guard !inlines.isEmpty else { continue }
            nodes.append(.paragraph(inlines, style: bodyStyle))
        }

        return nodes
    }
}


// OnlineNodeAttributedStringBuilder removed — unified into OnlineProviderAttributedStringBuilder.
// See OnlineProviderAttributedStringBuilder in OnlineProviderAttributedStringBuilder.swift.
// OnlineChapterContentService in OnlineChapterContentService.swift owns cache/fetch/HTML assembly.
