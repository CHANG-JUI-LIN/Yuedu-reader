import Foundation
import UIKit

/// Removes the source-provided title before an advanced-CSS title template is
/// prepended. Online review markup can represent `div` wrappers as paragraph
/// nodes, so this walks the first structural-content spine rather than assuming
/// every wrapper is `.block`.
enum OnlineChapterTitleDeduplicator {
    struct Result {
        let bodyNodes: [RenderableNode]
        let titleAccessories: [RenderableNode]
    }

    private enum NodeUpdate {
        case remove(accessories: [RenderableNode])
        case replace(RenderableNode, accessories: [RenderableNode])
    }

    static func deduplicatingLeadingTitle(
        from nodes: [RenderableNode],
        matching chapterTitle: String
    ) -> Result {
        let titleKey = normalizedTitleKey(chapterTitle)
        guard !titleKey.isEmpty,
              let stripped = strippingFirstTitle(in: nodes, matching: titleKey, depth: 0)
        else {
            AppLogger.render("⟐ title.dedup miss title=«\(chapterTitle.prefix(12))»")
            return Result(bodyNodes: nodes, titleAccessories: [])
        }
        AppLogger.render("⟐ title.dedup hit title=«\(chapterTitle.prefix(12))»")
        return Result(bodyNodes: stripped.nodes, titleAccessories: stripped.accessories)
    }

    static func removingLeadingTitle(
        from nodes: [RenderableNode],
        matching chapterTitle: String
    ) -> [RenderableNode] {
        deduplicatingLeadingTitle(from: nodes, matching: chapterTitle).bodyNodes
    }

    private static func strippingFirstTitle(
        in nodes: [RenderableNode],
        matching titleKey: String,
        depth: Int
    ) -> (nodes: [RenderableNode], accessories: [RenderableNode])? {
        guard depth < 12 else { return nil }
        for (index, node) in nodes.enumerated() {
            if case .text(let text) = node,
               text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            guard let update = titleUpdate(for: node, matching: titleKey, depth: depth) else {
                return nil
            }
            var copy = nodes
            switch update {
            case .remove(let accessories):
                copy.remove(at: index)
                return (copy, accessories)
            case .replace(let replacement, let accessories):
                copy[index] = replacement
                return (copy, accessories)
            }
        }
        return nil
    }

    private static func titleUpdate(
        for node: RenderableNode,
        matching titleKey: String,
        depth: Int
    ) -> NodeUpdate? {
        switch node {
        case .anchorTarget(let id, let child):
            guard let update = titleUpdate(
                for: child,
                matching: titleKey,
                depth: depth + 1
            ) else { return nil }
            switch update {
            case .remove(let accessories):
                return .remove(accessories: accessories)
            case .replace(let replacement, let accessories):
                return .replace(
                    .anchorTarget(id: id, child: replacement),
                    accessories: accessories
                )
            }

        case .block(let tag, let children, let style):
            guard let stripped = strippingFirstTitle(
                in: children,
                matching: titleKey,
                depth: depth + 1
            ) else { return nil }
            return .replace(
                .block(tag: tag, children: stripped.nodes, style: style),
                accessories: stripped.accessories
            )

        case .paragraph(let children, let style):
            // HTMLStyledASTRenderableNodeConverter intentionally maps `<div>`
            // to `.paragraph`. A wrapper paragraph therefore may contain more
            // paragraphs; descend before treating it as a leaf title line.
            if children.contains(where: isStructuralNode) {
                guard let stripped = strippingFirstTitle(
                    in: children,
                    matching: titleKey,
                    depth: depth + 1
                ) else { return nil }
                return .replace(
                    .paragraph(stripped.nodes, style: style),
                    accessories: stripped.accessories
                )
            }
            guard normalizedTitleKey(plainText(of: children)) == titleKey else { return nil }
            let survivors = removingTextRuns(from: children)
            return .remove(accessories: survivors)

        case .heading(let children, _, _):
            guard normalizedTitleKey(plainText(of: children)) == titleKey else { return nil }
            let survivors = removingTextRuns(from: children)
            return .remove(accessories: survivors)

        default:
            return nil
        }
    }

    private static func isStructuralNode(_ node: RenderableNode) -> Bool {
        switch node {
        case .block, .paragraph, .heading, .blockquote, .listItem:
            return true
        case .anchorTarget(_, let child):
            return isStructuralNode(child)
        default:
            return false
        }
    }

    /// Removes only typographic title content. Review badges and images remain,
    /// including when they share an inline wrapper with the title text.
    private static func removingTextRuns(from nodes: [RenderableNode]) -> [RenderableNode] {
        nodes.compactMap { node in
            switch node {
            case .text, .lineBreak, .ruby:
                return nil
            case .inline(let tag, let children, let style):
                let survivors = removingTextRuns(from: children)
                return survivors.isEmpty
                    ? nil
                    : .inline(tag: tag, children: survivors, style: style)
            case .anchor(let href, let children):
                let survivors = removingTextRuns(from: children)
                return survivors.isEmpty ? nil : .anchor(href: href, children: survivors)
            case .anchorTarget(let id, let child):
                guard let survivor = removingTextRuns(from: [child]).first else { return nil }
                return .anchorTarget(id: id, child: survivor)
            default:
                return node
            }
        }
    }

    private static func normalizedTitleKey(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }

    private static func plainText(of nodes: [RenderableNode]) -> String {
        nodes.map { node in
            switch node {
            case .text(let text):
                return text
            case .paragraph(let children, _),
                 .heading(let children, _, _),
                 .block(_, let children, _),
                 .inline(_, let children, _),
                 .anchor(_, let children),
                 .blockquote(let children),
                 .listItem(let children, _):
                return plainText(of: children)
            case .anchorTarget(_, let child):
                return plainText(of: [child])
            case .ruby(let base, _, _):
                return plainText(of: base)
            case .unsupportedInteractive(_, _, let children, _):
                return plainText(of: children)
            default:
                return ""
            }
        }.joined()
    }
}

/// Wraps `BookContentProvider` (online book source) as `AttributedStringBuilding`,
/// allowing `CoreTextScrollEngine` to directly consume online chapters.
///
/// Content handling:
///   - If `payload.body` is `.html` → use `HTMLAttributedStringBuilder` (preserves styling)
///   - If `payload.body` is `.plainText` → fall back to TXT pattern (title + paragraphs + indent)
@MainActor
final class OnlineProviderAttributedStringBuilder: @preconcurrency AttributedStringBuilding, RenderSizeAwareAttributedStringBuilding {

    private let provider: any BookContentProvider
    private let resourceProvider: (any BookResourceProvider)?
    private let styleResolver: EPUBStyleResolver?
    private let chapterSourceHrefs: [String?]
    private var cachedPayloadSourceHrefs: [Int: String] = [:]
    private var renderSize: CGSize
    /// Per-source content-image decryptor (Legado `ruleContent.imageDecode`),
    /// applied to downloaded image bytes before decoding. nil for most sources.
    private let imageDecode: (@Sendable (Data, String) -> Data?)?

    init(
        provider: any BookContentProvider,
        renderSize: CGSize,
        resourceProvider: (any BookResourceProvider)? = nil,
        chapterSourceHrefs: [String?] = [],
        fontRegistrationService: any FontRegistrationServicing = CoreTextFontRegistrationService(),
        imageDecode: (@Sendable (Data, String) -> Data?)? = nil
    ) {
        self.provider = provider
        self.renderSize = renderSize
        self.resourceProvider = resourceProvider
        self.styleResolver = resourceProvider.map {
            EPUBStyleResolver(resourceProvider: $0, fontRegistrationService: fontRegistrationService)
        }
        self.imageDecode = imageDecode
        if chapterSourceHrefs.count == provider.totalChapters {
            self.chapterSourceHrefs = chapterSourceHrefs
        } else {
            self.chapterSourceHrefs = Array(repeating: nil, count: provider.totalChapters)
        }
    }

    deinit {
        styleResolver?.cleanupFontFiles()
    }

    func updateRenderSize(_ size: CGSize) {
        renderSize = size
    }

    var chapterCount: Int { provider.totalChapters }

    var prefersLazyByteScan: Bool { true }

    func chapterTitle(at index: Int) -> String {
        provider.chapterTitle(at: index)
    }

    func chapterSourceHref(at index: Int) -> String? {
        guard (0..<chapterCount).contains(index) else { return nil }
        return cachedPayloadSourceHrefs[index] ?? chapterSourceHrefs[index]
    }

    func chapterIndex(for href: String) -> Int? {
        if let n = Int(href), n >= 0, n < chapterCount { return n }
        let target = normalizedURLKey(href)
        guard !target.isEmpty else { return nil }
        if let match = chapterSourceHrefs.enumerated().first(where: { normalizedURLKey($0.element) == target }) {
            return match.offset
        }
        return cachedPayloadSourceHrefs.first(where: { normalizedURLKey($0.value) == target })?.key
    }

    func chapterDataSize(at index: Int) async -> Int {
        guard (0..<chapterCount).contains(index),
              let payload = try? await provider.contentForChapter(index: index)
        else { return 0 }
        cacheSourceHref(from: payload)
        return payload.body.byteCount
    }

    func cssResourceHrefs() -> [String] {
        resourceProvider?.cssResourceHrefs() ?? []
    }

    private func payload(at index: Int) async throws -> ChapterContentPayload {
        do {
            return try await provider.contentForChapter(index: index)
        } catch let error as BookContentProviderError {
            if case .contentNotCached = error {
                throw AttributedStringBuildingError.contentNotCached(index)
            }
            throw error
        }
    }

    private func cacheSourceHref(from payload: ChapterContentPayload) {
        let sourceHref = (payload.sourceHref ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sourceHref.isEmpty else { return }
        cachedPayloadSourceHrefs[payload.index] = sourceHref
    }

    private func normalizedURLKey(_ value: String?) -> String {
        guard let value else { return "" }
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hashIndex = trimmed.firstIndex(of: "#") {
            trimmed = String(trimmed[..<hashIndex])
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    private func fallbackChapterHref(for index: Int, payload: ChapterContentPayload) -> String {
        let sourceHref = (payload.sourceHref ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !sourceHref.isEmpty { return sourceHref }
        if let mapped = chapterSourceHref(at: index), !mapped.isEmpty { return mapped }
        return "chapter/\(index).xhtml"
    }

    private func configureResourceCallbacks(
        for builder: HTMLAttributedStringBuilder,
        chapterHref: String,
        renderWidth: CGFloat
    ) {
        // Image loading works without a resource provider: online sources embed illustrations
        // and comment-bubble SVGs as data: URIs and absolute http(s) URLs. Wire it unconditionally.
        builder.imageLoader = { [weak self] src in
            await self?.loadImage(src: src, chapterHref: chapterHref, renderWidth: renderWidth)
        }
        guard let resourceProvider else { return }
        builder.resolvedFont = { [weak self] families, weight, italic, size in
            self?.styleResolver?.resolveRegisteredFont(
                families: families,
                weight: weight,
                italic: italic,
                size: size
            )
        }
        builder.resolvedFontFamily = { [weak self] rawName in
            guard let self else { return nil }
            let normalized = rawName
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                .lowercased()
            return styleResolver?.registeredFontFaces[normalized]?.postScriptName
                ?? styleResolver?.registeredFontFaces[normalized]?.familyName
        }
        builder.mediaURLResolver = { src in
            let resolved = EPUBStyleResolver.resolveImageHref(src, chapterHref: chapterHref)
            return resourceProvider.resourceURL(for: resolved).absoluteString
        }
        builder.cssLoader = { [weak self] href in
            await self?.loadCSS(href: href, chapterHref: chapterHref)
        }
    }

    private func loadImage(src: String, chapterHref: String, renderWidth: CGFloat) async -> UIImage? {
        let cleaned = OnlineImageLoader.cleanImageSource(src)
        guard !cleaned.isEmpty else { return nil }

        if let onlineImage = await OnlineImageLoader.load(
            src: cleaned, renderWidth: renderWidth, decode: imageDecode
        ) {
            return onlineImage
        }

        // EPUB-style book-local resource (only when a resource provider is present).
        guard let resourceProvider else { return nil }
        let resolved = EPUBStyleResolver.resolveImageHref(cleaned, chapterHref: chapterHref)
        let url = resourceProvider.resourceURL(for: resolved)
        guard let response = try? await resourceProvider.response(for: url) else { return nil }
        return UIImage(data: response.data)
    }

    private func loadCSS(href: String, chapterHref: String) async -> String? {
        guard let resourceProvider else { return nil }
        let resolved = EPUBStyleResolver.resolveImageHref(href, chapterHref: chapterHref)
        let url = resourceProvider.resourceURL(for: resolved)
        guard let response = try? await resourceProvider.response(for: url) else { return nil }
        let cssText = String(data: response.data, encoding: .utf8) ?? ""
        guard let styleResolver else { return cssText.isEmpty ? nil : cssText }
        let processed = await styleResolver.processStylesheet(
            cssText,
            cssHref: resolved,
            chapterHref: chapterHref
        )
        return processed.isEmpty ? nil : processed
    }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        let payload = try await payload(at: index)
        cacheSourceHref(from: payload)

        #if DEBUG
        AppLogger.render("onlinePipeline", context: [
            "builder": "OnlineProviderAttributedStringBuilder",
            "chapter": index,
            "body": payload.body.debugKind
        ])
        #endif

        switch payload.body {
        case .html(let rawHTML):
            // ⟐ 本章说 probe: does the chapter content actually carry the chapter-comment card and
            // per-paragraph bubbles the source's getComments() is supposed to inject? The card's
            // click action `androidshowChapterComments(...)` and the bubble action `showCmt(...)`
            // survive as literal text in the img click-config suffix (not base64), so we can detect
            // them in the raw HTML BEFORE any rendering. hasCard=false ⇒ the source/API never built
            // the card (server side); hasCard=true but no card on screen ⇒ an app render failure
            // (follow the matching ⟐ imgLoad / svgRaster lines for that SVG).
            AppLogger.render("⟐ ccsCard", context: [
                "chapter": index,
                "hasCard": rawHTML.contains("androidshowChapterComments"),
                "bubbles": rawHTML.components(separatedBy: "showCmt(").count - 1,
                "len": rawHTML.count
            ])
            return await buildHTMLChapter(
                payload: payload,
                html: ReaderHTMLUtilities.rewriteReviewComments(rawHTML),
                settings: settings,
                themeTextColor: themeTextColor,
                themeBackgroundColor: themeBackgroundColor
            )
        case .plainText(let text):
            return await buildPlainTextChapter(
                payload: payload,
                text: text,
                settings: settings,
                themeTextColor: themeTextColor,
                themeBackgroundColor: themeBackgroundColor
            )
        }
    }

    private func buildHTMLChapter(
        payload: ChapterContentPayload,
        html: String,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async -> AttributedChapterBuildResult {
        let contentRenderWidth = max(
            1,
            renderSize.width - settings.contentInsets.left - settings.contentInsets.right
        )
        let cfg = HTMLAttributedStringBuilder.Config(
            fontSize: settings.fontSize,
            lineHeightMultiple: settings.lineHeightMultiple,
            lineSpacing: settings.lineSpacing,
            paragraphSpacing: settings.paragraphSpacing,
            firstLineIndent: settings.fontSize * 2,
            textColor: themeTextColor,
            backgroundColor: themeBackgroundColor,
            fontFamilyName: UserReaderFontResolver.selectedPostScriptName,
            renderWidth: contentRenderWidth,
            writingMode: settings.writingMode
        )
        let builder = HTMLAttributedStringBuilder()
        let chapterHref = fallbackChapterHref(for: payload.index, payload: payload)
        configureResourceCallbacks(
            for: builder,
            chapterHref: chapterHref,
            renderWidth: contentRenderWidth
        )

        guard let ast = await builder.buildStyledAST(html: html, config: cfg) else {
            return AttributedChapterBuildResult(
                attributedString: NSAttributedString(),
                imagePage: nil,
                pageBackgroundImage: nil,
                anchorOffsets: [:]
            )
        }

        if let imagePage = await builder.imagePage(from: ast) {
            let pageBackgroundColor = builder.pageBackgroundColor(from: ast)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: settings.fontSize),
                .foregroundColor: themeTextColor,
                .backgroundColor: themeBackgroundColor,
            ]
            return AttributedChapterBuildResult(
                attributedString: NSAttributedString(string: "\u{FFFC}", attributes: attrs),
                imagePage: imagePage,
                pageBackgroundImage: nil,
                pageBackgroundColor: pageBackgroundColor,
                anchorOffsets: [:]
            )
        }

        // The CSS inline-whitespace preservation added for EPUB is intentionally not used here.
        // Online sources historically trim every extracted text-node boundary; some paragraph-
        // review sources switch their body to `div rs-native` markup only while reviews are on,
        // and feeding those nodes through the EPUB policy destroys their paragraph geometry.
        let nodes = HTMLStyledASTRenderableNodeConverter.convert(
            body: ast,
            whitespacePolicy: .trimTextNodeBoundaries
        )

        // Advanced-CSS chapter title for HTML-body chapters: source content
        // carries its own title as a heading or review-bearing paragraph. In
        // CSS mode, remove that leading title text and typeset the title through
        // ChapterTitleAttributedBuilder so HTML-body books honour the same
        // templates as plain-text ones.
        var renderNodes = nodes
        var cssTitle: NSMutableAttributedString?
        var titleAccessories: [RenderableNode] = []
        if settings.chapterTitleStyle.advancedCSSEnabled {
            let deduplicated = OnlineChapterTitleDeduplicator.deduplicatingLeadingTitle(
                from: nodes,
                matching: payload.title
            )
            renderNodes = deduplicated.bodyNodes
            titleAccessories = deduplicated.titleAccessories
            let titleAttr = NSMutableAttributedString()
            await ChapterTitleAttributedBuilder.append(
                title: payload.title,
                style: settings.chapterTitleStyle,
                settings: settings,
                renderWidth: contentRenderWidth,
                themeTextColor: themeTextColor,
                themeBackgroundColor: themeBackgroundColor,
                letterSpacing: settings.letterSpacing,
                to: titleAttr
            )
            cssTitle = titleAttr
        }

        let hasResources = resourceProvider != nil
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(
                from: settings,
                textColor: themeTextColor,
                fontFamily: UserReaderFontResolver.selectedPostScriptName,
                renderWidth: cfg.renderWidth,
                resolvedFont: styleResolver == nil ? nil : { [weak self] families, weight, italic, size in
                    self?.styleResolver?.resolveRegisteredFont(
                        families: families,
                        weight: weight,
                        italic: italic,
                        size: size
                    )
                },
                imageLoader: { [weak self] src in
                    await self?.loadImage(
                        src: src,
                        chapterHref: chapterHref,
                        renderWidth: contentRenderWidth
                    )
                },
                mediaURLResolver: !hasResources ? nil : { [weak self] src in
                    guard let self, let resourceProvider = self.resourceProvider else { return nil }
                    let resolved = EPUBStyleResolver.resolveImageHref(src, chapterHref: chapterHref)
                    return resourceProvider.resourceURL(for: resolved).absoluteString
                },
                centerStandaloneImages: true
            )
        )

        if let cssTitle, !titleAccessories.isEmpty {
            let renderedAccessories = await renderer.render(titleAccessories)
            Self.mergeTitleAccessories(renderedAccessories, into: cssTitle)
        }
        let bodyAttributed = await renderer.render(renderNodes)
        let attributedString: NSAttributedString
        if let cssTitle, cssTitle.length > 0 {
            cssTitle.append(bodyAttributed)
            attributedString = cssTitle
        } else {
            attributedString = bodyAttributed
        }
        // ⟐ 段評 format probe (Release-visible): paragraph structure + first paragraph styles.
        // Splits the search space for the "indent+spacing gone with 段評 on" report — if the
        // probes already show indent=0/spacing=0 (or paragraphs joined by \u{2028}), the content
        // or IR conversion is at fault; if they look right, the paginator/display side is.
        AppLogger.render(
            "⟐ onlineChapter format idx=\(payload.index)",
            context: Self.chapterFormatProbe(nodes: renderNodes, attributed: attributedString)
        )
        let pageBackgroundImage = await builder.pageBackgroundImage(from: ast)
        let pageBackgroundColor = builder.pageBackgroundColor(from: ast)
        return AttributedChapterBuildResult(
            attributedString: attributedString,
            imagePage: nil,
            pageBackgroundImage: pageBackgroundImage,
            pageBackgroundColor: pageBackgroundColor,
            anchorOffsets: builder.anchorOffsets(in: attributedString)
        )
    }

    /// Moves a source title's inline review attachment onto the last visible line of the
    /// advanced-CSS title. Keeping the attachment inside the now-empty source `<h1>` creates a
    /// full blank heading block between the CSS title and body text.
    static func mergeTitleAccessories(
        _ accessories: NSAttributedString,
        into title: NSMutableAttributedString
    ) {
        guard title.length > 0, accessories.length > 0 else { return }

        let accessory = NSMutableAttributedString(attributedString: accessories)
        for index in stride(from: accessory.length - 1, through: 0, by: -1) {
            let scalar = (accessory.string as NSString).character(at: index)
            if scalar == 0x0A || scalar == 0x2028 {
                accessory.deleteCharacters(in: NSRange(location: index, length: 1))
            }
        }
        guard accessory.length > 0 else { return }

        let titleText = title.string as NSString
        var lastVisibleIndex = title.length - 1
        while lastVisibleIndex >= 0 {
            let scalar = titleText.character(at: lastVisibleIndex)
            let isWhitespace = UnicodeScalar(scalar).map {
                CharacterSet.whitespaces.contains($0)
            } ?? false
            if scalar != 0x0A, scalar != 0x2028, !isWhitespace {
                break
            }
            lastVisibleIndex -= 1
        }
        guard lastVisibleIndex >= 0 else { return }

        let insertionIndex = lastVisibleIndex + 1
        let titleAttributes = title.attributes(at: lastVisibleIndex, effectiveRange: nil)
        if let paragraphStyle = titleAttributes[.paragraphStyle] {
            accessory.addAttribute(
                .paragraphStyle,
                value: paragraphStyle,
                range: NSRange(location: 0, length: accessory.length)
            )
        }
        title.insert(
            NSAttributedString(string: "\u{2009}", attributes: titleAttributes),
            at: insertionIndex
        )
        title.insert(accessory, at: insertionIndex + 1)
    }

    /// Diagnostic payload for the ⟐ onlineChapter format probe: IR node shape (descending into
    /// a single `<article>`/`<body>` container), paragraph count, "\n" vs U+2028 break counts,
    /// and the first four paragraphs' indent/spacing/line-height with a text preview.
    private static func chapterFormatProbe(
        nodes: [RenderableNode],
        attributed: NSAttributedString
    ) -> [String: Any] {
        func kind(_ node: RenderableNode) -> String {
            switch node {
            case .paragraph: return "p"
            case .block(let tag, _, _): return "block(\(tag))"
            case .heading(_, let level, _): return "h\(level)"
            case .text(let s): return s.trimmingCharacters(in: .whitespaces).isEmpty ? "ws" : "text"
            case .inline(let tag, _, _): return "inline(\(tag))"
            case .image: return "img"
            case .lineBreak: return "br"
            case .anchor: return "a"
            case .commentBadge: return "badge"
            case .table: return "table"
            default: return "?"
            }
        }
        var shape = nodes.map(kind)
        if nodes.count == 1 {
            if case .block(let tag, let children, _) = nodes[0] {
                shape = ["\(tag)>"] + children.prefix(14).map(kind)
                if children.count > 14 { shape.append("+\(children.count - 14)") }
            } else if case .paragraph(let children, _) = nodes[0] {
                shape = ["p>"] + children.prefix(14).map(kind)
                if children.count > 14 { shape.append("+\(children.count - 14)") }
            }
        }

        let ns = attributed.string as NSString
        var probes: [String] = []
        var paragraphCount = 0
        var location = 0
        while location < ns.length {
            let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
            location = max(NSMaxRange(range), location + 1)
            guard range.length > 0 else { continue }
            paragraphCount += 1
            guard probes.count < 4 else { continue }
            let para = attributed.attribute(
                .paragraphStyle, at: range.location, effectiveRange: nil
            ) as? NSParagraphStyle
            let preview = ns.substring(with: range)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(8)
            probes.append(
                "indent=\(Int(para?.firstLineHeadIndent ?? -1))"
                    + " spacing=\(Int(para?.paragraphSpacing ?? -1))"
                    + " lh=\(Int(para?.minimumLineHeight ?? -1))«\(preview)»"
            )
        }

        var newlines = 0
        var lineSeparators = 0
        for scalar in attributed.string.unicodeScalars {
            if scalar.value == 0x0A { newlines += 1 }
            if scalar.value == 0x2028 { lineSeparators += 1 }
        }

        var context: [String: Any] = [
            "nodes": shape.joined(separator: ","),
            "paras": paragraphCount,
            "nl": newlines,
            "ls": lineSeparators,
        ]
        for (index, probe) in probes.enumerated() {
            context["p\(index)"] = probe
        }
        return context
    }

    private func buildPlainTextChapter(
        payload: ChapterContentPayload,
        text: String,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async -> AttributedChapterBuildResult {
        let bodyFont = UserReaderFontResolver.bodyFont(size: settings.fontSize, isBold: settings.isBold)
        let bodyTargetLineHeight = ReaderTypographyCorrection.targetLineHeight(
            font: bodyFont,
            fontSize: settings.fontSize,
            lineHeightMultiple: settings.lineHeightMultiple
        )
        let bodyBaselineOffset = ReaderTypographyCorrection.baselineOffset(
            font: bodyFont,
            targetLineHeight: bodyTargetLineHeight
        )

        let bodyParaStyle = NSMutableParagraphStyle()
        bodyParaStyle.alignment = .justified // full justification: both margins align, CJK + Latin alike
        bodyParaStyle.hyphenationFactor = ReaderHyphenation.factor // break long Latin words instead of gapping the line
        bodyParaStyle.lineBreakMode = .byWordWrapping
        bodyParaStyle.minimumLineHeight = bodyTargetLineHeight
        bodyParaStyle.maximumLineHeight = bodyTargetLineHeight
        bodyParaStyle.paragraphSpacing = settings.paragraphSpacing
        bodyParaStyle.firstLineHeadIndent = settings.fontSize * 2

        let attr = NSMutableAttributedString()
        await ChapterTitleAttributedBuilder.append(
            title: payload.title,
            style: settings.chapterTitleStyle,
            settings: settings,
            renderWidth: max(1, renderSize.width - settings.contentInsets.left - settings.contentInsets.right),
            themeTextColor: themeTextColor,
            themeBackgroundColor: themeBackgroundColor,
            letterSpacing: settings.letterSpacing,
            to: attr
        )

        let paragraphs = ReaderHTMLUtilities.bodyParagraphs(
            fromPlainText: text,
            excludingLeadingTitle: payload.title
        )

        for para in paragraphs {
            let line = para + "\n"
            attr.append(NSAttributedString(
                string: line,
                attributes: ReaderHyphenation.tagging(
                    [
                        .font: bodyFont,
                        .foregroundColor: themeTextColor,
                        .baselineOffset: bodyBaselineOffset,
                        .paragraphStyle: bodyParaStyle,
                        .kern: settings.letterSpacing as NSNumber
                    ],
                    forText: para
                )
            ))
        }

        return AttributedChapterBuildResult(
            attributedString: attr,
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}
