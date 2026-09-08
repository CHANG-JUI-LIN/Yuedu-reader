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

enum WhiteSpaceMode: Equatable {
    case normal
    case nowrap
    case pre
    case preWrap
    case preLine
}

/// A resolved `background-image` with its sizing/positioning keywords.
/// Paint-only: presence never affects layout, so it never triggers a
/// capability rejection. The image source is resolved by the caller
/// (document imageLoader) into an actual bitmap at render time.
struct BackgroundImageStyle: Equatable {
    /// The raw `url(...)` source as authored.
    var source: String
    /// `background-size`: cover | contain | explicit size. nil = auto.
    var size: BackgroundSize = .auto
    /// `background-position` keywords (x, y). Default: 0% 0% (top-left).
    var positionX: BackgroundPosition = .percent(0)
    var positionY: BackgroundPosition = .percent(0)
    /// `background-repeat`: repeat | no-repeat. Default repeat.
    var repeatMode: BackgroundRepeatMode = .repeat
    /// `background-attachment`: scroll | fixed. Default scroll.
    var attachment: BackgroundAttachment = .scroll

    enum BackgroundSize: Equatable {
        case auto
        case cover
        case contain
    }

    enum BackgroundPosition: Equatable {
        case percent(CGFloat)     // 0…1
        case keyword(CGFloat)     // resolved offset as fraction of slack (0…1)
        case length(CGFloat)      // absolute offset
    }

    enum BackgroundRepeatMode: Equatable {
        case `repeat`
        case noRepeat
    }

    enum BackgroundAttachment: Equatable {
        case scroll
        case fixed
    }
}

/// Computed style: the result of cascading + inheritance. Box-model measures
/// are stored as `CSSLength` (specified values); the layout stage resolves
/// percentages/auto against the containing block into *used* values.
/// CSS 2.1 §9.5.1 `float`. Initial value `none`; not inherited.
enum CSSFloat: Equatable {
    case none, left, right

    /// The single source of truth for what counts as a valid `float` token.
    /// Returns `nil` for an invalid declaration (`center`, `inline-start`, a
    /// typo), which callers must DROP — dropping leaves the initial `none`.
    ///
    /// Both the style cascade and the capability scanner parse through here so
    /// they can never disagree about whether a box floats. They did disagree
    /// before: the scanner rejected a chapter on the `float` *key* alone, so
    /// Legacy EPUBs carrying only `float: center` (invalid → `none`)
    /// were refused by the browser engine despite having nothing to float.
    static func parse(_ value: String) -> CSSFloat? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none": return CSSFloat.none
        case "left": return .left
        case "right": return .right
        default: return nil
        }
    }
}

/// CSS 2.1 §9.5.2 `clear`. Initial value `none`; not inherited.
enum CSSClear: Equatable {
    case none, left, right, both
}

struct ComputedStyle: Equatable {
    var display: CSSDisplay = .block
    var isHidden = false
    /// Used `float`. STRICT: any token outside {none,left,right} leaves this at
    /// `.none`, because an invalid declaration is dropped and the property keeps
    /// its initial value. Some legacy EPUBs declare invalid `float: center`.
    /// on 51 of its 57 float-classed boxes — `center` is not a float value, so a
    /// browser renders those as ordinary blocks. Anything that dispatches on the
    /// CLASS NAME instead of this computed value floats 89% of them wrongly.
    var cssFloat: CSSFloat = .none
    /// Used `clear`. Same strict rule.
    var cssClear: CSSClear = .none

    var isFloated: Bool {
        cssFloat == .left || cssFloat == .right
    }

    // Inline text
    var fontSize: CGFloat
    var fontFamilies: [String]
    var fontWeight: Int
    var isItalic: Bool
    var color: UIColor?
    var backgroundColor: UIColor?
    /// Authored `background-image` (paint-only; resolved to a bitmap by the
    /// document imageLoader). nil = none.
    var backgroundImage: BackgroundImageStyle? = nil
    var textAlign: NSTextAlignment = .natural
    var lineHeight: CGFloat?            // nil = normal (ascent/descent)
    /// Unitless line-height is inherited as a multiplier and recomputed from
    /// each descendant's own font size. Length/percentage values are finalized
    /// to an absolute computed length before inheritance.
    var lineHeightMultiplier: CGFloat? = nil
    /// Transient winning specified length. The style builder resolves this only
    /// after the complete cascade has selected the final font size.
    var pendingLineHeightLength: CSSLength? = nil
    var whiteSpace: WhiteSpaceMode = .normal
    /// Inherited specified/computed value. Percentages remain symbolic until
    /// BlockLayout has resolved this block container's final inline size.
    var textIndent: CSSTextIndent = .initial
    var rubyAlign: RubyAlignment = .center
    var rubyPosition: RubyPosition = .over
    var rubyMerge: RubyMerge = .separate

    // Box model (specified)
    var width: CSSLength = .auto
    var height: CSSLength = .auto
    var maxWidth: CSSLength? = nil      // nil = none
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
    var pendingBorderTopWidth: CSSLength? = nil
    var pendingBorderRightWidth: CSSLength? = nil
    var pendingBorderBottomWidth: CSSLength? = nil
    var pendingBorderLeftWidth: CSSLength? = nil
    /// Per-side border styles (Phase 2C: dotted/dashed must render).
    var borderTopStyle: BorderStyle = .solid
    var borderRightStyle: BorderStyle = .solid
    var borderBottomStyle: BorderStyle = .solid
    var borderLeftStyle: BorderStyle = .solid
    var borderColor: UIColor?
    var borderRadius: CGFloat = 0
    var pendingBorderRadius: CSSLength? = nil
    var configParagraphSpacing: CGFloat = 0
    var configLineSpacing: CGFloat = 0
    var configLetterSpacing: CGFloat = 0
    var configBold = false

    init(
        fontSize: CGFloat = 17,
        fontFamilies: [String] = [],
        fontWeight: Int = 400,
        isItalic: Bool = false,
        color: UIColor? = nil,
        backgroundColor: UIColor? = nil,
        textAlign: NSTextAlignment = .natural,
        lineHeight: CGFloat? = nil,
        whiteSpace: WhiteSpaceMode = .normal
    ) {
        self.fontSize = fontSize
        self.fontFamilies = fontFamilies
        self.fontWeight = fontWeight
        self.isItalic = isItalic
        self.color = color
        self.backgroundColor = backgroundColor
        self.textAlign = textAlign
        self.lineHeight = lineHeight
        self.whiteSpace = whiteSpace
    }
}

extension ComputedStyle {
    mutating func finalizeLineHeight(rootFontSize: CGFloat) {
        if let multiplier = lineHeightMultiplier {
            lineHeight = max(0, fontSize * multiplier)
            pendingLineHeightLength = nil
            return
        }
        guard let length = pendingLineHeightLength else { return }
        lineHeight = CSSLengthResolver.resolve(
            length,
            emBase: fontSize,
            remBase: rootFontSize,
            percentBase: fontSize
        ).map { max(0, $0) }
        // CSS length/percentage line-height inherits as its absolute computed
        // value, unlike a unitless multiplier.
        pendingLineHeightLength = nil
    }

    mutating func finalizeBorderLengths(rootFontSize: CGFloat) {
        func resolved(_ length: CSSLength?) -> CGFloat? {
            guard let length else { return nil }
            return CSSLengthResolver.resolve(
                length,
                emBase: fontSize,
                remBase: rootFontSize,
                percentBase: 0
            ).map { max(0, $0) }
        }
        if let value = resolved(pendingBorderTopWidth) { borderTopWidth = value }
        if let value = resolved(pendingBorderRightWidth) { borderRightWidth = value }
        if let value = resolved(pendingBorderBottomWidth) { borderBottomWidth = value }
        if let value = resolved(pendingBorderLeftWidth) { borderLeftWidth = value }
        if let value = resolved(pendingBorderRadius) { borderRadius = value }
        pendingBorderTopWidth = nil
        pendingBorderRightWidth = nil
        pendingBorderBottomWidth = nil
        pendingBorderLeftWidth = nil
        pendingBorderRadius = nil
    }

    func inherited(from parent: ComputedStyle) -> ComputedStyle {
        var style = ComputedStyle(
            fontSize: parent.fontSize,
            fontFamilies: parent.fontFamilies,
            fontWeight: parent.fontWeight,
            isItalic: parent.isItalic,
            color: parent.color,
            backgroundColor: nil,
            textAlign: parent.textAlign,
            lineHeight: parent.lineHeight,
            whiteSpace: parent.whiteSpace
        )
        style.configParagraphSpacing = parent.configParagraphSpacing
        style.configLineSpacing = parent.configLineSpacing
        style.configLetterSpacing = parent.configLetterSpacing
        style.configBold = parent.configBold
        style.rubyAlign = parent.rubyAlign
        style.rubyPosition = parent.rubyPosition
        style.rubyMerge = parent.rubyMerge
        style.textIndent = parent.textIndent
        style.lineHeightMultiplier = parent.lineHeightMultiplier
        style.pendingLineHeightLength = nil
        return style
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
             "q", "cite", "mark", "time", "sub", "sup", "abbr", "label", "br",
             "ruby", "rt", "rp":
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
        case "pre":
            style.whiteSpace = .pre
        default:
            break
        }
        return style
    }
}
