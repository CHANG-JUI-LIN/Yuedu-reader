import CoreGraphics
import Foundation
import UIKit

struct EdgeSizes: Equatable {
    var top: CGFloat = 0
    var right: CGFloat = 0
    var bottom: CGFloat = 0
    var left: CGFloat = 0
    static let zero = EdgeSizes()
    var horizontal: CGFloat { left + right }
    var vertical: CGFloat { top + bottom }
}

enum CSSDisplay: Equatable { case block, inline, inlineBlock, none }

/// Computed style: the result of cascading + inheritance. Box-model measures
/// are stored as `CSSLength` (specified values); the layout stage resolves
/// percentages/auto against the containing block into *used* values.
struct ComputedStyle: Equatable {
    var display: CSSDisplay = .block
    var isHidden = false

    // Inline text
    var fontSize: CGFloat
    var fontFamilies: [String]
    var fontWeight: Int
    var isItalic: Bool
    var color: UIColor?
    var backgroundColor: UIColor?
    var textAlign: NSTextAlignment = .natural
    var lineHeight: CGFloat?            // nil = normal (ascent/descent)

    // Box model (specified)
    var width: CSSLength = .auto
    var height: CSSLength = .auto
    var marginTop: CSSLength = .px(0)
    var marginRight: CSSLength = .px(0)
    var marginBottom: CSSLength = .px(0)
    var marginLeft: CSSLength = .px(0)
    var paddingTop: CSSLength = .px(0)
    var paddingRight: CSSLength = .px(0)
    var paddingBottom: CSSLength = .px(0)
    var paddingLeft: CSSLength = .px(0)
    var borderTopWidth: CGFloat = 0
    var borderRightWidth: CGFloat = 0
    var borderBottomWidth: CGFloat = 0
    var borderLeftWidth: CGFloat = 0
    var borderColor: UIColor?
    var borderRadius: CGFloat = 0
    var configParagraphSpacing: CGFloat = 0

    init(
        fontSize: CGFloat = 17,
        fontFamilies: [String] = [],
        fontWeight: Int = 400,
        isItalic: Bool = false,
        color: UIColor? = nil,
        backgroundColor: UIColor? = nil,
        textAlign: NSTextAlignment = .natural,
        lineHeight: CGFloat? = nil
    ) {
        self.fontSize = fontSize
        self.fontFamilies = fontFamilies
        self.fontWeight = fontWeight
        self.isItalic = isItalic
        self.color = color
        self.backgroundColor = backgroundColor
        self.textAlign = textAlign
        self.lineHeight = lineHeight
    }
}

extension ComputedStyle {
    func inherited(from parent: ComputedStyle) -> ComputedStyle {
        ComputedStyle(
            fontSize: parent.fontSize,
            fontFamilies: parent.fontFamilies,
            fontWeight: parent.fontWeight,
            isItalic: parent.isItalic,
            color: parent.color,
            backgroundColor: nil,
            textAlign: parent.textAlign,
            lineHeight: parent.lineHeight
        )
    }
}

/// Minimal user-agent stylesheet, rendered as a base `ComputedStyle` per tag.
enum UserAgentStyle {
    static func basis(for tag: String) -> ComputedStyle {
        var style = ComputedStyle()
        switch tag {
        case "html", "body", "div", "section", "article", "header", "footer",
             "main", "aside", "nav", "blockquote", "figure", "figcaption",
             "table", "thead", "tbody", "tfoot", "tr", "td", "th", "ul", "ol",
             "li", "dl", "dt", "dd", "hr", "pre", "address", "form", "fieldset":
            style.display = .block
        case "span", "a", "em", "i", "strong", "b", "u", "s", "small", "code",
             "q", "cite", "mark", "time", "sub", "sup", "abbr", "label":
            style.display = .inline
            if tag == "em" || tag == "i" { style.isItalic = true }
            if tag == "strong" || tag == "b" { style.fontWeight = 700 }
        case "img", "svg", "canvas":
            style.display = .inlineBlock
        case "head", "script", "style", "title", "meta", "link", "template":
            style.display = .none
            style.isHidden = true
        default:
            style.display = .block
        }

        switch tag {
        case "p":
            style.marginTop = .em(1)
            style.marginBottom = .em(1)
        case "h1":
            style.fontSize = 32; style.fontWeight = 700
            style.marginTop = .em(0.67); style.marginBottom = .em(0.67)
        case "h2":
            style.fontSize = 24; style.fontWeight = 700
            style.marginTop = .em(0.83); style.marginBottom = .em(0.83)
        case "h3":
            style.fontSize = 18.72; style.fontWeight = 700
            style.marginTop = .em(1); style.marginBottom = .em(1)
        case "h4":
            style.fontSize = 16; style.fontWeight = 700
            style.marginTop = .em(1.33); style.marginBottom = .em(1.33)
        case "h5":
            style.fontSize = 13.28; style.fontWeight = 700
            style.marginTop = .em(1.67); style.marginBottom = .em(1.67)
        case "h6":
            style.fontSize = 10.72; style.fontWeight = 700
            style.marginTop = .em(2.33); style.marginBottom = .em(2.33)
        case "ul", "ol", "menu", "dir":
            style.paddingLeft = .px(40)
        case "blockquote":
            style.marginLeft = .px(40); style.marginRight = .px(40)
        case "hr":
            style.width = .percent(1)
        case "body":
            style.marginTop = .px(8); style.marginRight = .px(8)
            style.marginBottom = .px(8); style.marginLeft = .px(8)
        default:
            break
        }
        return style
    }
}