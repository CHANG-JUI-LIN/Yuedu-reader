import CoreText
import SwiftSoup
import UIKit

/// HTML/CSS -> NSAttributedString builder for local EPUB.
/// This path intentionally avoids DTCoreText so that font mapping,
/// image-page detection, and style precedence stay under our control.
final class HTMLAttributedStringBuilder {
    static let internalLinkAttribute = NSAttributedString.Key("ReaderInternalLink")
    static let anchorIDAttribute = NSAttributedString.Key("ReaderAnchorID")
    static let hrDividerAttribute = NSAttributedString.Key("ReaderHRDivider")
    static let blockBackgroundColorAttribute = NSAttributedString.Key("ReaderBlockBackgroundColor")
    static let blockRenderStyleAttribute = NSAttributedString.Key("ReaderBlockRenderStyle")
    static let blockRenderIDAttribute = NSAttributedString.Key("ReaderBlockRenderID")
    /// Marks a range whose block paragraph style is final and must not be flattened by an enclosing
    /// block's segment flush. Set when an inline element (e.g. `<a>`) wraps `display:block` children
    /// (TOC `span.toc-label` / `span.toc-desc`): the child blocks keep their own indentation instead
    /// of inheriting the list item's. Inert in the final string (CoreText ignores unknown keys).
    static let blockParagraphLockAttribute = NSAttributedString.Key("ReaderBlockParagraphLock")
    /// Container-level decoration (coexists with blockRenderStyle). Used for parent div border/background that spans across block children.
    static let containerBlockRenderStyleAttribute = NSAttributedString.Key("ReaderContainerBlockRenderStyle")
    static let containerBlockRenderIDAttribute = NSAttributedString.Key("ReaderContainerBlockRenderID")
    /// Second container-level decoration for a decorated parent wrapping an already-decorated child.
    static let outerContainerBlockRenderStyleAttribute = NSAttributedString.Key("ReaderOuterContainerBlockRenderStyle")
    static let outerContainerBlockRenderIDAttribute = NSAttributedString.Key("ReaderOuterContainerBlockRenderID")
    /// Marker attribute for CSS-explicit foreground color. Ranges with this attribute are not overwritten by withUpdatedColors().
    static let cssSpecifiedForegroundColorAttribute = NSAttributedString.Key("ReaderCSSSpecifiedForegroundColor")
    /// Marker attribute for vertical spacer runs (CTRunDelegate that are NOT image placeholders).
    static let spacerRunAttribute = NSAttributedString.Key("ReaderSpacerRun")
    /// Marker attribute for vertical inline annotation runs (e.g. span.small notes).
    static let inlineAnnotationRunAttribute = NSAttributedString.Key("ReaderInlineAnnotationRun")
    /// Marker attribute for EPUB CSS-forced page boundaries.
    static let pageBreakAttribute = NSAttributedString.Key("ReaderForcedPageBreak")
    /// Marker attribute preserving HTML5 semantic element identity through CoreText rendering.
    static let semanticTagAttribute = NSAttributedString.Key("ReaderHTMLSemanticTag")
    /// Marker attribute for paragraph ranges inside compact author-layout blocks (for example
    /// 多看-style chat threads). The paginator must not inflate zero spacing on these ranges.
    static let compactBlockSpacingAttribute = NSAttributedString.Key("ReaderCompactBlockSpacing")
    /// IPA pronunciation hint parsed from SSML/PLS metadata for system TTS.
    static let ipaPronunciationAttribute = NSAttributedString.Key("ReaderIPAPronunciation")
    /// Marker attribute for unsupported interactive EPUB objects rendered as graceful placeholders.
    static let unsupportedInteractiveAttribute = NSAttributedString.Key("ReaderUnsupportedInteractive")
    /// Marker attribute for tappable EPUB audio/video placeholders.
    static let mediaAttachmentAttribute = NSAttributedString.Key("ReaderEPUBMediaAttachment")
    /// Marker attribute for a CSS-floated element (e.g. `img.left { float:left; width:50% }`). Value is a
    /// `FloatPlaceholder`. The marker itself is a zero-width character placed at the float's anchor point in
    /// the text flow; the paginator carves a notch out of the page so following text wraps beside the float.
    static let floatAttribute = NSAttributedString.Key("ReaderFloatPlaceholder")
    static let rubyAnnotationAttribute = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
    /// Marker attribute drawing a border/background "chip" around an inline run (e.g. an EPUB
    /// `epub:type="pagebreak"` page-number badge). Value is an `InlineBorderBoxStyle`.
    static let inlineBorderBoxAttribute = NSAttributedString.Key("ReaderInlineBorderBox")
    /// Default tap-affordance color applied to a link's text *only* where the author hasn't set an
    /// explicit color (no `cssSpecifiedForegroundColorAttribute`). `.link` follows light/dark.
    static let defaultLinkColor = UIColor.link
    private static let paragraphSeparator = "\n"
    private static let lineSeparator = "\u{2028}"
    static let pageBreakMarker = "\u{200B}"

    /// Shared link resolution: extracts the internal-link href from an attributed string at the given character index.
    static func linkHref(at index: Int, in attributedString: NSAttributedString) -> String? {
        guard index >= 0, index < attributedString.length,
              let href = attributedString.attribute(
                  internalLinkAttribute,
                  at: index,
                  effectiveRange: nil
              ) as? String,
              !href.isEmpty
        else { return nil }
        return href
    }

    struct Config {
        var fontSize: CGFloat
        var lineHeightMultiple: CGFloat
        var lineSpacing: CGFloat
        var paragraphSpacing: CGFloat
        var firstLineIndent: CGFloat
        var textColor: UIColor
        var backgroundColor: UIColor
        var fontFamilyName: String?
        var renderWidth: CGFloat
        var writingMode: ReaderWritingMode = .horizontal
        var baseWritingDirection: NSWritingDirection = .natural
        var firstLetterRules: [CSSRule] = []
    }

    struct ImagePage {
        let source: String
        let image: UIImage?
    }

    struct ParsedHTML {
        let body: Element
        let rules: [CSSRule]
        let firstLetterRules: [CSSRule]
    }

    enum VerticalAlign {
        case baseline
        case `super`
        case sub
    }

    enum FloatSide {
        case left
        case right
    }

    /// Layout payload for a CSS-floated element (stored in `floatAttribute` on a zero-width marker run).
    /// `drawWidth`/`drawHeight` are the resolved on-page image size; margins are the float's CSS margins
    /// (the gutter between the float and the wrapped text). The paginator uses these to size the notch and
    /// position the drawn image.
    final class FloatPlaceholder {
        let side: FloatSide
        let image: UIImage?
        let drawWidth: CGFloat
        let drawHeight: CGFloat
        let marginLeft: CGFloat
        let marginRight: CGFloat
        let marginTop: CGFloat
        let marginBottom: CGFloat
        let source: String
        let alt: String?

        init(
            side: FloatSide,
            image: UIImage?,
            drawWidth: CGFloat,
            drawHeight: CGFloat,
            marginLeft: CGFloat,
            marginRight: CGFloat,
            marginTop: CGFloat,
            marginBottom: CGFloat,
            source: String,
            alt: String?
        ) {
            self.side = side
            self.image = image
            self.drawWidth = drawWidth
            self.drawHeight = drawHeight
            self.marginLeft = marginLeft
            self.marginRight = marginRight
            self.marginTop = marginTop
            self.marginBottom = marginBottom
            self.source = source
            self.alt = alt
        }
    }

    struct ResolvedStyle {
        var fontSize: CGFloat
        var fontFamilies: [String]
        var fontWeight: Int
        var isItalic: Bool
        var textColor: UIColor
        var textAlign: NSTextAlignment
        var baseWritingDirection: NSWritingDirection
        var textIndent: CGFloat
        var lineHeight: CGFloat
        /// Whether CSS explicitly specifies line-height (true = skip clamping)
        var lineHeightExplicit: Bool
        var paragraphSpacing: CGFloat
        var paragraphSpacingBefore: CGFloat
        var visualOffsetBefore: CGFloat
        /// margin-left (blockquote / nested list indent)
        var marginLeft: CGFloat
        /// List item bullet or ordinal string (e.g. "•" / "1."). nil means not a list item.
        var listBullet: String?
        /// CSS `list-style-type` (inherited). `"none"` suppresses the marker entirely — common in
        /// EPUB nav/TOC documents (`ol { list-style-type: none }`) that supply their own structure.
        var listStyleType: String? = nil
        var verticalAlign: VerticalAlign
        var isBlock: Bool
        var backgroundImage: String?
        /// Resolved CSS `background-size` in points (e.g. `3em 3em`). nil = intrinsic size.
        var backgroundImageSize: CGSize? = nil
        /// `background-size: 100% 100%` / `cover` — stretch to fill the decoration box.
        var backgroundImageStretches: Bool = false
        /// `background-repeat: repeat` — tile the image across the decoration box.
        var backgroundImageRepeats: Bool = false
        var backgroundFillColor: UIColor?
        var width: CGFloat?
        var height: CGFloat?
        var rawWidthPercent: CGFloat?
        var rawHeightPercent: CGFloat?
        var marginRight: CGFloat
        var paddingTop: CGFloat
        var paddingLeft: CGFloat
        var paddingBottom: CGFloat
        var paddingRight: CGFloat
        var isHorizontallyCentered: Bool
        var borderTopWidth: CGFloat
        var borderBottomWidth: CGFloat
        var borderLeftWidth: CGFloat
        var borderRightWidth: CGFloat
        var borderTopColor: UIColor?
        var borderBottomColor: UIColor?
        var borderLeftColor: UIColor?
        var borderRightColor: UIColor?
        var borderTopStyle: String?
        var borderBottomStyle: String?
        var borderLeftStyle: String?
        var borderRightStyle: String?
        var opacity: CGFloat
        /// CSS letter-spacing (px value). nil means use default tracking.
        var letterSpacing: CGFloat?
        /// Whether CSS explicitly specifies `color` (including inherited from CSS parent).
        /// withUpdatedColors() uses this to determine whether to preserve the original color.
        var hasCSSColor: Bool
        /// User-configured paragraph spacing, propagated from root and not overridden by CSS margin.
        /// Ensures the default <p> spacing is not zeroed out by EPUB CSS body/div margin:0.
        var configParagraphSpacing: CGFloat
        /// Non-nil when paragraph matches a :first-letter CSS rule. Applied to the first visible character.
        var firstLetterDeclarations: [String: String]?
        /// Resolved :first-letter style properties (nil when no :first-letter matches).
        var firstLetterFontSizeMultiplier: CGFloat?
        var firstLetterFontWeight: Int?
        var firstLetterColor: UIColor?
        var underline: Bool
        var strikethrough: Bool
        /// Accumulated margins from ancestor block containers.
        /// CoreText uses a single frame so parent block margins must be added to child paragraph indents.
        var inheritedBlockMarginLeft: CGFloat
        var inheritedBlockMarginRight: CGFloat
        var borderRadius: CGFloat
        /// Detected from CSS `writing-mode: vertical-rl` on this element.
        var isVerticalWritingMode: Bool = false
        var pageBreakBefore: Bool = false
        var pageBreakAfter: Bool = false
        var avoidsPageBreakInside: Bool = false
        /// CSS `float` side (`left`/`right`). Non-nil makes the element a float: the builder emits a
        /// zero-width marker and the paginator wraps surrounding text around it. Not inherited.
        var floatSide: FloatSide? = nil
        /// True when the author explicitly removed the border via `border: none` / `border-style: none`
        /// (keyword `none`/`hidden`). Used so a borderless, background-less `<hr>` renders as an
        /// invisible separator instead of a stray rule (e.g. calibre's `.transition` scene break).
        var borderExplicitlyNone: Bool = false
        /// True when the element generates no boxes and must be skipped entirely:
        /// CSS `display: none` or the HTML `hidden` attribute (e.g. EPUB nav `page-list` /
        /// `landmarks` blocks, which would otherwise paginate into many blank pages).
        var isHidden: Bool = false
    }

    /// Visual style for an inline border/background "chip" (stored in inlineBorderBoxAttribute).
    /// Padding is drawn as a visual inset around the run's glyphs — it does not reserve layout space,
    /// which is exactly right for self-contained badges like EPUB page-number markers.
    struct InlineBorderBoxStyle {
        let borderColor: UIColor
        let borderWidth: CGFloat
        let cornerRadius: CGFloat
        let fillColor: UIColor?
        let paddingHorizontal: CGFloat
        let paddingVertical: CGFloat
    }

    /// Visual style for HR dividers (stored in hrDividerAttribute).
    struct HRDividerStyle {
        let color: UIColor?
        let lineWidth: CGFloat?
        let ruleWidth: CGFloat?
        let ruleWidthPercent: CGFloat?
        let marginLeft: CGFloat
        let marginRight: CGFloat
        let inheritedBlockMarginLeft: CGFloat
        let inheritedBlockMarginRight: CGFloat
        let alignment: NSTextAlignment
        let isHorizontallyCentered: Bool
        let lineDash: [CGFloat]
    }

    struct BlockRenderStyle {
        struct BlockImage {
            let image: UIImage?
            let source: String
            let drawSize: CGSize
            let opacity: CGFloat
            let alignment: NSTextAlignment
            let paddingTop: CGFloat
            let paddingLeft: CGFloat
            let paddingBottom: CGFloat
            let paddingRight: CGFloat
        }

        /// CSS `background-image` on a decorated block — drawn inside the decoration box
        /// (between the fill and the border), behind the block's text.
        struct BackgroundImage {
            let image: UIImage?
            /// Resolved `background-size` in points. nil = intrinsic size.
            let size: CGSize?
            /// `100% 100%` / `cover` — stretch to fill the box.
            let stretches: Bool
            /// `background-repeat: repeat` — tile across the box.
            let repeats: Bool
        }

        let backgroundFillColor: UIColor?
        let borderTopWidth: CGFloat
        let borderBottomWidth: CGFloat
        let borderLeftWidth: CGFloat
        let borderRightWidth: CGFloat
        let borderTopColor: UIColor?
        let borderBottomColor: UIColor?
        let borderLeftColor: UIColor?
        let borderRightColor: UIColor?
        let width: CGFloat?
        let height: CGFloat?
        let textAlign: NSTextAlignment
        let isHorizontallyCentered: Bool
        let paragraphSpacingBefore: CGFloat
        let visualOffsetBefore: CGFloat
        let paddingTop: CGFloat
        let paddingLeft: CGFloat
        let paddingBottom: CGFloat
        let paddingRight: CGFloat
        let blockImage: BlockImage?
        let borderRadius: CGFloat
        let avoidsPageBreakInside: Bool
        /// When true the paginator sizes/positions the decoration box to the *actual* laid-out
        /// glyph bounds of each line instead of `width` + `textAlign`. Chat bubbles use this so a
        /// shrink-to-fit box hugs its text exactly, immune to sub-pixel column-width rounding
        /// (otherwise a right-floated box drifts a few points and clips its last glyph).
        var hugsContent: Bool = false
        var backgroundImage: BackgroundImage? = nil

        var hasVisualDecoration: Bool {
            backgroundFillColor != nil
                || borderTopWidth > 0 || borderBottomWidth > 0
                || borderLeftWidth > 0 || borderRightWidth > 0
                || blockImage != nil
                || backgroundImage?.image != nil
        }

        func withBackgroundFillColor(_ color: UIColor?) -> BlockRenderStyle {
            BlockRenderStyle(
                backgroundFillColor: color,
                borderTopWidth: borderTopWidth,
                borderBottomWidth: borderBottomWidth,
                borderLeftWidth: borderLeftWidth,
                borderRightWidth: borderRightWidth,
                borderTopColor: borderTopColor,
                borderBottomColor: borderBottomColor,
                borderLeftColor: borderLeftColor,
                borderRightColor: borderRightColor,
                width: width,
                height: height,
                textAlign: textAlign,
                isHorizontallyCentered: isHorizontallyCentered,
                paragraphSpacingBefore: paragraphSpacingBefore,
                visualOffsetBefore: visualOffsetBefore,
                paddingTop: paddingTop,
                paddingLeft: paddingLeft,
                paddingBottom: paddingBottom,
                paddingRight: paddingRight,
                blockImage: blockImage,
                borderRadius: borderRadius,
                avoidsPageBreakInside: avoidsPageBreakInside,
                hugsContent: hugsContent,
                backgroundImage: backgroundImage
            )
        }
    }

    indirect enum ASTNode {
        case text(TextNode)
        case lineBreak(BreakNode)
        case pageBreak
        case element(ElementNode)
    }

    struct TextNode {
        let text: String
    }

    struct BreakNode {
        let resolvedStyle: ResolvedStyle
    }

    struct ElementNode {
        let tag: String
        let id: String
        let classes: [String]
        let attributes: [String: String]
        let resolvedStyle: ResolvedStyle
        let children: [ASTNode]
        var svgContent: String?
    }

    var imageLoader: ((String) async -> UIImage?)?
    var cssLoader: ((String) async -> String?)?
    var mediaURLResolver: ((String) -> String?)?
    var resolvedFontFamily: ((String) -> String?)?
    var resolvedFont: (([String], Int, Bool, CGFloat) -> UIFont?)?
    /// Set to true after buildStyledAST if CSS writing-mode: vertical-rl is detected on the body element.
    var detectedVerticalWritingMode = false

    private let domParser = HTMLBuilderDOMParser()
    private let styleResolver = HTMLBuilderStyleResolver()
    private let cssPropertyRegistry = HTMLCSSPropertyApplierRegistry.defaultRegistry
    private var epubFlowLogCounts: [String: Int] = [:]
    private static let dirtyCJKSpaceRegex: NSRegularExpression? = {
        // Clean up spaces (including NBSP / &nbsp;) between CJK characters that may come from conversion artifacts, preventing excessive justified spacing.
        let pattern = "(?<=\\p{Han})(?:[\\s\\u{00A0}]+|&nbsp;+|&#160;+)+(?=\\p{Han})"
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()


    func buildStyledAST(html: String, config: Config) async -> ElementNode? {
        epubFlowLog("buildStyledAST.begin htmlLen=\(html.count) configWritingMode=\(config.writingMode) fontSize=\(config.fontSize) renderWidth=\(config.renderWidth)")
        let sanitizedHTML = cleanDirtySpacesInHTML(html)
        guard let parsed = await domParser.parse(
            html: sanitizedHTML,
            collectStyles: { document in
                await self.collectStyles(from: document)
            }
        ) else {
            return nil
        }

        var mergedConfig = config
        mergedConfig.firstLetterRules = parsed.firstLetterRules

        let ast = await styleResolver.buildAST(
            from: parsed,
            config: mergedConfig,
            makeRootStyle: { config in
                self.makeRootStyle(config: config)
            },
            resolveStyle: { element, parent, rules, rootFontSize, parentElement, config in
                self.resolvedStyle(
                    for: element,
                    parent: parent,
                    rules: rules,
                    rootFontSize: rootFontSize,
                    parentElement: parentElement,
                    config: config
                )
            },
            buildChildren: { nodes, parentStyle, rules, rootFontSize, parentElement, config in
                return await self.buildChildren(
                    from: nodes,
                    parentStyle: parentStyle,
                    rules: rules,
                    rootFontSize: rootFontSize,
                    parentElement: parentElement,
                    config: config
                )
            },
            makeAttributeMap: { element in
                self.makeAttributeMap(for: element)
            }
        )

        if ast.resolvedStyle.isVerticalWritingMode {
            detectedVerticalWritingMode = true
        }
        epubFlowLog("buildStyledAST.done bodyClass=\(ast.classes.joined(separator: ".")) bodyVertical=\(ast.resolvedStyle.isVerticalWritingMode) cssDetectedVertical=\(detectedVerticalWritingMode) childCount=\(ast.children.count)")
        return ast
    }

    func imagePage(from body: ElementNode) async -> ImagePage? {
        await extractImagePage(from: body)
    }

    func pageBackgroundImage(from body: ElementNode) async -> UIImage? {
        await loadBackgroundImage(from: body)
    }

    func anchorOffsets(in attributedString: NSAttributedString) -> [String: Int] {
        collectAnchorOffsets(in: attributedString)
    }

    private func collectStyles(from document: Document) async -> [String] {
        var styles: [String] = []
        if let head = document.head() {
            let styleTags = (try? head.select("style").array()) ?? []
            if !styleTags.isEmpty {
                epubFlowLog("css.inlineStyleTags count=\(styleTags.count)")
            }
            for styleTag in styleTags {
                let css = (try? styleTag.html()) ?? ""
                if !css.isEmpty {
                    epubFlowLog("css.inline len=\(css.count) hasVertical=\(cssContainsVerticalWritingMode(css))")
                    scanCSSForVerticalWritingMode(css)
                    styles.append(css)
                }
            }

            let links = (try? head.select("link[rel=stylesheet]").array()) ?? []
            epubFlowLog("css.links count=\(links.count)")
            for link in links {
                let href = (try? link.attr("href")) ?? ""
                guard !href.isEmpty else { continue }
                epubFlowLog("css.fetch href=\(href)")
                guard let cssText = await cssLoader?(href), !cssText.isEmpty else {
                    epubFlowLog("css.failed href=\(href)")
                    continue
                }
                epubFlowLog("css.loaded href=\(href) len=\(cssText.count) hasVertical=\(cssContainsVerticalWritingMode(cssText))")
                scanCSSForVerticalWritingMode(cssText)
                styles.append(cssText)
            }
        }
        return styles
    }

    private func scanCSSForVerticalWritingMode(_ css: String) {
        guard !detectedVerticalWritingMode else { return }
        guard let matchedProperty = firstVerticalWritingModeProperty(in: css) else { return }
        epubFlowLog("css.verticalWritingModeDetected property=\(matchedProperty)")
        detectedVerticalWritingMode = true
    }

    private func cssContainsVerticalWritingMode(_ css: String) -> Bool {
        firstVerticalWritingModeProperty(in: css) != nil
    }

    private func firstVerticalWritingModeProperty(in css: String) -> String? {
        let patterns: [(String, String)] = [
            ("-epub-writing-mode", #"-epub-writing-mode\s*:\s*vertical-rl"#),
            ("-webkit-writing-mode", #"-webkit-writing-mode\s*:\s*vertical-rl"#),
            ("writing-mode", #"(^|[;\s{])writing-mode\s*:\s*vertical-rl"#),
        ]
        for (property, pattern) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               regex.firstMatch(in: css, range: NSRange(css.startIndex..., in: css)) != nil {
                return property
            }
        }
        return nil
    }

    private func epubFlowLog(_ message: @autoclosure () -> String) {
        CoreTextPaginator.debugVerticalLog("EPUBFLOW \(message())")
    }

    private func shouldLogEPUBFlow(key: String, limit: Int = 3) -> Bool {
        let current = epubFlowLogCounts[key, default: 0]
        epubFlowLogCounts[key] = current + 1
        return current < limit
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

    private func styleProbeKey(tag: String, classes: [String], style: ResolvedStyle) -> String? {
        let classSet = Set(classes)
        if tag == "body" && classSet.contains("calibre") { return "style.body.calibre" }
        if tag == "p" && classSet.contains("calibre7") { return "style.p.calibre7" }
        if tag == "p" && classSet.contains("msonormal") { return "style.p.msonormal" }
        if (tag == "h2" || tag == "h3") && classSet.contains("calibre6") { return "style.heading.calibre6" }
        if tag == "span" && classSet.contains(where: { $0 == "small" || $0.hasPrefix("small") }) { return "style.span.small" }
        if tag == "img" && classSet.contains("font_patch") { return "style.img.font_patch" }
        if style.isVerticalWritingMode { return "style.vertical.\(tag)" }
        return nil
    }

    private func styleProbeSummary(_ style: ResolvedStyle) -> String {
        let width = style.width.map { "\($0)" } ?? "nil"
        let height = style.height.map { "\($0)" } ?? "nil"
        return "fontWeight=\(style.fontWeight) isItalic=\(style.isItalic) fontFamilies=\(style.fontFamilies) fontSize=\(style.fontSize) lineHeight=\(style.lineHeight) lineHeightExplicit=\(style.lineHeightExplicit) textIndent=\(style.textIndent) direction=\(style.baseWritingDirection.rawValue) paraBefore=\(style.paragraphSpacingBefore) paraAfter=\(style.paragraphSpacing) paddingL=\(style.paddingLeft) paddingR=\(style.paddingRight) width=\(width) height=\(height) block=\(style.isBlock) vertical=\(style.isVerticalWritingMode)"
    }

    private func buildChildren(
        from nodes: [Node],
        parentStyle: ResolvedStyle,
        rules: [CSSRule],
        rootFontSize: CGFloat,
        parentElement: Element?,
        config: Config
    ) async -> [ASTNode] {
        var result: [ASTNode] = []
        for node in nodes {
            if let textNode = node as? SwiftSoup.TextNode {
                let text = textNode.getWholeText()
                if !text.isEmpty {
                    result.append(.text(TextNode(text: text)))
                }
                continue
            }

            guard let element = node as? Element else { continue }
            let tag = element.tagName().lowercased()
            if tag == "script" || tag == "style" || tag == "noscript" {
                continue
            }
            if tag == "br" {
                let style = resolvedStyle(
                    for: element,
                    parent: parentStyle,
                    rules: rules,
                    rootFontSize: rootFontSize,
                    parentElement: parentElement,
                    config: config
                )
                result.append(.lineBreak(BreakNode(resolvedStyle: style)))
                continue
            }

            if tag == "svg" {
                let svgString: String
                do {
                    svgString = try element.outerHtml()
                } catch {
                    svgString = ""
                }
                let style = resolvedStyle(
                    for: element,
                    parent: parentStyle,
                    rules: rules,
                    rootFontSize: rootFontSize,
                    parentElement: parentElement,
                    config: config
                )
                if style.isHidden {
                    continue
                }
                let children = await buildChildren(
                    from: element.getChildNodes(),
                    parentStyle: style,
                    rules: rules,
                    rootFontSize: rootFontSize,
                    parentElement: element,
                    config: config
                )
                result.append(
                    .element(
                        ElementNode(
                            tag: tag,
                            id: element.id(),
                            classes: Array((try? element.classNames()) ?? []),
                            attributes: makeAttributeMap(for: element),
                            resolvedStyle: style,
                            children: children,
                            svgContent: svgString
                        )
                    )
                )
                continue
            }

            let style = resolvedStyle(
                for: element,
                parent: parentStyle,
                rules: rules,
                rootFontSize: rootFontSize,
                parentElement: parentElement,
                config: config
            )
            // `display: none` / HTML `hidden`: drop the element and its whole subtree before it can
            // emit nodes (or a page break) — both render paths consume this AST, so skipping here
            // covers legacy renderNode and the RenderableNode IR alike.
            if style.isHidden {
                continue
            }
            if style.pageBreakBefore {
                result.append(.pageBreak)
            }
            let children = await buildChildren(
                from: element.getChildNodes(),
                parentStyle: style,
                rules: rules,
                rootFontSize: rootFontSize,
                parentElement: element,
                config: config
            )
            result.append(
                .element(
                    ElementNode(
                        tag: tag,
                        id: element.id(),
                        classes: Array((try? element.classNames()) ?? []),
                        attributes: makeAttributeMap(for: element),
                        resolvedStyle: style,
                        children: children
                    )
                )
            )
            if style.pageBreakAfter {
                result.append(.pageBreak)
            }
        }
        return result
    }



    /// A decorated container (border/background/padding wrapping block children, e.g. an
    /// `aside.note` callout) draws its box by insetting the union of its child block lines
    /// outward by border + padding. But each child block carries its own paragraph style,
    /// so the container's own top/bottom margin + padding + border is never reserved as
    /// vertical space — the drawn box then butts against (or overlaps) the neighbouring
    /// block above/below, and adjacent callouts collide. Fold that inset into the first
    /// child's `paragraphSpacingBefore` and the last child's `paragraphSpacing`. Shared by
    /// both render pipelines (legacy `renderNode` and the RenderableNode IR renderer).
    ///
    /// CSS vertical margins collapse (only the larger margin survives between adjacent
    /// block-level elements). In CoreText, margin/padding/border all compound via
    /// `paragraphSpacingBefore` / `paragraphSpacing`. By separating the collapsible margin
    /// from non-collapsible padding+border, we match the CSS box model: child margin and
    /// container margin collapse to `max()`, then container padding+border are added.
    static func reserveContainerBlockInsets(
        in output: NSMutableAttributedString,
        collapsibleTop: CGFloat,
        collapsibleBottom: CGFloat,
        paddingTop: CGFloat,
        paddingBottom: CGFloat,
        borderTopWidth: CGFloat,
        borderBottomWidth: CGFloat
    ) {
        guard output.length > 0 else { return }
        let nonCollapsibleTop = paddingTop + borderTopWidth
        let nonCollapsibleBottom = paddingBottom + borderBottomWidth

        var firstRange = NSRange()
        let firstParagraph = output.attribute(.paragraphStyle, at: 0, effectiveRange: &firstRange) as? NSParagraphStyle
        CoreTextPaginator.debugVerticalLog(
            "reserveContainer beforeTop firstBefore=\(firstParagraph?.paragraphSpacingBefore ?? -1) firstAfter=\(firstParagraph?.paragraphSpacing ?? -1) range=(\(firstRange.location),\(firstRange.length)) collapsibleTop=\(collapsibleTop) collapsibleBottom=\(collapsibleBottom) nonCollapsibleTop=\(nonCollapsibleTop) nonCollapsibleBottom=\(nonCollapsibleBottom)"
        )
        if collapsibleTop > 0 || nonCollapsibleTop > 0 {
            var range = NSRange(location: 0, length: 0)
            if let para = output.attribute(.paragraphStyle, at: 0, effectiveRange: &range) as? NSParagraphStyle,
               let mutable = para.mutableCopy() as? NSMutableParagraphStyle {
                let current = mutable.paragraphSpacingBefore
                let collapsed = max(current, collapsibleTop)
                mutable.paragraphSpacingBefore = collapsed + nonCollapsibleTop
                CoreTextPaginator.debugVerticalLog(
                    "reserveContainer top range=(\(range.location),\(range.length)) collapsible=\(collapsibleTop) nonCollapsible=\(nonCollapsibleTop) was=\(current) collapsed=\(collapsed) now=\(mutable.paragraphSpacingBefore)"
                )
                output.addAttribute(.paragraphStyle, value: mutable, range: range)
            }
        }
        if collapsibleBottom > 0 || nonCollapsibleBottom > 0 {
            var range = NSRange(location: 0, length: 0)
            if let para = output.attribute(.paragraphStyle, at: output.length - 1, effectiveRange: &range) as? NSParagraphStyle,
               let mutable = para.mutableCopy() as? NSMutableParagraphStyle {
                let current = mutable.paragraphSpacing
                let collapsed = max(current, collapsibleBottom)
                mutable.paragraphSpacing = collapsed + nonCollapsibleBottom
                CoreTextPaginator.debugVerticalLog(
                    "reserveContainer bottom range=(\(range.location),\(range.length)) collapsible=\(collapsibleBottom) nonCollapsible=\(nonCollapsibleBottom) was=\(current) collapsed=\(collapsed) now=\(mutable.paragraphSpacing)"
                )
                output.addAttribute(.paragraphStyle, value: mutable, range: range)
            }
        }
    }

    /// `cssSpecifiedForegroundColorAttribute` too so it survives theme recoloring
    /// (`CoreTextPaginator.withUpdatedColors` only preserves marked ranges). Call only after
    /// `linkContentIsUnstyled` has confirmed the author left the link untouched.
    static func applyDefaultLinkColor(to attributed: NSMutableAttributedString) {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return }
        attributed.addAttribute(.foregroundColor, value: defaultLinkColor, range: fullRange)
        attributed.addAttribute(cssSpecifiedForegroundColorAttribute, value: defaultLinkColor, range: fullRange)
    }

    /// True only when the author left the link's content visually untouched: every run uses the
    /// inherited base font (no bold/italic/size/family change) and carries no author color,
    /// underline, strikethrough, background, inline chip, or attachment. A link the author *did*
    /// style — bold text, an italic/sized descendant (e.g. a TOC `span.toc-desc`), a custom color —
    /// is left exactly as authored and gets no default tint.
    static func linkContentIsUnstyled(_ attributed: NSAttributedString, baseFont: UIFont) -> Bool {
        let fullRange = NSRange(location: 0, length: attributed.length)
        guard fullRange.length > 0 else { return false }
        var unstyled = true
        attributed.enumerateAttributes(in: fullRange, options: []) { attrs, _, stop in
            if attrs[cssSpecifiedForegroundColorAttribute] != nil
                || attrs[.underlineStyle] != nil
                || attrs[.strikethroughStyle] != nil
                || attrs[.backgroundColor] != nil
                || attrs[inlineBorderBoxAttribute] != nil
                || attrs[mediaAttachmentAttribute] != nil
                || attrs[.attachment] != nil {
                unstyled = false
                stop.pointee = true
                return
            }
            if let font = attrs[.font] as? UIFont, !fontMatchesBase(font, baseFont) {
                unstyled = false
                stop.pointee = true
            }
        }
        return unstyled
    }

    /// Compares two fonts ignoring everything but size and bold/italic — the traits an author would
    /// change to "style" a link. Family is intentionally ignored (system font naming is noisy).
    private static func fontMatchesBase(_ font: UIFont, _ base: UIFont) -> Bool {
        guard abs(font.pointSize - base.pointSize) < 0.5 else { return false }
        let mask: UIFontDescriptor.SymbolicTraits = [.traitBold, .traitItalic]
        return font.fontDescriptor.symbolicTraits.intersection(mask)
            == base.fontDescriptor.symbolicTraits.intersection(mask)
    }


    static func makePageBreakMarker(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let marker = NSMutableAttributedString(string: pageBreakMarker, attributes: attributes)
        marker.addAttribute(pageBreakAttribute, value: true, range: NSRange(location: 0, length: marker.length))
        marker.addAttribute(.foregroundColor, value: UIColor.clear, range: NSRange(location: 0, length: marker.length))
        return marker
    }

    static func makeRubyAnnotation(text: String) -> CTRubyAnnotation {
        let attributes: [CFString: Any] = [
            kCTRubyAnnotationSizeFactorAttributeName: 0.85,
            kCTRubyAnnotationScaleToFitAttributeName: false,
        ]
        return CTRubyAnnotationCreateWithAttributes(
            .center,
            .auto,
            .before,
            text as CFString,
            attributes as CFDictionary
        )
    }



    static func isSemanticHTML5Tag(_ tag: String) -> Bool {
        switch tag {
        case "article", "aside", "details", "figcaption", "figure", "footer", "header",
             "main", "mark", "nav", "section", "summary", "time", "audio", "video", "table":
            return true
        default:
            return false
        }
    }




    private func isForcedPageBreakValue(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "always"
            || value == "page"
            || value == "left"
            || value == "right"
            || value == "recto"
            || value == "verso"
    }

    private func isAvoidPageBreakInsideValue(_ rawValue: String?) -> Bool {
        guard let rawValue else { return false }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "avoid" || value == "avoid-page"
    }

    private func extractImagePage(from body: ElementNode) async -> ImagePage? {
        guard let payload = imagePagePayload(from: body.children) else {
            return nil
        }

        let imageNode = payload.imageElement
        let src = imageSource(from: imageNode)
        guard !src.isEmpty else { return nil }
        let image = await imageLoader?(src)
        return ImagePage(source: src, image: image)
    }

    private func loadBackgroundImage(from body: ElementNode) async -> UIImage? {
        guard let src = body.resolvedStyle.backgroundImage, !src.isEmpty else { return nil }
        return await imageLoader?(src)
    }

    func backgroundImageSource(from body: ElementNode) -> String? {
        guard let src = body.resolvedStyle.backgroundImage, !src.isEmpty else { return nil }
        return src
    }


    private struct ImageOnlyBlockPayload {
        let imageElement: ElementNode
        let linkHref: String?
    }


    private func imagePagePayload(
        from nodes: [ASTNode],
        inheritedLinkHref: String? = nil
    ) -> ImageOnlyBlockPayload? {
        let renderables = nonWhitespaceNodes(from: nodes)
        guard renderables.count == 1,
              case .element(let element) = renderables[0]
        else {
            return nil
        }

        if element.tag == "img" || element.tag == "image" {
            return ImageOnlyBlockPayload(imageElement: element, linkHref: inheritedLinkHref)
        }

        if element.tag == "svg" {
            return ImageOnlyBlockPayload(
                imageElement: embeddedSVGImageElement(in: element) ?? element,
                linkHref: inheritedLinkHref
            )
        }

        if element.tag == "a" {
            return imagePagePayload(
                from: element.children,
                inheritedLinkHref: element.attributes["href"] ?? inheritedLinkHref
            )
        }

        if element.tag == "body" || isPlainImagePageWrapper(element) {
            return imagePagePayload(
                from: element.children,
                inheritedLinkHref: inheritedLinkHref
            )
        }

        return nil
    }

    private func nonWhitespaceNodes(from nodes: [ASTNode]) -> [ASTNode] {
        nodes.compactMap { node in
            switch node {
            case .text(let textNode):
                return textNode.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : node
            case .lineBreak, .pageBreak:
                return nil
            case .element:
                return node
            }
        }
    }

    private func isPlainImagePageWrapper(_ element: ElementNode) -> Bool {
        guard element.tag == "div" else { return false }
        return element.id.isEmpty
            && element.classes.isEmpty
            && element.attributes["style"] == nil
    }

    private func imageSource(from element: ElementNode) -> String {
        let directSource = element.attributes["src"]
            ?? element.attributes["xlink:href"]
            ?? element.attributes["href"]
        if let directSource, !directSource.isEmpty {
            return directSource
        }
        if element.tag == "svg", let imageElement = embeddedSVGImageElement(in: element) {
            return imageSource(from: imageElement)
        }
        return ""
    }

    private func embeddedSVGImageElement(in element: ElementNode) -> ElementNode? {
        guard element.tag == "svg" else { return nil }
        return firstDescendantImageElement(in: element.children)
    }

    private func firstDescendantImageElement(in nodes: [ASTNode]) -> ElementNode? {
        for node in nodes {
            guard case .element(let element) = node else { continue }
            if element.tag == "image" || element.tag == "img" {
                return element
            }
            if let nested = firstDescendantImageElement(in: element.children) {
                return nested
            }
        }
        return nil
    }

    private func resolveSVGPresentationAttributes(
        _ element: ElementNode,
        style: inout ResolvedStyle,
        config: Config
    ) {
        // SVG width/height presentation attributes (not CSS)
        if style.width == nil, let svgW = element.attributes["width"],
           let w = resolveLength(svgW, currentFontSize: style.fontSize, rootFontSize: config.fontSize, relativeBase: config.renderWidth) {
            style.width = w
            if svgW.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%"), let pct = Double(svgW.trimmingCharacters(in: .whitespacesAndNewlines).dropLast()) {
                style.rawWidthPercent = CGFloat(pct)
            }
        }
        if style.height == nil, let svgH = element.attributes["height"],
           let h = resolveLength(svgH, currentFontSize: style.fontSize, rootFontSize: config.fontSize, relativeBase: config.renderWidth) {
            style.height = h
            if svgH.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("%"), let pct = Double(svgH.trimmingCharacters(in: .whitespacesAndNewlines).dropLast()) {
                style.rawHeightPercent = CGFloat(pct)
            }
        }
    }


    /// Bakes a synthetic oblique (italic) slant into `font` via a shear matrix. Needed because the
    /// reader draws with CoreText (`CTFrameDraw`), which ignores the `.obliqueness` attribute — the
    /// slant only renders if it lives in the font's transformation matrix. Size, descriptor, and the
    /// cascade (fallback) list are preserved; horizontal advances are unchanged, so pagination is not
    /// affected. `slant` is the shear ratio (tan of the angle); 0.2 ≈ 11° matches typical oblique.
    static func synthesizedObliqueFont(from font: UIFont, slant: CGFloat = 0.2) -> UIFont {
        var matrix = CGAffineTransform(a: 1, b: 0, c: slant, d: 1, tx: 0, ty: 0)
        let ctFont = CTFontCreateWithFontDescriptor(
            font.fontDescriptor as CTFontDescriptor, font.pointSize, &matrix
        )
        return ctFont as UIFont
    }

    private func resolvedStyle(
        for element: Element,
        parent: ResolvedStyle,
        rules: [CSSRule],
        rootFontSize: CGFloat,
        parentElement: Element?,
        config: Config
    ) -> ResolvedStyle {
        var style = inheritedStyle(from: parent, tag: element.tagName().lowercased())
        let pct = config.renderWidth
        apply(
            declarations: userAgentDeclarations(for: element.tagName().lowercased(), config: parent),
            to: &style,
            parentStyle: parent,
            rootFontSize: rootFontSize,
            percentageBase: pct
        )
        applyHTMLDirectionAttribute(from: element, to: &style, inheritedDirection: parent.baseWritingDirection)

        let matchedRules = rules
            .filter { $0.selector.matches(element: element, parent: parentElement) }
            .sorted { lhs, rhs in
                if lhs.specificity == rhs.specificity { return lhs.order < rhs.order }
                return lhs.specificity < rhs.specificity
            }
        for rule in matchedRules {
            apply(
                declarations: rule.declarations,
                to: &style,
                parentStyle: parent,
                rootFontSize: rootFontSize,
                percentageBase: pct
            )
        }

        let inlineStyle = CSSParser.parseDeclarations((try? element.attr("style")) ?? "")
        apply(
            declarations: inlineStyle,
            to: &style,
            parentStyle: parent,
            rootFontSize: rootFontSize,
            percentageBase: pct
        )

        // Match :first-letter rules and resolve font-size / font-weight / color
        if !config.firstLetterRules.isEmpty {
            let matchedFL = config.firstLetterRules
                .filter { $0.selector.matches(element: element, parent: parentElement) }
                .sorted { lhs, rhs in lhs.specificity < rhs.specificity }
            if !matchedFL.isEmpty {
                var merged: [String: String] = [:]
                for rule in matchedFL {
                    for (k, v) in rule.declarations { merged[k] = v }
                }
                style.firstLetterDeclarations = merged

                // Resolve font-size (supports % and em)
                if let fs = merged["font-size"],
                   let val = resolveLength(fs, currentFontSize: style.fontSize, rootFontSize: rootFontSize, relativeBase: style.fontSize) {
                    style.firstLetterFontSizeMultiplier = val / style.fontSize
                }
                // Resolve font-weight
                if let fw = merged["font-weight"] {
                    style.firstLetterFontWeight = cssFontWeight(fw, current: style.fontWeight)
                }
                // Resolve color
                if let clr = merged["color"], let c = parseColor(clr) {
                    style.firstLetterColor = c
                }
            }
        }

        // Determine bullet string based on parent element type.
        // `list-style-type: none` (inherited from the enclosing list) suppresses the marker — EPUB
        // nav/TOC documents rely on this, otherwise every entry gets a stray "1."/"•".
        if element.tagName().lowercased() == "li", style.listStyleType != "none" {
            let parentTag = parentElement?.tagName().lowercased() ?? ""
            if parentTag == "ol" {
                var idx = 1
                if let parent = parentElement {
                    var count = 0
                    for sibling in parent.children() {
                        if sibling === element { break }
                        if sibling.tagName().lowercased() == "li" { count += 1 }
                    }
                    idx = count + 1
                }
                style.listBullet = "\(idx).\t"
            } else {
                style.listBullet = "•\t"
            }
        }

        // Underline / strikethrough from semantic HTML tags (regardless of CSS)
        switch element.tagName().lowercased() {
        case "u", "ins": style.underline = true
        case "s", "strike", "del": style.strikethrough = true
        default: break
        }

        // The HTML `hidden` boolean attribute maps to the UA rule `[hidden] { display: none }`.
        // We don't run scripts, so the `removeHidden()` reveal pattern won't fire — but for a static
        // reader, honoring `hidden` is what keeps EPUB nav `page-list`/`landmarks` blocks (and other
        // off-screen content) from paginating into a run of blank pages. `until-found` stays visible.
        if element.hasAttr("hidden"),
           ((try? element.attr("hidden")) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "until-found" {
            style.isHidden = true
        }

        // The reader owns the page content box and already supplies its own page margins
        // (baked into `config.renderWidth`). Author margin/padding on the root `html`/`body`
        // element is page chrome authored for print/desktop and double-insets the text.
        // Worse, with em-based values on a phone — e.g. the figure-gallery sample's
        // `body { margin-left: 6em; margin-right: 16em }` (~22em ≈ a whole screen width) —
        // it collapses the content box to a sliver: text wraps one word per line (reads like a
        // vertical strip) and images clamp to ~nothing. Neutralize the horizontal box on
        // html/body so content fills the reader frame, matching Readium/Apple Books. Vertical
        // margins are kept so chapter-top spacing is unaffected.
        let elementTag = element.tagName().lowercased()
        if elementTag == "body" || elementTag == "html" {
            if (style.marginLeft != 0 || style.marginRight != 0 || style.paddingLeft != 0 || style.paddingRight != 0),
               shouldLogEPUBFlow(key: "style.\(elementTag).margin.neutralized") {
                epubFlowLog("\(elementTag).margin.neutralized marginL=\(style.marginLeft) marginR=\(style.marginRight) padL=\(style.paddingLeft) padR=\(style.paddingRight) renderWidth=\(config.renderWidth)")
            }
            style.marginLeft = 0
            style.marginRight = 0
            style.paddingLeft = 0
            style.paddingRight = 0
        }

        // Accumulate block margins so nested block children inherit the parent content box.
        // CoreText uses a single frame — parent block margins must compound into child paragraph indents.
        if style.isBlock {
            style.inheritedBlockMarginLeft = style.inheritedBlockMarginLeft + style.marginLeft
            style.inheritedBlockMarginRight = style.inheritedBlockMarginRight + style.marginRight
        }

        let tag = element.tagName().lowercased()
        let classes = Array((try? element.classNames()) ?? [])

        if let key = styleProbeKey(tag: tag, classes: classes, style: style),
           shouldLogEPUBFlow(key: key, limit: key == "style.span.small" ? 8 : 4) {
            let matchedDeclarationKeys = matchedRules
                .flatMap { $0.declarations.keys }
                .sorted()
                .joined(separator: ",")
            let inlineKeys = inlineStyle.keys.sorted().joined(separator: ",")
            let textPreview = key == "style.span.small"
                ? " text=\"\(debugTextPreview((try? element.text()) ?? ""))\""
                : ""
            epubFlowLog("style tag=\(tag) class=\(classes.joined(separator: ".")) matchedRules=\(matchedRules.count) declKeys=[\(matchedDeclarationKeys)] inlineKeys=[\(inlineKeys)] \(styleProbeSummary(style))\(textPreview)")
        }

        return style
    }

    private func applyHTMLDirectionAttribute(
        from element: Element,
        to style: inout ResolvedStyle,
        inheritedDirection: NSWritingDirection
    ) {
        guard element.hasAttr("dir") else { return }
        let raw = (try? element.attr("dir")) ?? ""
        let autoText = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto"
            ? ((try? element.text()) ?? "")
            : nil
        if let direction = HTMLWritingDirectionResolver.resolve(
            raw,
            autoText: autoText,
            inherited: inheritedDirection
        ) {
            style.baseWritingDirection = direction
        }
    }

    private func inheritedStyle(from parent: ResolvedStyle, tag: String) -> ResolvedStyle {
        ResolvedStyle(
            fontSize: parent.fontSize,
            fontFamilies: parent.fontFamilies,
            fontWeight: parent.fontWeight,
            isItalic: parent.isItalic,
            textColor: parent.textColor,
            textAlign: parent.textAlign,
            baseWritingDirection: parent.baseWritingDirection,
            textIndent: parent.textIndent,
            lineHeight: parent.lineHeight,
            lineHeightExplicit: parent.lineHeightExplicit,
            paragraphSpacing: parent.paragraphSpacing,
            paragraphSpacingBefore: 0,
            visualOffsetBefore: 0,
            marginLeft: 0,
            listBullet: nil,
            listStyleType: parent.listStyleType,
            verticalAlign: .baseline,
            isBlock: false,
            backgroundImage: nil,
            backgroundFillColor: nil,
            width: nil,
            height: nil,
            marginRight: 0,
            paddingTop: 0,
            paddingLeft: 0,
            paddingBottom: 0,
            paddingRight: 0,
            isHorizontallyCentered: false,
            borderTopWidth: 0,
            borderBottomWidth: 0,
            borderLeftWidth: 0,
            borderRightWidth: 0,
            borderTopColor: nil,
            borderBottomColor: nil,
            borderLeftColor: nil,
            borderRightColor: nil,
            borderTopStyle: nil,
            borderBottomStyle: nil,
            borderLeftStyle: nil,
            borderRightStyle: nil,
            opacity: 1,
            letterSpacing: parent.letterSpacing,
            hasCSSColor: parent.hasCSSColor,
            configParagraphSpacing: parent.configParagraphSpacing,
            firstLetterDeclarations: nil,
            firstLetterFontSizeMultiplier: nil,
            firstLetterFontWeight: nil,
            firstLetterColor: nil,
            underline: parent.underline,
            strikethrough: parent.strikethrough,
            inheritedBlockMarginLeft: parent.inheritedBlockMarginLeft,
            inheritedBlockMarginRight: parent.inheritedBlockMarginRight,
            borderRadius: parent.borderRadius,
            isVerticalWritingMode: parent.isVerticalWritingMode,
            pageBreakBefore: false,
            pageBreakAfter: false,
            avoidsPageBreakInside: false
        )
    }

    private func makeRootStyle(config: Config) -> ResolvedStyle {
        let defaultLineHeight = clampLineHeight(
            absolute: config.fontSize * max(1.0, config.lineHeightMultiple),
            fontSize: config.fontSize
        )
        return ResolvedStyle(
            fontSize: config.fontSize,
            fontFamilies: config.fontFamilyName.map { [$0] } ?? [],
            fontWeight: 400,
            isItalic: false,
            textColor: config.textColor,
            textAlign: .natural,
            baseWritingDirection: config.baseWritingDirection,
            textIndent: config.firstLineIndent,
            lineHeight: defaultLineHeight,
            lineHeightExplicit: false,
            paragraphSpacing: config.paragraphSpacing,
            paragraphSpacingBefore: 0,
            visualOffsetBefore: 0,
            marginLeft: 0,
            listBullet: nil,
            listStyleType: nil,
            verticalAlign: .baseline,
            isBlock: true,
            backgroundImage: nil,
            backgroundFillColor: nil,
            width: nil,
            height: nil,
            marginRight: 0,
            paddingTop: 0,
            paddingLeft: 0,
            paddingBottom: 0,
            paddingRight: 0,
            isHorizontallyCentered: false,
            borderTopWidth: 0,
            borderBottomWidth: 0,
            borderLeftWidth: 0,
            borderRightWidth: 0,
            borderTopColor: nil,
            borderBottomColor: nil,
            borderLeftColor: nil,
            borderRightColor: nil,
            borderTopStyle: nil,
            borderBottomStyle: nil,
            borderLeftStyle: nil,
            borderRightStyle: nil,
            opacity: 1,
            letterSpacing: nil,
            hasCSSColor: false,
            configParagraphSpacing: config.paragraphSpacing,
            firstLetterDeclarations: nil,
            firstLetterFontSizeMultiplier: nil,
            firstLetterFontWeight: nil,
            firstLetterColor: nil,
            underline: false,
            strikethrough: false,
            inheritedBlockMarginLeft: 0,
            inheritedBlockMarginRight: 0,
            borderRadius: 0,
            isVerticalWritingMode: false,
            pageBreakBefore: false,
            pageBreakAfter: false,
            avoidsPageBreakInside: false
        )
    }

    private func userAgentDeclarations(for tag: String, config: ResolvedStyle) -> [String: String] {
        switch tag {
        case "body":
            return ["display": "block"]
        case "div", "section", "article", "main", "header", "footer", "nav", "aside", "figure", "address":
            return [
                "display": "block",
                "line-height": "\(config.lineHeight / max(config.fontSize, 1))",
            ]
        case "figcaption":
            return [
                "display": "block",
                "font-size": "0.9em",
                "text-align": "center",
                "line-height": "\(config.lineHeight / max(config.fontSize, 1))",
            ]
        case "table":
            return [
                "display": "block",
                "text-indent": "0",
                "line-height": "\(config.lineHeight / max(config.fontSize, 1))",
            ]
        case "caption":
            return ["display": "block", "text-align": "center", "font-size": "0.9em"]
        case "thead", "tbody", "tfoot", "tr":
            return ["display": "block", "text-indent": "0"]
        case "th", "td":
            return ["display": "inline", "text-indent": "0"]
        case "p":
            return [
                "display": "block",
                "line-height": "\(config.lineHeight / max(config.fontSize, 1))",
                // User-configured paragraph spacing as <p> default, unaffected by EPUB CSS body/div margin:0
                "paragraph-spacing": "\(config.configParagraphSpacing)",
            ]
        case "blockquote":
            return [
                "display": "block",
                "margin-left": "2em",
                "line-height": "\(config.lineHeight / max(config.fontSize, 1))",
            ]
        case "h1":
            return ["display": "block", "font-size": "2em", "font-weight": "700", "text-indent": "0"]
        case "h2":
            return ["display": "block", "font-size": "1.5em", "font-weight": "700", "text-indent": "0"]
        case "h3":
            return ["display": "block", "font-size": "1.17em", "font-weight": "700", "text-indent": "0"]
        case "h4", "h5", "h6":
            return ["display": "block", "font-size": "1em", "font-weight": "700", "text-indent": "0"]
        case "ul", "ol":
            return ["display": "block", "margin-left": "1.5em"]
        case "li":
            return ["display": "block", "text-indent": "0"]
        case "hr":
            return ["display": "block", "border-top-width": "1", "border-top-color": "currentColor"]
        case "img", "image", "svg":
            return ["display": "inline-block"]
        case "b", "strong":
            return ["font-weight": "700"]
        case "i", "em", "cite":
            return ["font-style": "italic"]
        case "sup":
            return ["font-size": "0.75em", "vertical-align": "super"]
        case "sub":
            return ["font-size": "0.75em", "vertical-align": "sub"]
        case "mark":
            return ["background-color": "#fff2a8"]
        case "u", "ins":
            return ["text-decoration": "underline"]
        case "s", "strike", "del":
            return ["text-decoration": "line-through"]
        default:
            return [:]
        }
    }

    private func apply(
        declarations: [String: String],
        to style: inout ResolvedStyle,
        parentStyle: ResolvedStyle,
        rootFontSize: CGFloat,
        percentageBase: CGFloat? = nil
    ) {
        let applyContext = HTMLCSSApplyContext(
            parentStyle: parentStyle,
            rootFontSize: rootFontSize,
            resolveLength: { raw, currentFontSize, rootFontSize, relativeBase in
                self.resolveLength(
                    raw,
                    currentFontSize: currentFontSize,
                    rootFontSize: rootFontSize,
                    relativeBase: relativeBase
                )
            },
            parseColor: { self.parseColor($0) },
            cssFontWeight: { self.cssFontWeight($0, current: $1) },
            cssAlignment: { self.cssAlignment($0) },
            cssDisplayIsBlock: { self.cssDisplayIsBlock($0) },
            resolveLineHeight: { raw, fontSize, rootFontSize in
                self.resolveLineHeight(raw, fontSize: fontSize, rootFontSize: rootFontSize)
            },
            extractURL: { self.extractURL(from: $0) },
            parseEmbeddedColor: { self.parseEmbeddedColor(in: $0) }
        )
        let handledProperties = cssPropertyRegistry.apply(
            declarations: declarations,
            style: &style,
            context: applyContext
        )

        if !handledProperties.contains("font-size"), let fontSize = declarations["font-size"] {
            style.fontSize = resolveLength(
                fontSize,
                currentFontSize: parentStyle.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: parentStyle.fontSize
            ) ?? style.fontSize
        }

        if !handledProperties.contains("font-family"), let fontFamily = declarations["font-family"] {
            style.fontFamilies = fontFamily
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) }
        }
        if !handledProperties.contains("font-weight"), let weight = declarations["font-weight"] {
            style.fontWeight = cssFontWeight(weight, current: style.fontWeight)
        }
        if !handledProperties.contains("font-style"), let fontStyle = declarations["font-style"] {
            style.isItalic = fontStyle.lowercased().contains("italic")
        }
        if !handledProperties.contains("text-align"), let textAlign = declarations["text-align"] {
            style.textAlign = cssAlignment(textAlign)
        }
        if !handledProperties.contains("display"), let display = declarations["display"] {
            style.isHidden = display.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
            style.isBlock = cssDisplayIsBlock(display)
        }
        if let listStyleType = declarations["list-style-type"] {
            style.listStyleType = listStyleType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        // `list-style` shorthand: a `none` token clears the marker type (and image).
        if let listStyle = declarations["list-style"] {
            let tokens = listStyle.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            if tokens.contains("none") {
                style.listStyleType = "none"
            }
        }
        if !handledProperties.contains("color"), let color = declarations["color"], let resolved = parseColor(color) {
            style.textColor = resolved
            style.hasCSSColor = true
        }
        if let opacity = declarations["opacity"], let value = Double(opacity.trimmingCharacters(in: .whitespacesAndNewlines)) {
            style.opacity = max(0, min(1, CGFloat(value)))
        }
        if !handledProperties.contains("background-image"), let backgroundImage = declarations["background-image"] {
            style.backgroundImage = extractURL(from: backgroundImage)
        }
        if let background = declarations["background"] {
            if style.backgroundImage == nil {
                style.backgroundImage = extractURL(from: background)
            }
            if style.backgroundFillColor == nil {
                style.backgroundFillColor = parseEmbeddedColor(in: background)
            }
        }
        if let backgroundSize = declarations["background-size"] {
            let value = backgroundSize.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
            if value == "cover" || value == "contain" || parts.allSatisfy({ $0.hasSuffix("%") }) {
                // Percentage sizes track the box, not a fixed length — approximate by stretching
                // (the dominant duokan usage is `100% 100%` frame images).
                style.backgroundImageStretches = true
                style.backgroundImageSize = nil
            } else if let first = parts.first,
                      let w = resolveLength(first, currentFontSize: style.fontSize, rootFontSize: rootFontSize, relativeBase: style.fontSize, percentageBase: percentageBase) {
                let h = parts.dropFirst().first.flatMap {
                    resolveLength($0, currentFontSize: style.fontSize, rootFontSize: rootFontSize, relativeBase: style.fontSize, percentageBase: percentageBase)
                } ?? w
                style.backgroundImageStretches = false
                style.backgroundImageSize = CGSize(width: max(1, w), height: max(1, h))
            }
        }
        if let backgroundRepeat = declarations["background-repeat"] {
            let value = backgroundRepeat.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            style.backgroundImageRepeats = value == "repeat" || value == "repeat-x" || value == "repeat-y"
        }
        if !handledProperties.contains("background-color"), let backgroundColor = declarations["background-color"],
           let resolved = parseColor(backgroundColor) {
            style.backgroundFillColor = resolved
        }
        if let width = declarations["width"],
           let value = resolveLength(
                width,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize,
                percentageBase: percentageBase
           ) {
            style.width = max(0, value)
            let trimmed = width.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("%"), let pct = Double(trimmed.dropLast()) {
                style.rawWidthPercent = CGFloat(pct)
            }
        }
        if let height = declarations["height"],
           let value = resolveLength(
                height,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize,
                percentageBase: percentageBase
           ) {
            style.height = max(0, value)
            let trimmed = height.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasSuffix("%"), let pct = Double(trimmed.dropLast()) {
                style.rawHeightPercent = CGFloat(pct)
            }
        }
        if let textIndent = declarations["text-indent"],
           let value = resolveLength(
                textIndent,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize,
                percentageBase: percentageBase
           ) {
            style.textIndent = value
        }
        if !handledProperties.contains("line-height"), let lineHeight = declarations["line-height"] {
            if let resolved = resolveLineHeight(lineHeight, fontSize: style.fontSize, rootFontSize: rootFontSize) {
                // When CSS explicitly specifies line-height, skip clamping to respect EPUB layout intent.
                style.lineHeight = resolved
                style.lineHeightExplicit = true
            }
        }
        if isForcedPageBreakValue(declarations["page-break-before"] ?? declarations["break-before"]) {
            style.pageBreakBefore = true
        }
        if isForcedPageBreakValue(declarations["page-break-after"] ?? declarations["break-after"]) {
            style.pageBreakAfter = true
        }
        if isAvoidPageBreakInsideValue(declarations["page-break-inside"] ?? declarations["break-inside"]) {
            style.avoidsPageBreakInside = true
        }
        if let paragraphSpacing = declarations["margin-bottom"] ?? declarations["paragraph-spacing"],
           let value = resolveLength(
                paragraphSpacing,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize,
                percentageBase: percentageBase
           ) {
            style.paragraphSpacing = max(0, value)
        }
        if let marginTop = declarations["margin-top"],
           let value = resolveLength(
                marginTop,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize,
                percentageBase: percentageBase
           ) {
            style.paragraphSpacingBefore = max(0, value)
            style.visualOffsetBefore = max(0, value)
        }
        if let margin = declarations["margin"] {
            applyMarginShorthand(
                margin,
                to: &style,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                percentageBase: percentageBase
            )
        }
        if let marginLeft = declarations["margin-left"],
           let value = resolveLength(
                marginLeft,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize,
                percentageBase: percentageBase
           ) {
            style.marginLeft = max(0, value)
        }
        if let marginRight = declarations["margin-right"],
           let value = resolveLength(
                marginRight,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize,
                percentageBase: percentageBase
           ) {
            style.marginRight = max(0, value)
        }
        if let padding = declarations["padding"] {
            applyPaddingShorthand(
                padding,
                to: &style,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                percentageBase: percentageBase
            )
        }
        if let paddingTop = declarations["padding-top"],
           let value = resolveLength(
                paddingTop,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize,
                percentageBase: percentageBase
           ) {
            style.paddingTop = max(0, value)
        }
        if let paddingLeft = declarations["padding-left"],
           let value = resolveLength(
                paddingLeft,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize,
                percentageBase: percentageBase
           ) {
            style.paddingLeft = max(0, value)
        }
        if let paddingRight = declarations["padding-right"],
           let value = resolveLength(
                paddingRight,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize,
                percentageBase: percentageBase
           ) {
            style.paddingRight = max(0, value)
        }
        if let paddingBottom = declarations["padding-bottom"],
           let value = resolveLength(
                paddingBottom,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize,
                percentageBase: percentageBase
           ) {
            style.paddingBottom = max(0, value)
        }
        if let verticalAlign = declarations["vertical-align"] {
            switch verticalAlign.trimmingCharacters(in: .whitespaces).lowercased() {
            case "super": style.verticalAlign = .super
            case "sub":   style.verticalAlign = .sub
            default:      style.verticalAlign = .baseline
            }
        }
        if let border = declarations["border"] {
            applyBorderShorthand(border, edge: .top, to: &style)
            applyBorderShorthand(border, edge: .bottom, to: &style)
            applyBorderShorthand(border, edge: .left, to: &style)
            applyBorderShorthand(border, edge: .right, to: &style)
        }
        if let borderTop = declarations["border-top"] {
            applyBorderShorthand(borderTop, edge: .top, to: &style)
        }
        if let borderBottom = declarations["border-bottom"] {
            applyBorderShorthand(borderBottom, edge: .bottom, to: &style)
        }
        if let borderLeft = declarations["border-left"] {
            applyBorderShorthand(borderLeft, edge: .left, to: &style)
        }
        if let borderRight = declarations["border-right"] {
            applyBorderShorthand(borderRight, edge: .right, to: &style)
        }
        if let borderTopWidth = declarations["border-top-width"],
           let value = resolveLength(
                borderTopWidth,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize
           ) {
            style.borderTopWidth = max(0, value)
        }
        if let borderBottomWidth = declarations["border-bottom-width"],
           let value = resolveLength(
                borderBottomWidth,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize
           ) {
            style.borderBottomWidth = max(0, value)
        }
        if let borderTopColor = declarations["border-top-color"] {
            style.borderTopColor = parseBorderColor(borderTopColor, currentTextColor: style.textColor)
        }
        if let borderBottomColor = declarations["border-bottom-color"] {
            style.borderBottomColor = parseBorderColor(borderBottomColor, currentTextColor: style.textColor)
        }
        if let borderLeftWidth = declarations["border-left-width"],
           let value = resolveLength(
                borderLeftWidth,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize
           ) {
            style.borderLeftWidth = max(0, value)
        }
        if let borderRightWidth = declarations["border-right-width"],
           let value = resolveLength(
                borderRightWidth,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize
           ) {
            style.borderRightWidth = max(0, value)
        }
        if let borderLeftColor = declarations["border-left-color"] {
            style.borderLeftColor = parseBorderColor(borderLeftColor, currentTextColor: style.textColor)
        }
        if let borderRightColor = declarations["border-right-color"] {
            style.borderRightColor = parseBorderColor(borderRightColor, currentTextColor: style.textColor)
        }
        if let borderWidth = declarations["border-width"] {
            applyBorderWidthShorthand(borderWidth, to: &style, rootFontSize: rootFontSize)
        }
        if let borderColor = declarations["border-color"],
           let firstToken = borderColor.split(whereSeparator: \.isWhitespace).first,
           let color = parseBorderColor(String(firstToken), currentTextColor: style.textColor) {
            // 1–4 value shorthand; approximate multi-color sides with the first color.
            style.borderTopColor = color
            style.borderBottomColor = color
            style.borderLeftColor = color
            style.borderRightColor = color
        }
        applyBorderStyleShorthand(declarations["border-style"], to: &style)
        applyBorderLineStyle(declarations["border-top-style"], edge: .top, to: &style)
        applyBorderLineStyle(declarations["border-bottom-style"], edge: .bottom, to: &style)
        applyBorderLineStyle(declarations["border-left-style"], edge: .left, to: &style)
        applyBorderLineStyle(declarations["border-right-style"], edge: .right, to: &style)
        if let borderRadius = declarations["border-radius"] {
            // `RenderStyle.borderRadius` models one uniform radius (no per-corner support yet). The
            // 2/3/4-value shorthand (`10px 0px 10px 10px` = TL/TR/BR/BL) can't map to a single
            // length, so approximate with the LARGEST corner. Chat-bubble idioms deliberately zero
            // one corner (`0px 10px 10px` for the speech-tail notch); taking the first token there
            // would collapse the whole box to square — the max keeps it visibly rounded.
            let radii = borderRadius
                .split(whereSeparator: \.isWhitespace)
                .compactMap { resolveLength(String($0), currentFontSize: style.fontSize, rootFontSize: rootFontSize, relativeBase: style.fontSize) }
            style.borderRadius = max(0, radii.max() ?? 0)
        }
    }

    private func applyBorderWidthShorthand(_ raw: String, to style: inout ResolvedStyle, rootFontSize: CGFloat) {
        let tokens = raw.split(whereSeparator: \.isWhitespace)
            .compactMap { resolveLength(String($0), currentFontSize: style.fontSize, rootFontSize: rootFontSize, relativeBase: style.fontSize) }
        guard !tokens.isEmpty else { return }
        let top    = tokens[0]
        let right  = tokens.count >= 2 ? tokens[1] : top
        let bottom = tokens.count >= 3 ? tokens[2] : top
        let left   = tokens.count >= 4 ? tokens[3] : right
        style.borderTopWidth    = max(0, top)
        style.borderRightWidth  = max(0, right)
        style.borderBottomWidth = max(0, bottom)
        style.borderLeftWidth   = max(0, left)
    }

    private enum BorderEdge {
        case top
        case bottom
        case left
        case right
    }

    private func applyBorderShorthand(_ raw: String, edge: BorderEdge, to style: inout ResolvedStyle) {
        let tokens = raw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return }

        let lowered = tokens.map { $0.lowercased() }
        if lowered.contains("none") || lowered.contains("hidden") {
            style.borderExplicitlyNone = true
            setBorder(width: 0, color: nil, lineStyle: lowered.contains("hidden") ? "hidden" : "none", edge: edge, to: &style)
            return
        }

        var width: CGFloat?
        var color: UIColor?
        var lineStyle: String?
        for token in tokens {
            if lineStyle == nil, let normalizedStyle = normalizedBorderLineStyle(token) {
                lineStyle = normalizedStyle
                continue
            }
            if width == nil,
               let resolvedWidth = resolveLength(
                    token,
                    currentFontSize: style.fontSize,
                    rootFontSize: style.fontSize,
                    relativeBase: style.fontSize
               ) {
                width = max(0, resolvedWidth)
                continue
            }
            if color == nil {
                color = parseBorderColor(token, currentTextColor: style.textColor)
            }
        }

        setBorder(width: width ?? 0, color: color, lineStyle: lineStyle, edge: edge, to: &style)
    }

    private func parseBorderColor(_ raw: String, currentTextColor: UIColor) -> UIColor? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "currentcolor" {
            return currentTextColor
        }
        return parseColor(raw)
    }

    private func applyBorderStyleShorthand(_ raw: String?, to style: inout ResolvedStyle) {
        guard let raw else { return }
        let values = raw
            .split(whereSeparator: \.isWhitespace)
            .compactMap { normalizedBorderLineStyle(String($0)) }
        guard !values.isEmpty else { return }
        let top = values[0]
        let right = values.count >= 2 ? values[1] : top
        let bottom = values.count >= 3 ? values[2] : top
        let left = values.count >= 4 ? values[3] : right
        applyBorderLineStyle(top, edge: .top, to: &style)
        applyBorderLineStyle(right, edge: .right, to: &style)
        applyBorderLineStyle(bottom, edge: .bottom, to: &style)
        applyBorderLineStyle(left, edge: .left, to: &style)
    }

    private func applyBorderLineStyle(_ raw: String?, edge: BorderEdge, to style: inout ResolvedStyle) {
        guard let raw,
              let lineStyle = normalizedBorderLineStyle(raw)
        else { return }
        applyBorderLineStyle(lineStyle, edge: edge, to: &style)
    }

    private func applyBorderLineStyle(_ lineStyle: String, edge: BorderEdge, to style: inout ResolvedStyle) {
        if lineStyle == "none" || lineStyle == "hidden" {
            style.borderExplicitlyNone = true
            setBorder(width: 0, color: nil, lineStyle: lineStyle, edge: edge, to: &style)
        } else {
            setBorderLineStyle(lineStyle, edge: edge, to: &style)
        }
    }

    private func normalizedBorderLineStyle(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "none", "hidden", "solid", "dashed", "dotted", "double", "groove", "ridge", "inset", "outset":
            return value
        default:
            return nil
        }
    }

    private func setBorder(width: CGFloat, color: UIColor?, lineStyle: String?, edge: BorderEdge, to style: inout ResolvedStyle) {
        switch edge {
        case .top:
            style.borderTopWidth = width
            style.borderTopColor = color
            if let lineStyle { style.borderTopStyle = lineStyle }
        case .bottom:
            style.borderBottomWidth = width
            style.borderBottomColor = color
            if let lineStyle { style.borderBottomStyle = lineStyle }
        case .left:
            style.borderLeftWidth = width
            style.borderLeftColor = color
            if let lineStyle { style.borderLeftStyle = lineStyle }
        case .right:
            style.borderRightWidth = width
            style.borderRightColor = color
            if let lineStyle { style.borderRightStyle = lineStyle }
        }
    }

    private func setBorderLineStyle(_ lineStyle: String, edge: BorderEdge, to style: inout ResolvedStyle) {
        switch edge {
        case .top:
            style.borderTopStyle = lineStyle
        case .bottom:
            style.borderBottomStyle = lineStyle
        case .left:
            style.borderLeftStyle = lineStyle
        case .right:
            style.borderRightStyle = lineStyle
        }
    }

    private func resolveLineHeight(_ raw: String, fontSize: CGFloat, rootFontSize: CGFloat) -> CGFloat? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let number = Double(value) {
            return CGFloat(number) * fontSize
        }
        return resolveLength(value, currentFontSize: fontSize, rootFontSize: rootFontSize, relativeBase: fontSize)
    }

    private func resolveLength(
        _ raw: String,
        currentFontSize: CGFloat,
        rootFontSize: CGFloat,
        relativeBase: CGFloat,
        percentageBase: CGFloat? = nil
    ) -> CGFloat? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Relative font-size keywords (CSS uses ~1.2× steps). Only meaningful for `font-size`, but
        // these keywords never appear on length properties so resolving them here is harmless.
        if value == "smaller" { return relativeBase / 1.2 }
        if value == "larger" { return relativeBase * 1.2 }
        if value.hasPrefix("calc("), value.hasSuffix(")") {
            return resolveCalc(String(value.dropFirst(5).dropLast()), currentFontSize: currentFontSize, rootFontSize: rootFontSize, relativeBase: relativeBase)
        }
        if value.hasSuffix("rem"), let number = Double(value.dropLast(3)) {
            return CGFloat(number) * rootFontSize
        }
        if value.hasSuffix("em"), let number = Double(value.dropLast(2)) {
            return CGFloat(number) * relativeBase
        }
        if value.hasSuffix("%"), let number = Double(value.dropLast()) {
            return CGFloat(number / 100.0) * (percentageBase ?? relativeBase)
        }
        if value.hasSuffix("pt"), let number = Double(value.dropLast(2)) {
            return CGFloat(number)
        }
        if value.hasSuffix("px"), let number = Double(value.dropLast(2)) {
            return CGFloat(number)
        }
        if let number = Double(value) {
            return CGFloat(number)
        }
        return nil
    }

    private func applyMarginShorthand(
        _ raw: String,
        to style: inout ResolvedStyle,
        currentFontSize: CGFloat,
        rootFontSize: CGFloat,
        percentageBase: CGFloat? = nil
    ) {
        let tokens = raw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return }
        let resolved = expandBoxShorthand(tokens)
        if let top = resolved.top, let topValue = resolveBoxValue(top, currentFontSize: currentFontSize, rootFontSize: rootFontSize, percentageBase: percentageBase) {
            style.paragraphSpacingBefore = max(0, topValue)
            style.visualOffsetBefore = max(0, topValue)
        }
        if let bottom = resolved.bottom, let bottomValue = resolveBoxValue(bottom, currentFontSize: currentFontSize, rootFontSize: rootFontSize, percentageBase: percentageBase) {
            style.paragraphSpacing = max(0, bottomValue)
        }
        if let left = resolved.left {
            if left.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto" {
                // Only center when BOTH left AND right are auto
                if let right = resolved.right, right.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto" {
                    style.isHorizontallyCentered = true
                }
            } else if let leftValue = resolveBoxValue(left, currentFontSize: currentFontSize, rootFontSize: rootFontSize, percentageBase: percentageBase) {
                style.marginLeft = max(0, leftValue)
            }
        }
        if let right = resolved.right {
            if right.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto" {
                // Only center when BOTH left AND right are auto
                if let left = resolved.left, left.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto" {
                    // already handled above
                } else {
                    // right-only auto: don't center, just skip margin-right
                }
            } else if let rightValue = resolveBoxValue(right, currentFontSize: currentFontSize, rootFontSize: rootFontSize, percentageBase: percentageBase) {
                style.marginRight = max(0, rightValue)
            }
        }
    }

    private func applyPaddingShorthand(
        _ raw: String,
        to style: inout ResolvedStyle,
        currentFontSize: CGFloat,
        rootFontSize: CGFloat,
        percentageBase: CGFloat? = nil
    ) {
        let tokens = raw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return }
        let resolved = expandBoxShorthand(tokens)
        if let top = resolved.top, let topValue = resolveBoxValue(top, currentFontSize: currentFontSize, rootFontSize: rootFontSize, percentageBase: percentageBase) {
            style.paddingTop = max(0, topValue)
        }
        if let left = resolved.left, let leftValue = resolveBoxValue(left, currentFontSize: currentFontSize, rootFontSize: rootFontSize, percentageBase: percentageBase) {
            style.paddingLeft = max(0, leftValue)
        }
        if let bottom = resolved.bottom, let bottomValue = resolveBoxValue(bottom, currentFontSize: currentFontSize, rootFontSize: rootFontSize, percentageBase: percentageBase) {
            style.paddingBottom = max(0, bottomValue)
        }
        if let right = resolved.right, let rightValue = resolveBoxValue(right, currentFontSize: currentFontSize, rootFontSize: rootFontSize, percentageBase: percentageBase) {
            style.paddingRight = max(0, rightValue)
        }
    }

    private func expandBoxShorthand(_ tokens: [String]) -> (top: String?, right: String?, bottom: String?, left: String?) {
        switch tokens.count {
        case 1:
            return (tokens[0], tokens[0], tokens[0], tokens[0])
        case 2:
            return (tokens[0], tokens[1], tokens[0], tokens[1])
        case 3:
            return (tokens[0], tokens[1], tokens[2], tokens[1])
        default:
            return (tokens[0], tokens[1], tokens[2], tokens[3])
        }
    }

    private func resolveBoxValue(
        _ raw: String,
        currentFontSize: CGFloat,
        rootFontSize: CGFloat,
        percentageBase: CGFloat? = nil
    ) -> CGFloat? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value != "auto" else { return nil }
        return resolveLength(
            value,
            currentFontSize: currentFontSize,
            rootFontSize: rootFontSize,
            relativeBase: currentFontSize,
            percentageBase: percentageBase
        )
    }

    private func resolveCalc(
        _ expression: String,
        currentFontSize: CGFloat,
        rootFontSize: CGFloat,
        relativeBase: CGFloat
    ) -> CGFloat? {
        let trimmed = expression.replacingOccurrences(of: " ", with: "")
        for op in ["+", "-"] {
            if let index = trimmed.lastIndex(of: Character(op)) {
                let lhs = String(trimmed[..<index])
                let rhs = String(trimmed[trimmed.index(after: index)...])
                guard let left = resolveLength(lhs, currentFontSize: currentFontSize, rootFontSize: rootFontSize, relativeBase: relativeBase),
                      let right = resolveLength(rhs, currentFontSize: currentFontSize, rootFontSize: rootFontSize, relativeBase: relativeBase)
                else { return nil }
                return op == "+" ? left + right : left - right
            }
        }
        for op in ["*", "/"] {
            if let index = trimmed.lastIndex(of: Character(op)) {
                let lhs = String(trimmed[..<index])
                let rhs = String(trimmed[trimmed.index(after: index)...])
                if let left = resolveLength(lhs, currentFontSize: currentFontSize, rootFontSize: rootFontSize, relativeBase: relativeBase),
                   let scalar = Double(rhs) {
                    return op == "*" ? left * CGFloat(scalar) : left / max(CGFloat(scalar), 0.0001)
                }
                if let right = resolveLength(rhs, currentFontSize: currentFontSize, rootFontSize: rootFontSize, relativeBase: relativeBase),
                   let scalar = Double(lhs) {
                    return op == "*" ? CGFloat(scalar) * right : CGFloat(scalar) / max(right, 0.0001)
                }
            }
        }
        return resolveLength(trimmed, currentFontSize: currentFontSize, rootFontSize: rootFontSize, relativeBase: relativeBase)
    }

    private func cssFontWeight(_ raw: String, current: Int) -> Int {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let numeric = Int(value) { return numeric }
        switch value {
        case "bold", "bolder":
            return 700
        case "normal", "lighter":
            return 400
        default:
            return current
        }
    }

    private func uiFontWeight(from cssWeight: Int) -> UIFont.Weight {
        switch cssWeight {
        case ..<350: return .regular
        case 350..<450: return .regular
        case 450..<550: return .medium
        case 550..<650: return .semibold
        case 650..<750: return .bold
        case 750..<850: return .heavy
        default: return .black
        }
    }

    private func cssAlignment(_ raw: String) -> NSTextAlignment {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "center":
            return .center
        case "right", "end":
            return .right
        case "justify":
            return .justified
        default:
            return .natural
        }
    }

    private func clampLineHeight(absolute: CGFloat, fontSize: CGFloat) -> CGFloat {
        let minValue = fontSize * 1.1
        let maxValue = fontSize * 2.0
        return min(max(absolute, minValue), maxValue)
    }

    private func normalizeWhitespace(_ text: String) -> String {
        // NB: form feed must be ICU's `\x{000C}` — `\u{000C}` is Swift escape syntax that
        // ICU rejects, which silently invalidates the whole class so nothing collapses.
        let collapsed = text.replacingOccurrences(of: "[ \\t\\r\\n\\x{000C}]+", with: " ", options: .regularExpression)
        return collapsed.replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    private func cleanDirtySpacesInHTML(_ rawHTML: String) -> String {
        guard let regex = Self.dirtyCJKSpaceRegex else { return rawHTML }
        let range = NSRange(location: 0, length: rawHTML.utf16.count)
        return regex.stringByReplacingMatches(in: rawHTML, options: [], range: range, withTemplate: "")
    }

    private func extractURL(from value: String) -> String? {
        guard let start = value.range(of: "("), let end = value.range(of: ")", options: .backwards) else {
            return nil
        }
        let raw = value[start.upperBound..<end.lowerBound]
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))
        return trimmed.isEmpty ? nil : trimmed
    }

    private func parseColor(_ raw: String) -> UIColor? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("#") {
            let hex = String(value.dropFirst())
            if hex.count == 3 {
                let expanded = hex.map { "\($0)\($0)" }.joined()
                return colorFromHex(expanded)
            }
            if hex.count == 6 {
                return colorFromHex(hex)
            }
        }

        if value.hasPrefix("rgba(") || value.hasPrefix("rgb(") {
            return parseRGBColor(value)
        }

        switch value {
        case "red":
            return .red
        case "white":
            return .white
        case "black":
            return .black
        case "gray", "grey":
            return .gray
        case "blue":
            return .blue
        case "transparent":
            // Must resolve to a real (alpha-0) color, not nil — nil reads as "unspecified" and
            // falls back to a visible default (e.g. border color defaults to currentColor/.label).
            // EPUB authors use `border: 1px solid transparent` as a spacing hack expecting no
            // visible border at all; failing to parse it previously drew a solid black/white line.
            return .clear
        default:
            return nil
        }
    }

    private func parseEmbeddedColor(in raw: String) -> UIColor? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let rgbaRange = value.range(of: #"rgba?\([^)]+\)"#, options: .regularExpression) {
            return parseColor(String(value[rgbaRange]))
        }
        if let hexRange = value.range(of: #"#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{3})"#, options: .regularExpression) {
            return parseColor(String(value[hexRange]))
        }
        return nil
    }

    private func parseRGBColor(_ raw: String) -> UIColor? {
        guard let start = raw.firstIndex(of: "("),
              let end = raw.lastIndex(of: ")"),
              start < end else {
            return nil
        }
        let components = raw[raw.index(after: start)..<end]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard components.count == 3 || components.count == 4 else { return nil }
        guard let red = parseRGBComponent(components[0]),
              let green = parseRGBComponent(components[1]),
              let blue = parseRGBComponent(components[2]) else {
            return nil
        }
        let alpha: CGFloat
        if components.count == 4 {
            guard let parsedAlpha = Double(components[3]) else { return nil }
            alpha = max(0, min(1, CGFloat(parsedAlpha)))
        } else {
            alpha = 1
        }
        return UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    private func parseRGBComponent(_ raw: String) -> CGFloat? {
        if raw.hasSuffix("%") {
            guard let value = Double(raw.dropLast()) else { return nil }
            return max(0, min(1, CGFloat(value / 100)))
        }
        guard let value = Double(raw) else { return nil }
        return max(0, min(1, CGFloat(value / 255)))
    }

    private func cssDisplayIsBlock(_ raw: String) -> Bool {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch value {
        case "block", "list-item", "table", "flex", "grid":
            return true
        default:
            return false
        }
    }

    private func colorFromHex(_ hex: String) -> UIColor? {
        guard let value = Int(hex, radix: 16) else { return nil }
        let red = CGFloat((value >> 16) & 0xFF) / 255.0
        let green = CGFloat((value >> 8) & 0xFF) / 255.0
        let blue = CGFloat(value & 0xFF) / 255.0
        return UIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    private func normalizeFontName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))).lowercased()
    }

    private func collectAnchorOffsets(in attributedString: NSAttributedString) -> [String: Int] {
        guard attributedString.length > 0 else { return [:] }
        var result: [String: Int] = [:]
        attributedString.enumerateAttribute(
            Self.anchorIDAttribute,
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { value, range, _ in
            guard let id = value as? String, !id.isEmpty else { return }
            result[id] = range.location
        }
        return result
    }

    private func makeAttributeMap(for element: Element) -> [String: String] {
        var attributes: [String: String] = [:]
        for key in [
            "id", "class", "style", "src", "href", "xlink:href", "width", "height",
            "alt", "alttext", "display", "data", "title", "aria-label", "poster", "type",
            "controls", "colspan", "rowspan", "scope", "ssml:ph", "ssml:alphabet",
            "data-yd-imgstyle"
        ] {
            let value = (try? element.attr(key)) ?? ""
            if !value.isEmpty {
                attributes[key] = value
            }
        }
        return attributes
    }

    /// Finds the CSS ::first-letter range: any leading punctuation followed by the first letter/digit.
    /// Returns nil when the string has no visible letter.
    static func firstLetterRange(in text: String) -> NSRange? {
        let scalars = Array(text.unicodeScalars)
        var i = 0

        // Skip whitespace and newlines
        while i < scalars.count {
            let ch = scalars[i]
            if !CharacterSet.whitespacesAndNewlines.contains(ch) { break }
            i += 1
        }
        guard i < scalars.count else { return nil }
        let start = i

        // Skip leading punctuation to find the first letter/digit
        while i < scalars.count {
            let ch = scalars[i]
            if CharacterSet.letters.contains(ch) || CharacterSet.decimalDigits.contains(ch) {
                break
            }
            i += 1
        }
        guard i < scalars.count else {
            // Only punctuation found — style just the first punctuation char
            return NSRange(location: start, length: 1)
        }
        // Include leading punctuation + first letter
        let end = i + 1
        let length = end - start
        return NSRange(location: start, length: length)
    }
}

struct CSSRule {
    let selector: CSSSelector
    let declarations: [String: String]
    let specificity: Int
    let order: Int
}

struct CSSSelector {
    /// A single `[attr]` / `[attr=val]` / `[attr~=val]` … condition. `name` is already normalized to
    /// the DOM attribute form (namespace pipe `epub|type` and escaped `epub\:type` both → `epub:type`).
    struct AttributeSelector {
        enum Op {
            case exists      // [attr]
            case equals      // [attr=val]
            case includes    // [attr~=val]  (whitespace-separated list contains val)
            case dashMatch   // [attr|=val]  (val or val-…)
            case prefix      // [attr^=val]
            case suffix      // [attr$=val]
            case substring   // [attr*=val]
        }
        let name: String
        let op: Op
        let value: String
    }

    /// How a component connects to the component on its left (its ancestor side). Only descendant
    /// (` `) and child (`>`) are modeled; sibling combinators (`+`/`~`) make the whole selector
    /// unsupported so the rule is dropped — see `CSSParser.parseSelector`.
    enum Combinator {
        case descendant
        case child
    }

    struct Component {
        let tag: String?
        let id: String?
        let classes: Set<String>
        let attributes: [AttributeSelector]
        let firstChild: Bool
        /// Combinator linking this component to the previous (left) one. Ignored for the first.
        let combinator: Combinator
    }

    /// Components in source order: `components[0]` is the leftmost (outermost ancestor),
    /// `components.last` is the subject matched against the candidate element itself.
    let components: [Component]

    /// Matches the full complex selector by walking the component chain right-to-left. Descendant
    /// steps backtrack across every ancestor; child steps require the direct parent. Supports an
    /// arbitrary number of components (e.g. `nav[epub|type~='toc'] a > span.toc-label`).
    func matches(element: Element, parent: Element?) -> Bool {
        matchChain(index: components.count - 1, element: element, parent: parent)
    }

    private func matchChain(index: Int, element: Element, parent: Element?) -> Bool {
        guard index >= 0 else { return true }
        let component = components[index]
        guard matches(component: component, element: element, parent: parent) else { return false }
        guard index > 0 else { return true }

        // `component.combinator` describes how this component connects to components[index - 1].
        switch component.combinator {
        case .child:
            guard let parent else { return false }
            return matchChain(index: index - 1, element: parent, parent: parent.parent())
        case .descendant:
            var ancestor = parent
            while let current = ancestor {
                if matchChain(index: index - 1, element: current, parent: current.parent()) {
                    return true
                }
                ancestor = current.parent()
            }
            return false
        }
    }

    private func matches(component: Component, element: Element, parent: Element?) -> Bool {
        if let tag = component.tag, element.tagName().lowercased() != tag {
            return false
        }
        if let id = component.id, element.id() != id {
            return false
        }
        let classNames = Set((try? element.classNames()) ?? [])
        if !component.classes.isSubset(of: classNames) {
            return false
        }
        for attribute in component.attributes where !Self.matches(attribute: attribute, element: element) {
            return false
        }
        if component.firstChild, !isFirstElementChild(element, parent: parent) {
            return false
        }
        return true
    }

    private static func matches(attribute: AttributeSelector, element: Element) -> Bool {
        let actual = attributeValue(named: attribute.name, of: element)
        switch attribute.op {
        case .exists:
            return actual != nil
        case .equals:
            return actual == attribute.value
        case .includes:
            guard let actual, !attribute.value.isEmpty else { return false }
            return actual
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" || $0 == "\u{0C}" })
                .contains { $0 == Substring(attribute.value) }
        case .dashMatch:
            guard let actual else { return false }
            return actual == attribute.value || actual.hasPrefix(attribute.value + "-")
        case .prefix:
            guard let actual, !attribute.value.isEmpty else { return false }
            return actual.hasPrefix(attribute.value)
        case .suffix:
            guard let actual, !attribute.value.isEmpty else { return false }
            return actual.hasSuffix(attribute.value)
        case .substring:
            guard let actual, !attribute.value.isEmpty else { return false }
            return actual.contains(attribute.value)
        }
    }

    /// Reads an attribute by name, falling back to a lowercased lookup (HTML attribute names are
    /// ASCII case-insensitive; EPUB content is lowercase, so exact match almost always hits first).
    private static func attributeValue(named name: String, of element: Element) -> String? {
        if element.hasAttr(name) { return try? element.attr(name) }
        let lower = name.lowercased()
        if lower != name, element.hasAttr(lower) { return try? element.attr(lower) }
        return nil
    }

    private func isFirstElementChild(_ element: Element, parent: Element?) -> Bool {
        guard let parent else { return true }
        for child in parent.getChildNodes() {
            if let childElement = child as? Element {
                return childElement == element
            }
        }
        return false
    }
}

enum CSSParser {
    /// Strips CSS comments and statement at-rules (`@charset`, `@namespace`, stray `@import`) that
    /// carry no `{ }` block. The rule regex below treats everything up to the first `{` as the
    /// selector, so leaving these in front of the first style rule fuses them into that rule's
    /// selector — making it unmatchable and silently dropping its declarations. In practice the
    /// first rule is `body { … }`, so the document-wide `font-family` (and the embedded-font cascade
    /// that depends on it) vanishes. Block at-rules like `@font-face` are removed upstream; `@media`
    /// blocks are left untouched (still unsupported, but no longer able to break a neighbor).
    private static func sanitize(_ css: String) -> String {
        css
            .replacingOccurrences(of: #"/\*.*?\*/"#, with: "", options: .regularExpression)
            .replacingOccurrences(
                of: #"@(?:charset|namespace|import)\b[^{};]*;"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
    }

    static func parse(css: String, orderOffset: Int = 0) -> [CSSRule] {
        let stripped = sanitize(css)
        guard let regex = try? NSRegularExpression(
            pattern: #"([^{}]+)\{([^{}]+)\}"#,
            options: [.dotMatchesLineSeparators]
        ) else {
            return []
        }

        let nsCSS = stripped as NSString
        return regex.matches(in: stripped, range: NSRange(location: 0, length: nsCSS.length)).enumerated().flatMap { index, match in
            let selectorText = nsCSS.substring(with: match.range(at: 1))
            let declarations = parseDeclarations(nsCSS.substring(with: match.range(at: 2)))
            let selectors = selectorText
                .split(separator: ",")
                .compactMap { parseSelector(String($0)) }
            return selectors.map { selector in
                CSSRule(
                    selector: selector,
                    declarations: declarations,
                    specificity: specificity(of: selector),
                    order: orderOffset + index
                )
            }
        }
    }

    /// Parses CSS and returns (regular rules, first-letter rules).
    static func parseWithFirstLetter(css: String, orderOffset: Int = 0) -> (regular: [CSSRule], firstLetter: [CSSRule]) {
        let stripped = sanitize(css)
        guard let regex = try? NSRegularExpression(
            pattern: #"([^{}]+)\{([^{}]+)\}"#,
            options: [.dotMatchesLineSeparators]
        ) else {
            return ([], [])
        }

        var regular: [CSSRule] = []
        var firstLetter: [CSSRule] = []
        let nsCSS = stripped as NSString
        for (index, match) in regex.matches(in: stripped, range: NSRange(location: 0, length: nsCSS.length)).enumerated() {
            let selectorText = nsCSS.substring(with: match.range(at: 1))
            let declarations = parseDeclarations(nsCSS.substring(with: match.range(at: 2)))
            for rawSelector in selectorText.split(separator: ",").map(String.init) {
                let trimmed = rawSelector.trimmingCharacters(in: .whitespacesAndNewlines)
                let isFirstLetter = trimmed.hasSuffix(":first-letter")

                let selectorBody: String
                if isFirstLetter {
                    let endIndex = trimmed.lastIndex(of: ":") ?? trimmed.endIndex
                    selectorBody = String(trimmed[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    selectorBody = trimmed
                }

                guard !selectorBody.isEmpty, let selector = parseSelector(selectorBody) else { continue }
                let rule = CSSRule(
                    selector: selector,
                    declarations: declarations,
                    specificity: specificity(of: selector),
                    order: orderOffset + index
                )
                if isFirstLetter {
                    firstLetter.append(rule)
                } else {
                    regular.append(rule)
                }
            }
        }
        return (regular, firstLetter)
    }

    static func parseDeclarations(_ css: String) -> [String: String] {
        var declarations: [String: String] = [:]
        for segment in css.split(separator: ";", omittingEmptySubsequences: true) {
            let parts = segment.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty && !value.isEmpty {
                declarations[key] = value
            }
        }
        return declarations
    }

    /// Splits a complex selector into components joined by descendant (whitespace) and child (`>`)
    /// combinators. Bracket-aware so a combinator-like character inside an attribute value (e.g.
    /// `[title='a > b']`) is not treated as a separator. Any unparseable component (sibling
    /// combinators `+`/`~`, pseudo-classes, `*`) drops the whole rule — matching prior behavior.
    private static func parseSelector(_ raw: String) -> CSSSelector? {
        var tokens: [(combinator: CSSSelector.Combinator, text: String)] = []
        var current = ""
        var pendingCombinator: CSSSelector.Combinator = .descendant
        var bracketDepth = 0

        func flush() {
            guard !current.isEmpty else { return }
            tokens.append((pendingCombinator, current))
            current = ""
            pendingCombinator = .descendant
        }

        for char in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            if char == "[" { bracketDepth += 1; current.append(char); continue }
            if char == "]" { bracketDepth = max(0, bracketDepth - 1); current.append(char); continue }
            if bracketDepth > 0 { current.append(char); continue }

            if char == ">" {
                flush()
                pendingCombinator = .child
            } else if char.isWhitespace {
                flush()
            } else {
                current.append(char)
            }
        }
        flush()

        guard !tokens.isEmpty else { return nil }
        var components: [CSSSelector.Component] = []
        for token in tokens {
            guard let component = parseComponent(token.text, combinator: token.combinator) else { return nil }
            components.append(component)
        }
        return CSSSelector(components: components)
    }

    private static func parseComponent(_ raw: String, combinator: CSSSelector.Combinator) -> CSSSelector.Component? {
        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }

        var firstChild = false
        if token.lowercased().hasSuffix(":first-child") {
            firstChild = true
            token = String(token.dropLast(":first-child".count))
        }

        // Pull out every `[ … ]` attribute selector, then strip them so the remainder is a plain
        // tag/id/class token. Anything unparseable inside the brackets makes the whole rule unsupported.
        var attributes: [CSSSelector.AttributeSelector] = []
        if token.contains("[") {
            guard let regex = try? NSRegularExpression(pattern: "\\[[^\\]]*\\]") else { return nil }
            let ns = token as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            for match in regex.matches(in: token, range: fullRange) {
                let body = String(ns.substring(with: match.range).dropFirst().dropLast())
                guard let attribute = parseAttributeSelector(body) else { return nil }
                attributes.append(attribute)
            }
            token = regex.stringByReplacingMatches(in: token, range: fullRange, withTemplate: "")
        }

        // Combinators / pseudo-elements in the remainder are unsupported.
        if token.contains(">") || token.contains("+") || token.contains("~")
            || token.contains("*") || token.contains("[") || token.contains("]")
            || token.contains("(") || token.contains(":") {
            return nil
        }

        var tag: String?
        var id: String?
        var classes = Set<String>()
        var buffer = ""
        var mode: Character = "t"

        func flush() {
            guard !buffer.isEmpty else { return }
            switch mode {
            case "t":
                tag = buffer.lowercased()
            case "#":
                id = buffer
            case ".":
                classes.insert(buffer)
            default:
                break
            }
            buffer = ""
        }

        for char in token {
            if char == "#" || char == "." {
                flush()
                mode = char
            } else {
                buffer.append(char)
            }
        }
        flush()

        guard tag != nil || id != nil || !classes.isEmpty || !attributes.isEmpty else { return nil }

        return CSSSelector.Component(tag: tag, id: id, classes: classes, attributes: attributes, firstChild: firstChild, combinator: combinator)
    }

    /// Parses the inside of one `[ … ]` block, e.g. `epub|type~='pagebreak'`.
    private static func parseAttributeSelector(_ raw: String) -> CSSSelector.AttributeSelector? {
        let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }

        guard let eqIndex = body.firstIndex(of: "=") else {
            guard let name = normalizeAttributeName(body) else { return nil }
            return CSSSelector.AttributeSelector(name: name, op: .exists, value: "")
        }

        let op: CSSSelector.AttributeSelector.Op
        let nameEnd: String.Index
        let opChar = eqIndex > body.startIndex ? body[body.index(before: eqIndex)] : nil
        switch opChar {
        case "~": op = .includes;   nameEnd = body.index(before: eqIndex)
        case "|": op = .dashMatch;  nameEnd = body.index(before: eqIndex)
        case "^": op = .prefix;     nameEnd = body.index(before: eqIndex)
        case "$": op = .suffix;     nameEnd = body.index(before: eqIndex)
        case "*": op = .substring;  nameEnd = body.index(before: eqIndex)
        default:  op = .equals;     nameEnd = eqIndex
        }

        guard let name = normalizeAttributeName(String(body[body.startIndex..<nameEnd])) else { return nil }
        let value = unquoteAttributeValue(String(body[body.index(after: eqIndex)...]))
        return CSSSelector.AttributeSelector(name: name, op: op, value: value)
    }

    /// `epub|type` (CSS namespace) and `epub\:type` (escaped colon) both map to the XHTML DOM
    /// attribute name `epub:type`. A leading `|` / `*|` (no/any namespace) is dropped.
    private static func normalizeAttributeName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.replacingOccurrences(of: "\\:", with: ":")
        name = name.replacingOccurrences(of: "\\", with: "")
        if name.hasPrefix("*|") {
            name = String(name.dropFirst(2))
        } else if name.hasPrefix("|") {
            name = String(name.dropFirst())
        } else {
            name = name.replacingOccurrences(of: "|", with: ":")
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func unquoteAttributeValue(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a trailing case-insensitivity flag (`[attr=val i]`).
        if value.hasSuffix(" i") || value.hasSuffix(" I") {
            value = String(value.dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func specificity(of selector: CSSSelector) -> Int {
        selector.components.reduce(0) { partial, component in
            partial
            + (component.id == nil ? 0 : 100)
            + component.classes.count * 10
            + component.attributes.count * 10
            + (component.firstChild ? 10 : 0)
            + (component.tag == nil ? 0 : 1)
        }
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let traits = [UIFontDescriptor.TraitKey.weight: weight]
        let descriptor = fontDescriptor.addingAttributes([.traits: traits])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
