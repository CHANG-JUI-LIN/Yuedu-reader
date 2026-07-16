import Foundation
import UIKit

enum HTMLStyledASTRenderableNodeConverter {
    enum WhitespacePolicy: Equatable {
        /// CSS-like inline flow used by EPUB: preserve authored inline separators (including
        /// U+3000), while dropping only whitespace adjacent to real block/line boundaries.
        case preserveInlineFlow
        /// The online-reader behavior from before the EPUB whitespace compatibility change:
        /// every text node is trimmed at its own edges after ASCII whitespace collapsing.
        case trimTextNodeBoundaries
    }

    static func convert(
        body: HTMLAttributedStringBuilder.ElementNode,
        whitespacePolicy: WhitespacePolicy = .preserveInlineFlow
    ) -> [RenderableNode] {
        mapChildren(
            body.children,
            parentFontSize: body.resolvedStyle.fontSize,
            whitespacePolicy: whitespacePolicy
        )
    }

    /// HTML whitespace collapsing for normal-flow text: runs of spaces, tabs, CR/LF and
    /// form feeds collapse to a single space (and nbsp is normalized to a space). Mirrors
    /// `HTMLAttributedStringBuilder.normalizeWhitespace` so the renderable-node pipeline
    /// matches the legacy `renderNode` path. Without it, EPUB source line breaks and the
    /// leading indentation of hard-wrapped `<p>` blocks rendered verbatim — every wrapped
    /// paragraph came out as staggered, indented fragments. (`white-space: pre` is not yet
    /// modeled here, matching the legacy path.)
    static func normalizeWhitespace(_ text: String) -> String {
        // NB: form feed must be ICU's `\x{000C}` — `\u{000C}` is Swift escape syntax that
        // ICU rejects, which silently invalidates the whole class so nothing collapses.
        let collapsed = text.replacingOccurrences(
            of: "[ \\t\\r\\n\\x{000C}]+",
            with: " ",
            options: .regularExpression
        )
        return collapsed.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Maps a child list to renderable nodes, applying CSS-style whitespace processing:
    /// runs of ASCII whitespace collapse to one space; a whitespace-only node adjacent to a
    /// block boundary (a block sibling, or the edge of a block parent) is source formatting
    /// and drops; and a content node's boundary spaces trim only against those same block
    /// boundaries. Spaces inside inline flow are content ("foo <b>bar</b> baz"), as is
    /// U+3000 ideographic space, which CSS never collapses — trimming it flattened duokan's
    /// `<span>参考消息</span>　title` gap so the chip overlapped the title glyphs.
    static func mapChildren(
        _ children: [HTMLAttributedStringBuilder.ASTNode],
        parentFontSize: CGFloat,
        parentIsBlock: Bool = true,
        whitespacePolicy: WhitespacePolicy = .preserveInlineFlow
    ) -> [RenderableNode] {
        if whitespacePolicy == .trimTextNodeBoundaries {
            return children.compactMap { node -> RenderableNode? in
                guard case .text(let textNode) = node else {
                    return node.asRenderableNode(
                        parentFontSize: parentFontSize,
                        whitespacePolicy: whitespacePolicy
                    )
                }
                let normalized = normalizeWhitespace(textNode.text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { return nil }
                return .text(normalized)
            }
        }

        // A line/segment boundary eats the collapsed space beside it: block siblings
        // (anonymous-block edges), <br> (a space right after it would render at the new
        // line's start), and page breaks. Inline elements and images are flow — the
        // space beside them is a word separator.
        func isBoundary(_ node: HTMLAttributedStringBuilder.ASTNode) -> Bool {
            switch node {
            case .element(let element): return element.resolvedStyle.isBlock
            case .lineBreak, .pageBreak: return true
            case .text: return false
            }
        }
        return children.enumerated().compactMap { index, node -> RenderableNode? in
            guard case .text(let textNode) = node else {
                return node.asRenderableNode(
                    parentFontSize: parentFontSize,
                    whitespacePolicy: whitespacePolicy
                )
            }
            var normalized = normalizeWhitespace(textNode.text)
            let afterBoundary = index == 0
                ? parentIsBlock
                : isBoundary(children[index - 1])
            let beforeBoundary = index == children.count - 1
                ? parentIsBlock
                : isBoundary(children[index + 1])
            if normalized.allSatisfy({ $0 == " " }) {
                let dropped = afterBoundary || beforeBoundary
                guard !normalized.isEmpty else { return nil }
                return dropped ? nil : .text(" ")
            }
            if afterBoundary, normalized.hasPrefix(" ") {
                normalized.removeFirst()
            }
            if beforeBoundary, normalized.hasSuffix(" ") {
                normalized.removeLast()
            }
            return normalized.isEmpty ? nil : .text(normalized)
        }
    }
}

private extension HTMLAttributedStringBuilder.ASTNode {
    func asRenderableNode(
        parentFontSize: CGFloat,
        whitespacePolicy: HTMLStyledASTRenderableNodeConverter.WhitespacePolicy
    ) -> RenderableNode {
        switch self {
        case .text(let node):
            return .text(HTMLStyledASTRenderableNodeConverter.normalizeWhitespace(node.text))
        case .lineBreak(let node):
            // A `<br>` the CSS promotes to display:block terminates the visual paragraph (real
            // paragraph break, no first-line indent on the continuation) instead of emitting a
            // soft line separator. Common in Calibre copyright pages (`<br class="calibre1">`).
            return node.resolvedStyle.isBlock ? .text("\n") : .lineBreak
        case .pageBreak:
            return .pageBreak
        case .element(let node):
            return node.asRenderableNode(
                parentFontSize: parentFontSize,
                whitespacePolicy: whitespacePolicy
            )
        }
    }
}

private extension HTMLAttributedStringBuilder.ElementNode {
    func asRenderableNode(
        parentFontSize: CGFloat,
        whitespacePolicy: HTMLStyledASTRenderableNodeConverter.WhitespacePolicy
    ) -> RenderableNode {
        let myFontSize = resolvedStyle.fontSize
        let mappedChildren = HTMLStyledASTRenderableNodeConverter.mapChildren(
            children,
            parentFontSize: myFontSize,
            parentIsBlock: resolvedStyle.isBlock,
            whitespacePolicy: whitespacePolicy
        )
        var style = RenderStyle.from(resolvedStyle: resolvedStyle, parentFontSize: parentFontSize)
        style.sourceElementTag = tag
        style.hyphenationPolicy = resolvedStyle.hyphenationPolicy
        if containsFloatDescendant || classes.contains("tk") {
            style.compactChildBlockSpacing = true
        }
        let ssmlAlphabet = attributes["ssml:alphabet"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let ssmlIPA = attributes["ssml:ph"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ssmlIPA.isEmpty,
           ssmlAlphabet == nil || ssmlAlphabet == "ipa" {
            style.ssmlIPA = ssmlIPA
        }
        style.isInlineAnnotation = isInlineAnnotationElement
        if style.isInlineAnnotation {
            CoreTextPaginator.debugVerticalLog("EPUBFLOW converter.inlineAnnotation tag=\(tag) class=\(classes.joined(separator: ".")) fontMultiplier=\(style.fontSizeMultiplier) childCount=\(mappedChildren.count)")
        }
        let node: RenderableNode

        switch tag {
        case "table":
            if let table = HTMLTableModel.from(element: self) {
                node = .table(table, style: style)
            } else {
                node = .block(tag: tag, children: mappedChildren, style: style)
            }

        case "math":
            let mode: MathDisplayMode = attributes["display"] == "block" || resolvedStyle.isBlock ? .block : .inline
            node = .mathML(
                MathMLPayload(
                    latex: MathMLLatexConverter.latex(from: self),
                    alt: attributes["alttext"] ?? attributes["alt"],
                    displayMode: mode
                ),
                style: style
            )

        case "audio", "video":
            if let media = mediaAttachment {
                node = .media(media, style: style)
            } else {
                // No player surfaced (controls-less background audio, or no source). Render nothing —
                // never fall back to the element's `<div class="errmsg">` "unsupported" children.
                node = .text("")
            }

        case "object":
            let type = attributes["type"] ?? ""
            if !type.lowercased().hasPrefix("image/") {
                node = .unsupportedInteractive(
                    type: type,
                    title: attributes["title"] ?? attributes["aria-label"] ?? type,
                    children: mappedChildren,
                    style: style
                )
            } else {
                node = .block(tag: tag, children: mappedChildren, style: style)
            }

        case "p", "div", "body":
            if tag == "body" {
                // The body's background-image is rendered per-page by the pageBackgroundImage
                // pipeline (cover-sized); drawing it again as a block decoration would double it.
                style.backgroundImageSource = nil
            }
            node = .paragraph(mappedChildren, style: style)

        case "section", "article", "main", "header", "footer", "nav", "aside", "figure", "figcaption", "address":
            node = .block(tag: tag, children: mappedChildren, style: style)

        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.last ?? "1")) ?? 1
            node = .heading(mappedChildren, level: level, style: style)

        case "blockquote":
            node = .block(tag: tag, children: mappedChildren, style: style)

        case "li":
            let bullet = resolvedStyle.listBullet ?? "•"
            node = .listItem(mappedChildren, bullet: bullet)

        case "hr":
            node = .horizontalRule(style: style)

        case "br":
            node = .lineBreak

        case "a":
            let href = attributes["href"] ?? ""
            let className = attributes["class"] ?? ""
            let isReviewImageAnchor = className
                .split(separator: " ")
                .contains { $0 == "yd-review-image" }
            if let marker = ReaderHTMLUtilities.decodeReviewHref(href), !isReviewImageAnchor {
                node = .commentBadge(count: marker.count, reviewURL: href, title: marker.title)
            } else {
                // `.anchor` carries only the href, so the anchor's own CSS (e.g. `a { font-weight:bold }`,
                // a custom color, italic — common in TOCs) would be dropped. When the anchor styles its
                // own text, wrap the children in an inline style node so that styling cascades, mirroring
                // the legacy renderNode path (which renders an anchor's children with the anchor's
                // resolved style as the inherited style). Plain links stay unwrapped so the single-image
                // anchor detection (`unwrapSingleImage`) and minimal nesting are preserved.
                let anchorStylesOwnText = style.bold || style.italic || style.color != nil
                    || !style.fontFamilies.isEmpty || style.underline || style.strikethrough
                    || style.fontSizeMultiplier != 1.0
                    || attributes["xml:lang"] != nil || attributes["lang"] != nil
                node = .anchor(
                    href: href,
                    children: anchorStylesOwnText
                        ? [.inline(tag: "a", children: mappedChildren, style: style)]
                        : mappedChildren
                )
            }

        case "ruby":
            node = rubySegments(
                parentFontSize: myFontSize,
                style: style,
                whitespacePolicy: whitespacePolicy
            )

        case "img", "image":
            let src = attributes["src"] ?? attributes["xlink:href"] ?? attributes["href"] ?? ""
            let alt = attributes["alt"] ?? ""
            // Legado `style:"text"` click-config directive → render at the surrounding text size
            // (small inline 段評 bubble), not the SVG's intrinsic 180×144.
            if attributes["data-yd-imgstyle"]?.lowercased() == "text" {
                style.isTextSizedImage = true
            }
            node = .image(src: src, alt: alt, style: style)

        case "svg":
            let alt = attributes["aria-label"] ?? attributes["alt"] ?? ""
            let imageNode: RenderableNode = .image(src: "svg:", alt: alt, style: style, svgContent: svgContent)
            if resolvedStyle.isBlock {
                node = .block(tag: "svg", children: [imageNode], style: style)
            } else {
                node = imageNode
            }

        default:
            if resolvedStyle.isBlock {
                node = .block(tag: tag, children: mappedChildren, style: style)
            } else {
                node = .inline(tag: tag, children: mappedChildren, style: style)
            }
        }

        guard !id.isEmpty else { return node }
        return .anchorTarget(id: id, child: node)
    }

    /// Pairs each run of base content with the `<rt>` that follows it, so
    /// `<ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby>` produces one annotation per base character
    /// instead of one merged annotation across the whole element.
    private func rubySegments(
        parentFontSize: CGFloat,
        style: RenderStyle,
        whitespacePolicy: HTMLStyledASTRenderableNodeConverter.WhitespacePolicy
    ) -> RenderableNode {
        var segments: [RenderableNode] = []
        var pendingBase: [RenderableNode] = []
        for child in children {
            if case .element(let element) = child, element.isRubyAnnotationElement {
                guard element.tag == "rt" else { continue }
                let annotation = element.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !pendingBase.isEmpty else { continue }
                if annotation.isEmpty {
                    segments.append(contentsOf: pendingBase)
                } else {
                    segments.append(.ruby(base: pendingBase, text: annotation, style: style))
                }
                pendingBase = []
            } else {
                pendingBase.append(child.asRenderableNode(
                    parentFontSize: parentFontSize,
                    whitespacePolicy: whitespacePolicy
                ))
            }
        }
        segments.append(contentsOf: pendingBase)
        if segments.count == 1, let only = segments.first {
            return only
        }
        return .inline(tag: "ruby", children: segments, style: style)
    }

    private var plainText: String {
        children.map { child -> String in
            switch child {
            case .text(let node):
                return node.text
            case .lineBreak:
                return " "
            case .pageBreak:
                return ""
            case .element(let element):
                return element.plainText
            }
        }.joined()
    }

    private var containsFloatDescendant: Bool {
        children.contains { child in
            guard case .element(let element) = child else { return false }
            return element.resolvedStyle.floatSide != nil || element.containsFloatDescendant
        }
    }

    private var isRubyAnnotationElement: Bool {
        tag == "rt" || tag == "rp"
    }

    private var isInlineAnnotationElement: Bool {
        guard tag == "span" else { return false }
        return classes.contains { className in
            className == "small" || className.hasPrefix("small")
        }
    }

    private var mediaAttachment: EPUBMediaAttachment? {
        let source = mediaSource
        guard !source.isEmpty else { return nil }
        let kind: EPUBMediaKind = tag == "video" ? .video : .audio
        // Controls-less <audio> = invisible background soundtrack (matches Apple Books / Readium).
        if kind == .audio, attributes["controls"] == nil { return nil }
        return EPUBMediaAttachment(
            kind: kind,
            sourceHref: source,
            mediaType: mediaType,
            title: attributes["title"] ?? attributes["aria-label"] ?? attributes["alt"],
            posterHref: attributes["poster"]
        )
    }

    private var mediaSource: String {
        if let src = attributes["src"], !src.isEmpty {
            return src
        }
        for child in children {
            guard case .element(let element) = child,
                  element.tag == "source",
                  let src = element.attributes["src"],
                  !src.isEmpty
            else { continue }
            return src
        }
        return ""
    }

    private var mediaType: String? {
        if let type = attributes["type"], !type.isEmpty {
            return type
        }
        for child in children {
            guard case .element(let element) = child,
                  element.tag == "source",
                  let type = element.attributes["type"],
                  !type.isEmpty
            else { continue }
            return type
        }
        return nil
    }
}

private extension RenderStyle {
    static func from(resolvedStyle s: HTMLAttributedStringBuilder.ResolvedStyle, parentFontSize: CGFloat) -> RenderStyle {
        let multiplier: CGFloat = parentFontSize > 0 ? s.fontSize / parentFontSize : 1.0
        return RenderStyle(
            fontSizeMultiplier: multiplier,
            fontFamilies: s.fontFamilies,
            fontWeight: s.fontWeight,
            bold: s.fontWeight >= 700,
            italic: s.isItalic,
            color: s.hasCSSColor ? RenderColor(uiColor: s.textColor) : nil,
            backgroundColor: s.backgroundFillColor.flatMap { RenderColor(uiColor: $0) },
            textIndent: s.textIndent,
            textAlign: .from(nsTextAlignment: s.textAlign),
            baseWritingDirection: s.baseWritingDirection,
            language: s.language,
            lineHeightMultiplier: s.lineHeightExplicit
                ? max(1.0, s.lineHeight / max(s.fontSize, 1))
                : 1.0,
            marginLeft: s.marginLeft,
            marginRight: s.marginRight,
            rawWidthPercent: s.rawWidthPercent,
            paddingTop: s.paddingTop,
            paddingLeft: s.paddingLeft,
            paddingBottom: s.paddingBottom,
            paddingRight: s.paddingRight,
            paragraphSpacingBefore: s.paragraphSpacingBefore,
            visualOffsetBefore: s.visualOffsetBefore,
            paragraphSpacingAfter: s.paragraphSpacing,
            width: s.width,
            height: s.height,
            opacity: s.opacity,
            borderTopWidth: s.borderTopWidth,
            borderBottomWidth: s.borderBottomWidth,
            borderLeftWidth: s.borderLeftWidth,
            borderRightWidth: s.borderRightWidth,
            borderTopColor: s.borderTopColor.flatMap { RenderColor(uiColor: $0) },
            borderBottomColor: s.borderBottomColor.flatMap { RenderColor(uiColor: $0) },
            borderLeftColor: s.borderLeftColor.flatMap { RenderColor(uiColor: $0) },
            borderRightColor: s.borderRightColor.flatMap { RenderColor(uiColor: $0) },
            borderTopStyle: s.borderTopStyle,
            borderBottomStyle: s.borderBottomStyle,
            borderLeftStyle: s.borderLeftStyle,
            borderRightStyle: s.borderRightStyle,
            borderExplicitlyNone: s.borderExplicitlyNone,
            isHorizontallyCentered: s.isHorizontallyCentered,
            firstLetterFontSizeMultiplier: s.firstLetterFontSizeMultiplier,
            firstLetterFontWeight: s.firstLetterFontWeight,
            firstLetterColor: s.firstLetterColor.flatMap { RenderColor(uiColor: $0) },
            underline: s.underline,
            strikethrough: s.strikethrough,
            isVerticalWritingMode: s.isVerticalWritingMode,
            borderRadius: s.borderRadius,
            floatSide: s.floatSide.map { side in
                switch side {
                case .left: return .left
                case .right: return .right
                }
            },
            avoidsPageBreakInside: s.avoidsPageBreakInside,
            hasExplicitVerticalMargins: s.hasExplicitVerticalMargins,
            backgroundImageSource: s.backgroundImage,
            backgroundImageSize: s.backgroundImageSize,
            backgroundImageStretches: s.backgroundImageStretches,
            backgroundImageRepeats: s.backgroundImageRepeats
        )
    }
}

private extension RenderTextAlignment {
    static func from(nsTextAlignment align: NSTextAlignment) -> RenderTextAlignment {
        switch align {
        case .left:      return .left
        case .center:    return .center
        case .right:     return .right
        case .justified: return .justify
        default:         return .natural
        }
    }
}
