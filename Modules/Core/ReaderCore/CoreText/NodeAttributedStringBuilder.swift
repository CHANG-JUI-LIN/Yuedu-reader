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

@MainActor
final class OnlineNodeAttributedStringBuilder: @preconcurrency AttributedStringBuilding, RenderSizeAwareAttributedStringBuilding {

    private let refs: [OnlineChapterRef]
    private let bookId: UUID
    private let fetcher: any BookSourceFetching
    private var renderSize: CGSize

    init(
        refs: [OnlineChapterRef],
        bookId: UUID,
        fetcher: any BookSourceFetching,
        renderSize: CGSize = .zero
    ) {
        self.refs = refs
        self.bookId = bookId
        self.fetcher = fetcher
        self.renderSize = renderSize
    }

    // MARK: - AttributedStringBuilding

    var chapterCount: Int { refs.count }
    var prefersLazyByteScan: Bool { true }

    func updateRenderSize(_ size: CGSize) {
        renderSize = size
    }

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
        // Volume headers render a divider (no package); report a non-zero size so the engine
        // treats them as loaded rather than an empty chapter awaiting content.
        if ref.shouldRenderAsVolumeSeparator {
            return max(1, ref.title.lengthOfBytes(using: .utf8))
        }
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

        // Volume headers (作品相关 / 第N卷 …) carry no fetchable chapter content; loading one as a
        // chapter spins forever. Render a centered volume-title divider page instead of fetching.
        if ref.shouldRenderAsVolumeSeparator {
            return await volumeDividerResult(
                title: ReaderHTMLUtilities.displayText(fromHTMLFragment: ref.title),
                settings: settings,
                themeTextColor: themeTextColor,
                themeBackgroundColor: themeBackgroundColor
            )
        }

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

        if let html = cachedNormalizedHTML(for: ref, package: package, sanitizedURL: sanitizedURL) {
            // Skeleton: strip the huge base64 data-URIs so the tag structure (p/small/img/…) is visible.
            let skeleton = html
                .replacingOccurrences(of: #"base64,[A-Za-z0-9+/=]+"#, with: "base64,…", options: .regularExpression)
                .replacingOccurrences(of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
            AppLogger.parse("⟐ reviewDiag", context: [
                "index": index,
                "title": ref.title,
                "imgCount": html.components(separatedBy: "<img").count - 1,
                "ydreviewCount": html.components(separatedBy: "ydreview://").count - 1,
                "ydReviewImage": html.contains("yd-review-image"),
                "hasComment": html.range(of: "<comment", options: .caseInsensitive) != nil,
                "skeleton": String(skeleton.prefix(900))
            ])
            if html.range(of: "<img", options: .caseInsensitive) != nil,
               let htmlResult = await buildHTMLChapter(
                html: html,
                settings: settings,
                themeTextColor: themeTextColor,
                themeBackgroundColor: themeBackgroundColor
               ) {
                return htmlResult
            }
        }

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
            let badgeCount = reviewParagraphs.filter { $0.reviewHref != nil }.count
            AppLogger.parse("⟐ reviewRender", context: [
                "index": index,
                "branch": badgeCount > 0 ? "reviewNodes" : "reviewHTML-noBadges",
                "paras": reviewParagraphs.count,
                "badges": badgeCount,
                "ydreview": reviewHTML.components(separatedBy: "ydreview://").count - 1
            ])
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

    /// Renders a volume header (作品相关 / 第N卷 …) as a standalone centered title page, matching
    /// how the official client shows a volume divider. No content is fetched.
    private func volumeDividerResult(
        title: String,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async -> AttributedChapterBuildResult {
        let displayTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleStyle = RenderStyle(
            fontSizeMultiplier: 1.0,   // heading level 1 → renderer auto-scales larger
            bold: true,
            textAlign: .center,
            paragraphSpacingAfter: 24
        )
        let nodes: [RenderableNode] = [
            .heading([.text(displayTitle.isEmpty ? "—" : displayTitle)], level: 1, style: titleStyle)
        ]
        let rendererConfig = NodeAttributedStringRenderer.Config(
            from: settings,
            textColor: themeTextColor,
            fontFamily: UserReaderFontResolver.selectedPostScriptName
        )
        let renderer = NodeAttributedStringRenderer(config: rendererConfig)
        return AttributedChapterBuildResult(
            attributedString: await renderer.render(nodes),
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }

    private func cachedNormalizedHTML(
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

        return html
    }

    private func cachedReviewHTML(
        for ref: OnlineChapterRef,
        package: ChapterPackage,
        sanitizedURL: String
    ) -> String? {
        guard let html = cachedNormalizedHTML(for: ref, package: package, sanitizedURL: sanitizedURL) else {
            return nil
        }

        let rewritten = ReaderHTMLUtilities.rewriteReviewComments(html)
        let markerCount = rewritten.components(separatedBy: "ydreview://").count - 1
        AppLogger.parse("⟐ reviewCache", context: [
            "index": package.chapterIndex,
            "title": ref.title,
            "htmlLen": html.count,
            "rewrittenLen": rewritten.count,
            "commentTags": html.lowercased().components(separatedBy: "<comment").count - 1,
            "ydreview": markerCount,
            "reviewImage": rewritten.contains("yd-review-image"),
            "hasImg": html.range(of: "<img", options: .caseInsensitive) != nil
        ])
        guard markerCount > 0 else {
            return nil
        }
        return rewritten
    }

    private func buildHTMLChapter(
        html: String,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async -> AttributedChapterBuildResult? {
        // DEFENSIVE: normalized HTML is supposed to be sanitized at fetch time, but chapters
        // cached by older builds (before the sanitize pipeline) still carry the Legado
        // `,{json}` click-config suffix. Its inner double-quotes prematurely close the `src`
        // attribute, so SwiftSoup swallows the rest of the chapter → only the first ~few
        // hundred chars survive (the "第一章 renders blank / data-URI shown as text" bug).
        // sanitize is guarded by a `,{` check, so it's a no-op on already-clean cache.
        let hadClickConfig = html.range(of: ",{") != nil
        let sanitized = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(html)
        if hadClickConfig {
            AppLogger.parse("⟐ staleCacheSanitized", context: [
                "inLen": html.count,
                "outLen": sanitized.count,
                "stillHasClickConfig": sanitized.range(of: ",{") != nil
            ])
        }
        let rewritten = ReaderHTMLUtilities.rewriteReviewComments(sanitized)
        AppLogger.parse("⟐ reviewHTML render", context: [
            "inYdreview": html.components(separatedBy: "ydreview://").count - 1,
            "outYdreview": rewritten.components(separatedBy: "ydreview://").count - 1,
            "inComment": html.lowercased().components(separatedBy: "<comment").count - 1,
            "hasReviewImage": rewritten.contains("yd-review-image"),
            "hasImg": html.range(of: "<img", options: .caseInsensitive) != nil
        ])
        let renderWidth = max(0, renderSize.width)
        let config = HTMLAttributedStringBuilder.Config(
            fontSize: settings.fontSize,
            lineHeightMultiple: settings.lineHeightMultiple,
            lineSpacing: settings.lineSpacing,
            paragraphSpacing: settings.paragraphSpacing,
            firstLineIndent: settings.fontSize * 2,  // 2-em first-line indent, matching TXT chapters
            textColor: themeTextColor,
            backgroundColor: themeBackgroundColor,
            fontFamilyName: UserReaderFontResolver.selectedPostScriptName,
            renderWidth: renderWidth,
            writingMode: settings.writingMode
        )
        let builder = HTMLAttributedStringBuilder()
        builder.imageLoader = { [weak self] src in
            guard let self else { return nil }
            let renderWidth = self.currentRenderWidth()
            return await OnlineImageLoader.load(src: src, renderWidth: renderWidth)
        }

        guard let ast = await builder.buildStyledAST(html: rewritten, config: config) else {
            return nil
        }

        if let imagePage = await builder.imagePage(from: ast) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: settings.fontSize),
                .foregroundColor: themeTextColor,
                .backgroundColor: themeBackgroundColor,
            ]
            return AttributedChapterBuildResult(
                attributedString: NSAttributedString(string: "\u{FFFC}", attributes: attrs),
                imagePage: imagePage,
                pageBackgroundImage: nil,
                anchorOffsets: [:]
            )
        }

        let rawNodes = HTMLStyledASTRenderableNodeConverter.convert(body: ast)
        AppLogger.parse("⟐ nodeTree", context: ["tree": String(Self.describeNodes(rawNodes).prefix(800))])
        // Lift standalone content illustrations out of the text flow onto their own centered line
        // at natural size (renderer caps at column), instead of inline-left with text wrapping.
        // Comment-bubble images (review `<a>` wrappers) untouched.
        let nodes = Self.fullWidthCenterContentImages(rawNodes, columnWidth: renderWidth, firstLineIndent: settings.fontSize * 2)
        AppLogger.parse("⟐ imgLayout", context: [
            "renderWidth": renderWidth,
            "rawTopNodes": rawNodes.count,
            "topNodes": nodes.count,
            "imagesLifted": Self.countCenteredImageBlocks(nodes)
        ])
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: settings,
                textColor: themeTextColor,
                fontFamily: UserReaderFontResolver.selectedPostScriptName,
                renderWidth: renderWidth,
                imageLoader: { [weak self] src in
                    guard let self else { return nil }
                    let renderWidth = self.currentRenderWidth()
                    return await OnlineImageLoader.load(src: src, renderWidth: renderWidth)
                }
            )
        )
        let _renderStart = Date()
        AppLogger.render("⟐ renderNodes start", context: ["topNodes": nodes.count])
        let attributedString = await renderer.render(nodes)
        AppLogger.render("⟐ renderNodes done", context: [
            "ms": Int(Date().timeIntervalSince(_renderStart) * 1000),
            "len": attributedString.length
        ])
        return AttributedChapterBuildResult(
            attributedString: attributedString,
            imagePage: nil,
            pageBackgroundImage: await builder.pageBackgroundImage(from: ast),
            anchorOffsets: builder.anchorOffsets(in: attributedString)
        )
    }

    private func currentRenderWidth() -> CGFloat {
        max(0, renderSize.width)
    }

    // MARK: - Content image layout

    /// Lifts standalone content images onto their own centered line (natural size) and groups
    /// loose inline content (bare text + `<small>` tag runs) into proper paragraphs so the body
    /// reads correctly instead of everything concatenating on one line.
    /// Comment-bubble images (wrapped in a review `<a>`/anchor) stay inline within their run.
    private static func fullWidthCenterContentImages(
        _ nodes: [RenderableNode],
        columnWidth: CGFloat,
        firstLineIndent: CGFloat
    ) -> [RenderableNode] {
        nodes.flatMap { expandContentImages(in: $0, columnWidth: columnWidth, firstLineIndent: firstLineIndent) }
    }

    private static func expandContentImages(
        in node: RenderableNode,
        columnWidth: CGFloat,
        firstLineIndent: CGFloat
    ) -> [RenderableNode] {
        switch node {
        case .image:
            // A bare, standalone image (no surrounding text) is a content illustration — e.g. the
            // 版权信息 page's full-width SVG card. Lift it onto its own centered line. (段評 comment
            // bubbles are never bare: they always trail paragraph text, handled in `.paragraph`.)
            return [centeredImageBlock(node, columnWidth: columnWidth)]

        case .paragraph(let children, let style):
            // An SVG that shares its paragraph with real text is an inline 段評 bubble (sits at the
            // line end, like 光遇) — keep it. An SVG that is the paragraph's sole content is a
            // standalone illustration (版权信息 card) — lift & center it, otherwise the first-line
            // indent shoves it off to the right.
            let hasText = hasTextLikeSibling(children)
            let needsSplit = children.contains { child in
                if case .image = child { return !(isInlineSVGImage(child) && hasText) }
                if case .inline(let t, _, _) = child { return t.lowercased() == "small" }
                return false
            }
            guard needsSplit else { return [node] }
            return splitAroundImages(children, columnWidth: columnWidth, keepSVGInline: hasText) { run in
                .paragraph(run, style: style)
            }

        case .block(let tag, let children, let style):
            let expanded = children.flatMap { expandContentImages(in: $0, columnWidth: columnWidth, firstLineIndent: firstLineIndent) }
            return [.block(tag: tag, children: groupLooseInline(expanded, indent: firstLineIndent), style: style)]

        case .blockquote(let children):
            let expanded = children.flatMap { expandContentImages(in: $0, columnWidth: columnWidth, firstLineIndent: firstLineIndent) }
            return [.blockquote(groupLooseInline(expanded, indent: firstLineIndent))]

        case .listItem(let children, let bullet):
            return [.listItem(children.flatMap { expandContentImages(in: $0, columnWidth: columnWidth, firstLineIndent: firstLineIndent) }, bullet: bullet)]

        case .heading:
            // A title may carry a 本章说 bubble appended inline — keep heading children as-authored
            // (don't lift the bubble onto its own line).
            return [node]

        // `<article id="reader-content">` (and any id'd element) is wrapped in an anchorTarget —
        // we MUST descend through it, otherwise the whole chapter's images are never reached.
        case .anchorTarget(let id, let child):
            let expanded = expandContentImages(in: child, columnWidth: columnWidth, firstLineIndent: firstLineIndent)
            if expanded.count == 1 {
                return [.anchorTarget(id: id, child: expanded[0])]
            }
            return [.anchorTarget(id: id, child: .block(tag: "div", children: groupLooseInline(expanded, indent: firstLineIndent), style: .none))]

        // A `<small>` directly in a block (the 版权信息 page's genre-tag run) → its own un-indented line.
        case .inline(let tag, _, _) where tag.lowercased() == "small":
            return [.paragraph([node], style: .none)]

        default:
            return [node]
        }
    }

    /// Wraps runs of loose inline siblings (bare text, spans, links) into paragraphs so they get a
    /// real line break + first-line indent, instead of being concatenated by `renderBlock`.
    /// Block-level children (headings, images-as-blocks, the `<small>` paragraph) pass through.
    private static func groupLooseInline(_ nodes: [RenderableNode], indent: CGFloat) -> [RenderableNode] {
        guard nodes.contains(where: isLooseInline) else { return nodes }
        var result: [RenderableNode] = []
        var run: [RenderableNode] = []
        func flush() {
            defer { run = [] }
            guard run.contains(where: { !isBlankInline($0) }) else { return }
            var style = RenderStyle.none
            style.textIndent = indent
            result.append(.paragraph(run, style: style))
        }
        for node in nodes {
            if isLooseInline(node) {
                run.append(node)
            } else {
                flush()
                result.append(node)
            }
        }
        flush()
        return result
    }

    /// SVG images (段評 comment bubbles, info cards) must stay INLINE in the text flow — only
    /// raster/remote illustrations (e.g. the 版权页 author photo) get lifted onto their own
    /// centered line. Lifting inline SVG bubbles is what made 光遇's line-end bubbles jump to
    /// their own line (the regression the user reported).
    private static func isInlineSVGImage(_ node: RenderableNode) -> Bool {
        guard case .image(let src, _, _, let svgContent) = node else { return false }
        if svgContent != nil { return true }
        let s = src.lowercased()
        return s.contains("svg+xml") || s.contains("data:image/svg")
    }

    /// True when a run carries real inline text/content, meaning an accompanying SVG image is an
    /// inline 段評 bubble (trailing the text) rather than a standalone illustration to be centered.
    private static func hasTextLikeSibling(_ children: [RenderableNode]) -> Bool {
        children.contains { node in
            switch node {
            case .text(let s): return !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .inline, .anchor, .ruby, .commentBadge: return true
            default: return false
            }
        }
    }

    private static func isLooseInline(_ node: RenderableNode) -> Bool {
        switch node {
        case .text, .inline, .anchor, .ruby, .lineBreak, .commentBadge:
            return true
        default:
            return false
        }
    }

    /// Splits a paragraph's children at bare images: inline runs stay paragraphs, each image
    /// becomes its own centered block. Anchor-wrapped (review) images remain inside the run.
    private static func splitAroundImages(
        _ children: [RenderableNode],
        columnWidth: CGFloat,
        keepSVGInline: Bool,
        wrapInline: ([RenderableNode]) -> RenderableNode
    ) -> [RenderableNode] {
        var result: [RenderableNode] = []
        var run: [RenderableNode] = []
        func flush() {
            defer { run = [] }
            guard run.contains(where: { !isBlankInline($0) }) else { return }
            result.append(wrapInline(run))
        }
        for child in children {
            if case .image = child, !(isInlineSVGImage(child) && keepSVGInline) {
                flush()
                result.append(centeredImageBlock(child, columnWidth: columnWidth))
            } else if case .inline(let t, _, _) = child, t.lowercased() == "small" {
                // A `<small>` tag-run (genre tags on the 版权信息 page) sits inline at the end of
                // the description paragraph. Break it onto its own un-indented line.
                flush()
                result.append(.paragraph([child], style: .none))
            } else {
                run.append(child)
            }
        }
        flush()
        return result.isEmpty ? [wrapInline(children)] : result
    }

    private static func isBlankInline(_ node: RenderableNode) -> Bool {
        if case .text(let s) = node { return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if case .lineBreak = node { return true }
        return false
    }

    private static func centeredImageBlock(_ imageNode: RenderableNode, columnWidth: CGFloat) -> RenderableNode {
        guard case .image = imageNode else { return imageNode }
        // Render at the image's NATURAL size (capped at the column by the renderer's image-metrics
        // stage), like the official client — do NOT upscale small images to full width. Just lift
        // it onto its own centered line so body text doesn't wrap awkwardly beside it.
        var blockStyle = RenderStyle.none
        blockStyle.textAlign = .center
        blockStyle.isHorizontallyCentered = true
        return .block(tag: "div", children: [imageNode], style: blockStyle)
    }

    /// Diagnostic: compact node-tree description (node type + tag + short text) for logging.
    private static func describeNodes(_ nodes: [RenderableNode], depth: Int = 0) -> String {
        guard depth < 7 else { return "…" }
        return nodes.map { node -> String in
            switch node {
            case .text(let s):
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? "·" : "txt(\(t.prefix(6)))"
            case .image(let src, _, let st, let svg):
                let id = svg != nil ? "svg" : String(src.prefix(16))
                return "IMG[\(id)|w=\(st.width.map { Int($0) } ?? -1)]"
            case .paragraph(let c, _): return "P{\(describeNodes(c, depth: depth + 1))}"
            case .heading(let c, let l, _): return "h\(l){\(describeNodes(c, depth: depth + 1))}"
            case .block(let t, let c, _): return "blk(\(t)){\(describeNodes(c, depth: depth + 1))}"
            case .inline(let t, let c, _): return "inl(\(t)){\(describeNodes(c, depth: depth + 1))}"
            case .anchor(_, let c): return "a{\(describeNodes(c, depth: depth + 1))}"
            case .anchorTarget(_, let ch): return "aT{\(describeNodes([ch], depth: depth + 1))}"
            case .blockquote(let c): return "bq{\(describeNodes(c, depth: depth + 1))}"
            case .lineBreak: return "br"
            default: return "?"
            }
        }.joined(separator: ",")
    }

    /// Diagnostic: count the centered image blocks this transform produced (recursively).
    private static func countCenteredImageBlocks(_ nodes: [RenderableNode]) -> Int {
        var count = 0
        for node in nodes {
            switch node {
            case .block(_, let children, let style):
                if style.isHorizontallyCentered, children.count == 1, case .image = children[0] {
                    count += 1
                }
                count += countCenteredImageBlocks(children)
            case .blockquote(let children):
                count += countCenteredImageBlocks(children)
            case .paragraph(let children, _):
                count += countCenteredImageBlocks(children)
            case .heading(let children, _, _):
                count += countCenteredImageBlocks(children)
            case .listItem(let children, _):
                count += countCenteredImageBlocks(children)
            case .anchorTarget(_, let child):
                count += countCenteredImageBlocks([child])
            default:
                break
            }
        }
        return count
    }

}
