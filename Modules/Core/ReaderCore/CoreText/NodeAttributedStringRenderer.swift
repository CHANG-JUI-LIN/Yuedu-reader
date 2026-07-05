import CoreText
import Foundation
import UIKit

// MARK: - NodeAttributedStringRenderer
//
// Consumes [RenderableNode] → NSAttributedString.
//
// Design principles:
//   - Pure conversion function, no side effects, no stored state (struct)
//   - Passes "inherited attributes" (font family, size, color) down the tree via RenderContext
//   - Each block node determines its own NSParagraphStyle; inline nodes only modify font/color
//   - `.rawHTML` fallback: displays placeholder in Debug, silently ignored in Release
//   - `.image` enters existing paginator / page view pipeline via RunDelegate placeholder

struct NodeAttributedStringRenderer {

    // MARK: - Rendering Config

    struct Config {
        let baseFontSize: CGFloat
        let lineHeightMultiple: CGFloat
        let paragraphSpacing: CGFloat
        let letterSpacing: CGFloat
        let textColor: UIColor
        let backgroundColor: UIColor
        let fontFamily: String?
        let renderWidth: CGFloat?
        let resolvedFont: (([String], Int, Bool, CGFloat) -> UIFont?)?
        let imageLoader: ((String) async -> UIImage?)?
        let mediaURLResolver: ((String) -> String?)?
        let writingMode: ReaderWritingMode
        let baseWritingDirection: NSWritingDirection
        let isBold: Bool
        /// Center standalone block images that carry no explicit horizontal alignment. Online
        /// web-novel sources (起点/Legado) emit chapter illustrations & 版权页 author photos as bare
        /// `<img>` with no centering CSS but expect them centered, matching the source apps. Left
        /// off for EPUB, whose stylesheets position images themselves.
        let centerStandaloneImages: Bool

        init(
            from settings: ReaderRenderSettings,
            textColor: UIColor? = nil,
            fontFamily: String? = nil,
            renderWidth: CGFloat? = nil,
            resolvedFont: (([String], Int, Bool, CGFloat) -> UIFont?)? = nil,
            imageLoader: ((String) async -> UIImage?)? = nil,
            mediaURLResolver: ((String) -> String?)? = nil,
            baseWritingDirection: NSWritingDirection = .natural,
            centerStandaloneImages: Bool = false
        ) {
            self.baseFontSize = settings.fontSize
            self.lineHeightMultiple = settings.lineHeightMultiple
            self.paragraphSpacing = settings.paragraphSpacing
            self.letterSpacing = settings.letterSpacing
            self.textColor = textColor ?? settings.textColor
            self.backgroundColor = settings.backgroundColor
            self.fontFamily = fontFamily
            self.renderWidth = renderWidth
            self.resolvedFont = resolvedFont
            self.imageLoader = imageLoader
            self.mediaURLResolver = mediaURLResolver
            self.writingMode = settings.writingMode
            self.baseWritingDirection = baseWritingDirection
            self.isBold = settings.isBold
            self.centerStandaloneImages = centerStandaloneImages
        }
    }

    let config: Config

    // MARK: - Entry Point

    /// Converts a set of top-level nodes into a pageable NSAttributedString.
    func render(_ nodes: [RenderableNode]) async -> NSAttributedString {
        let result = NSMutableAttributedString()
        let ctx = RenderContext.makeBody(config: config)
        for node in nodes {
            // A bare `<img>` becomes a TOP-LEVEL `.image` node (the converter never wraps it in a
            // block), so it would otherwise render as an inline attachment, left-aligned. Online
            // sources expect standalone illustrations / 版权页 author photos centered — route them
            // through the block-image path so the centering applies. Inline-sized bubbles
            // (isTextSizedImage) and EPUB (flag off) are untouched.
            if config.centerStandaloneImages,
               let payload = unwrapSingleImage(from: node),
               !payload.style.isTextSizedImage {
                result.append(await renderImageOnlyBlock(
                    payload: payload,
                    blockStyle: payload.style,
                    ctx: ctx,
                    isHeading: false,
                    headingLevel: 0
                ))
                continue
            }
            result.append(await render(node: node, ctx: ctx))
        }
        let processed = NSMutableAttributedString(attributedString: CJKTypographyProcessor.apply(to: result))
        relaxParagraphsContainingRubyAnnotations(processed)
        relaxParagraphsContainingTallRuns(processed)
        normalizeCompactBlockSpacing(processed)
        return processed
    }

    // MARK: - Node Rendering (Recursive)

    private func render(node: RenderableNode, ctx: RenderContext) async -> NSAttributedString {
        switch node {

        // ──────────────── Leaf nodes ────────────────

        case .text(let str):
            return NSAttributedString(string: str, attributes: ctx.baseAttributes)

        case .lineBreak:
            // \u{2028} = Unicode Line Separator (matching HTMLAttributedStringBuilder convention)
            return NSAttributedString(string: "\u{2028}", attributes: ctx.baseAttributes)

        case .horizontalRule(let style):
            var attrs = ctx.baseAttributes
            let resolvedLineWidth = style.borderTopWidth > 0 ? style.borderTopWidth
                : style.borderBottomWidth > 0 ? style.borderBottomWidth
                : style.height.flatMap { $0 > 0 ? $0 : nil }
            if style.borderExplicitlyNone, resolvedLineWidth == nil {
                return horizontalRuleSpacer(attributes: attrs, style: style, ctx: ctx)
            }
            let lineStyle = style.borderTopWidth > 0 ? style.borderTopStyle
                : style.borderBottomWidth > 0 ? style.borderBottomStyle
                : style.borderTopStyle ?? style.borderBottomStyle
            let hrStyle = HTMLAttributedStringBuilder.HRDividerStyle(
                color: style.borderTopColor?.uiColor
                    ?? style.borderBottomColor?.uiColor
                    ?? style.color?.uiColor
                    ?? style.backgroundColor?.uiColor,
                lineWidth: resolvedLineWidth,
                ruleWidth: style.width,
                ruleWidthPercent: style.rawWidthPercent,
                marginLeft: style.marginLeft,
                marginRight: style.marginRight,
                inheritedBlockMarginLeft: ctx.inheritedBlockMarginLeft,
                inheritedBlockMarginRight: ctx.inheritedBlockMarginRight,
                alignment: {
                    switch style.textAlign {
                    case .left: return .left
                    case .center: return .center
                    case .right: return .right
                    case .justify: return .justified
                    case .natural: return .natural
                    }
                }(),
                isHorizontallyCentered: style.isHorizontallyCentered,
                lineDash: Self.hrLineDash(for: lineStyle, lineWidth: resolvedLineWidth ?? 0.5)
            )
            attrs[HTMLAttributedStringBuilder.hrDividerAttribute] = hrStyle
            return horizontalRuleSpacer(attributes: attrs, style: style, ctx: ctx)

        case .pageBreak:
            return HTMLAttributedStringBuilder.makePageBreakMarker(attributes: ctx.baseAttributes)

        case .rawHTML(let html):
            #if DEBUG
            let placeholder = "[rawHTML: \(html.prefix(40))]\n"
            return NSAttributedString(string: placeholder, attributes: ctx.baseAttributes)
            #else
            return NSAttributedString()
            #endif

        // ──────────────── Image (fallback: show alt-text) ────────────────

        case .image(let src, let alt, let style, let svgContent):
            return await renderInlineImage(src: src, alt: alt, style: style, svgContent: svgContent, ctx: ctx)

        case .mathML(let latex, let alt, let style, let displayMode):
            return await renderMathML(latex: latex, alt: alt, style: style, displayMode: displayMode, ctx: ctx)

        case .table(let table, let style):
            return await renderTable(table, style: style, ctx: ctx)

        case .media(let media, let style):
            return await renderMedia(media, style: style, ctx: ctx)

        case .unsupportedInteractive(let type, let title, let children, let style):
            return await renderUnsupportedInteractive(
                type: type,
                title: title,
                children: children,
                style: style,
                ctx: ctx
            )

        // ──────────────── Paragraph ────────────────

        case .paragraph(let children, let style):
            return await renderBlock(children: children, style: style, ctx: ctx, isHeading: false)

        case .blockquote(let children):
            var style = RenderStyle.none
            style.marginLeft = 20
            style.italic = true
            return await renderBlock(children: children, style: style, ctx: ctx, isHeading: false)

        case .listItem(let children, let bullet):
            let hasBlockChildren = children.contains { child in
                if case .paragraph = child { return true }
                if case .block = child { return true }
                if case .heading = child { return true }
                if case .blockquote = child { return true }
                return false
            }
            if hasBlockChildren {
                // A structural item (`<li><p>…</p></li>`, e.g. duokan footnotes) renders its
                // children as blocks so the paragraph keeps its own font/line-height/indent.
                // The marker is spliced into the first paragraph: a marker run carrying the
                // outer list context's attributes would force the list's (larger) line box
                // onto the item's first line, and a separate trailing "\n" would add a full
                // blank paragraph after every item.
                let result = NSMutableAttributedString()
                for child in children {
                    result.append(await render(node: child, ctx: ctx))
                }
                guard result.length > 0 else { return result }
                let first = result.attributes(at: 0, effectiveRange: nil)
                var bulletAttrs: [NSAttributedString.Key: Any] = [:]
                bulletAttrs[.font] = first[.font] ?? ctx.font
                bulletAttrs[.foregroundColor] = first[.foregroundColor] ?? ctx.textColor
                if let para = first[.paragraphStyle] {
                    bulletAttrs[.paragraphStyle] = para
                }
                result.insert(NSAttributedString(string: bullet + "\u{2009}", attributes: bulletAttrs), at: 0)
                return result
            }
            let bulletStr = NSAttributedString(string: bullet + "\u{2009}", attributes: ctx.baseAttributes)
            let body = await renderInlineChildren(children, ctx: ctx)
            let result = NSMutableAttributedString()
            result.append(bulletStr)
            result.append(body)
            result.append(NSAttributedString(string: "\n", attributes: ctx.baseAttributes))
            return result

        // ──────────────── Heading ────────────────

        case .heading(let children, let level, let style):
            return await renderBlock(children: children, style: style, ctx: ctx, isHeading: true, headingLevel: level)

        // ──────────────── Container ────────────────

        case .block(let tag, let children, let style):
            let rendered = NSMutableAttributedString(
                attributedString: await renderBlock(children: children, style: style, ctx: ctx, isHeading: false)
            )
            addSemanticTagIfNeeded(tag, to: rendered)
            return rendered

        case .inline(let tag, let children, let style):
            let childCtx = applyInlineStyle(style, to: ctx)
            let rendered = await renderInlineChildren(children, ctx: childCtx)
            if isVertical(style), style.isInlineAnnotation {
                CoreTextPaginator.debugVerticalLog("EPUBFLOW render.inlineAnnotation.node renderedLen=\(rendered.length) placeholderFont=\(ctx.font.pointSize) annotationFont=\(childCtx.font.pointSize) preview=\"\(debugTextPreview(rendered.string))\"")
                return makeInlineAnnotationPlaceholder(
                    rendered,
                    placeholderCtx: ctx,
                    annotationCtx: childCtx
                )
            }
            let tagged = NSMutableAttributedString(attributedString: rendered)
            addSemanticTagIfNeeded(tag, to: tagged)
            // Inline element with a border → draw a bordered "chip" around its glyphs (e.g. an
            // `epub:type="pagebreak"` page-number badge). Mirrors the legacy renderNode path.
            if tagged.length > 0, let chip = Self.inlineBorderBoxStyle(for: style) {
                tagged.addAttribute(
                    HTMLAttributedStringBuilder.inlineBorderBoxAttribute,
                    value: chip,
                    range: NSRange(location: 0, length: tagged.length)
                )
            }
            return tagged

        case .anchor(let href, let children):
            var childCtx = ctx
            childCtx.linkHref = href
            let rendered = NSMutableAttributedString(attributedString: await renderInlineChildren(children, ctx: childCtx))
            // Default tap-affordance color only for links the author left untouched (no bold/italic/
            // sized/colored content). `ctx.font` is the inherited base the link's text builds on.
            if !href.isEmpty,
               HTMLAttributedStringBuilder.linkContentIsUnstyled(rendered, baseFont: ctx.font) {
                HTMLAttributedStringBuilder.applyDefaultLinkColor(to: rendered)
            }
            return rendered

        case .commentBadge(let count, let reviewURL, let title):
            return await renderCommentBadge(count: count, reviewURL: reviewURL, title: title, ctx: ctx)

        case .ruby(let base, let text, let style):
            let childCtx = applyInlineStyle(style, to: ctx)
            let rendered = NSMutableAttributedString(attributedString: await renderInlineChildren(base, ctx: childCtx))
            addRubyAnnotation(text, to: rendered)
            return rendered

        case .anchorTarget(let id, let child):
            let rendered = NSMutableAttributedString(attributedString: await render(node: child, ctx: ctx))
            guard rendered.length > 0 else { return rendered }
            rendered.addAttribute(
                HTMLAttributedStringBuilder.anchorIDAttribute,
                value: id,
                range: NSRange(location: 0, length: min(1, rendered.length))
            )
            return rendered
        }
    }

    private func horizontalRuleSpacer(
        attributes: [NSAttributedString.Key: Any],
        style: RenderStyle,
        ctx: RenderContext
    ) -> NSAttributedString {
        var attrs = attributes
        let fontSize = ctx.font.pointSize
        let hrPara = NSMutableParagraphStyle()
        hrPara.minimumLineHeight = fontSize
        hrPara.maximumLineHeight = fontSize
        hrPara.paragraphSpacingBefore = fontSize * 0.5
        hrPara.paragraphSpacing = fontSize * 0.5
        hrPara.baseWritingDirection = style.baseWritingDirection
        let leftInset = max(0, ctx.inheritedBlockMarginLeft + style.marginLeft)
        let rightInset = max(0, ctx.inheritedBlockMarginRight + style.marginRight)
        hrPara.headIndent = leftInset
        hrPara.firstLineHeadIndent = leftInset
        hrPara.tailIndent = rightInset > 0 ? -rightInset : 0
        attrs[.paragraphStyle] = hrPara
        return NSAttributedString(string: "\n", attributes: attrs)
    }

    private static func hrLineDash(for lineStyle: String?, lineWidth: CGFloat) -> [CGFloat] {
        let width = max(0.5, lineWidth)
        switch lineStyle?.lowercased() {
        case "dashed":
            return [max(3, width * 4), max(2, width * 3)]
        case "dotted":
            return [width, max(width, width * 2)]
        default:
            return []
        }
    }

    // MARK: - Block Rendering

    /// Block-level renderable-node kinds: they terminate the current visual paragraph and
    /// start their own line (drives both container detection and anonymous-block breaks).
    private static func isBlockLevelChild(_ child: RenderableNode) -> Bool {
        switch child {
        case .paragraph, .block, .heading, .blockquote, .listItem, .horizontalRule:
            return true
        default:
            return false
        }
    }

    private func renderBlock(
        children: [RenderableNode],
        style: RenderStyle,
        ctx: RenderContext,
        isHeading: Bool,
        headingLevel: Int = 0
    ) async -> NSAttributedString {
        if let imagePayload = singleImagePayload(from: children) {
            return await renderImageOnlyBlock(
                payload: imagePayload,
                blockStyle: style,
                ctx: ctx,
                isHeading: isHeading,
                headingLevel: headingLevel
            )
        }

        // A CSS-floated *text* block (chat-bubble idiom: `div.se { float:right; ... }` /
        // `div.ot { float:left }`) is not a magazine-style float-around-image (those carry a
        // `FloatPlaceholder`); it is an instant-message bubble. Render it as a width-constrained,
        // side-aligned, colored, rounded box instead of a full-width block. Horizontal only.
        if let side = style.floatSide,
           !isHeading,
           !isVertical(style),
           config.renderWidth != nil {
            return await renderFloatBubble(children: children, style: style, side: side, ctx: ctx)
        }

        let hasBlockChildren = children.contains(where: Self.isBlockLevelChild)

        // A chat thread wrapper (`div.tk`) holds a stack of floated message bubbles. Its authored
        // 1em margins compound with each bubble's spacing and the surrounding narration — and,
        // unlike a browser, this renderer does not collapse adjacent margins — so threads render far
        // looser than Apple Books / Readest. Detect the wrapper and tighten its own vertical margin.
        let wrapsFloatBubble = style.compactChildBlockSpacing || children.contains { child in
            switch child {
            case .paragraph(_, let s), .block(_, _, let s): return s.floatSide != nil
            default: return false
            }
        }

        var childCtx = applyBlockStyle(style, to: ctx, isHeading: isHeading, headingLevel: headingLevel)
        if wrapsFloatBubble { childCtx.compactBlockSpacing = true }
        if style.backgroundColor != nil
            || style.backgroundImageSource != nil
            || style.borderTopWidth > 0 || style.borderBottomWidth > 0
            || style.borderLeftWidth > 0 || style.borderRightWidth > 0 {
            childCtx.insideDecoratedContainer = true
        }
        let result = NSMutableAttributedString()
        if isVertical(style),
           !hasBlockChildren,
           style.visualOffsetBefore > 0 {
            result.append(verticalInlineSpacer(advance: style.visualOffsetBefore, ctx: childCtx))
        }
        for child in children {
            // A block child after unterminated inline content (a loose `<img>` before a `<p>`,
            // duokan phone-frame idiom) must start its own CoreText paragraph — CoreText applies
            // the paragraph style of the FIRST character to the whole paragraph, so without this
            // break the `<p>` inherits the container's style and loses its own margins/indent.
            // The break is the CSS anonymous-block boundary that would exist in a browser.
            if Self.isBlockLevelChild(child),
               result.length > 0,
               !result.string.hasSuffix("\n") {
                result.append(NSAttributedString(string: "\n", attributes: childCtx.baseAttributes))
            }
            result.append(await render(node: child, ctx: childCtx))
        }
        collapseAdjacentParagraphSpacing(
            result,
            honorStructuralInsets: !isVertical(style)
        )
        let contentLength = result.length
        // An empty block (`<div style="clear:both"></div>`, layout-only wrappers) is zero-height
        // in CSS; emitting its trailing newline anyway would fabricate a visible blank paragraph.
        // Keep the anchor line only when the block draws something by itself (a spacer with an
        // explicit height, background, or border).
        if contentLength == 0 {
            let drawsSomething = style.height != nil
                || style.backgroundColor != nil
                || style.backgroundImageSource != nil
                || style.borderTopWidth > 0 || style.borderBottomWidth > 0
                || style.borderLeftWidth > 0 || style.borderRightWidth > 0
            guard drawsSomething else { return result }
        }
        if contentLength > 0 {
            if wrapsFloatBubble {
                markCompactBlockSpacing(
                    result,
                    range: NSRange(location: 0, length: contentLength),
                    reason: "floatThread"
                )
            }
            let backgroundImage = await loadBlockBackgroundImage(for: style)
            if hasBlockChildren {
                applyContainerDecorationAttributes(
                    style: style,
                    to: result,
                    range: NSRange(location: 0, length: contentLength),
                    backgroundImage: backgroundImage
                )
                // The thread wrapper keeps its authored outer margins (`div.tk { margin: 1em }`):
                // the old spacing bloat came from fabricated blank paragraphs (see above), not from
                // the margins themselves. Compact normalization preserves a compact range's first
                // `paragraphSpacingBefore` / last `paragraphSpacing` so this reserve survives.
                reserveContainerInsets(result, style: style)
            } else {
                applyBlockDecorationAttributes(
                    style: style,
                    to: result,
                    range: NSRange(location: 0, length: contentLength),
                    backgroundImage: backgroundImage
                )
            }
        }
        // Apply :first-letter styles to the first typographic letter unit
        if let flSizeMul = style.firstLetterFontSizeMultiplier, result.length > 0 {
            if let flRange = HTMLAttributedStringBuilder.firstLetterRange(in: result.string) {
                let baseFont = result.attribute(.font, at: flRange.location, effectiveRange: nil) as? UIFont ?? childCtx.font
                let flSize = baseFont.pointSize * flSizeMul
                let flWeight = style.firstLetterFontWeight ?? childCtx.fontWeight
                let system = UIFont.systemFont(ofSize: flSize, weight: {
                    switch flWeight {
                    case ..<350: return .regular
                    case 350..<450: return .regular
                    case 450..<550: return .medium
                    case 550..<650: return .semibold
                    case 650..<750: return .bold
                    case 750..<850: return .heavy
                    default: return .black
                    }
                }())
                let flItalic = baseFont.fontDescriptor.symbolicTraits.contains(.traitItalic)
                if flItalic, let desc = system.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    result.addAttribute(.font, value: UIFont(descriptor: desc, size: flSize), range: flRange)
                } else {
                    result.addAttribute(.font, value: system, range: flRange)
                }
                if let flColor = style.firstLetterColor {
                    result.addAttribute(.foregroundColor, value: flColor.uiColor, range: flRange)
                }

                // Relax maximumLineHeight so the first line can grow to fit the large first letter.
                if let para = result.attribute(.paragraphStyle, at: flRange.location, effectiveRange: nil) as? NSParagraphStyle,
                   let mutablePara = para.mutableCopy() as? NSMutableParagraphStyle {
                    let flRequiredHeight = flSize * 0.7
                    if mutablePara.maximumLineHeight > 0 && mutablePara.maximumLineHeight < flRequiredHeight {
                        mutablePara.maximumLineHeight = 0
                        result.addAttribute(.paragraphStyle, value: mutablePara, range: NSRange(location: 0, length: result.length))
                    }
                }
            }
        }

        if !hasBlockChildren {
            applyBlockBreakContinuationIndent(result)
        }
        // Terminate the block's last paragraph — but only when the content doesn't already end
        // with one. Block children each close their own paragraph, so unconditionally appending
        // here gave every closed container an extra empty full-height paragraph, compounding
        // per nesting level (the mysterious gaps after chat threads / callout boxes).
        if !result.string.hasSuffix("\n") {
            result.append(NSAttributedString(string: "\n", attributes: childCtx.baseAttributes))
        }
        return result
    }

    /// A block-level `<br>` injects a hard "\n" inside the paragraph's content. CoreText treats
    /// the following text as a new paragraph, which would re-apply the first-line indent; the
    /// legacy pipeline rendered such continuations flush with the body, so drop the indent here.
    private func applyBlockBreakContinuationIndent(_ output: NSMutableAttributedString) {
        guard output.length > 0, output.string.contains("\n") else { return }
        let ns = output.string as NSString
        var location = 0
        var isFirstParagraph = true
        while location < ns.length {
            let paragraphRange = ns.paragraphRange(for: NSRange(location: location, length: 0))
            defer {
                location = paragraphRange.location + max(paragraphRange.length, 1)
                isFirstParagraph = false
            }
            guard !isFirstParagraph, paragraphRange.length > 0 else { continue }
            guard let style = output.attribute(
                .paragraphStyle,
                at: paragraphRange.location,
                effectiveRange: nil
            ) as? NSParagraphStyle,
                style.firstLineHeadIndent != style.headIndent
            else { continue }
            let continuation = style.mutableCopy() as! NSMutableParagraphStyle
            continuation.firstLineHeadIndent = style.headIndent
            output.addAttribute(.paragraphStyle, value: continuation, range: paragraphRange)
        }
    }

    // MARK: - Inline Children

    private func renderInlineChildren(_ children: [RenderableNode], ctx: RenderContext) async -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in children {
            result.append(await render(node: child, ctx: ctx))
        }
        return result
    }

    /// Builds an inline-chip style from an inline element's border, or nil when it has none.
    private static func inlineBorderBoxStyle(for style: RenderStyle) -> HTMLAttributedStringBuilder.InlineBorderBoxStyle? {
        let widths = [style.borderTopWidth, style.borderBottomWidth, style.borderLeftWidth, style.borderRightWidth]
        guard let borderWidth = widths.first(where: { $0 > 0 }) else { return nil }
        let borderColor = (style.borderTopColor
            ?? style.borderLeftColor
            ?? style.borderRightColor
            ?? style.borderBottomColor
            ?? style.color)?.uiColor ?? .label
        return HTMLAttributedStringBuilder.InlineBorderBoxStyle(
            borderColor: borderColor,
            borderWidth: borderWidth,
            cornerRadius: style.borderRadius,
            fillColor: style.backgroundColor?.uiColor,
            paddingHorizontal: max(style.paddingLeft, style.paddingRight),
            paddingVertical: max(style.paddingTop, style.paddingBottom)
        )
    }

    // MARK: - Apply Block Style to Context

    private func applyBlockStyle(
        _ style: RenderStyle,
        to ctx: RenderContext,
        isHeading: Bool,
        headingLevel: Int = 0
    ) -> RenderContext {
        var newCtx = ctx

        // ── Font size ──
        let sizeMultiplier: CGFloat
        if isHeading {
            switch headingLevel {
            case 1:  sizeMultiplier = 2.0
            case 2:  sizeMultiplier = 1.5
            case 3:  sizeMultiplier = 1.25
            case 4:  sizeMultiplier = 1.1
            case 5:  sizeMultiplier = 1.0
            default: sizeMultiplier = 0.9
            }
        } else {
            sizeMultiplier = style.fontSizeMultiplier
        }
        let newSize = ctx.baseSize * sizeMultiplier

        // ── Weight and italic ──
        let families = style.fontFamilies.isEmpty ? ctx.fontFamilies : style.fontFamilies
        let bold = isHeading || style.bold
        let weight = bold ? max(style.fontWeight, 700) : max(style.fontWeight, ctx.fontWeight)
        let italic = style.italic
        newCtx.font = makeFont(families: families, size: newSize, weight: weight, italic: italic)
        newCtx.fontFamilies = families
        newCtx.fontWeight = weight
        if style.lineHeightMultiplier > 1.0 {
            newCtx.lineHeightMultiple = style.lineHeightMultiplier
        }

        // ── Color ──
        if let c = style.color { newCtx.textColor = c.uiColor; newCtx.hasCSSColor = true }

        // ── Paragraph Style ──
        let para = NSMutableParagraphStyle()
        let lineBoxHeight = targetLineHeight(ctx: newCtx)
        para.minimumLineHeight = lineBoxHeight
        para.maximumLineHeight = lineBoxHeight
        let defaultParagraphSpacing = isHeading ? config.paragraphSpacing * 0.6 : config.paragraphSpacing
        let resolvedParagraphSpacing: CGFloat
        if ctx.compactBlockSpacing {
            resolvedParagraphSpacing = 0
        } else if style.paragraphSpacingAfter > 0 {
            resolvedParagraphSpacing = style.paragraphSpacingAfter
        } else if ctx.insideDecoratedContainer && style.hasExplicitVerticalMargins {
            // Inside a decorated box the author's explicit `margin: 0` wins over the reader's
            // default paragraph spacing (`.sys p { margin: 0 }` — the pill's lines sit snug).
            resolvedParagraphSpacing = 0
        } else {
            resolvedParagraphSpacing = defaultParagraphSpacing
        }
        para.paragraphSpacing = isVertical(style)
            ? min(resolvedParagraphSpacing, newCtx.font.pointSize)
            : resolvedParagraphSpacing + style.paddingBottom
        // In vertical mode, CSS margin-top (→ paragraphSpacingBefore) adds space
        // in the block-progression direction (right-to-left for vertical-rl).
        // Large values (e.g. 10em on .normalp1) were authored for horizontal layout
        // and would push content off-screen; cap at 1em to prevent this.
        if isVertical(style) {
            para.paragraphSpacingBefore = 0
        } else {
            let resolvedParagraphSpacingBefore = ctx.compactBlockSpacing
                ? min(max(0, style.paragraphSpacingBefore), ctx.baseSize * 0.15)
                : style.paragraphSpacingBefore
            para.paragraphSpacingBefore = resolvedParagraphSpacingBefore + style.paddingTop
        }
        let cumulativeMarginLeft = ctx.inheritedBlockMarginLeft + style.marginLeft
        let cumulativeMarginRight = ctx.inheritedBlockMarginRight + style.marginRight
        let structuralLeft = cumulativeMarginLeft + style.borderLeftWidth + style.paddingLeft
        let structuralRight = cumulativeMarginRight + style.borderRightWidth + style.paddingRight
        // A fixed-width block with `margin: auto` centers within the containing block's CONTENT
        // box (after inherited padding/margins), not the full render width — centering against
        // renderWidth and then ALSO adding the inherited insets would double-count them.
        let widthInset: CGFloat
        if style.isHorizontallyCentered, let blockWidth = style.width, blockWidth > 0,
           let renderWidth = config.renderWidth {
            let contentBoxWidth = max(blockWidth, renderWidth - structuralLeft - structuralRight)
            widthInset = max(0, (contentBoxWidth - blockWidth) / 2)
        } else {
            widthInset = 0
        }
        let leftInset = structuralLeft + widthInset
        let rightInset = structuralRight + widthInset
        let rtlRightAligned = style.baseWritingDirection == .rightToLeft
            && (style.textAlign == .right || style.textAlign == .natural)
            && !isVertical(style)
        if rtlRightAligned {
            // CoreText double-counts a negative tailIndent on the leading (right) edge of
            // RTL right-aligned text, over-insetting it. Carry the right margin in headIndent
            // (the leading inset) and leave tailIndent at 0. See HTMLAttributedStringBuilder.
            // Only for right/natural alignment — centered/justified need symmetric indents.
            para.headIndent = rightInset
            para.firstLineHeadIndent = rightInset + style.textIndent
            para.tailIndent = 0
        } else {
            para.firstLineHeadIndent = leftInset + style.textIndent
            para.headIndent = leftInset
            para.tailIndent = rightInset > 0 ? -rightInset : 0
        }
        para.alignment = nsTextAlignment(from: style.textAlign)
        para.baseWritingDirection = style.baseWritingDirection
        newCtx.paragraphStyle = para
        newCtx.baselineOffset = ReaderTypographyCorrection.baselineOffset(
            font: newCtx.font,
            targetLineHeight: para.minimumLineHeight
        )

        if style.underline { newCtx.underline = true }
        if style.strikethrough { newCtx.strikethrough = true }
        // Accumulate the parent content box for nested child blocks. CoreText has one frame, so
        // child paragraph indents must inherit not only authored margins, but also the centering
        // inset created by width:auto margins plus border/padding. Otherwise a `width:80%`
        // decorated container can draw correctly while its nested `<p>` still lays out against the
        // full page column and spills through the border.
        newCtx.inheritedBlockMarginLeft = leftInset
        newCtx.inheritedBlockMarginRight = rightInset

        return newCtx
    }

    // MARK: - Apply Inline Style to Context

    private func applyInlineStyle(_ style: RenderStyle, to ctx: RenderContext) -> RenderContext {
        guard style.bold || style.italic || style.color != nil || !style.fontFamilies.isEmpty
                || style.underline || style.strikethrough || style.fontSizeMultiplier != 1.0
                || style.ssmlIPA != nil else { return ctx }
        var newCtx = ctx
        let families = style.fontFamilies.isEmpty ? ctx.fontFamilies : style.fontFamilies
        let bold = style.bold || ctx.font.isBold
        let weight = bold ? max(style.fontWeight, max(ctx.fontWeight, 700)) : max(style.fontWeight, ctx.fontWeight)
        let fontSize = style.fontSizeMultiplier != 1.0
            ? ctx.font.pointSize * style.fontSizeMultiplier
            : ctx.font.pointSize
        newCtx.font = makeFont(families: families, size: fontSize, weight: weight, italic: style.italic || ctx.font.isItalic)
        newCtx.fontFamilies = families
        newCtx.fontWeight = weight
        if let c = style.color { newCtx.textColor = c.uiColor; newCtx.hasCSSColor = true }
        if style.underline { newCtx.underline = true }
        if style.strikethrough { newCtx.strikethrough = true }
        if let ipa = style.ssmlIPA { newCtx.ipaPronunciation = ipa }
        return newCtx
    }

    // MARK: - Line Height Calculation

    private func targetLineHeight(ctx: RenderContext) -> CGFloat {
        ReaderTypographyCorrection.targetLineHeight(
            font: ctx.font,
            fontSize: ctx.font.pointSize,
            lineHeightMultiple: ctx.lineHeightMultiple
        )
    }

    // MARK: - Font

    private func makeFont(families: [String], size: CGFloat, weight: Int, italic: Bool) -> UIFont {
        var font = makeFontResolved(families: families, size: size, weight: weight, italic: italic)
        // Synthetic italic: like the legacy builder, when CSS asks for italic but the resolved face
        // has no italic variant (embedded EPUB fonts often ship only an upright file), bake the slant
        // into the font matrix. CoreText's CTFrameDraw ignores the `.obliqueness` attribute, so the
        // shear has to live in the font itself — otherwise the italic silently renders flat here.
        if italic && !font.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            font = HTMLAttributedStringBuilder.synthesizedObliqueFont(from: font)
        }
        return font
    }

    private func makeFontResolved(families: [String], size: CGFloat, weight: Int, italic: Bool) -> UIFont {
        let bold = weight >= 600 || config.isBold
        let candidateFamilies = families + (config.fontFamily.map { [$0] } ?? [])
        if let resolved = config.resolvedFont?(candidateFamilies, bold ? max(weight, 700) : weight, italic, size) {
            return wrapCJKFont(resolved, size: size)
        }

        for family in candidateFamilies {
            let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))
            guard !trimmed.isEmpty else { continue }
            if let font = UIFont(name: trimmed, size: size) {
                let withTraits = applyTraits(to: font, bold: bold, italic: italic, size: size)
                let descriptor = withTraits.fontDescriptor.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes())
                return wrapCJKFont(UIFont(descriptor: descriptor, size: size), size: size)
            }
        }

        if bold && italic {
            let system = UIFont.systemFont(ofSize: size, weight: .bold)
            var traits = system.fontDescriptor.symbolicTraits
            traits.insert(.traitItalic)
            if let descriptor = system.fontDescriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: descriptor.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes()), size: size)
            }
            return UIFont(descriptor: system.fontDescriptor.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes()), size: size)
        } else if bold {
            return UIFont(descriptor: UIFont.systemFont(ofSize: size, weight: .bold).fontDescriptor.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes()), size: size)
        } else if italic {
            return UIFont(descriptor: UIFont.italicSystemFont(ofSize: size).fontDescriptor.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes()), size: size)
        } else {
            return UIFont(descriptor: UIFont.systemFont(ofSize: size).fontDescriptor.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes()), size: size)
        }
    }

    private func applyTraits(to font: UIFont, bold: Bool, italic: Bool, size: CGFloat) -> UIFont {
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
            return UIFont(descriptor: descriptor, size: size)
        }
        // Font doesn't support requested traits natively — use synthetic bold/italic
        var desc = font.fontDescriptor
        if bold {
            let attrs: [UIFontDescriptor.AttributeName: Any] = [
                .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]
            ]
            desc = desc.addingAttributes(attrs)
        }
        if italic {
            let obliqued = HTMLAttributedStringBuilder.synthesizedObliqueFont(from: UIFont(descriptor: desc, size: size))
            desc = obliqued.fontDescriptor
        }
        return UIFont(descriptor: desc.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes()), size: size)
    }

    private static func cascadeAttributes() -> [UIFontDescriptor.AttributeName: Any] {
        let fallbacks = ["Georgia", "PingFangSC-Regular", "STHeitiSC-Light", "AppleColorEmoji"]
            .compactMap { UIFontDescriptor(name: $0, size: 0) }
        guard !fallbacks.isEmpty else { return [:] }
        return [.cascadeList: fallbacks]
    }

    private func wrapCJKFont(_ font: UIFont, size: CGFloat) -> UIFont {
        guard isCJKFont(font) else { return font }
        guard let georgia = UIFont(name: "Georgia", size: size) else { return font }
        var desc = georgia.fontDescriptor
        let cjkDesc = font.fontDescriptor
        let fallbackDescs = [cjkDesc]
            + ["PingFangSC-Regular", "STHeitiSC-Light", "AppleColorEmoji"]
                .compactMap { UIFontDescriptor(name: $0, size: 0) }
        desc = desc.addingAttributes([.cascadeList: fallbackDescs])
        return UIFont(descriptor: desc, size: size)
    }

    private func isCJKFont(_ font: UIFont) -> Bool {
        var ch: UniChar = 0x4E2D
        var glyph: CGGlyph = 0
        return CTFontGetGlyphsForCharacters(font as CTFont, &ch, &glyph, 1) && glyph != 0
    }

    // MARK: - Images / Block Decoration

    private struct SingleImagePayload {
        let src: String
        let alt: String
        let style: RenderStyle
        let anchorID: String?
        let href: String?
        let svgContent: String?
    }

    private struct ImageMetrics {
        let drawWidth: CGFloat
        let drawHeight: CGFloat
        let totalWidth: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    /// Renders a paragraph-review (段評) count bubble as an inline image attachment.
    /// The placeholder carries `internalLinkAttribute = reviewURL` so both the paged
    /// (attachment hit-test) and scroll (link hit-test) tap paths can recognize it.
    private func renderCommentBadge(
        count: String,
        reviewURL: String,
        title: String,
        ctx: RenderContext
    ) async -> NSAttributedString {
        let badgeColor = ctx.textColor.withAlphaComponent(0.55)
        let image = ReviewBadgeRenderer.bubble(count: count, pointSize: ctx.font.pointSize, color: badgeColor)
        var style = RenderStyle.none
        style.width = image.size.width
        style.height = image.size.height
        style.isTextSizedImage = true
        let placeholder = NSMutableAttributedString(
            attributedString: await makeImagePlaceholder(
                image: image,
                style: style,
                ctx: ctx,
                imageSource: "",
                imageAlt: title,
                displayMode: .inline
            )
        )
        guard placeholder.length > 0 else { return placeholder }
        placeholder.addAttribute(
            HTMLAttributedStringBuilder.internalLinkAttribute,
            value: reviewURL,
            range: NSRange(location: 0, length: placeholder.length)
        )
        return placeholder
    }

    private func renderInlineImage(
        src: String,
        alt: String,
        style: RenderStyle,
        svgContent: String?,
        ctx: RenderContext
    ) async -> NSAttributedString {
        // ⟐ bubble diagnostics: confirm on device whether 段評 SVGs (光遇/企点) even reach this
        // renderer, and whether they're flagged text-sized. Fingerprint keeps DISTINCT bubble
        // types from deduping into one line (so we see isTextSized per template, not just the first).
        let bubbleFP = src.range(of: ";base64,").map { String(src[$0.upperBound...].prefix(10)) } ?? String(src.prefix(10))
        CommentBubbleSVGRecognizer.diag("render:enter fp=\(bubbleFP) isTextSized=\(style.isTextSizedImage) svg=\(svgContent != nil || src.lowercased().contains("svg"))",
            context: ["srcPrefix": String(src.prefix(56)), "hasSvgContent": svgContent != nil])

        if style.isTextSizedImage {
            let recognized = CommentBubbleSVGRecognizer.recognize(src: src, svgContent: svgContent)
            CommentBubbleSVGRecognizer.diag("textSized:enter recognized=\(recognized != nil)",
                context: ["srcPrefix": String(src.prefix(48)), "svgContentLen": svgContent?.count ?? -1])
            if let recognized {
                let image = CommentBubbleSVGRecognizer.draw(svg: recognized, pointSize: ctx.font.pointSize, themeTextColor: ctx.textColor)
                let metrics = await resolvedImageMetrics(
                    image: image,
                    style: style,
                    font: ctx.font,
                    displayMode: .inline,
                    availableWidthOverride: availableImageWidth(in: ctx)
                )
                return await makeImagePlaceholder(
                    image: image,
                    style: style,
                    ctx: ctx,
                    imageSource: "",
                    imageAlt: alt,
                    displayMode: .inline,
                    precomputedMetrics: metrics
                )
            }
        }

        if let svgContent, !svgContent.isEmpty {
            let screenWidth = await MainActor.run { UIScreen.main.bounds.width }
            let resolvedWidth = config.renderWidth ?? screenWidth
            let targetSize = await SVGWebViewRasterizer.shared.resolveSVGSize(
                styleWidth: style.width,
                styleHeight: style.height,
                svgString: svgContent,
                renderWidth: resolvedWidth
            )
            var image = await SVGWebViewRasterizer.shared.render(
                svgString: svgContent,
                size: targetSize,
                baseURL: nil
            )
            if style.isTextSizedImage, let img = image {
                image = img.trimmingTransparentPixels() ?? img
            }
            if image == nil {
                guard !alt.isEmpty else { return NSAttributedString() }
                var attrs = ctx.baseAttributes
                attrs[.foregroundColor] = UIColor.secondaryLabel
                return NSAttributedString(string: "[\(alt)]", attributes: attrs)
            }
            if let side = style.floatSide {
                return makeFloatPlaceholder(
                    side: side,
                    image: image,
                    style: style,
                    imageSource: "",
                    imageAlt: alt,
                    ctx: ctx
                )
            }
            let metrics = await resolvedImageMetrics(
                image: image,
                style: style,
                font: ctx.font,
                displayMode: .inline,
                availableWidthOverride: availableImageWidth(in: ctx)
            )
            return await makeImagePlaceholder(
                image: image,
                style: style,
                ctx: ctx,
                imageSource: "",
                imageAlt: alt,
                displayMode: .inline,
                precomputedMetrics: metrics
            )
        }

        if config.imageLoader == nil {
            if let side = style.floatSide {
                return makeFloatPlaceholder(
                    side: side,
                    image: nil,
                    style: style,
                    imageSource: src,
                    imageAlt: alt,
                    ctx: ctx
                )
            }
            guard !alt.isEmpty else { return NSAttributedString() }
            var attrs = ctx.baseAttributes
            let altFont = UIFont(name: ctx.font.fontName, size: ctx.font.pointSize - 1)
                ?? UIFont.italicSystemFont(ofSize: ctx.font.pointSize - 1)
            attrs[.font] = altFont
            return NSAttributedString(string: "[\(alt)]\n", attributes: attrs)
        }

        var image = src.isEmpty ? nil : await config.imageLoader?(src)
        // ⟐ bubble: this is the WebView-fallback path (recognize missed). Whether the baked-in
        // SVG margins get cropped depends ENTIRELY on isTextSizedImage here. Log the decision +
        // the before/after size so we can see if the gap survives trimming or trimming is skipped.
        if svgContent != nil || src.lowercased().contains("svg") {
            let fp = src.range(of: ";base64,").map { String(src[$0.upperBound...].prefix(10)) } ?? String(src.prefix(10))
            let before = image.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil"
            let after = (style.isTextSizedImage ? image?.trimmingTransparentPixels() : image).map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? before
            CommentBubbleSVGRecognizer.diag("loaderTrim fp=\(fp) isTextSized=\(style.isTextSizedImage)",
                context: ["before": before, "after": after])
        }
        if style.isTextSizedImage, let img = image {
            image = img.trimmingTransparentPixels() ?? img
        }
        CoreTextPaginator.debugVerticalLog("EPUBFLOW render.inlineImage.node src=\(src) alt=\(alt) imageLoaded=\(image != nil) writingMode=\(config.writingMode) fontSize=\(ctx.font.pointSize) styleWidth=\(style.width.map { "\($0)" } ?? "nil") styleHeight=\(style.height.map { "\($0)" } ?? "nil")")
        if let side = style.floatSide {
            return makeFloatPlaceholder(
                side: side,
                image: image,
                style: style,
                imageSource: src,
                imageAlt: alt,
                ctx: ctx
            )
        }
        return await makeImagePlaceholder(
            image: image,
            style: style,
            ctx: ctx,
            imageSource: src,
            imageAlt: alt,
            displayMode: .inline
        )
    }

    private func renderMathML(
        latex: String,
        alt: String,
        style: RenderStyle,
        displayMode: MathDisplayMode,
        ctx: RenderContext
    ) async -> NSAttributedString {
        let mathCtx = applyInlineStyle(style, to: ctx)
        let runMode: ImageRunInfo.DisplayMode = displayMode == .block ? .block : .inline
        let maxWidth = max(1, config.renderWidth ?? 320)
        let rendered = await MathMLImageRenderer.render(
            latex: latex,
            fontSize: mathCtx.font.pointSize,
            textColor: mathCtx.textColor,
            displayMode: runMode,
            maxWidth: maxWidth
        )
        guard let rendered else {
            var attrs = mathCtx.baseAttributes
            attrs[.foregroundColor] = UIColor.secondaryLabel
            return NSAttributedString(
                string: MathMLLatexConverter.fallbackText(alt: alt, latex: latex),
                attributes: attrs
            )
        }
        let image = rendered.image

        let metrics = await resolvedMathImageMetrics(
            image: image,
            style: style,
            font: mathCtx.font,
            displayMode: runMode,
            mathDescent: rendered.descent
        )
        let placeholder = NSMutableAttributedString(
            attributedString: await makeImagePlaceholder(
                image: image,
                style: style,
                ctx: mathCtx,
                imageSource: "mathml:",
                imageAlt: alt,
                displayMode: runMode,
                precomputedMetrics: metrics
            )
        )
        if placeholder.length > 0 {
            placeholder.addAttribute(
                HTMLAttributedStringBuilder.semanticTagAttribute,
                value: "math",
                range: NSRange(location: 0, length: placeholder.length)
            )
        }
        return placeholder
    }

    private func renderImageOnlyBlock(
        payload: SingleImagePayload,
        blockStyle: RenderStyle,
        ctx: RenderContext,
        isHeading: Bool,
        headingLevel: Int
    ) async -> NSAttributedString {
        let blockCtx = applyBlockStyle(blockStyle, to: ctx, isHeading: isHeading, headingLevel: headingLevel)
        let image: UIImage?
        if let svgContent = payload.svgContent, !svgContent.isEmpty {
            let screenWidth = await MainActor.run { UIScreen.main.bounds.width }
            let resolvedWidth = config.renderWidth ?? screenWidth
            let targetSize = await SVGWebViewRasterizer.shared.resolveSVGSize(
                styleWidth: payload.style.width,
                styleHeight: payload.style.height,
                svgString: svgContent,
                renderWidth: resolvedWidth
            )
            image = await SVGWebViewRasterizer.shared.render(
                svgString: svgContent,
                size: targetSize,
                baseURL: nil
            )
        } else {
            image = payload.src.isEmpty ? nil : await config.imageLoader?(payload.src)
        }

        var attachmentStyle = blockStyle
        if let width = payload.style.width {
            attachmentStyle.width = width
        }
        if let height = payload.style.height {
            attachmentStyle.height = height
        }
        attachmentStyle.paddingTop += payload.style.paddingTop
        attachmentStyle.paddingLeft += payload.style.paddingLeft
        attachmentStyle.paddingBottom += payload.style.paddingBottom
        attachmentStyle.paddingRight += payload.style.paddingRight
        attachmentStyle.opacity = payload.style.opacity

        // Online sources (起点/Legado) emit bare `<img>` illustrations & author photos that the
        // source apps center; honor that when the block carries no explicit alignment of its own.
        let shouldCenter = blockStyle.isHorizontallyCentered
            || (config.centerStandaloneImages && attachmentStyle.textAlign == .natural)
        let imageAlignment: NSTextAlignment = shouldCenter ? .center : nsTextAlignment(from: attachmentStyle.textAlign)

        let imageMetrics = await resolvedImageMetrics(
            image: image,
            style: attachmentStyle,
            font: blockCtx.font,
            displayMode: .block,
            availableWidthOverride: availableImageWidth(in: blockCtx)
        )
        let blockImage = HTMLAttributedStringBuilder.BlockRenderStyle.BlockImage(
            image: image,
            source: payload.src,
            drawSize: CGSize(width: imageMetrics.drawWidth, height: imageMetrics.drawHeight),
            opacity: attachmentStyle.opacity,
            alignment: imageAlignment,
            paddingTop: attachmentStyle.paddingTop,
            paddingLeft: attachmentStyle.paddingLeft,
            paddingBottom: attachmentStyle.paddingBottom,
            paddingRight: attachmentStyle.paddingRight
        )

        let placeholder = NSMutableAttributedString(
            attributedString: await makeImagePlaceholder(
                image: image,
                style: attachmentStyle,
                ctx: blockCtx,
                imageSource: payload.src,
                imageAlt: payload.alt,
                displayMode: .block,
                precomputedMetrics: imageMetrics
            )
        )
        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttribute(
            .paragraphStyle,
            value: imageBlockParagraphStyle(
                base: blockCtx.paragraphStyle,
                metrics: imageMetrics,
                isHorizontallyCentered: shouldCenter
            ),
            range: range
        )
        if let href = payload.href {
            placeholder.addAttribute(HTMLAttributedStringBuilder.internalLinkAttribute, value: href, range: range)
        }
        if let anchorID = payload.anchorID {
            placeholder.addAttribute(
                HTMLAttributedStringBuilder.anchorIDAttribute,
                value: anchorID,
                range: NSRange(location: 0, length: min(1, placeholder.length))
            )
        }
        applyBlockDecorationAttributes(style: attachmentStyle, to: placeholder, range: range, blockImage: blockImage)

        let output = NSMutableAttributedString(attributedString: placeholder)
        output.append(NSAttributedString(string: "\n", attributes: blockCtx.baseAttributes))
        return output
    }

    private func renderTable(
        _ table: HTMLTableModel,
        style: RenderStyle,
        ctx: RenderContext
    ) async -> NSAttributedString {
        let blockCtx = applyBlockStyle(style, to: ctx, isHeading: false)
        // Rasterize at exactly the width the table's paragraph gives it (column width minus the
        // `width: 90%` + `margin: auto` centering insets). Generating at the full page width and
        // letting the image metrics squeeze it into the paragraph scaled the whole bitmap down
        // (~0.9x here) — smaller, blurry cell text versus the tap-to-open original ("被压缩").
        let maxWidth: CGFloat
        if let available = availableImageWidth(in: blockCtx) {
            maxWidth = available
        } else if let renderWidth = config.renderWidth {
            maxWidth = renderWidth
        } else {
            maxWidth = await MainActor.run { UIScreen.main.bounds.width }
        }

        let image = await MainActor.run {
            HTMLTableRasterizer.render(
                table: table,
                maxWidth: maxWidth,
                baseFont: blockCtx.font,
                textColor: blockCtx.textColor,
                backgroundColor: config.backgroundColor
            )
        }
        guard let image else {
            return NSAttributedString(string: table.accessibilityText + "\n", attributes: blockCtx.baseAttributes)
        }

        var tableStyle = style
        tableStyle.width = image.size.width
        tableStyle.height = image.size.height
        // The paragraph's centering insets already applied `table { width: 90% }` when the
        // bitmap width was chosen above; leaving the percent on the style would make the image
        // metrics multiply it in AGAIN (0.9 × 0.9 ≈ 0.8 of the column — the residual "压缩").
        tableStyle.rawWidthPercent = nil
        let metrics = await resolvedImageMetrics(
            image: image,
            style: tableStyle,
            font: blockCtx.font,
            displayMode: .block,
            availableWidthOverride: availableImageWidth(in: blockCtx)
        )
        let placeholder = NSMutableAttributedString(
            attributedString: await makeImagePlaceholder(
                image: image,
                style: tableStyle,
                ctx: blockCtx,
                imageSource: "table",
                imageAlt: table.accessibilityText,
                displayMode: .block,
                precomputedMetrics: metrics
            )
        )
        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttribute(
            .paragraphStyle,
            value: imageBlockParagraphStyle(
                base: blockCtx.paragraphStyle,
                metrics: metrics,
                // `table { margin: 1em auto }` — without this the placeholder line stays
                // left-pinned and the table hugs the left edge with all the slack on the right.
                isHorizontallyCentered: style.isHorizontallyCentered
            ),
            range: range
        )
        placeholder.addAttribute(
            HTMLAttributedStringBuilder.semanticTagAttribute,
            value: "table",
            range: range
        )
        let output = NSMutableAttributedString(attributedString: placeholder)
        output.append(NSAttributedString(string: "\n", attributes: blockCtx.baseAttributes))
        return output
    }

    private func renderMedia(
        _ media: EPUBMediaAttachment,
        style: RenderStyle,
        ctx: RenderContext
    ) async -> NSAttributedString {
        let blockCtx = applyBlockStyle(style, to: ctx, isHeading: false)
        let maxWidth: CGFloat
        if let renderWidth = config.renderWidth {
            maxWidth = renderWidth
        } else {
            maxWidth = await MainActor.run { UIScreen.main.bounds.width }
        }
        let resolvedMedia = EPUBMediaAttachment(
            kind: media.kind,
            sourceHref: config.mediaURLResolver?(media.sourceHref) ?? media.sourceHref,
            mediaType: media.mediaType,
            title: media.title,
            posterHref: media.posterHref.flatMap { config.mediaURLResolver?($0) ?? $0 }
        )
        let intrinsicSize: CGSize? = {
            guard let w = style.width, w > 0 else { return nil }
            if let h = style.height, h > 0 { return CGSize(width: w, height: h) }
            return CGSize(width: w, height: w * 9.0 / 16.0)
        }()
        let image = await MainActor.run {
            EPUBMediaPlaceholderRenderer.image(
                for: resolvedMedia,
                maxWidth: maxWidth,
                intrinsicSize: intrinsicSize,
                font: blockCtx.font,
                textColor: blockCtx.textColor,
                backgroundColor: config.backgroundColor
            )
        }

        var mediaStyle = style
        mediaStyle.width = image.size.width
        mediaStyle.height = image.size.height
        let metrics = await resolvedImageMetrics(
            image: image,
            style: mediaStyle,
            font: blockCtx.font,
            displayMode: .block,
            availableWidthOverride: availableImageWidth(in: blockCtx)
        )
        // Center/lay out using the clamped draw size the placeholder actually reserves.
        mediaStyle.width = metrics.drawWidth
        mediaStyle.height = metrics.drawHeight
        let placeholder = NSMutableAttributedString(
            attributedString: await makeImagePlaceholder(
                image: image,
                style: mediaStyle,
                ctx: blockCtx,
                imageSource: resolvedMedia.sourceHref,
                imageAlt: resolvedMedia.title,
                displayMode: .block,
                precomputedMetrics: metrics
            )
        )
        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttribute(HTMLAttributedStringBuilder.mediaAttachmentAttribute, value: resolvedMedia, range: range)
        placeholder.addAttribute(HTMLAttributedStringBuilder.semanticTagAttribute, value: media.kind.rawValue, range: range)
        placeholder.addAttribute(
            .paragraphStyle,
            value: imageBlockParagraphStyle(base: blockCtx.paragraphStyle, metrics: metrics),
            range: range
        )
        let output = NSMutableAttributedString(attributedString: placeholder)
        output.append(NSAttributedString(string: "\n", attributes: blockCtx.baseAttributes))
        return output
    }

    private func renderUnsupportedInteractive(
        type: String,
        title: String,
        children: [RenderableNode],
        style: RenderStyle,
        ctx: RenderContext
    ) async -> NSAttributedString {
        let blockCtx = applyBlockStyle(style, to: ctx, isHeading: false)
        let maxWidth: CGFloat
        if let renderWidth = config.renderWidth {
            maxWidth = renderWidth
        } else {
            maxWidth = await MainActor.run { UIScreen.main.bounds.width }
        }
        let image = await MainActor.run {
            EPUBMediaPlaceholderRenderer.interactiveImage(
                title: localized("Interactive content isn't supported"),
                detail: title,
                maxWidth: maxWidth,
                font: blockCtx.font,
                textColor: blockCtx.textColor
            )
        }

        var placeholderStyle = style
        placeholderStyle.width = image.size.width
        placeholderStyle.height = image.size.height
        let metrics = await resolvedImageMetrics(
            image: image,
            style: placeholderStyle,
            font: blockCtx.font,
            displayMode: .block
        )
        placeholderStyle.width = metrics.drawWidth
        placeholderStyle.height = metrics.drawHeight

        let placeholder = NSMutableAttributedString(
            attributedString: await makeImagePlaceholder(
                image: image,
                style: placeholderStyle,
                ctx: blockCtx,
                imageSource: "",
                imageAlt: localized("Interactive content isn't supported"),
                displayMode: .block,
                precomputedMetrics: metrics
            )
        )
        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttribute(
            HTMLAttributedStringBuilder.unsupportedInteractiveAttribute,
            value: type,
            range: range
        )
        placeholder.addAttribute(
            HTMLAttributedStringBuilder.semanticTagAttribute,
            value: "unsupported-interactive",
            range: range
        )
        placeholder.addAttribute(
            .paragraphStyle,
            value: imageBlockParagraphStyle(base: blockCtx.paragraphStyle, metrics: metrics),
            range: range
        )

        let output = NSMutableAttributedString(attributedString: placeholder)
        output.append(NSAttributedString(string: "\n", attributes: blockCtx.baseAttributes))
        if !children.isEmpty {
            output.append(await renderBlock(children: children, style: style, ctx: ctx, isHeading: false))
        }
        return output
    }

    private func makeImagePlaceholder(
        image: UIImage?,
        style: RenderStyle,
        ctx: RenderContext,
        imageSource: String,
        imageAlt: String? = nil,
        displayMode: ImageRunInfo.DisplayMode,
        precomputedMetrics: ImageMetrics? = nil
    ) async -> NSAttributedString {
        let metrics: ImageMetrics
        if let precomputedMetrics {
            metrics = precomputedMetrics
        } else {
            metrics = await resolvedImageMetrics(
                image: image,
                style: style,
                font: ctx.font,
                displayMode: displayMode,
                availableWidthOverride: availableImageWidth(in: ctx)
            )
        }
        let placeholder = NSMutableAttributedString(
            attributedString: RunDelegateProvider.makeImagePlaceholder(
                image: image,
                font: ctx.font,
                textColor: ctx.textColor,
                totalWidth: metrics.totalWidth,
                drawWidth: metrics.drawWidth,
                drawHeight: metrics.drawHeight,
                ascent: metrics.ascent,
                descent: metrics.descent,
                paddingLeft: style.paddingLeft,
                paddingRight: style.paddingRight,
                imageSource: imageSource,
                imageAlt: imageAlt,
                displayMode: displayMode,
                opacity: style.opacity,
                isTextSized: style.isTextSizedImage
            )
        )
        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttributes(ctx.baseAttributes, range: range)
        return placeholder
    }

    private func relaxParagraphsContainingTallRuns(_ attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0 else { return }
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        let fullRange = NSRange(location: 0, length: attributedString.length)
        let nsString = attributedString.string as NSString
        var paragraphs: [(range: NSRange, requiredHeight: CGFloat)] = []

        attributedString.enumerateAttributes(in: fullRange) { attributes, range, _ in
            guard attributes[HTMLAttributedStringBuilder.spacerRunAttribute] == nil,
                  attributes[HTMLAttributedStringBuilder.inlineAnnotationRunAttribute] == nil,
                  let delegateValue = attributes[delegateKey]
            else { return }
            let delegate = delegateValue as! CTRunDelegate
            let info = Unmanaged<ImageRunInfo>
                .fromOpaque(CTRunDelegateGetRefCon(delegate))
                .takeUnretainedValue()
            guard info.image != nil else { return }

            let requiredHeight = ceil(info.ascent + info.descent)
            guard requiredHeight > 0 else { return }
            let paragraphRange = nsString.paragraphRange(for: range)
            if let index = paragraphs.firstIndex(where: { NSEqualRanges($0.range, paragraphRange) }) {
                paragraphs[index].requiredHeight = max(paragraphs[index].requiredHeight, requiredHeight)
            } else {
                paragraphs.append((paragraphRange, requiredHeight))
            }
        }

        for paragraph in paragraphs {
            var updates: [(range: NSRange, style: NSParagraphStyle)] = []
            attributedString.enumerateAttribute(.paragraphStyle, in: paragraph.range) { value, range, _ in
                guard let style = value as? NSParagraphStyle,
                      style.maximumLineHeight > 0,
                      style.maximumLineHeight < paragraph.requiredHeight
                else { return }
                let relaxed = style.mutableCopy() as! NSMutableParagraphStyle
                relaxed.maximumLineHeight = paragraph.requiredHeight
                updates.append((range, relaxed))
            }
            for update in updates {
                attributedString.addAttribute(.paragraphStyle, value: update.style, range: update.range)
            }
        }
    }

    private func relaxParagraphsContainingRubyAnnotations(_ attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: attributedString.length)
        let nsString = attributedString.string as NSString
        var paragraphRanges: [NSRange] = []

        attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.rubyAnnotationAttribute,
            in: fullRange,
            options: []
        ) { value, range, _ in
            guard value != nil else { return }
            let paragraphRange = nsString.paragraphRange(for: range)
            if !paragraphRanges.contains(where: { NSEqualRanges($0, paragraphRange) }) {
                paragraphRanges.append(paragraphRange)
            }
        }
        guard !paragraphRanges.isEmpty else { return }

        for paragraphRange in paragraphRanges {
            var updates: [(range: NSRange, style: NSParagraphStyle)] = []
            attributedString.enumerateAttribute(.paragraphStyle, in: paragraphRange, options: []) { value, range, _ in
                guard let style = value as? NSParagraphStyle else { return }
                let sampleIndex = max(0, min(range.location, attributedString.length - 1))
                let font = attributedString.attribute(.font, at: sampleIndex, effectiveRange: nil) as? UIFont
                let pointSize = font?.pointSize ?? config.baseFontSize
                let baseLineHeight = max(
                    style.minimumLineHeight,
                    font?.lineHeight ?? pointSize * config.lineHeightMultiple
                )
                let requiredLineHeight = ceil(baseLineHeight + pointSize * 0.75)
                guard style.minimumLineHeight < requiredLineHeight || style.maximumLineHeight > 0 else { return }

                let relaxed = style.mutableCopy() as! NSMutableParagraphStyle
                relaxed.minimumLineHeight = max(relaxed.minimumLineHeight, requiredLineHeight)
                relaxed.maximumLineHeight = 0
                updates.append((range, relaxed))
            }
            for update in updates {
                attributedString.addAttribute(.paragraphStyle, value: update.style, range: update.range)
            }
        }
    }

    private func markCompactBlockSpacing(
        _ attributedString: NSMutableAttributedString,
        range: NSRange,
        reason: String
    ) {
        guard attributedString.length > 0, range.length > 0 else { return }
        let boundedRange = NSIntersectionRange(
            range,
            NSRange(location: 0, length: attributedString.length)
        )
        guard boundedRange.length > 0 else { return }
        attributedString.addAttribute(
            HTMLAttributedStringBuilder.compactBlockSpacingAttribute,
            value: reason,
            range: boundedRange
        )
    }

    private func normalizeCompactBlockSpacing(_ attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0 else { return }
        let fullRange = NSRange(location: 0, length: attributedString.length)
        let nsString = attributedString.string as NSString
        let compactAfterMinimum: CGFloat = 0.01
        let compactSpacingMaximum = max(compactAfterMinimum, config.baseFontSize * 0.15)
        var processedParagraphs = Set<String>()

        attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.compactBlockSpacingAttribute,
            in: fullRange,
            options: []
        ) { value, effectiveRange, _ in
            guard value != nil else { return }
            var location = effectiveRange.location
            let effectiveEnd = min(attributedString.length, NSMaxRange(effectiveRange))
            while location < effectiveEnd {
                let rawParagraphRange = nsString.paragraphRange(
                    for: NSRange(location: location, length: 0)
                )
                let paragraphRange = NSIntersectionRange(rawParagraphRange, fullRange)
                guard paragraphRange.length > 0 else {
                    location += 1
                    continue
                }
                let key = "\(paragraphRange.location):\(paragraphRange.length)"
                if processedParagraphs.insert(key).inserted {
                    // The compact range's first `paragraphSpacingBefore` and last
                    // `paragraphSpacing` are the thread's spacing against the *outside*
                    // (its authored container margin + padding reserve) — only spacing
                    // between paragraphs inside the thread is compacted.
                    normalizeCompactParagraphSpacing(
                        attributedString,
                        paragraphRange: paragraphRange,
                        maxSpacing: compactSpacingMaximum,
                        afterMinimum: compactAfterMinimum,
                        preserveBefore: rawParagraphRange.location <= effectiveRange.location,
                        preserveAfter: NSMaxRange(rawParagraphRange) >= effectiveEnd,
                        reason: String(describing: value!)
                    )
                }
                let next = max(location + 1, NSMaxRange(rawParagraphRange))
                location = next
            }
        }
    }

    private func normalizeCompactParagraphSpacing(
        _ attributedString: NSMutableAttributedString,
        paragraphRange: NSRange,
        maxSpacing: CGFloat,
        afterMinimum: CGFloat,
        preserveBefore: Bool = false,
        preserveAfter: Bool = false,
        reason: String
    ) {
        // A paragraph that begins/ends a decorated container run carries that container's
        // padding+border in its reserved spacing; the drawn box extends outward by exactly
        // that amount, so the cap must leave it intact or the border overlaps neighbours.
        let structural = Self.containerNonCollapsibleInsets(in: attributedString, paragraphRange: paragraphRange)
        let beforeCap = maxSpacing + structural.top
        let afterCap = maxSpacing + structural.bottom
        var updates: [(range: NSRange, style: NSMutableParagraphStyle, oldBefore: CGFloat, oldAfter: CGFloat)] = []
        attributedString.enumerateAttribute(.paragraphStyle, in: paragraphRange, options: []) { value, range, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let mutable = style.mutableCopy() as! NSMutableParagraphStyle
            let oldBefore = mutable.paragraphSpacingBefore
            let oldAfter = mutable.paragraphSpacing
            let newBefore = preserveBefore ? oldBefore : min(max(0, oldBefore), beforeCap)
            let newAfter = preserveAfter
                ? max(afterMinimum, oldAfter)
                : max(afterMinimum, min(max(oldAfter, 0), afterCap))
            guard abs(newBefore - oldBefore) > 0.001 || abs(newAfter - oldAfter) > 0.001 else {
                return
            }
            mutable.paragraphSpacingBefore = newBefore
            mutable.paragraphSpacing = newAfter
            updates.append((range, mutable, oldBefore, oldAfter))
        }

        for update in updates {
            attributedString.addAttribute(.paragraphStyle, value: update.style, range: update.range)
        }
    }

    private func makeFloatPlaceholder(
        side: RenderFloatSide,
        image: UIImage?,
        style: RenderStyle,
        imageSource: String,
        imageAlt: String?,
        ctx: RenderContext
    ) -> NSAttributedString {
        let renderWidth = max(1, config.renderWidth ?? 320)
        var drawWidth: CGFloat
        if let pct = style.rawWidthPercent {
            drawWidth = renderWidth * pct / 100.0
        } else if let width = style.width {
            drawWidth = width
        } else {
            drawWidth = renderWidth * 0.5
        }
        drawWidth = max(1, min(drawWidth, renderWidth * 0.6))

        var drawHeight: CGFloat
        if let height = style.height {
            drawHeight = height
        } else if let image, image.size.width > 0 {
            drawHeight = drawWidth * image.size.height / image.size.width
        } else {
            drawHeight = drawWidth
        }
        drawHeight = max(1, min(drawHeight, renderWidth * 1.5))

        let placeholder = HTMLAttributedStringBuilder.FloatPlaceholder(
            side: {
                switch side {
                case .left: return .left
                case .right: return .right
                }
            }(),
            image: image,
            drawWidth: ceil(drawWidth),
            drawHeight: ceil(drawHeight),
            marginLeft: max(0, style.marginLeft),
            marginRight: max(0, style.marginRight),
            marginTop: 0,
            marginBottom: max(0, style.paragraphSpacingAfter),
            source: imageSource,
            alt: imageAlt
        )
        let marker = NSMutableAttributedString(string: "\u{200B}", attributes: ctx.baseAttributes)
        marker.addAttribute(
            HTMLAttributedStringBuilder.floatAttribute,
            value: placeholder,
            range: NSRange(location: 0, length: marker.length)
        )
        return marker
    }

    private func imageBlockParagraphStyle(base: NSParagraphStyle, metrics: ImageMetrics, isHorizontallyCentered: Bool = false) -> NSParagraphStyle {
        let paragraph = base.mutableCopy() as! NSMutableParagraphStyle
        let reservedLineHeight = ceil(max(paragraph.minimumLineHeight, metrics.ascent + metrics.descent))
        paragraph.minimumLineHeight = reservedLineHeight
        paragraph.maximumLineHeight = reservedLineHeight
        if isHorizontallyCentered {
            paragraph.alignment = .center
        }
        return paragraph
    }

    private func makeInlineAnnotationPlaceholder(
        _ content: NSAttributedString,
        placeholderCtx: RenderContext,
        annotationCtx: RenderContext
    ) -> NSAttributedString {
        guard content.length > 0 else { return NSAttributedString() }
        let annotation = NSMutableAttributedString(attributedString: content)
        annotation.normalizeForVerticalLayoutInPlace()
        annotation.addAttribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            value: true,
            range: NSRange(location: 0, length: annotation.length)
        )
        CoreTextPaginator.debugVerticalLog("EPUBFLOW annotation.placeholder.node len=\(annotation.length) placeholderFont=\(placeholderCtx.font.pointSize) annotationFont=\(annotationCtx.font.pointSize) preview=\"\(debugTextPreview(annotation.string))\"")
        let placeholder = NSMutableAttributedString(attributedString: RunDelegateProvider.makeInlineAnnotationPlaceholder(
            attributedString: annotation,
            placeholderFont: placeholderCtx.font,
            textColor: annotationCtx.textColor
        ))
        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttributes(placeholderCtx.baseAttributes, range: range)
        placeholder.addAttribute(HTMLAttributedStringBuilder.inlineAnnotationRunAttribute, value: true, range: range)
        placeholder.addAttribute(HTMLAttributedStringBuilder.spacerRunAttribute, value: true, range: range)
        return placeholder
    }

    private func addRubyAnnotation(_ text: String, to attributedString: NSMutableAttributedString) {
        let rubyText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rubyText.isEmpty, attributedString.length > 0 else { return }
        attributedString.addAttribute(
            HTMLAttributedStringBuilder.rubyAnnotationAttribute,
            value: HTMLAttributedStringBuilder.makeRubyAnnotation(text: rubyText),
            range: NSRange(location: 0, length: attributedString.length)
        )
    }

    private func debugTextPreview(_ text: String, limit: Int = 60) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{FFFC}", with: "OBJ")
            .replacingOccurrences(of: "\u{3000}", with: "IDEOSPACE")
        return String(normalized.prefix(limit))
    }

    private func availableImageWidth(in ctx: RenderContext) -> CGFloat? {
        guard let renderWidth = config.renderWidth else { return nil }
        let paragraph = ctx.paragraphStyle
        let leftInset = max(0, min(paragraph.headIndent, paragraph.firstLineHeadIndent))
        let rightInset = paragraph.tailIndent < 0 ? -paragraph.tailIndent : 0
        return max(1, renderWidth - leftInset - rightInset)
    }

    private func resolvedImageMetrics(
        image: UIImage?,
        style: RenderStyle,
        font: UIFont,
        displayMode: ImageRunInfo.DisplayMode = .inline,
        availableWidthOverride: CGFloat? = nil
    ) async -> ImageMetrics {
        let screenWidth = await MainActor.run { UIScreen.main.bounds.width }
        let baseWidth = availableWidthOverride ?? config.renderWidth ?? screenWidth
        let availableWidth = max(1, baseWidth - style.paddingLeft - style.paddingRight)
        let maxDrawHeight = max(1, baseWidth * 1.5)
        let isVertical = self.isVertical(style)
        let explicitWidth = style.rawWidthPercent.map { max(0, baseWidth * $0 / 100.0) } ?? style.width

        var drawWidth: CGFloat
        var drawHeight: CGFloat

        if let image {
            // In vertical mode, CSS width/height were authored for horizontal layout.
            // For block images: ignore explicit width so the image fills the column.
            // For inline images (font_patch etc.): keep the 1em constraint so they stay character-sized.
            if isVertical, displayMode == .block, style.width != nil {
                drawWidth = min(image.size.width, availableWidth)
                drawHeight = image.size.height * (drawWidth / max(image.size.width, 1))
            } else if let explicitWidth, let explicitHeight = style.height {
                drawWidth = explicitWidth
                drawHeight = explicitHeight
            } else if let explicitWidth {
                let ratio = explicitWidth / max(image.size.width, 1)
                drawWidth = explicitWidth
                drawHeight = image.size.height * ratio
            } else if let explicitHeight = style.height {
                let ratio = explicitHeight / max(image.size.height, 1)
                drawWidth = image.size.width * ratio
                drawHeight = explicitHeight
            } else if style.isTextSizedImage {
                // Legado `style:"text"`: scale the image so its height matches the surrounding text
                // line height — a small inline icon (段評 comment bubble) that sits at the line end,
                // not a full-size illustration. Preserve aspect ratio from the rasterized bitmap.
                let targetHeight = max(font.lineHeight, font.pointSize)
                let ratio = targetHeight / max(image.size.height, 1)
                drawWidth = image.size.width * ratio
                drawHeight = targetHeight
            } else {
                drawWidth = image.size.width
                drawHeight = image.size.height
            }
        } else {
            // No image yet (async remote load in flight / failed). Reserve a modest SQUARE
            // placeholder rather than a full-width 0.6-ratio box, so a thumbnail-sized image
            // doesn't flash stretched-wide before it finishes loading.
            let placeholderSide = min(availableWidth, 180)
            drawWidth = explicitWidth ?? placeholderSide
            drawHeight = style.height ?? placeholderSide
        }

        if drawWidth > availableWidth {
            let scale = availableWidth / max(drawWidth, 1)
            drawWidth = availableWidth
            drawHeight *= scale
        }
        if drawHeight > maxDrawHeight {
            let scale = maxDrawHeight / max(drawHeight, 1)
            drawHeight = maxDrawHeight
            drawWidth *= scale
        }

        let totalWidth = isVertical ? drawHeight : drawWidth + style.paddingLeft + style.paddingRight
        let lineHeight = max(font.lineHeight, font.pointSize)
        let ascent: CGFloat
        let descent: CGFloat
        if isVertical {
            ascent = drawWidth / 2
            descent = drawWidth / 2
        } else if drawHeight > lineHeight {
            ascent = drawHeight
            descent = 0
        } else {
            let verticalSlack = lineHeight - drawHeight
            ascent = drawHeight + verticalSlack * 0.7
            descent = verticalSlack * 0.3
        }

        return ImageMetrics(
            drawWidth: drawWidth,
            drawHeight: drawHeight,
            totalWidth: totalWidth,
            ascent: ascent,
            descent: descent
        )
    }

    private func resolvedMathImageMetrics(
        image: UIImage,
        style: RenderStyle,
        font: UIFont,
        displayMode: ImageRunInfo.DisplayMode,
        mathDescent: CGFloat
    ) async -> ImageMetrics {
        let metrics = await resolvedImageMetrics(
            image: image,
            style: style,
            font: font,
            displayMode: displayMode
        )
        guard displayMode == .inline, !isVertical(style) else {
            return metrics
        }
        // Place the math baseline on the surrounding text baseline, instead of guessing a descent
        // from the font metrics. The renderer reports absolute baseline metrics for the bitmap; if
        // resolvedImageMetrics rescaled the bitmap (width clamp), rescale the descent with it.
        let rescale = image.size.height > 0 ? metrics.drawHeight / image.size.height : 1
        let descent = max(0, min(metrics.drawHeight, mathDescent * rescale))
        return ImageMetrics(
            drawWidth: metrics.drawWidth,
            drawHeight: metrics.drawHeight,
            totalWidth: metrics.totalWidth,
            ascent: max(1, metrics.drawHeight - descent),
            descent: descent
        )
    }

    private func isVertical(_ style: RenderStyle) -> Bool {
        config.writingMode.isVertical || style.isVerticalWritingMode
    }

    private func singleImagePayload(from children: [RenderableNode]) -> SingleImagePayload? {
        let renderableChildren = children.filter { child in
            switch child {
            case .text(let text):
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .lineBreak, .pageBreak:
                return false
            default:
                return true
            }
        }
        guard renderableChildren.count == 1 else { return nil }
        return unwrapSingleImage(from: renderableChildren[0])
    }

    private func unwrapSingleImage(
        from node: RenderableNode,
        anchorID: String? = nil,
        href: String? = nil
    ) -> SingleImagePayload? {
        switch node {
        case .anchorTarget(let id, let child):
            return unwrapSingleImage(from: child, anchorID: anchorID ?? id, href: href)
        case .anchor(let target, let children):
            guard children.count == 1 else { return nil }
            return unwrapSingleImage(from: children[0], anchorID: anchorID, href: href ?? target)
        case .inline(_, let children, _):
            // An anchor that styles its own text wraps its children in an inline node (see the
            // converter); unwrap it so a linked single image is still detected. The text styling
            // is irrelevant for an image-only anchor.
            guard children.count == 1 else { return nil }
            return unwrapSingleImage(from: children[0], anchorID: anchorID, href: href)
        case .image(let src, let alt, let style, let svgContent):
            return SingleImagePayload(src: src, alt: alt, style: style, anchorID: anchorID, href: href, svgContent: svgContent)
        default:
            return nil
        }
    }

    /// True if any position in `range` already carries a container render-style attribute.
    /// Plain child block decorations (hr/images) must not suppress a parent frame.
    /// Second decoration layer for a decorated container that wraps an already-decorated
    /// container (duokan double-frame: `div.aaa` beige mat around `div.bbb` bordered box).
    /// The inner box's padding+border chrome is baked into the outer style's padding so the
    /// outer frame draws OUTSIDE the inner border instead of on top of it — the paginator
    /// expands each decoration rect by its own chrome only.
    private func applyOuterContainerDecorationAttributes(
        style: RenderStyle,
        to attributedString: NSMutableAttributedString,
        range: NSRange,
        backgroundImage: HTMLAttributedStringBuilder.BlockRenderStyle.BackgroundImage? = nil
    ) {
        var hasOuter = false
        attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.outerContainerBlockRenderStyleAttribute,
            in: range
        ) { value, _, stop in
            if value != nil { hasOuter = true; stop.pointee = true }
        }
        // Three or more decorated levels: keep the innermost two, drop the rest.
        guard !hasOuter else { return }

        var chromeTop: CGFloat = 0
        var chromeLeft: CGFloat = 0
        var chromeBottom: CGFloat = 0
        var chromeRight: CGFloat = 0
        for key in [
            HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute,
            HTMLAttributedStringBuilder.blockRenderStyleAttribute,
        ] {
            attributedString.enumerateAttribute(key, in: range) { value, _, _ in
                guard let inner = value as? HTMLAttributedStringBuilder.BlockRenderStyle else { return }
                chromeTop = max(chromeTop, inner.paddingTop + inner.borderTopWidth)
                chromeLeft = max(chromeLeft, inner.paddingLeft + inner.borderLeftWidth)
                chromeBottom = max(chromeBottom, inner.paddingBottom + inner.borderBottomWidth)
                chromeRight = max(chromeRight, inner.paddingRight + inner.borderRightWidth)
            }
        }
        var outerStyle = style
        outerStyle.paddingTop += chromeTop
        outerStyle.paddingLeft += chromeLeft
        outerStyle.paddingBottom += chromeBottom
        outerStyle.paddingRight += chromeRight
        guard let blockRenderStyle = makeBlockRenderStyle(
            from: outerStyle,
            backgroundImage: backgroundImage
        ) else { return }
        let blockID = "outer-container-" + UUID().uuidString
        attributedString.addAttribute(
            HTMLAttributedStringBuilder.outerContainerBlockRenderStyleAttribute,
            value: blockRenderStyle,
            range: range
        )
        attributedString.addAttribute(
            HTMLAttributedStringBuilder.outerContainerBlockRenderIDAttribute,
            value: blockID,
            range: range
        )
    }

    private func hasExistingBlockDecoration(in attributedString: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var found = false
        attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute,
            in: range
        ) { value, _, stop in
            guard value != nil else { return }
            found = true
            stop.pointee = true
        }
        return found
    }

    private func applyBlockDecorationAttributes(
        style: RenderStyle,
        to attributedString: NSMutableAttributedString,
        range: NSRange,
        blockImage: HTMLAttributedStringBuilder.BlockRenderStyle.BlockImage? = nil,
        backgroundImage: HTMLAttributedStringBuilder.BlockRenderStyle.BackgroundImage? = nil
    ) {
        guard range.length > 0 else { return }
        if let backgroundColor = style.backgroundColor?.uiColor {
            attributedString.addAttribute(
                HTMLAttributedStringBuilder.blockBackgroundColorAttribute,
                value: backgroundColor,
                range: range
            )
        }
        guard let blockRenderStyle = makeBlockRenderStyle(
            from: style,
            blockImage: blockImage,
            backgroundImage: backgroundImage
        ) else { return }
        let blockID = UUID().uuidString
        attributedString.addAttribute(
            HTMLAttributedStringBuilder.blockRenderStyleAttribute,
            value: blockRenderStyle,
            range: range
        )
        attributedString.addAttribute(
            HTMLAttributedStringBuilder.blockRenderIDAttribute,
            value: blockID,
            range: range
        )
    }

    private func applyContainerDecorationAttributes(
        style: RenderStyle,
        to attributedString: NSMutableAttributedString,
        range: NSRange,
        hugsContent: Bool = false,
        backgroundImage: HTMLAttributedStringBuilder.BlockRenderStyle.BackgroundImage? = nil
    ) {
        guard range.length > 0 else { return }
        // A descendant (e.g. a chat-bubble `<div>` floated inside a plain wrapper `<div>`) may
        // already carry its own container decoration attribute over part of this range.
        // `addAttribute` is "last write wins" per character for a given key, so blindly applying
        // the OUTER block's decoration here would silently overwrite — not layer with — the
        // descendant's, erasing its background/border/radius. Route the outer decoration to the
        // dedicated second layer instead (duokan double-frame: `div.aaa` mat around `div.bbb`).
        if hasExistingBlockDecoration(in: attributedString, range: range) {
            applyOuterContainerDecorationAttributes(
                style: style,
                to: attributedString,
                range: range,
                backgroundImage: backgroundImage
            )
            return
        }
        if let backgroundColor = style.backgroundColor?.uiColor {
            attributedString.addAttribute(
                HTMLAttributedStringBuilder.blockBackgroundColorAttribute,
                value: backgroundColor,
                range: range
            )
        }
        guard let blockRenderStyle = makeBlockRenderStyle(
            from: style,
            hugsContent: hugsContent,
            backgroundImage: backgroundImage
        ) else { return }
        let blockID = "container-" + UUID().uuidString
        attributedString.addAttribute(
            HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute,
            value: blockRenderStyle,
            range: range
        )
        attributedString.addAttribute(
            HTMLAttributedStringBuilder.containerBlockRenderIDAttribute,
            value: blockID,
            range: range
        )
    }

    /// A decorated container (border/background/padding wrapping block children, e.g. an
    /// `aside.note` callout) draws its box by insetting the content rect outward by its
    /// border + padding (`drawBlockRenderables`). But each child block overwrites the
    /// paragraph style, so the container's own top/bottom margin + padding + border was
    /// never reserved as vertical space — the drawn box then overlapped the neighbouring
    /// block above and below (and adjacent callouts collided). Fold that inset back into
    /// the first child's `paragraphSpacingBefore` and the last child's `paragraphSpacing`.
    /// CSS margin collapse: CoreText adds `paragraphSpacing + nextParagraphSpacingBefore`
    /// between adjacent paragraphs, but the CSS box model collapses these into
    /// `max(margin-bottom, margin-top)`. Collapse every adjacent pair in the result
    /// so rendered spacing matches the authored CSS.
    private func collapseAdjacentParagraphSpacing(
        _ result: NSMutableAttributedString,
        honorStructuralInsets: Bool = true
    ) {
        guard result.length > 0 else { return }
        let ns = result.string as NSString
        let firstParaRange = ns.paragraphRange(for: NSRange(location: 0, length: 0))
        let firstEnd = firstParaRange.location + firstParaRange.length
        guard firstEnd < ns.length else { return }

        var prevRange = firstParaRange
        var currLoc = firstEnd
        while currLoc < ns.length {
            let currRange = ns.paragraphRange(for: NSRange(location: currLoc, length: 0))
            guard currRange.location > prevRange.location else { break }

            let prevAttrRange = NSRange(location: prevRange.location, length: prevRange.length)
            let currAttrRange = NSRange(location: currRange.location, length: currRange.length)

            if let prevPara = result.attribute(.paragraphStyle, at: prevRange.location, effectiveRange: nil) as? NSParagraphStyle,
               let currPara = result.attribute(.paragraphStyle, at: currRange.location, effectiveRange: nil) as? NSParagraphStyle {
                let spacing = prevPara.paragraphSpacing
                let spacingBefore = currPara.paragraphSpacingBefore
                if spacing > 0 || spacingBefore > 0 {
                    // CSS collapses *margins* only. A decorated container's padding+border share
                    // of the reserved spacing (folded in by `reserveContainerBlockInsets`) is
                    // structural: the drawn box extends outward by exactly that amount, so moving
                    // it to the neighbour would make the border overlap the neighbour's line
                    // (chat-bubble borders slicing through the sender name above them).
                    let prevStructural = honorStructuralInsets
                        ? min(spacing, Self.containerNonCollapsibleInsets(in: result, paragraphRange: prevRange).bottom)
                        : 0
                    let currStructural = honorStructuralInsets
                        ? min(spacingBefore, Self.containerNonCollapsibleInsets(in: result, paragraphRange: currRange).top)
                        : 0
                    let collapsed = max(spacing - prevStructural, spacingBefore - currStructural)
                    if prevStructural > 0 || currStructural > 0 {
                        AppLogger.render("⟐ boxGap", context: [
                            "prevSpacing": Int(spacing),
                            "currBefore": Int(spacingBefore),
                            "prevStruct": Int(prevStructural),
                            "currStruct": Int(currStructural),
                            "collapsed": Int(collapsed),
                            "prevTail": String((result.string as NSString).substring(with: prevRange).suffix(6)),
                        ])
                    }
                    if let prevMutable = prevPara.mutableCopy() as? NSMutableParagraphStyle,
                       let currMutable = currPara.mutableCopy() as? NSMutableParagraphStyle {
                        prevMutable.paragraphSpacing = prevStructural + collapsed
                        currMutable.paragraphSpacingBefore = currStructural
                        result.addAttribute(.paragraphStyle, value: prevMutable, range: prevAttrRange)
                        result.addAttribute(.paragraphStyle, value: currMutable, range: currAttrRange)
                    }
                }
            }
            prevRange = currRange
            currLoc = currRange.location + currRange.length
        }
    }

    private func reserveContainerInsets(_ result: NSMutableAttributedString, style: RenderStyle) {
        guard !isVertical(style),
              style.borderTopWidth > 0 || style.borderBottomWidth > 0
                || style.paddingTop > 0 || style.paddingBottom > 0
        else { return }
        HTMLAttributedStringBuilder.reserveContainerBlockInsets(
            in: result,
            collapsibleTop: style.paragraphSpacingBefore,
            collapsibleBottom: style.paragraphSpacingAfter,
            paddingTop: style.paddingTop,
            paddingBottom: style.paddingBottom,
            borderTopWidth: style.borderTopWidth,
            borderBottomWidth: style.borderBottomWidth
        )
    }

    /// The padding+border share of a paragraph's reserved vertical spacing, present when the
    /// paragraph begins (`top`) or ends (`bottom`) a decorated container's attribute run.
    /// `reserveContainerBlockInsets` folds these into `paragraphSpacingBefore`/`paragraphSpacing`,
    /// and `drawBlockRenderables` extends the drawn box outward by exactly this amount — so
    /// margin-collapse and compact-spacing normalization must treat the share as structural.
    private static func containerNonCollapsibleInsets(
        in attributedString: NSAttributedString,
        paragraphRange: NSRange
    ) -> (top: CGFloat, bottom: CGFloat) {
        guard paragraphRange.length > 0,
              NSMaxRange(paragraphRange) <= attributedString.length
        else { return (0, 0) }
        let full = NSRange(location: 0, length: attributedString.length)
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var startRun = NSRange()
        if let style = attributedString.attribute(
            HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute,
            at: paragraphRange.location,
            longestEffectiveRange: &startRun,
            in: full
        ) as? HTMLAttributedStringBuilder.BlockRenderStyle,
           startRun.location == paragraphRange.location {
            top = style.paddingTop + style.borderTopWidth
        }
        var endRun = NSRange()
        if let style = attributedString.attribute(
            HTMLAttributedStringBuilder.containerBlockRenderStyleAttribute,
            at: NSMaxRange(paragraphRange) - 1,
            longestEffectiveRange: &endRun,
            in: full
        ) as? HTMLAttributedStringBuilder.BlockRenderStyle,
           NSMaxRange(endRun) == NSMaxRange(paragraphRange) {
            bottom = style.paddingBottom + style.borderBottomWidth
        }
        return (top, bottom)
    }

    /// Renders a CSS-floated text block (`div.ot` / `div.se` instant-message bubble) as a
    /// shrink-to-fit, side-hugging, colored, rounded box — the way 多看-style EPUBs draw chat
    /// dialogue. The authored `float` + `display:inline-block` geometry has no CoreText analogue,
    /// so we synthesize it: measure the text's natural width, cap it at a fraction of the column,
    /// push the child text onto the float side via inherited block margins, and decorate the
    /// resulting narrow column with the bubble's background / border / corner radius.
    private func renderFloatBubble(
        children: [RenderableNode],
        style: RenderStyle,
        side: RenderFloatSide,
        ctx: RenderContext
    ) async -> NSAttributedString {
        let renderWidth = max(1, config.renderWidth ?? 320)
        let availableWidth = max(1, renderWidth - ctx.inheritedBlockMarginLeft - ctx.inheritedBlockMarginRight)
        let padLeft = style.paddingLeft
        let padRight = style.paddingRight
        let borderLeft = style.borderLeftWidth
        let borderRight = style.borderRightWidth
        let horizontalChrome = padLeft + padRight + borderLeft + borderRight

        // Bubbles never exceed ~74% of the column; leave room for the opposite-side gutter so the
        // left/right distinction (sender vs. receiver) reads clearly.
        let maxTextWidth = max(1, availableWidth * 0.74 - horizontalChrome)
        let minTextWidth = min(maxTextWidth, ctx.baseSize * 2)

        // Pass 1 — render at full width purely to measure the text's natural (unwrapped) extent.
        let measureCtx = applyBlockStyle(style, to: ctx, isHeading: false)
        var compactMeasureCtx = measureCtx
        compactMeasureCtx.compactBlockSpacing = true
        let measured = await renderFloatBubbleChildren(children, ctx: compactMeasureCtx)
        let naturalWidth = naturalParagraphWidth(of: measured)
        let textWidth = max(minTextWidth, min(maxTextWidth, naturalWidth))

        // Pass 2 — re-render with the text pinned to the float side at the measured width. The
        // child paragraphs inherit these block margins, which become their head/tail indents.
        var bubbleCtx = applyBlockStyle(style, to: ctx, isHeading: false)
        bubbleCtx.compactBlockSpacing = true
        let addedLeft: CGFloat
        let addedRight: CGFloat
        switch side {
        case .right:
            addedLeft = max(0, availableWidth - textWidth - padRight - borderRight)
            addedRight = padRight + borderRight
        case .left:
            addedLeft = padLeft + borderLeft
            addedRight = max(0, availableWidth - textWidth - padLeft - borderLeft)
        }
        bubbleCtx.inheritedBlockMarginLeft = ctx.inheritedBlockMarginLeft + addedLeft
        bubbleCtx.inheritedBlockMarginRight = ctx.inheritedBlockMarginRight + addedRight

        let result = NSMutableAttributedString(
            attributedString: await renderFloatBubbleChildren(children, ctx: bubbleCtx)
        )
        guard result.length > 0 else { return result }
        markCompactBlockSpacing(
            result,
            range: NSRange(location: 0, length: result.length),
            reason: "floatBubble"
        )

        // Chat bubbles read left-aligned, never justified. The book's `p { text-align: justify }`
        // cascades into `.tk p`, and a justified line is stretched to the column width — which would
        // defeat the `hugsContent` box (it measures the un-justified glyph run). Force natural
        // alignment while preserving the side-pinning indents set above.
        let fullRange = NSRange(location: 0, length: result.length)
        var alignmentFixups: [(NSRange, NSMutableParagraphStyle)] = []
        result.enumerateAttribute(.paragraphStyle, in: fullRange, options: []) { value, range, _ in
            guard let para = value as? NSParagraphStyle, para.alignment == .justified else { return }
            let mutable = para.mutableCopy() as! NSMutableParagraphStyle
            mutable.alignment = .natural
            alignmentFixups.append((range, mutable))
        }
        for (range, para) in alignmentFixups {
            result.addAttribute(.paragraphStyle, value: para, range: range)
        }

        // Decorate the column with `hugsContent`, so the paginator sizes the box to the actual
        // laid-out glyphs (immune to column-width rounding) rather than `width`/`textAlign`. The
        // child text indents (above) still place the text on the float side; the box then hugs it.
        var boxStyle = style
        boxStyle.floatSide = nil
        boxStyle.width = textWidth
        boxStyle.marginLeft = 0
        boxStyle.marginRight = 0
        boxStyle.isHorizontallyCentered = false
        boxStyle.textAlign = (side == .right) ? .right : .left
        boxStyle.paragraphSpacingBefore = max(0, style.paragraphSpacingBefore)
        boxStyle.paragraphSpacingAfter = max(0, style.paragraphSpacingAfter)

        applyContainerDecorationAttributes(
            style: boxStyle,
            to: result,
            range: NSRange(location: 0, length: result.length),
            hugsContent: true
        )
        reserveContainerInsets(result, style: boxStyle)
        return result
    }

    /// Renders the children of a float bubble with an already-resolved block context (mirrors the
    /// child loop in `renderBlock` minus the decoration pass, which the caller applies itself).
    private func renderFloatBubbleChildren(
        _ children: [RenderableNode],
        ctx: RenderContext
    ) async -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in children {
            result.append(await render(node: child, ctx: ctx))
        }
        return result
    }

    /// Natural (single-line, unwrapped) width of the widest paragraph in an attributed string.
    /// Used to shrink-to-fit a chat bubble before the column width is constrained.
    private func naturalParagraphWidth(of attributed: NSAttributedString) -> CGFloat {
        guard attributed.length > 0 else { return 0 }
        let nsString = attributed.string as NSString
        var maxWidth: CGFloat = 0
        nsString.enumerateSubstrings(
            in: NSRange(location: 0, length: nsString.length),
            options: .byParagraphs
        ) { _, range, _, _ in
            guard range.length > 0 else { return }
            let paragraph = attributed.attributedSubstring(from: range)
            let line = CTLineCreateWithAttributedString(paragraph as CFAttributedString)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            maxWidth = max(maxWidth, CGFloat(width))
        }
        return maxWidth
    }

    /// Loads the block's CSS background-image (decorative frame / texture) for the decoration box.
    private func loadBlockBackgroundImage(
        for style: RenderStyle
    ) async -> HTMLAttributedStringBuilder.BlockRenderStyle.BackgroundImage? {
        guard let src = style.backgroundImageSource, !src.isEmpty,
              let image = await config.imageLoader?(src)
        else { return nil }
        return HTMLAttributedStringBuilder.BlockRenderStyle.BackgroundImage(
            image: image,
            size: style.backgroundImageSize,
            stretches: style.backgroundImageStretches,
            repeats: style.backgroundImageRepeats
        )
    }

    private func makeBlockRenderStyle(
        from style: RenderStyle,
        blockImage: HTMLAttributedStringBuilder.BlockRenderStyle.BlockImage? = nil,
        hugsContent: Bool = false,
        backgroundImage: HTMLAttributedStringBuilder.BlockRenderStyle.BackgroundImage? = nil
    ) -> HTMLAttributedStringBuilder.BlockRenderStyle? {
        let renderStyle = HTMLAttributedStringBuilder.BlockRenderStyle(
            backgroundFillColor: style.backgroundColor?.uiColor,
            borderTopWidth: style.borderTopWidth,
            borderBottomWidth: style.borderBottomWidth,
            borderLeftWidth: style.borderLeftWidth,
            borderRightWidth: style.borderRightWidth,
            borderTopColor: style.borderTopColor?.uiColor,
            borderBottomColor: style.borderBottomColor?.uiColor,
            borderLeftColor: style.borderLeftColor?.uiColor,
            borderRightColor: style.borderRightColor?.uiColor,
            width: style.width,
            height: style.height,
            textAlign: nsTextAlignment(from: style.textAlign),
            isHorizontallyCentered: style.isHorizontallyCentered,
            paragraphSpacingBefore: style.paragraphSpacingBefore,
            visualOffsetBefore: style.visualOffsetBefore,
            paddingTop: style.paddingTop,
            paddingLeft: style.paddingLeft,
            paddingBottom: style.paddingBottom,
            paddingRight: style.paddingRight,
            blockImage: blockImage,
            borderRadius: style.borderRadius,
            avoidsPageBreakInside: style.avoidsPageBreakInside,
            hugsContent: hugsContent,
            backgroundImage: backgroundImage
        )
        return renderStyle.hasVisualDecoration ? renderStyle : nil
    }

    private func verticalInlineSpacer(advance: CGFloat, ctx: RenderContext) -> NSAttributedString {
        let spacer = NSMutableAttributedString(attributedString: RunDelegateProvider.makeVerticalSpacerPlaceholder(
            advance: advance,
            font: ctx.font,
            textColor: ctx.textColor
        ))
        let range = NSRange(location: 0, length: spacer.length)
        spacer.addAttributes(ctx.baseAttributes, range: range)
        spacer.addAttribute(HTMLAttributedStringBuilder.spacerRunAttribute, value: true, range: range)
        return spacer
    }

    private func nsTextAlignment(from align: RenderTextAlignment) -> NSTextAlignment {
        switch align {
        case .natural:  return .natural
        case .left:     return .left
        case .center:   return .center
        case .right:    return .right
        case .justify:  return .justified
        }
    }

    private func addSemanticTagIfNeeded(_ tag: String, to attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0,
              HTMLAttributedStringBuilder.isSemanticHTML5Tag(tag)
        else { return }
        var rangesToTag: [NSRange] = []
        attributedString.enumerateAttribute(
            HTMLAttributedStringBuilder.semanticTagAttribute,
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { value, range, _ in
            if value == nil {
                rangesToTag.append(range)
            }
        }
        for range in rangesToTag {
            attributedString.addAttribute(
                HTMLAttributedStringBuilder.semanticTagAttribute,
                value: tag,
                range: range
            )
        }
    }

    // MARK: - RenderContext

    private struct RenderContext {
        var font: UIFont
        var fontFamilies: [String]
        var fontWeight: Int
        var textColor: UIColor
        var hasCSSColor: Bool
        var kern: CGFloat
        var paragraphStyle: NSParagraphStyle
        var baselineOffset: CGFloat
        var lineHeightMultiple: CGFloat
        var linkHref: String?
        var ipaPronunciation: String?
        var underline: Bool
        var strikethrough: Bool
        var inheritedBlockMarginLeft: CGFloat
        var inheritedBlockMarginRight: CGFloat
        /// Inside a chat thread (`div.tk` of message bubbles): suppress the reader's body
        /// paragraph-spacing between the tightly-packed name labels and bubbles, so a large
        /// paragraph-gap setting doesn't blow the thread apart (Apple Books / Readest stay tight).
        var compactBlockSpacing: Bool = false
        /// True inside a decorated container (fill/border/background-image box, e.g. `.sys`):
        /// there the author's explicit `margin: 0` beats the reader's default paragraph spacing.
        var insideDecoratedContainer: Bool = false

        /// Records the body's base font size for heading proportional scaling.
        var baseSize: CGFloat

        var baseAttributes: [NSAttributedString.Key: Any] {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .kern: kern as NSNumber,
                .baselineOffset: baselineOffset as NSNumber,
                .paragraphStyle: paragraphStyle
            ]
            if hasCSSColor {
                attrs[HTMLAttributedStringBuilder.cssSpecifiedForegroundColorAttribute] = textColor
            }
            if let href = linkHref {
                // Tappable. Default link tint is applied in the `.anchor` case (only for links the
                // author left untouched), not here — keep the run's authored/inherited color.
                attrs[HTMLAttributedStringBuilder.internalLinkAttribute] = href
            }
            if let ipaPronunciation {
                attrs[HTMLAttributedStringBuilder.ipaPronunciationAttribute] = ipaPronunciation
            }
            if underline {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if strikethrough {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            return attrs
        }

        static func makeBody(config: Config) -> RenderContext {
            let font = UIFont.systemFont(ofSize: config.baseFontSize)
            let targetLineHeight = ReaderTypographyCorrection.targetLineHeight(
                font: font,
                fontSize: config.baseFontSize,
                lineHeightMultiple: config.lineHeightMultiple
            )
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = targetLineHeight
            para.maximumLineHeight = targetLineHeight
            para.paragraphSpacing = config.paragraphSpacing
            para.alignment = .natural
            para.baseWritingDirection = config.baseWritingDirection
            return RenderContext(
                font: font,
                fontFamilies: config.fontFamily.map { [$0] } ?? [],
                fontWeight: 400,
                textColor: config.textColor,
                hasCSSColor: false,
                kern: config.letterSpacing,
                paragraphStyle: para,
                baselineOffset: ReaderTypographyCorrection.baselineOffset(
                    font: font,
                    targetLineHeight: targetLineHeight
                ),
                lineHeightMultiple: config.lineHeightMultiple,
                underline: false,
                strikethrough: false,
                inheritedBlockMarginLeft: 0,
                inheritedBlockMarginRight: 0,
                baseSize: config.baseFontSize
            )
        }
    }
}

// MARK: - UIFont Helpers (check weight / italic)

private extension UIFont {
    var isBold: Bool {
        fontDescriptor.symbolicTraits.contains(.traitBold)
    }
    var isItalic: Bool {
        fontDescriptor.symbolicTraits.contains(.traitItalic)
    }
}
