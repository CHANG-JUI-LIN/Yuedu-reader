import Foundation
import UIKit

// MARK: - NodeAttributedStringRenderer
//
// 消費 [RenderableNode] → NSAttributedString。
//
// 設計原則：
//   - 純轉換函式，無副作用，無儲存狀態（struct）
//   - 透過 RenderContext 把字形系列、大小、顏色等「繼承屬性」往下傳遞
//   - 每個 block node 自己決定 NSParagraphStyle；inline node 只改 font/color
//   - `.rawHTML` 降級：在 Debug 顯示佔位符，在 Release 靜默忽略
//   - `.image` 透過 RunDelegate placeholder 進入現有 paginator / page view 管道

struct NodeAttributedStringRenderer {

    // MARK: - 渲染設定

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

        init(
            from settings: ReaderRenderSettings,
            textColor: UIColor? = nil,
            renderWidth: CGFloat? = nil,
            resolvedFont: (([String], Int, Bool, CGFloat) -> UIFont?)? = nil,
            imageLoader: ((String) async -> UIImage?)? = nil
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
        }
    }

    let config: Config

    // MARK: - 入口

    /// 把一組頂層節點轉成可分頁的 NSAttributedString。
    func render(_ nodes: [RenderableNode]) async -> NSAttributedString {
        let result = NSMutableAttributedString()
        let ctx = RenderContext.makeBody(config: config)
        for node in nodes {
            result.append(await render(node: node, ctx: ctx))
        }
        return CJKTypographyProcessor.apply(to: result)
    }

    // MARK: - 節點渲染（遞迴）

    private func render(node: RenderableNode, ctx: RenderContext) async -> NSAttributedString {
        switch node {

        // ──────────────── 葉節點 ────────────────

        case .text(let str):
            return NSAttributedString(string: str, attributes: ctx.baseAttributes)

        case .lineBreak:
            // \u{2028} = Unicode Line Separator（同 HTMLAttributedStringBuilder 慣例）
            return NSAttributedString(string: "\u{2028}", attributes: ctx.baseAttributes)

        case .horizontalRule:
            var attrs = ctx.baseAttributes
            attrs[HTMLAttributedStringBuilder.hrDividerAttribute] = true as NSNumber
            return NSAttributedString(string: "\n", attributes: attrs)

        case .pageBreak:
            return NSAttributedString(string: "\n", attributes: ctx.baseAttributes)

        case .rawHTML(let html):
            #if DEBUG
            let placeholder = "[rawHTML: \(html.prefix(40))]\n"
            return NSAttributedString(string: placeholder, attributes: ctx.baseAttributes)
            #else
            return NSAttributedString()
            #endif

        // ──────────────── 圖片（降級：顯示 alt-text） ────────────────

        case .image(let src, let alt, let style):
            return await renderInlineImage(src: src, alt: alt, style: style, ctx: ctx)

        // ──────────────── 段落 ────────────────

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

        // ──────────────── 標題 ────────────────

        case .heading(let children, let level, let style):
            return await renderBlock(children: children, style: style, ctx: ctx, isHeading: true, headingLevel: level)

        // ──────────────── 容器 ────────────────

        case .block(_, let children, let style):
            return await renderBlock(children: children, style: style, ctx: ctx, isHeading: false)

        case .inline(_, let children, let style):
            let childCtx = applyInlineStyle(style, to: ctx)
            return await renderInlineChildren(children, ctx: childCtx)

        case .anchor(let href, let children):
            var childCtx = ctx
            childCtx.linkHref = href
            return await renderInlineChildren(children, ctx: childCtx)

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

    // MARK: - 輔助：Block 渲染

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

        let childCtx = applyBlockStyle(style, to: ctx, isHeading: isHeading, headingLevel: headingLevel)
        let result = NSMutableAttributedString()
        for child in children {
            result.append(await render(node: child, ctx: childCtx))
        }
        let contentLength = result.length
        if contentLength > 0 {
            applyBlockDecorationAttributes(style: style, to: result, range: NSRange(location: 0, length: contentLength))
        }
        result.append(NSAttributedString(string: "\n", attributes: childCtx.baseAttributes))
        return result
    }

    // MARK: - 輔助：Inline 子節點

    private func renderInlineChildren(_ children: [RenderableNode], ctx: RenderContext) async -> NSAttributedString {
        let result = NSMutableAttributedString()
        for child in children {
            result.append(await render(node: child, ctx: ctx))
        }
        return result
    }

    // MARK: - 輔助：套用 Block 風格到 Context

    private func applyBlockStyle(
        _ style: RenderStyle,
        to ctx: RenderContext,
        isHeading: Bool,
        headingLevel: Int = 0
    ) -> RenderContext {
        var newCtx = ctx

        // ── 字形大小 ──
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

        // ── 字重與斜體 ──
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

        // ── 顏色 ──
        if let c = style.color { newCtx.textColor = c.uiColor }

        // ── Paragraph Style ──
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = targetLineHeight(ctx: newCtx)
        para.maximumLineHeight = targetLineHeight(ctx: newCtx)
        para.paragraphSpacing = style.paragraphSpacingAfter > 0
            ? style.paragraphSpacingAfter
            : (isHeading ? config.paragraphSpacing * 0.6 : config.paragraphSpacing)
        para.paragraphSpacingBefore = style.paragraphSpacingBefore
        para.firstLineHeadIndent = style.textIndent
        para.headIndent = style.marginLeft + style.paddingLeft
        para.tailIndent = style.paddingRight > 0 ? -style.paddingRight : 0
        para.alignment = nsTextAlignment(from: style.textAlign)
        newCtx.paragraphStyle = para
        newCtx.baselineOffset = ReaderTypographyCorrection.baselineOffset(
            font: newCtx.font,
            targetLineHeight: para.minimumLineHeight
        )

        return newCtx
    }

    // MARK: - 輔助：套用 Inline 風格到 Context

    private func applyInlineStyle(_ style: RenderStyle, to ctx: RenderContext) -> RenderContext {
        guard style.bold || style.italic || style.color != nil || !style.fontFamilies.isEmpty else { return ctx }
        var newCtx = ctx
        let families = style.fontFamilies.isEmpty ? ctx.fontFamilies : style.fontFamilies
        let bold = style.bold || ctx.font.isBold
        let weight = bold ? max(style.fontWeight, max(ctx.fontWeight, 700)) : max(style.fontWeight, ctx.fontWeight)
        newCtx.font = makeFont(families: families, size: ctx.font.pointSize, weight: weight, italic: style.italic || ctx.font.isItalic)
        newCtx.fontFamilies = families
        newCtx.fontWeight = weight
        if let c = style.color { newCtx.textColor = c.uiColor }
        return newCtx
    }

    // MARK: - 輔助：行高計算

    private func targetLineHeight(ctx: RenderContext) -> CGFloat {
        ReaderTypographyCorrection.targetLineHeight(
            font: ctx.font,
            fontSize: ctx.font.pointSize,
            lineHeightMultiple: ctx.lineHeightMultiple
        )
    }

    // MARK: - 輔助：字形

    private func makeFont(families: [String], size: CGFloat, weight: Int, italic: Bool) -> UIFont {
        let bold = weight >= 600
        let candidateFamilies = families + (config.fontFamily.map { [$0] } ?? [])
        if let resolved = config.resolvedFont?(candidateFamilies, weight, italic, size) {
            return resolved
        }

        for family in candidateFamilies {
            let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))
            guard !trimmed.isEmpty else { continue }
            if let font = UIFont(name: trimmed, size: size) {
                return applyTraits(to: font, bold: bold, italic: italic, size: size)
            }
        }

        if bold && italic {
            return UIFont(descriptor: UIFont.systemFont(ofSize: size).fontDescriptor.withSymbolicTraits([.traitBold, .traitItalic])
                ?? UIFont.systemFont(ofSize: size).fontDescriptor, size: size)
        } else if bold {
            return UIFont.systemFont(ofSize: size, weight: .bold)
        } else if italic {
            return UIFont.italicSystemFont(ofSize: size)
        } else {
            return UIFont.systemFont(ofSize: size)
        }
    }

    private func applyTraits(to font: UIFont, bold: Bool, italic: Bool, size: CGFloat) -> UIFont {
        var traits = font.fontDescriptor.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(traits) else {
            return UIFont(descriptor: font.fontDescriptor, size: size)
        }
        return UIFont(descriptor: descriptor, size: size)
    }

    // MARK: - 圖片 / 區塊裝飾

    private struct SingleImagePayload {
        let src: String
        let alt: String
        let style: RenderStyle
        let anchorID: String?
        let href: String?
    }

    private struct ImageMetrics {
        let drawWidth: CGFloat
        let drawHeight: CGFloat
        let totalWidth: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    private func renderInlineImage(
        src: String,
        alt: String,
        style: RenderStyle,
        ctx: RenderContext
    ) async -> NSAttributedString {
        if config.imageLoader == nil {
            guard !alt.isEmpty else { return NSAttributedString() }
            var attrs = ctx.baseAttributes
            let altFont = UIFont(name: ctx.font.fontName, size: ctx.font.pointSize - 1)
                ?? UIFont.italicSystemFont(ofSize: ctx.font.pointSize - 1)
            attrs[.font] = altFont
            return NSAttributedString(string: "[\(alt)]\n", attributes: attrs)
        }

        let image = src.isEmpty ? nil : await config.imageLoader?(src)
        return makeImagePlaceholder(image: image, style: style, ctx: ctx, imageSource: src, displayMode: .inline)
    }

    private func renderImageOnlyBlock(
        payload: SingleImagePayload,
        blockStyle: RenderStyle,
        ctx: RenderContext,
        isHeading: Bool,
        headingLevel: Int
    ) async -> NSAttributedString {
        let blockCtx = applyBlockStyle(blockStyle, to: ctx, isHeading: isHeading, headingLevel: headingLevel)
        let image = payload.src.isEmpty ? nil : await config.imageLoader?(payload.src)

        var attachmentStyle = blockStyle
        if let width = payload.style.width {
            attachmentStyle.width = width
        }
        if let height = payload.style.height {
            attachmentStyle.height = height
        }
        attachmentStyle.paddingLeft += payload.style.paddingLeft
        attachmentStyle.paddingRight += payload.style.paddingRight
        attachmentStyle.opacity = payload.style.opacity

        let imageMetrics = resolvedImageMetrics(image: image, style: attachmentStyle, font: blockCtx.font)
        let blockImage = HTMLAttributedStringBuilder.BlockRenderStyle.BlockImage(
            image: image,
            source: payload.src,
            drawSize: CGSize(width: imageMetrics.drawWidth, height: imageMetrics.drawHeight),
            opacity: attachmentStyle.opacity,
            alignment: nsTextAlignment(from: attachmentStyle.textAlign),
            paddingLeft: attachmentStyle.paddingLeft,
            paddingRight: attachmentStyle.paddingRight
        )

        let placeholder = NSMutableAttributedString(
            attributedString: makeImagePlaceholder(
                image: image,
                style: attachmentStyle,
                ctx: blockCtx,
                imageSource: payload.src,
                displayMode: .block,
                precomputedMetrics: imageMetrics
            )
        )
        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttribute(.paragraphStyle, value: blockCtx.paragraphStyle, range: range)
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

    private func makeImagePlaceholder(
        image: UIImage?,
        style: RenderStyle,
        ctx: RenderContext,
        imageSource: String,
        displayMode: ImageRunInfo.DisplayMode,
        precomputedMetrics: ImageMetrics? = nil
    ) -> NSAttributedString {
        let metrics = precomputedMetrics ?? resolvedImageMetrics(image: image, style: style, font: ctx.font)
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
                displayMode: displayMode,
                opacity: style.opacity
            )
        )
        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttributes(ctx.baseAttributes, range: range)
        return placeholder
    }

    private func resolvedImageMetrics(image: UIImage?, style: RenderStyle, font: UIFont) -> ImageMetrics {
        let availableWidth = max(1, (config.renderWidth ?? UIScreen.main.bounds.width) - style.paddingLeft - style.paddingRight)
        let maxDrawHeight = max(1, (config.renderWidth ?? UIScreen.main.bounds.width) * 1.5)

        var drawWidth: CGFloat
        var drawHeight: CGFloat

        if let image {
            if let explicitWidth = style.width, let explicitHeight = style.height {
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

        let totalWidth = drawWidth + style.paddingLeft + style.paddingRight
        let lineHeight = max(font.lineHeight, font.pointSize)
        let ascent: CGFloat
        let descent: CGFloat
        if drawHeight > lineHeight {
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

    private func singleImagePayload(from children: [RenderableNode]) -> SingleImagePayload? {
        guard children.count == 1 else { return nil }
        return unwrapSingleImage(from: children[0])
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
        case .image(let src, let alt, let style):
            return SingleImagePayload(src: src, alt: alt, style: style, anchorID: anchorID, href: href)
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

    private func makeBlockRenderStyle(
        from style: RenderStyle,
        blockImage: HTMLAttributedStringBuilder.BlockRenderStyle.BlockImage? = nil
    ) -> HTMLAttributedStringBuilder.BlockRenderStyle? {
        let renderStyle = HTMLAttributedStringBuilder.BlockRenderStyle(
            backgroundFillColor: style.backgroundColor?.uiColor,
            borderTopWidth: style.borderTopWidth,
            borderBottomWidth: style.borderBottomWidth,
            borderTopColor: style.borderTopColor?.uiColor,
            borderBottomColor: style.borderBottomColor?.uiColor,
            width: style.width,
            height: style.height,
            textAlign: nsTextAlignment(from: style.textAlign),
            isHorizontallyCentered: style.isHorizontallyCentered,
            paragraphSpacingBefore: style.paragraphSpacingBefore,
            visualOffsetBefore: 0,
            paddingLeft: style.paddingLeft,
            paddingRight: style.paddingRight,
            blockImage: blockImage
        )
        return renderStyle.hasVisualDecoration ? renderStyle : nil
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

    // MARK: - RenderContext

    private struct RenderContext {
        var font: UIFont
        var fontFamilies: [String]
        var fontWeight: Int
        var textColor: UIColor
        var kern: CGFloat
        var paragraphStyle: NSParagraphStyle
        var baselineOffset: CGFloat
        var lineHeightMultiple: CGFloat
        var linkHref: String?

        /// 記錄 body 的基準字號，供 heading 按比例放大用。
        var baseSize: CGFloat

        var baseAttributes: [NSAttributedString.Key: Any] {
            var attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .kern: kern as NSNumber,
                .baselineOffset: baselineOffset as NSNumber,
                .paragraphStyle: paragraphStyle
            ]
            if let href = linkHref {
                attrs[HTMLAttributedStringBuilder.internalLinkAttribute] = href
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
            return RenderContext(
                font: font,
                fontFamilies: config.fontFamily.map { [$0] } ?? [],
                fontWeight: 400,
                textColor: config.textColor,
                kern: config.letterSpacing,
                paragraphStyle: para,
                baselineOffset: ReaderTypographyCorrection.baselineOffset(
                    font: font,
                    targetLineHeight: targetLineHeight
                ),
                lineHeightMultiple: config.lineHeightMultiple,
                baseSize: config.baseFontSize
            )
        }
    }
}

// MARK: - UIFont 輔助（判斷目前字重 / 斜體）

private extension UIFont {
    var isBold: Bool {
        fontDescriptor.symbolicTraits.contains(.traitBold)
    }
    var isItalic: Bool {
        fontDescriptor.symbolicTraits.contains(.traitItalic)
    }
}
