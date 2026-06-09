import Foundation
import UIKit

enum HTMLStyledASTRenderableNodeConverter {
    static func convert(body: HTMLAttributedStringBuilder.ElementNode) -> [RenderableNode] {
        mapChildren(body.children, parentFontSize: body.resolvedStyle.fontSize)
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

    /// Maps a child list to renderable nodes, collapsing text whitespace and dropping the
    /// indentation-only text nodes that sit between block-level siblings. Such a collapsed
    /// space would otherwise leak into the following block and corrupt its paragraph style
    /// (the same reason `HTMLAttributedStringBuilder.renderBlockChildren` skips them).
    static func mapChildren(
        _ children: [HTMLAttributedStringBuilder.ASTNode],
        parentFontSize: CGFloat
    ) -> [RenderableNode] {
        let hasBlockSibling = children.contains { node in
            if case .element(let element) = node { return element.resolvedStyle.isBlock }
            return false
        }
        return children.compactMap { node -> RenderableNode? in
            guard case .text(let textNode) = node else {
                return node.asRenderableNode(parentFontSize: parentFontSize)
            }
            let normalized = normalizeWhitespace(textNode.text)
            if hasBlockSibling, normalized.allSatisfy({ $0 == " " }) {
                return nil
            }
            return .text(normalized)
        }
    }
}

private extension HTMLAttributedStringBuilder.ASTNode {
    func asRenderableNode(parentFontSize: CGFloat) -> RenderableNode {
        switch self {
        case .text(let node):
            return .text(HTMLStyledASTRenderableNodeConverter.normalizeWhitespace(node.text))
        case .lineBreak:
            return .lineBreak
        case .pageBreak:
            return .pageBreak
        case .element(let node):
            return node.asRenderableNode(parentFontSize: parentFontSize)
        }
    }
}

private extension HTMLAttributedStringBuilder.ElementNode {
    func asRenderableNode(parentFontSize: CGFloat) -> RenderableNode {
        let myFontSize = resolvedStyle.fontSize
        let mappedChildren = HTMLStyledASTRenderableNodeConverter.mapChildren(children, parentFontSize: myFontSize)
        var style = RenderStyle.from(resolvedStyle: resolvedStyle, parentFontSize: parentFontSize)
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
            if let latex = MathMLLatexConverter.latex(from: self) {
                let alt = attributes["alttext"] ?? attributes["alt"] ?? latex
                let mode: MathDisplayMode = attributes["display"] == "block" || resolvedStyle.isBlock ? .block : .inline
                node = .mathML(latex: latex, alt: alt, style: style, displayMode: mode)
            } else {
                node = .inline(tag: tag, children: mappedChildren, style: style)
            }

        case "audio", "video":
            if let media = mediaAttachment {
                node = .media(media, style: style)
            } else {
                // No player surfaced (controls-less background audio, or no source). Render nothing —
                // never fall back to the element's `<div class="errmsg">` "unsupported" children.
                node = .text("")
            }

        case "p", "div", "body":
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
            if let marker = ReaderHTMLUtilities.decodeReviewHref(href) {
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
                node = .anchor(
                    href: href,
                    children: anchorStylesOwnText
                        ? [.inline(tag: "a", children: mappedChildren, style: style)]
                        : mappedChildren
                )
            }

        case "ruby":
            node = .ruby(
                base: rubyBaseChildren(parentFontSize: myFontSize),
                text: rubyAnnotationText,
                style: style
            )

        case "img", "image":
            let src = attributes["src"] ?? attributes["xlink:href"] ?? attributes["href"] ?? ""
            let alt = attributes["alt"] ?? ""
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

    private func rubyBaseChildren(parentFontSize: CGFloat) -> [RenderableNode] {
        children.compactMap { child in
            guard case .element(let element) = child,
                  element.isRubyAnnotationElement
            else {
                return child.asRenderableNode(parentFontSize: parentFontSize)
            }
            return nil
        }
    }

    private var rubyAnnotationText: String {
        children.compactMap { child -> String? in
            guard case .element(let element) = child,
                  element.isRubyAnnotationElement
            else { return nil }
            return element.plainText
        }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
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
            }
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
