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

        init(
            from settings: ReaderRenderSettings,
            textColor: UIColor? = nil,
            renderWidth: CGFloat? = nil,
            resolvedFont: (([String], Int, Bool, CGFloat) -> UIFont?)? = nil,
            imageLoader: ((String) async -> UIImage?)? = nil,
            mediaURLResolver: ((String) -> String?)? = nil,
            baseWritingDirection: NSWritingDirection = .natural
        ) {
            self.baseFontSize = settings.fontSize
            self.lineHeightMultiple = settings.lineHeightMultiple
            self.paragraphSpacing = settings.paragraphSpacing
            self.letterSpacing = settings.letterSpacing
            self.textColor = textColor ?? settings.textColor
            self.backgroundColor = settings.backgroundColor
            self.fontFamily = nil
            self.renderWidth = renderWidth
            self.resolvedFont = resolvedFont
            self.imageLoader = imageLoader
            self.mediaURLResolver = mediaURLResolver
            self.writingMode = settings.writingMode
            self.baseWritingDirection = baseWritingDirection
        }
    }

    let config: Config

    // MARK: - Entry Point

    /// Converts a set of top-level nodes into a pageable NSAttributedString.
    func render(_ nodes: [RenderableNode]) async -> NSAttributedString {
        let result = NSMutableAttributedString()
        let ctx = RenderContext.makeBody(config: config)
        for node in nodes {
            result.append(await render(node: node, ctx: ctx))
        }
        return CJKTypographyProcessor.apply(to: result)
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
            let hrStyle = HTMLAttributedStringBuilder.HRDividerStyle(
                color: style.borderTopColor?.uiColor
                    ?? style.borderBottomColor?.uiColor
                    ?? style.color?.uiColor
                    ?? style.backgroundColor?.uiColor,
                lineWidth: style.borderTopWidth > 0 ? style.borderTopWidth
                    : style.height.flatMap { $0 > 0 ? $0 : nil },
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
                isHorizontallyCentered: style.isHorizontallyCentered
            )
            attrs[HTMLAttributedStringBuilder.hrDividerAttribute] = hrStyle
            let fontSize = ctx.font.pointSize
            let hrPara = NSMutableParagraphStyle()
            hrPara.minimumLineHeight = fontSize
            hrPara.maximumLineHeight = fontSize
            hrPara.paragraphSpacingBefore = fontSize * 0.5
            hrPara.paragraphSpacing = fontSize * 0.5
            hrPara.baseWritingDirection = style.baseWritingDirection
            attrs[.paragraphStyle] = hrPara
            return NSAttributedString(string: "\n", attributes: attrs)

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

        case .table(let table, let style):
            return await renderTable(table, style: style, ctx: ctx)

        case .media(let media, let style):
            return await renderMedia(media, style: style, ctx: ctx)

        // ──────────────── Paragraph ────────────────

        case .paragraph(let children, let style):
            return await renderBlock(children: children, style: style, ctx: ctx, isHeading: false)

        case .blockquote(let children):
            var style = RenderStyle.none
            style.marginLeft = 20
            style.italic = true
            return await renderBlock(children: children, style: style, ctx: ctx, isHeading: false)

        case .listItem(let children, let bullet):
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

    // MARK: - Block Rendering

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

        let hasBlockChildren = children.contains { child in
            if case .paragraph = child { return true }
            if case .block = child { return true }
            if case .heading = child { return true }
            if case .blockquote = child { return true }
            if case .listItem = child { return true }
            if case .horizontalRule = child { return true }
            return false
        }

        let childCtx = applyBlockStyle(style, to: ctx, isHeading: isHeading, headingLevel: headingLevel)
        let result = NSMutableAttributedString()
        if isVertical(style),
           !hasBlockChildren,
           style.visualOffsetBefore > 0 {
            result.append(verticalInlineSpacer(advance: style.visualOffsetBefore, ctx: childCtx))
        }
        for child in children {
            result.append(await render(node: child, ctx: childCtx))
        }
        let contentLength = result.length
        if contentLength > 0 {
            if hasBlockChildren {
                applyContainerDecorationAttributes(style: style, to: result, range: NSRange(location: 0, length: contentLength))
                reserveContainerInsets(result, style: style)
            } else {
                applyBlockDecorationAttributes(style: style, to: result, range: NSRange(location: 0, length: contentLength))
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

        result.append(NSAttributedString(string: "\n", attributes: childCtx.baseAttributes))
        return result
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
        let resolvedParagraphSpacing = style.paragraphSpacingAfter > 0
            ? style.paragraphSpacingAfter
            : (isHeading ? config.paragraphSpacing * 0.6 : config.paragraphSpacing)
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
            para.paragraphSpacingBefore = style.paragraphSpacingBefore + style.paddingTop
        }
        let cumulativeMarginLeft = ctx.inheritedBlockMarginLeft + style.marginLeft
        let cumulativeMarginRight = ctx.inheritedBlockMarginRight + style.marginRight
        let leftInset = cumulativeMarginLeft + style.borderLeftWidth + style.paddingLeft
        let rightInset = cumulativeMarginRight + style.borderRightWidth + style.paddingRight
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
        // Accumulate for nested child blocks
        newCtx.inheritedBlockMarginLeft = cumulativeMarginLeft
        newCtx.inheritedBlockMarginRight = cumulativeMarginRight

        return newCtx
    }

    // MARK: - Apply Inline Style to Context

    private func applyInlineStyle(_ style: RenderStyle, to ctx: RenderContext) -> RenderContext {
        guard style.bold || style.italic || style.color != nil || !style.fontFamilies.isEmpty
                || style.underline || style.strikethrough || style.fontSizeMultiplier != 1.0 else { return ctx }
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
        let bold = weight >= 600
        let candidateFamilies = families + (config.fontFamily.map { [$0] } ?? [])
        if let resolved = config.resolvedFont?(candidateFamilies, weight, italic, size) {
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
        // Custom font doesn't support requested traits — fall back to system font
        if bold && italic {
            let system = UIFont.systemFont(ofSize: size, weight: .bold)
            if let desc = system.fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic]) {
                return UIFont(descriptor: desc.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes()), size: size)
            }
            return UIFont(descriptor: system.fontDescriptor.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes()), size: size)
        } else if bold {
            return UIFont(descriptor: UIFont.systemFont(ofSize: size, weight: .bold).fontDescriptor.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes()), size: size)
        } else if italic {
            return UIFont(descriptor: UIFont.italicSystemFont(ofSize: size).fontDescriptor.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes()), size: size)
        }
        return UIFont(descriptor: font.fontDescriptor.addingAttributes(NodeAttributedStringRenderer.cascadeAttributes()), size: size)
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
        if let svgContent, !svgContent.isEmpty {
            let screenWidth = await MainActor.run { UIScreen.main.bounds.width }
            let resolvedWidth = config.renderWidth ?? screenWidth
            let targetSize = await SVGWebViewRasterizer.shared.resolveSVGSize(
                styleWidth: style.width,
                styleHeight: style.height,
                svgString: svgContent,
                renderWidth: resolvedWidth
            )
            let image = await SVGWebViewRasterizer.shared.render(
                svgString: svgContent,
                size: targetSize,
                baseURL: nil
            )
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
            let metrics = await resolvedImageMetrics(image: image, style: style, font: ctx.font, displayMode: .inline)
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

        let image = src.isEmpty ? nil : await config.imageLoader?(src)
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

        let imageMetrics = await resolvedImageMetrics(image: image, style: attachmentStyle, font: blockCtx.font, displayMode: .block)
        let blockImage = HTMLAttributedStringBuilder.BlockRenderStyle.BlockImage(
            image: image,
            source: payload.src,
            drawSize: CGSize(width: imageMetrics.drawWidth, height: imageMetrics.drawHeight),
            opacity: attachmentStyle.opacity,
            alignment: nsTextAlignment(from: attachmentStyle.textAlign),
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
                isHorizontallyCentered: blockStyle.isHorizontallyCentered
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
        let maxWidth: CGFloat
        if let renderWidth = config.renderWidth {
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
        let metrics = await resolvedImageMetrics(image: image, style: tableStyle, font: blockCtx.font, displayMode: .block)
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
            value: imageBlockParagraphStyle(base: blockCtx.paragraphStyle, metrics: metrics),
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
        let metrics = await resolvedImageMetrics(image: image, style: mediaStyle, font: blockCtx.font, displayMode: .block)
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
            metrics = await resolvedImageMetrics(image: image, style: style, font: ctx.font, displayMode: displayMode)
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
                opacity: style.opacity
            )
        )
        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttributes(ctx.baseAttributes, range: range)
        // An inline image sharing a block with other content (e.g. <figure><img/><figcaption/></figure>)
        // inherits the block's paragraph style, which pins maximumLineHeight to the *text* line height.
        // CoreText would then clamp the image's reserved line, and the image would overflow upward and
        // overlap the preceding content. Raise maximumLineHeight to fit the image; minimumLineHeight is
        // left untouched so any text on the same line stays compact. Block images get their paragraph
        // style overridden by the caller, so this only affects the inline case.
        if displayMode == .inline, ctx.paragraphStyle.maximumLineHeight > 0 {
            let required = ceil(metrics.ascent + metrics.descent)
            if required > ctx.paragraphStyle.maximumLineHeight {
                let relaxed = ctx.paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
                relaxed.maximumLineHeight = required
                placeholder.addAttribute(.paragraphStyle, value: relaxed, range: range)
            }
        }
        return placeholder
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

    private func resolvedImageMetrics(image: UIImage?, style: RenderStyle, font: UIFont, displayMode: ImageRunInfo.DisplayMode = .inline) async -> ImageMetrics {
        let screenWidth = await MainActor.run { UIScreen.main.bounds.width }
        let baseWidth = config.renderWidth ?? screenWidth
        let availableWidth = max(1, baseWidth - style.paddingLeft - style.paddingRight)
        let maxDrawHeight = max(1, baseWidth * 1.5)
        let isVertical = self.isVertical(style)

        var drawWidth: CGFloat
        var drawHeight: CGFloat

        if let image {
            // In vertical mode, CSS width/height were authored for horizontal layout.
            // For block images: ignore explicit width so the image fills the column.
            // For inline images (font_patch etc.): keep the 1em constraint so they stay character-sized.
            if isVertical, displayMode == .block, style.width != nil {
                drawWidth = min(image.size.width, availableWidth)
                drawHeight = image.size.height * (drawWidth / max(image.size.width, 1))
            } else if let explicitWidth = style.width, let explicitHeight = style.height {
                drawWidth = explicitWidth
                drawHeight = explicitHeight
            } else if let explicitWidth = style.width {
                let ratio = explicitWidth / max(image.size.width, 1)
                drawWidth = explicitWidth
                drawHeight = image.size.height * ratio
            } else if let explicitHeight = style.height {
                let ratio = explicitHeight / max(image.size.height, 1)
                drawWidth = image.size.width * ratio
                drawHeight = explicitHeight
            } else {
                drawWidth = image.size.width
                drawHeight = image.size.height
            }
        } else {
            let fallbackHeight = style.height ?? (availableWidth * 0.6)
            drawWidth = style.width ?? availableWidth
            drawHeight = fallbackHeight
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

    private func applyBlockDecorationAttributes(
        style: RenderStyle,
        to attributedString: NSMutableAttributedString,
        range: NSRange,
        blockImage: HTMLAttributedStringBuilder.BlockRenderStyle.BlockImage? = nil
    ) {
        guard range.length > 0 else { return }
        if let backgroundColor = style.backgroundColor?.uiColor {
            attributedString.addAttribute(
                HTMLAttributedStringBuilder.blockBackgroundColorAttribute,
                value: backgroundColor,
                range: range
            )
        }
        guard let blockRenderStyle = makeBlockRenderStyle(from: style, blockImage: blockImage) else { return }
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
        range: NSRange
    ) {
        guard range.length > 0 else { return }
        if let backgroundColor = style.backgroundColor?.uiColor {
            attributedString.addAttribute(
                HTMLAttributedStringBuilder.blockBackgroundColorAttribute,
                value: backgroundColor,
                range: range
            )
        }
        guard let blockRenderStyle = makeBlockRenderStyle(from: style) else { return }
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
    private func reserveContainerInsets(_ result: NSMutableAttributedString, style: RenderStyle) {
        guard !isVertical(style),
              style.borderTopWidth > 0 || style.borderBottomWidth > 0
                || style.paddingTop > 0 || style.paddingBottom > 0
        else { return }
        HTMLAttributedStringBuilder.reserveContainerBlockInsets(
            in: result,
            topInset: style.paragraphSpacingBefore + style.paddingTop + style.borderTopWidth,
            bottomInset: style.paragraphSpacingAfter + style.paddingBottom + style.borderBottomWidth
        )
    }

    private func makeBlockRenderStyle(
        from style: RenderStyle,
        blockImage: HTMLAttributedStringBuilder.BlockRenderStyle.BlockImage? = nil
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
            borderRadius: style.borderRadius
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
        var underline: Bool
        var strikethrough: Bool
        var inheritedBlockMarginLeft: CGFloat
        var inheritedBlockMarginRight: CGFloat

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
