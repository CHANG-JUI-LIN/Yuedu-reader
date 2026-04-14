import Foundation
import UIKit

enum HTMLStyledASTRenderableNodeConverter {
    static func convert(body: HTMLAttributedStringBuilder.ElementNode) -> [RenderableNode] {
        body.children.map { $0.asRenderableNode() }
    }
}

private extension HTMLAttributedStringBuilder.ASTNode {
    func asRenderableNode() -> RenderableNode {
        switch self {
        case .text(let node):
            return .text(node.text)
        case .lineBreak:
            return .lineBreak
        case .element(let node):
            return node.asRenderableNode()
        }
    }
}

private extension HTMLAttributedStringBuilder.ElementNode {
    func asRenderableNode() -> RenderableNode {
        let mappedChildren = children.map { $0.asRenderableNode() }
        let style = RenderStyle.from(resolvedStyle: resolvedStyle)
        let node: RenderableNode

        switch tag {
        case "p", "div", "section", "article", "main", "header", "footer", "nav", "aside", "body":
            node = .paragraph(mappedChildren, style: style)

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
            node = .anchor(href: href, children: mappedChildren)

        case "img", "image":
            let src = attributes["src"] ?? attributes["xlink:href"] ?? attributes["href"] ?? ""
            let alt = attributes["alt"] ?? ""
            node = .image(src: src, alt: alt, style: style)

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
}

private extension RenderStyle {
    static func from(resolvedStyle s: HTMLAttributedStringBuilder.ResolvedStyle) -> RenderStyle {
        RenderStyle(
            fontSizeMultiplier: 1.0,
            fontFamilies: s.fontFamilies,
            fontWeight: s.fontWeight,
            bold: s.fontWeight >= 700,
            italic: s.isItalic,
            color: s.hasCSSColor ? RenderColor(uiColor: s.textColor) : nil,
            backgroundColor: s.backgroundFillColor.flatMap { RenderColor(uiColor: $0) },
            textIndent: s.textIndent,
            textAlign: .from(nsTextAlignment: s.textAlign),
            lineHeightMultiplier: s.lineHeightExplicit
                ? max(1.0, s.lineHeight / max(s.fontSize, 1))
                : 1.0,
            marginLeft: s.marginLeft,
            paddingLeft: s.paddingLeft,
            paddingRight: s.paddingRight,
            paragraphSpacingBefore: s.paragraphSpacingBefore,
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
            isHorizontallyCentered: s.isHorizontallyCentered
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