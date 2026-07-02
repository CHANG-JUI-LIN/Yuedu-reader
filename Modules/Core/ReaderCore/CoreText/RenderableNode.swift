import Foundation
import UIKit

// MARK: - RenderableNode
//
// Unified intermediate representation (IR) for the rendering pipeline.
//
// Design goals:
//   - All format parsers (TXT / EPUB / Web / Markdown / PDF) output this type
//   - All renderers (CoreText paged / UIScrollView scrolling / future PDF export) consume this type
//   - Format and rendering container are fully decoupled; adding a new format only requires a Converter, with zero renderer changes
//
// Migration strategy:
//   `HTMLAttributedStringBuilder.ASTNode` is converted to RenderableNode via a bridging extension,
//   allowing the HTML path to continue working during the transition without a big-bang rewrite.

/// Rendering IR node. `indirect` supports nested containers (block containing inline, etc.).
public indirect enum RenderableNode: Sendable {

    // MARK: Block-level

    /// Paragraph. Composed of a set of inline nodes, with paragraph spacing before and after.
    case paragraph([RenderableNode], style: RenderStyle = .body)

    /// Heading (h1-h6).
    case heading([RenderableNode], level: Int, style: RenderStyle = .none)

    /// Horizontal rule (<hr>).
    case horizontalRule(style: RenderStyle = .none)

    /// Blockquote (<blockquote>).
    case blockquote([RenderableNode])

    /// List item (<li>). bullet is the text prefix ("•" / "1.").
    case listItem([RenderableNode], bullet: String)

    /// Generic container (<div>/<section>/<article> etc., or wrapping node for format conversion).
    case block(tag: String, children: [RenderableNode], style: RenderStyle = .none)

    // MARK: Inline-level

    /// Plain text fragment.
    case text(String)

    /// Line break (<br>).
    case lineBreak

    /// Inline container (<span>/<em>/<strong>/<code> etc.).
    case inline(tag: String, children: [RenderableNode], style: RenderStyle = .none)

    /// Link (<a>), href is the target URL or anchor ID.
    case anchor(href: String, children: [RenderableNode])

    /// Ruby annotation (<ruby>base<rt>annotation</rt></ruby>).
    case ruby(base: [RenderableNode], text: String, style: RenderStyle = .none)

    /// Anchor target (corresponds to any element's id). The Renderer marks the anchor offset on the output.
    case anchorTarget(id: String, child: RenderableNode)

    // MARK: Media

    /// Image. src is a relative or absolute path; imageLoader handles async loading at the Renderer stage.
    /// svgContent carries inline SVG XML for rasterization instead of src loading.
    case image(src: String, alt: String, style: RenderStyle = .none, svgContent: String? = nil)

    /// MathML converted to LaTeX and rasterized with iosMath into a CoreText attachment.
    case mathML(latex: String, alt: String, style: RenderStyle = .none, displayMode: MathDisplayMode = .inline)

    /// Rasterized HTML table. Keeps row/cell semantics intact until the final renderer stage.
    case table(HTMLTableModel, style: RenderStyle = .none)

    /// EPUB audio/video attachment rendered as a tappable placeholder.
    case media(EPUBMediaAttachment, style: RenderStyle = .none)

    /// Unsupported EPUB interactive object, rendered as a static placeholder plus fallback content.
    case unsupportedInteractive(type: String, title: String, children: [RenderableNode], style: RenderStyle = .none)

    /// Paragraph-review badge (段評). Renders as a tappable inline count bubble; `reviewURL`
    /// carries the `ydreview://` action that opens the source's review web page.
    case commentBadge(count: String, reviewURL: String, title: String)

    // MARK: Special

    /// EPUB forced page break (page-break-before / page-break-after).
    case pageBreak

    /// Fallback node: unparseable HTML fragment, routed through the legacy HTMLAttributedStringBuilder path.
    case rawHTML(String)
}

// MARK: - RenderStyle (Node Style Attributes)
//
// Intentionally designed as a lightweight value type (struct + Sendable),
// transferable across actor / Task boundaries, with no UIKit dependency (UIColor → RenderColor).
// The Renderer stage converts RenderColor to UIColor.

public struct RenderStyle: Sendable {
    public var fontSizeMultiplier: CGFloat
    public var fontFamilies: [String]
    public var fontWeight: Int
    public var bold: Bool
    public var italic: Bool
    public var color: RenderColor?
    public var backgroundColor: RenderColor?
    /// CSS text-indent (em units)
    public var textIndent: CGFloat
    public var textAlign: RenderTextAlignment
    public var baseWritingDirection: NSWritingDirection
    public var lineHeightMultiplier: CGFloat
    /// CSS margin-left (blockquote, list indent)
    public var marginLeft: CGFloat
    /// CSS margin-right
    public var marginRight: CGFloat
    /// CSS raw width percentage (before resolution to points), used by hr dividers
    public var rawWidthPercent: CGFloat?
    /// CSS padding-top
    public var paddingTop: CGFloat
    /// CSS padding-left
    public var paddingLeft: CGFloat
    /// CSS padding-bottom
    public var paddingBottom: CGFloat
    /// CSS padding-right
    public var paddingRight: CGFloat
    /// Paragraph spacing before (multiplied by baseFontSize at render time)
    public var paragraphSpacingBefore: CGFloat
    /// Physical top offset. In vertical writing this is inline advance, not column spacing.
    public var visualOffsetBefore: CGFloat
    /// Paragraph spacing after
    public var paragraphSpacingAfter: CGFloat
    /// Explicit width/height (common for images / card blocks)
    public var width: CGFloat?
    public var height: CGFloat?
    /// Legado `style:"text"` image directive — render this image inline at the surrounding text's
    /// line height (a small character-sized icon, e.g. 段評 comment bubbles), regardless of the
    /// image's intrinsic size. Set from the click-config suffix; never from CSS.
    public var isTextSizedImage: Bool
    /// Opacity (common for images / decoration)
    public var opacity: CGFloat
    public var borderTopWidth: CGFloat
    public var borderBottomWidth: CGFloat
    public var borderLeftWidth: CGFloat
    public var borderRightWidth: CGFloat
    public var borderTopColor: RenderColor?
    public var borderBottomColor: RenderColor?
    public var borderLeftColor: RenderColor?
    public var borderRightColor: RenderColor?
    public var borderTopStyle: String?
    public var borderBottomStyle: String?
    public var borderLeftStyle: String?
    public var borderRightStyle: String?
    public var borderExplicitlyNone: Bool
    public var isHorizontallyCentered: Bool
    /// Pre-resolved :first-letter font-size multiplier. nil when no :first-letter matches.
    public var firstLetterFontSizeMultiplier: CGFloat?
    /// Pre-resolved :first-letter font-weight.
    public var firstLetterFontWeight: Int?
    /// Pre-resolved :first-letter color.
    public var firstLetterColor: RenderColor?
    public var underline: Bool
    public var strikethrough: Bool
    public var borderRadius: CGFloat
    public var isInlineAnnotation: Bool
    public var isVerticalWritingMode: Bool
    public var floatSide: RenderFloatSide?
    /// A block whose child paragraphs should not inherit reader default paragraph spacing.
    /// Used for EPUB chat-thread wrappers containing floated message bubbles.
    public var compactChildBlockSpacing: Bool
    public var avoidsPageBreakInside: Bool
    public var ssmlIPA: String?
    /// CSS `background-image` URL on a block (decorative frames / textures). The renderer loads
    /// it and the block-decoration system draws it behind the block's text (Phase 1, before glyphs).
    public var backgroundImageSource: String?
    /// Resolved CSS `background-size` in points (e.g. `3em 3em`). nil = intrinsic size.
    public var backgroundImageSize: CGSize?
    /// `background-size: 100% 100%` / `cover` — stretch to fill the decoration box.
    public var backgroundImageStretches: Bool
    /// `background-repeat: repeat` — tile the image across the decoration box.
    public var backgroundImageRepeats: Bool

    public init(
        fontSizeMultiplier: CGFloat = 1.0,
        fontFamilies: [String] = [],
        fontWeight: Int = 400,
        bold: Bool = false,
        italic: Bool = false,
        color: RenderColor? = nil,
        backgroundColor: RenderColor? = nil,
        textIndent: CGFloat = 0,
        textAlign: RenderTextAlignment = .natural,
        baseWritingDirection: NSWritingDirection = .natural,
        lineHeightMultiplier: CGFloat = 1.0,
        marginLeft: CGFloat = 0,
        marginRight: CGFloat = 0,
        rawWidthPercent: CGFloat? = nil,
        paddingTop: CGFloat = 0,
        paddingLeft: CGFloat = 0,
        paddingBottom: CGFloat = 0,
        paddingRight: CGFloat = 0,
        paragraphSpacingBefore: CGFloat = 0,
        visualOffsetBefore: CGFloat = 0,
        paragraphSpacingAfter: CGFloat = 0,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        isTextSizedImage: Bool = false,
        opacity: CGFloat = 1.0,
        borderTopWidth: CGFloat = 0,
        borderBottomWidth: CGFloat = 0,
        borderLeftWidth: CGFloat = 0,
        borderRightWidth: CGFloat = 0,
        borderTopColor: RenderColor? = nil,
        borderBottomColor: RenderColor? = nil,
        borderLeftColor: RenderColor? = nil,
        borderRightColor: RenderColor? = nil,
        borderTopStyle: String? = nil,
        borderBottomStyle: String? = nil,
        borderLeftStyle: String? = nil,
        borderRightStyle: String? = nil,
        borderExplicitlyNone: Bool = false,
        isHorizontallyCentered: Bool = false,
        firstLetterFontSizeMultiplier: CGFloat? = nil,
        firstLetterFontWeight: Int? = nil,
        firstLetterColor: RenderColor? = nil,
        underline: Bool = false,
        strikethrough: Bool = false,
        isInlineAnnotation: Bool = false,
        isVerticalWritingMode: Bool = false,
        borderRadius: CGFloat = 0,
        floatSide: RenderFloatSide? = nil,
        compactChildBlockSpacing: Bool = false,
        avoidsPageBreakInside: Bool = false,
        ssmlIPA: String? = nil,
        backgroundImageSource: String? = nil,
        backgroundImageSize: CGSize? = nil,
        backgroundImageStretches: Bool = false,
        backgroundImageRepeats: Bool = false
    ) {
        self.fontSizeMultiplier = fontSizeMultiplier
        self.fontFamilies = fontFamilies
        self.fontWeight = fontWeight
        self.bold = bold
        self.italic = italic
        self.color = color
        self.backgroundColor = backgroundColor
        self.textIndent = textIndent
        self.textAlign = textAlign
        self.baseWritingDirection = baseWritingDirection
        self.lineHeightMultiplier = lineHeightMultiplier
        self.marginLeft = marginLeft
        self.marginRight = marginRight
        self.rawWidthPercent = rawWidthPercent
        self.paddingTop = paddingTop
        self.paddingLeft = paddingLeft
        self.paddingBottom = paddingBottom
        self.paddingRight = paddingRight
        self.paragraphSpacingBefore = paragraphSpacingBefore
        self.visualOffsetBefore = visualOffsetBefore
        self.paragraphSpacingAfter = paragraphSpacingAfter
        self.width = width
        self.height = height
        self.isTextSizedImage = isTextSizedImage
        self.opacity = opacity
        self.borderTopWidth = borderTopWidth
        self.borderBottomWidth = borderBottomWidth
        self.borderLeftWidth = borderLeftWidth
        self.borderRightWidth = borderRightWidth
        self.borderTopColor = borderTopColor
        self.borderBottomColor = borderBottomColor
        self.borderLeftColor = borderLeftColor
        self.borderRightColor = borderRightColor
        self.borderTopStyle = borderTopStyle
        self.borderBottomStyle = borderBottomStyle
        self.borderLeftStyle = borderLeftStyle
        self.borderRightStyle = borderRightStyle
        self.borderExplicitlyNone = borderExplicitlyNone
        self.isHorizontallyCentered = isHorizontallyCentered
        self.firstLetterFontSizeMultiplier = firstLetterFontSizeMultiplier
        self.firstLetterFontWeight = firstLetterFontWeight
        self.firstLetterColor = firstLetterColor
        self.underline = underline
        self.strikethrough = strikethrough
        self.borderRadius = borderRadius
        self.isInlineAnnotation = isInlineAnnotation
        self.isVerticalWritingMode = isVerticalWritingMode
        self.floatSide = floatSide
        self.compactChildBlockSpacing = compactChildBlockSpacing
        self.avoidsPageBreakInside = avoidsPageBreakInside
        self.ssmlIPA = ssmlIPA
        self.backgroundImageSource = backgroundImageSource
        self.backgroundImageSize = backgroundImageSize
        self.backgroundImageStretches = backgroundImageStretches
        self.backgroundImageRepeats = backgroundImageRepeats
    }

    /// No style override (default for inline cases).
    public static let none = RenderStyle()

    /// Body paragraph style (default for block cases).
    public static let body = RenderStyle()
}

// MARK: - RenderTextAlignment

public enum RenderTextAlignment: Sendable {
    case natural
    case left
    case center
    case right
    case justify
}

public enum RenderFloatSide: Sendable {
    case left
    case right
}

public enum MathDisplayMode: Sendable {
    case inline
    case block
}

// MARK: - RenderColor (UIKit-independent color type)

public struct RenderColor: Sendable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Convert from UIColor.
    ///
    /// - Note: UIColor.getRed(_:green:blue:alpha:) is safe on any thread for programmatically created colors (RGB/hex).
    ///   Dynamic system colors (.systemBackground etc.) that need trait resolution should be called on the main thread.
    public init?(uiColor: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard uiColor.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        self.red = r; self.green = g; self.blue = b; self.alpha = a
    }

    /// Convert back to UIColor (used at Renderer stage).
    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
