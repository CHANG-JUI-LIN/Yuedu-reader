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
        let nodes = TXTRenderableNodeConverter.convert(chapter: chapter)

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

    static func convert(chapter: UnifiedChapter) -> [RenderableNode] {
        var nodes: [RenderableNode] = []

        // ── Chapter title ──
        let titleStyle = RenderStyle(
            fontSizeMultiplier: 1.0,   // heading level 2 → renderer auto-scales to 1.5×
            bold: true,
            textAlign: .center,
            paragraphSpacingAfter: 24
        )
        nodes.append(.heading([.text(chapter.title)], level: 2, style: titleStyle))

        // ── Paragraphs ──
        for para in chapter.paragraphs {
            let trimmed = para.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Preserving \u{3000}\u{3000} prefix for visual consistency with the old pipeline.
            // Future work: remove this prefix and use RenderStyle.textIndent instead.
            nodes.append(.paragraph([.text("\u{3000}\u{3000}" + trimmed)], style: .body))
        }

        return nodes
    }

    /// Like `convert`, but each paragraph may carry a trailing paragraph-review (段評) badge.
    /// Layout matches `convert` exactly so review chapters look identical to ordinary chapters,
    /// with the tappable count bubble inlined at the end of its paragraph.
    static func convertReview(
        title: String,
        paragraphs: [ReaderHTMLUtilities.ReviewParagraph]
    ) -> [RenderableNode] {
        var nodes: [RenderableNode] = []

        let titleStyle = RenderStyle(
            fontSizeMultiplier: 1.0,   // heading level 2 → renderer auto-scales to 1.5×
            bold: true,
            textAlign: .center,
            paragraphSpacingAfter: 24
        )
        nodes.append(.heading([.text(title)], level: 2, style: titleStyle))

        for para in paragraphs {
            var inlines: [RenderableNode] = []
            let trimmed = para.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                inlines.append(.text("\u{3000}\u{3000}" + trimmed))
            }
            if let href = para.reviewHref,
               let marker = ReaderHTMLUtilities.decodeReviewHref(href) {
                // Thin space so the bubble doesn't butt against the final glyph.
                if !inlines.isEmpty {
                    inlines.append(.text("\u{2009}"))
                }
                inlines.append(
                    .commentBadge(count: marker.count, reviewURL: href, title: marker.title)
                )
            }
            guard !inlines.isEmpty else { continue }
            nodes.append(.paragraph(inlines, style: .body))
        }

        return nodes
    }
}

// MARK: - OnlineNodeAttributedStringBuilder
//
// AttributedStringBuilding implementation for online novel chapters.
// Reads cached ChapterPackages from BookSourceFetcher. Chapters with HTML-only
// paragraph-review markers are rendered from cached normalized HTML; ordinary
// text chapters continue through TXTRenderableNodeConverter.
// Uncached chapters return an empty string; once fetched, CoreTextPageEngine rebuilds the page.

struct OnlineNodeAttributedStringBuilder: AttributedStringBuilding {

    let refs: [OnlineChapterRef]
    let bookId: UUID
    let fetcher: any BookSourceFetching

    // MARK: - AttributedStringBuilding

    var chapterCount: Int { refs.count }
    var prefersLazyByteScan: Bool { true }

    func chapterTitle(at index: Int) -> String {
        guard refs.indices.contains(index) else { return "" }
        return ReaderHTMLUtilities.displayText(fromHTMLFragment: refs[index].title)
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
        guard let package = pkg, !package.content.isEmpty else {
            throw AttributedStringBuildingError.contentNotCached(index)
        }
        let content = package.content

        // Bad cache (merged chapters, abnormally long content): clear it and trigger refetch to avoid permanently showing excessive pages
        if ChapterFetchManager.isSuspiciousChapterContent(content) {
            fetcher.clearChapterCache(bookId: bookId, chapterIndex: index)
            throw AttributedStringBuildingError.contentNotCached(index)
        }

        if OnlineChapterCacheWritePolicy.shouldRefetchStrippedRenderArtifacts(
            package: package,
            hasBookSource: true
        ) {
            fetcher.clearChapterCache(bookId: bookId, chapterIndex: index)
            throw AttributedStringBuildingError.contentNotCached(index)
        }

        let displayTitle = ReaderHTMLUtilities.displayText(fromHTMLFragment: ref.title)

        // Paragraph-review chapters render through the SAME node/text layout as ordinary
        // chapters (first-line indent, centered title, configured spacing); the per-paragraph
        // 段評 badge is appended as an inline node at the end of its paragraph. Rendering the
        // raw source HTML through HTMLAttributedStringBuilder instead would swap renderers and
        // wreck the layout.
        var nodes: [RenderableNode]?
        if let reviewHTML = cachedReviewHTML(for: ref, package: package, sanitizedURL: sanitizedURL) {
            let reviewParagraphs = ReaderHTMLUtilities.reviewParagraphs(
                fromHTML: reviewHTML,
                excludingLeadingTitle: displayTitle
            )
            if reviewParagraphs.contains(where: { $0.reviewHref != nil }) {
                nodes = TXTRenderableNodeConverter.convertReview(
                    title: displayTitle,
                    paragraphs: reviewParagraphs
                )
            }
        }

        if nodes == nil {
            let paragraphs = ReaderHTMLUtilities.bodyParagraphs(
                fromPlainText: content,
                excludingLeadingTitle: displayTitle
            )
            let chapter = UnifiedChapter(
                index: index,
                title: displayTitle,
                paragraphs: paragraphs,
                sourceHref: sanitizedURL
            )
            nodes = TXTRenderableNodeConverter.convert(chapter: chapter)
        }

        let rendererConfig = NodeAttributedStringRenderer.Config(
            from: settings,
            textColor: themeTextColor,
            fontFamily: UserReaderFontResolver.selectedPostScriptName
        )
        let renderer = NodeAttributedStringRenderer(config: rendererConfig)
        return AttributedChapterBuildResult(
            attributedString: await renderer.render(nodes ?? []),
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

    private func cachedReviewHTML(
        for ref: OnlineChapterRef,
        package: ChapterPackage,
        sanitizedURL: String
    ) -> String? {
        guard package.rawHTMLFilename != nil || package.normalizedHTMLFilename != nil else {
            return nil
        }

        let html = fetcher.loadNormalizedChapterHTMLSync(
            bookId: bookId,
            chapterIndex: ref.index,
            expectedSourceURL: sanitizedURL,
            expectedTOCTitle: ref.title
        )
        ?? (sanitizedURL != ref.url
            ? fetcher.loadNormalizedChapterHTMLSync(
                bookId: bookId,
                chapterIndex: ref.index,
                expectedSourceURL: ref.url,
                expectedTOCTitle: ref.title
            )
            : nil)

        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let rewritten = ReaderHTMLUtilities.rewriteReviewComments(html)
        guard rewritten.range(of: "ydreview://", options: .caseInsensitive) != nil else {
            return nil
        }
        return rewritten
    }

}
