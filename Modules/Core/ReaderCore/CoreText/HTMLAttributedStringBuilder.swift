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
    /// Marker attribute for tappable EPUB audio/video placeholders.
    static let mediaAttachmentAttribute = NSAttributedString.Key("ReaderEPUBMediaAttachment")
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
        var firstLetterRules: [CSSRule] = []
    }

    struct ImagePage {
        let source: String
        let image: UIImage?
    }

    struct BuildResult {
        let attributedString: NSAttributedString
        let imagePage: ImagePage?
        let pageBackgroundImage: UIImage?
        let pageBackgroundImageSource: String?
        let anchorOffsets: [String: Int]
    }

    struct ParsedHTML {
        let body: Element
        let rules: [CSSRule]
        let firstLetterRules: [CSSRule]
    }

    struct RenderedContent {
        let attributedString: NSAttributedString
        let pageBackgroundImage: UIImage?
        let pageBackgroundImageSource: String?
        let anchorOffsets: [String: Int]
    }

    enum VerticalAlign {
        case baseline
        case `super`
        case sub
    }

    struct ResolvedStyle {
        var fontSize: CGFloat
        var fontFamilies: [String]
        var fontWeight: Int
        var isItalic: Bool
        var textColor: UIColor
        var textAlign: NSTextAlignment
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

        var hasVisualDecoration: Bool {
            backgroundFillColor != nil
                || borderTopWidth > 0 || borderBottomWidth > 0
                || borderLeftWidth > 0 || borderRightWidth > 0
                || blockImage != nil
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
                borderRadius: borderRadius
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
    private let coreTextRenderer = HTMLBuilderCoreTextRenderer()
    private let cssPropertyRegistry = HTMLCSSPropertyApplierRegistry.defaultRegistry
    private var epubFlowLogCounts: [String: Int] = [:]
    private static let dirtyCJKSpaceRegex: NSRegularExpression? = {
        // Clean up spaces (including NBSP / &nbsp;) between CJK characters that may come from conversion artifacts, preventing excessive justified spacing.
        let pattern = "(?<=\\p{Han})(?:[\\s\\u{00A0}]+|&nbsp;+|&#160;+)+(?=\\p{Han})"
        return try? NSRegularExpression(pattern: pattern, options: [])
    }()

    func build(html: String, config: Config) async -> BuildResult {
        guard let ast = await buildStyledAST(html: html, config: config) else {
            return BuildResult(
                attributedString: NSAttributedString(),
                imagePage: nil,
                pageBackgroundImage: nil,
                pageBackgroundImageSource: nil,
                anchorOffsets: [:]
            )
        }

        if let imagePage = await imagePage(from: ast) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: makeFont(from: ast.resolvedStyle, config: config),
                .foregroundColor: config.textColor,
                .backgroundColor: config.backgroundColor,
            ]
            return BuildResult(
                attributedString: NSAttributedString(string: "\u{FFFC}", attributes: attrs),
                imagePage: imagePage,
                pageBackgroundImage: nil,
                pageBackgroundImageSource: nil,
                anchorOffsets: [:]
            )
        }

        let rendered = await coreTextRenderer.render(
            ast: ast,
            config: config,
            renderBlockChildren: { nodes, parentStyle, config in
                return await self.renderBlockChildren(nodes, parentStyle: parentStyle, config: config)
            },
            collectAnchorOffsets: { attributedString in
                self.anchorOffsets(in: attributedString)
            },
            backgroundImageSource: { ast in
                self.backgroundImageSource(from: ast)
            },
            loadBackgroundImage: { ast in
                return await self.loadBackgroundImage(from: ast)
            },
            debugLog: { _ in }
        )

        return BuildResult(
            attributedString: rendered.attributedString,
            imagePage: nil,
            pageBackgroundImage: rendered.pageBackgroundImage,
            pageBackgroundImageSource: rendered.pageBackgroundImageSource,
            anchorOffsets: rendered.anchorOffsets
        )
    }

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
        return "fontWeight=\(style.fontWeight) isItalic=\(style.isItalic) fontFamilies=\(style.fontFamilies) fontSize=\(style.fontSize) lineHeight=\(style.lineHeight) lineHeightExplicit=\(style.lineHeightExplicit) textIndent=\(style.textIndent) paraBefore=\(style.paragraphSpacingBefore) paraAfter=\(style.paragraphSpacing) paddingL=\(style.paddingLeft) paddingR=\(style.paddingRight) width=\(width) height=\(height) block=\(style.isBlock) vertical=\(style.isVerticalWritingMode)"
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

    private func renderBlockChildren(
        _ nodes: [ASTNode],
        parentStyle: ResolvedStyle,
        config: Config
    ) async -> NSAttributedString {
        let output = NSMutableAttributedString()
        for node in nodes {
            let nodeToRender: ASTNode
            if output.length == 0,
               case .element(let element) = node,
               element.resolvedStyle.isBlock,
               element.resolvedStyle.paragraphSpacingBefore > 0 {
                output.append(makeTopSpacer(height: element.resolvedStyle.paragraphSpacingBefore, style: parentStyle, config: config))
                nodeToRender = .element(adjustedTopLevelBlockElement(element))
            } else {
                nodeToRender = node
            }
            let rendered = await renderNode(nodeToRender, inheritedStyle: parentStyle, config: config)
            if rendered.length == 0 {
                // HR divider may produce a zero-length attributed string
                if case .element(let el) = node, el.tag == "hr" {
                    let fallback = makeHRDivider(style: el.resolvedStyle, config: config)
                    output.append(fallback)
                }
                continue
            }
            // Skip whitespace-only text nodes between block-level elements (indentation whitespace between body and block elements),
            // to prevent them from being merged into the next paragraph by CoreText, which would corrupt that paragraph's paragraphStyle
            if rendered.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !containsRenderableMetadata(rendered) {
                continue
            }
            appendNode(rendered, to: output)
        }
        trimTrailingBreaks(in: output)
        return output
    }

    private func adjustedTopLevelBlockElement(_ element: ElementNode) -> ElementNode {
        var style = element.resolvedStyle
        style.visualOffsetBefore = style.paragraphSpacingBefore
        style.paragraphSpacingBefore = 0
        return ElementNode(
            tag: element.tag,
            id: element.id,
            classes: element.classes,
            attributes: element.attributes,
            resolvedStyle: style,
            children: element.children
        )
    }

    private func makeTopSpacer(height: CGFloat, style: ResolvedStyle, config: Config) -> NSAttributedString {
        guard height > 0 else { return NSAttributedString() }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = height
        paragraph.maximumLineHeight = height
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        return NSAttributedString(
            string: Self.paragraphSeparator,
            attributes: [
                .font: makeFont(from: style, config: config),
                .foregroundColor: UIColor.clear,
                .paragraphStyle: paragraph,
            ]
        )
    }

    /// A decorated container (border/background/padding wrapping block children, e.g. an
    /// `aside.note` callout) draws its box by insetting the union of its child block lines
    /// outward by border + padding. But each child block carries its own paragraph style,
    /// so the container's own top/bottom margin + padding + border is never reserved as
    /// vertical space — the drawn box then butts against (or overlaps) the neighbouring
    /// block above/below, and adjacent callouts collide. Fold that inset into the first
    /// child's `paragraphSpacingBefore` and the last child's `paragraphSpacing`. Shared by
    /// both render pipelines (legacy `renderNode` and the RenderableNode IR renderer).
    static func reserveContainerBlockInsets(
        in output: NSMutableAttributedString,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) {
        guard output.length > 0 else { return }
        if topInset > 0 {
            var range = NSRange(location: 0, length: 0)
            if let para = output.attribute(.paragraphStyle, at: 0, effectiveRange: &range) as? NSParagraphStyle,
               let mutable = para.mutableCopy() as? NSMutableParagraphStyle {
                mutable.paragraphSpacingBefore += topInset
                output.addAttribute(.paragraphStyle, value: mutable, range: range)
            }
        }
        if bottomInset > 0 {
            var range = NSRange(location: 0, length: 0)
            if let para = output.attribute(.paragraphStyle, at: output.length - 1, effectiveRange: &range) as? NSParagraphStyle,
               let mutable = para.mutableCopy() as? NSMutableParagraphStyle {
                mutable.paragraphSpacing += bottomInset
                output.addAttribute(.paragraphStyle, value: mutable, range: range)
            }
        }
    }

    private func verticalInlineSpacer(advance: CGFloat, style: ResolvedStyle, config: Config) -> NSAttributedString {
        let font = makeFont(from: style, config: config)
        let spacer = NSMutableAttributedString(attributedString: RunDelegateProvider.makeVerticalSpacerPlaceholder(
            advance: advance,
            font: font,
            textColor: style.textColor
        ))
        let range = NSRange(location: 0, length: spacer.length)
        spacer.addAttributes(baseTextAttributes(style: style, config: config), range: range)
        spacer.addAttribute(Self.spacerRunAttribute, value: true, range: range)
        return spacer
    }

    private func containsRenderableMetadata(_ string: NSAttributedString) -> Bool {
        guard string.length > 0 else { return false }
        let range = NSRange(location: 0, length: string.length)
        let keys: [NSAttributedString.Key] = [
            Self.blockBackgroundColorAttribute,
            Self.blockRenderStyleAttribute,
            Self.blockRenderIDAttribute,
            Self.hrDividerAttribute,
            Self.pageBreakAttribute,
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
        ]
        for key in keys {
            var found = false
            string.enumerateAttribute(key, in: range, options: []) { value, _, stop in
                if value != nil {
                    found = true
                    stop.pointee = true
                }
            }
            if found { return true }
        }
        return false
    }

    private func renderNode(
        _ node: ASTNode,
        inheritedStyle: ResolvedStyle,
        config: Config
    ) async -> NSAttributedString {
        switch node {
        case .pageBreak:
            return Self.makePageBreakMarker(attributes: baseTextAttributes(style: inheritedStyle, config: config))
        case .lineBreak(let breakNode):
            let breakStyle = breakNode.resolvedStyle
            let separator = breakStyle.isBlock ? Self.paragraphSeparator : Self.lineSeparator
            let attributes = breakStyle.isBlock
                ? paragraphTerminatorAttributes(style: inheritedStyle, config: config)
                : baseTextAttributes(style: inheritedStyle, config: config)
            return NSAttributedString(string: separator, attributes: attributes)
        case .text(let textNode):
            return NSAttributedString(
                string: normalizeWhitespace(textNode.text),
                attributes: baseTextAttributes(style: inheritedStyle, config: config)
            )
        case .element(let element):
            if element.tag == "a",
               let href = element.attributes["href"],
               let marker = ReaderHTMLUtilities.decodeReviewHref(href) {
                return makeReviewBadgePlaceholder(marker: marker, href: href, style: element.resolvedStyle, config: config)
            }

            if element.tag == "table" {
                return await renderTableElement(element, config: config)
            }

            if element.tag == "audio" || element.tag == "video" {
                return await renderMediaElement(element, config: config)
            }

            if element.tag == "img" || element.tag == "image" {
                let src = imageSource(from: element)
                let image = src.isEmpty ? nil : await imageLoader?(src)
                var imgStyle = element.resolvedStyle
                resolveSVGPresentationAttributes(element, style: &imgStyle, config: config)
                if element.classes.contains("font_patch"),
                   shouldLogEPUBFlow(key: "render.img.font_patch", limit: 8) {
                    epubFlowLog("render.img.font_patch src=\(src) alt=\(element.attributes["alt"] ?? "nil") imageLoaded=\(image != nil) style=\(styleProbeSummary(imgStyle))")
                }
                return makeImagePlaceholder(
                    image: image,
                    config: config,
                    style: imgStyle,
                    imageSource: src,
                    imageAlt: element.attributes["alt"]
                )
            }

            if element.tag == "svg", let svgContent = element.svgContent, !svgContent.isEmpty {
                return await makeSVGPlaceholder(
                    svgContent: svgContent,
                    element: element,
                    config: config
                )
            }

            if element.tag == "ruby" {
                return await renderRubyElement(element, inheritedStyle: inheritedStyle, config: config)
            }

            if config.writingMode.isVertical, isInlineAnnotationElement(element) {
                let annotationContent = NSMutableAttributedString()
                for child in element.children {
                    let childString = await renderNode(child, inheritedStyle: element.resolvedStyle, config: config)
                    if childString.length == 0 { continue }
                    appendNode(childString, to: annotationContent)
                }
                if shouldLogEPUBFlow(key: "render.inlineAnnotation.legacy", limit: 10) {
                    epubFlowLog("render.inlineAnnotation.legacy class=\(element.classes.joined(separator: ".")) contentLen=\(annotationContent.length) preview=\"\(debugTextPreview(annotationContent.string))\"")
                }

                let placeholder = NSMutableAttributedString(attributedString: makeInlineAnnotationPlaceholder(
                    annotationContent,
                    placeholderStyle: inheritedStyle,
                    annotationStyle: element.resolvedStyle,
                    config: config
                ))

                if !element.id.isEmpty, placeholder.length > 0 {
                    placeholder.addAttribute(
                        Self.anchorIDAttribute,
                        value: element.id,
                        range: NSRange(location: 0, length: min(1, placeholder.length))
                    )
                }

                return placeholder
            }

            if element.resolvedStyle.isBlock {
                let block = NSMutableAttributedString(attributedString: await renderBlockElement(element, config: config))
                addSemanticTagIfNeeded(element.tag, to: block)
                // Capture the block's id as an anchor target (TOC fragments frequently point at
                // heading/div blocks, e.g. <h3 id="…">). Inline ids are tagged elsewhere, but the
                // block path returns before that, so anchorOffsets would otherwise miss them.
                guard !element.id.isEmpty, block.length > 0,
                      block.attribute(Self.anchorIDAttribute, at: 0, effectiveRange: nil) == nil
                else { return block }
                let tagged = NSMutableAttributedString(attributedString: block)
                tagged.addAttribute(
                    Self.anchorIDAttribute,
                    value: element.id,
                    range: NSRange(location: 0, length: 1)
                )
                return tagged
            }

            let childResult = NSMutableAttributedString()
            for child in element.children {
                let childString = await renderNode(child, inheritedStyle: element.resolvedStyle, config: config)
                if childString.length == 0 { continue }
                appendNode(childString, to: childResult)
            }

            if childResult.length == 0 {
                return NSAttributedString()
            }

            // Inline element carrying a border → draw it as a bordered "chip" around its glyphs
            // (e.g. an `epub:type="pagebreak"` page-number badge). Block borders are handled by the
            // block-decoration path; this covers the inline case CoreText can't border on its own.
            if let chip = Self.inlineBorderBoxStyle(for: element.resolvedStyle) {
                childResult.addAttribute(
                    Self.inlineBorderBoxAttribute,
                    value: chip,
                    range: NSRange(location: 0, length: childResult.length)
                )
            }

            if element.tag == "a",
               let href = element.attributes["href"],
               !href.isEmpty {
                let range = NSRange(location: 0, length: childResult.length)
                childResult.addAttribute(
                    Self.internalLinkAttribute,
                    value: href,
                    range: range
                )
                // Give a default tap-affordance color ONLY to links the author left untouched.
                // If the author styled the link (bold/italic/sized text, a custom color, an
                // italic TOC description, …) we respect that and add no tint. No forced underline.
                let baseFont = makeFont(from: inheritedStyle, config: config)
                if Self.linkContentIsUnstyled(childResult, baseFont: baseFont) {
                    Self.applyDefaultLinkColor(to: childResult)
                }
            }

            if !element.id.isEmpty {
                childResult.addAttribute(
                    Self.anchorIDAttribute,
                    value: element.id,
                    range: NSRange(location: 0, length: min(1, childResult.length))
                )
            }

            addSemanticTagIfNeeded(element.tag, to: childResult)

            return childResult
        }
    }

    /// Applies the default link color across the whole run. Stamped as
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

    /// Builds an inline-chip style from a resolved style that has at least one border edge, or nil.
    /// Used only for inline (non-block) elements — block borders go through the block decoration path.
    private static func inlineBorderBoxStyle(for style: ResolvedStyle) -> InlineBorderBoxStyle? {
        guard !style.isBlock else { return nil }
        let widths = [style.borderTopWidth, style.borderBottomWidth, style.borderLeftWidth, style.borderRightWidth]
        guard let borderWidth = widths.first(where: { $0 > 0 }) else { return nil }
        let borderColor = style.borderTopColor
            ?? style.borderLeftColor
            ?? style.borderRightColor
            ?? style.borderBottomColor
            ?? style.textColor
        return InlineBorderBoxStyle(
            borderColor: borderColor,
            borderWidth: borderWidth,
            cornerRadius: style.borderRadius,
            fillColor: style.backgroundFillColor,
            paddingHorizontal: max(style.paddingLeft, style.paddingRight),
            paddingVertical: max(style.paddingTop, style.paddingBottom)
        )
    }

    static func makePageBreakMarker(attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let marker = NSMutableAttributedString(string: pageBreakMarker, attributes: attributes)
        marker.addAttribute(pageBreakAttribute, value: true, range: NSRange(location: 0, length: marker.length))
        marker.addAttribute(.foregroundColor, value: UIColor.clear, range: NSRange(location: 0, length: marker.length))
        return marker
    }

    static func makeRubyAnnotation(text: String) -> CTRubyAnnotation {
        let attributes: [CFString: Any] = [
            kCTRubyAnnotationSizeFactorAttributeName: 0.5,
            kCTRubyAnnotationScaleToFitAttributeName: true,
        ]
        return CTRubyAnnotationCreateWithAttributes(
            .auto,
            .auto,
            .before,
            text as CFString,
            attributes as CFDictionary
        )
    }

    private func renderRubyElement(
        _ element: ElementNode,
        inheritedStyle: ResolvedStyle,
        config: Config
    ) async -> NSAttributedString {
        let base = NSMutableAttributedString()
        var pendingBase: [ASTNode] = []

        func renderPendingBase(with annotationText: String?) async {
            guard !pendingBase.isEmpty else { return }
            let segment = NSMutableAttributedString()
            for child in pendingBase {
                let childString = await renderNode(child, inheritedStyle: element.resolvedStyle, config: config)
                if childString.length == 0 { continue }
                appendNode(childString, to: segment)
            }
            if let annotationText {
                addRubyAnnotation(annotationText, to: segment)
            }
            appendNode(segment, to: base)
            pendingBase.removeAll()
        }

        for child in element.children {
            if case .element(let rubyChild) = child,
               isRubyAnnotationElement(rubyChild) {
                await renderPendingBase(with: rubyPlainText(from: rubyChild))
            } else {
                pendingBase.append(child)
            }
        }
        await renderPendingBase(with: nil)

        if base.length == 0 {
            return NSAttributedString()
        }
        if !element.id.isEmpty {
            base.addAttribute(
                Self.anchorIDAttribute,
                value: element.id,
                range: NSRange(location: 0, length: min(1, base.length))
            )
        }
        return base
    }

    private func addRubyAnnotation(_ text: String, to attributedString: NSMutableAttributedString) {
        let rubyText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rubyText.isEmpty, attributedString.length > 0 else { return }
        attributedString.addAttribute(
            Self.rubyAnnotationAttribute,
            value: Self.makeRubyAnnotation(text: rubyText),
            range: NSRange(location: 0, length: attributedString.length)
        )
    }

    private func makeHRDivider(style: ResolvedStyle, config: Config) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = style.fontSize * 0.25
        paragraph.paragraphSpacing = style.fontSize * 0.25
        paragraph.minimumLineHeight = style.fontSize
        paragraph.maximumLineHeight = style.fontSize

        // A <hr> whose border was explicitly removed (border: none / border-style: none) and
        // that has no positive border and no background fill is a semantic separator only — it
        // must not draw a rule. (e.g. calibre's `.transition`, paired with a visible "—" glyph.)
        // CSS `color`/`height` on such an element are not a substitute for a border, so emit
        // spacing only without the hrDivider attribute.
        let hasVisibleBorder = style.borderTopWidth > 0 || style.borderBottomWidth > 0
        let suppress = style.borderExplicitlyNone && !hasVisibleBorder && style.backgroundFillColor == nil
        if suppress {
            return NSAttributedString(
                string: "\n",
                attributes: [
                    .font: makeFont(from: style, config: config),
                    .foregroundColor: UIColor.clear,
                    .paragraphStyle: paragraph,
                ]
            )
        }

            // Determine color from CSS: border-top-color > border-bottom-color > text color > separator
        let hrColor = style.borderTopColor
            ?? style.borderBottomColor
            ?? (style.hasCSSColor ? style.textColor : nil)
            ?? style.backgroundFillColor
            ?? UIColor.separator
        // Determine width from CSS: border-top-width > height > default 0.5pt
        let hrLineWidth = style.borderTopWidth > 0
            ? style.borderTopWidth
            : (style.height.flatMap { $0 > 0 ? $0 : nil } ?? 0.5)
        // Rule width: explicit width, percentage of content width, or nil (full width)
        let ruleWidth: CGFloat? = style.width
        let ruleWidthPercent: CGFloat? = style.rawWidthPercent
        let hrStyle = HRDividerStyle(
            color: hrColor,
            lineWidth: hrLineWidth,
            ruleWidth: ruleWidth,
            ruleWidthPercent: ruleWidthPercent,
            marginLeft: style.marginLeft,
            marginRight: style.marginRight,
            inheritedBlockMarginLeft: style.inheritedBlockMarginLeft,
            inheritedBlockMarginRight: style.inheritedBlockMarginRight,
            alignment: style.textAlign,
            isHorizontallyCentered: style.isHorizontallyCentered
        )

        return NSAttributedString(
            string: "\n",
            attributes: [
                .font: makeFont(from: style, config: config),
                .foregroundColor: UIColor.clear,
                .paragraphStyle: paragraph,
                Self.hrDividerAttribute: hrStyle,
            ]
        )
    }

    private func renderTableElement(
        _ element: ElementNode,
        config: Config
    ) async -> NSAttributedString {
        guard let table = HTMLTableModel.from(element: element) else {
            return NSAttributedString()
        }
        var tableStyle = element.resolvedStyle
        tableStyle.textIndent = 0
        let font = makeFont(from: tableStyle, config: config)
        let tableTextColor = tableStyle.textColor
        let image = await MainActor.run {
            HTMLTableRasterizer.render(
                table: table,
                maxWidth: config.renderWidth,
                baseFont: font,
                textColor: tableTextColor,
                backgroundColor: config.backgroundColor
            )
        }
        if let image {
            tableStyle.width = image.size.width
            tableStyle.height = image.size.height
        }
        let metrics = resolvedImageMetrics(image: image, config: config, style: tableStyle)
        let placeholder = NSMutableAttributedString(
            attributedString: makeImagePlaceholder(
                image: image,
                config: config,
                style: tableStyle,
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
                base: makeParagraphStyle(for: tableStyle, config: config),
                metrics: metrics
            ),
            range: range
        )
        addSemanticTagIfNeeded(element.tag, to: placeholder)
        let output = NSMutableAttributedString(attributedString: placeholder)
        if shouldTerminateBlock(element) {
            output.append(
                NSAttributedString(
                    string: Self.paragraphSeparator,
                    attributes: paragraphTerminatorAttributes(style: tableStyle, config: config)
                )
            )
        }
        return output
    }

    private func renderMediaElement(
        _ element: ElementNode,
        config: Config
    ) async -> NSAttributedString {
        guard let media = mediaAttachment(from: element) else {
            return NSAttributedString()
        }
        var mediaStyle = element.resolvedStyle
        mediaStyle.textIndent = 0
        let font = makeFont(from: mediaStyle, config: config)
        let mediaTextColor = mediaStyle.textColor
        // Honor the element's CSS box (e.g. `#video1 { width:360px; height:200px }`) so the video
        // placeholder keeps the author's aspect ratio.
        let intrinsicSize: CGSize? = {
            guard let w = element.resolvedStyle.width, w > 0 else { return nil }
            if let h = element.resolvedStyle.height, h > 0 { return CGSize(width: w, height: h) }
            return CGSize(width: w, height: w * 9.0 / 16.0)
        }()
        let image = await MainActor.run {
            EPUBMediaPlaceholderRenderer.image(
                for: media,
                maxWidth: config.renderWidth,
                intrinsicSize: intrinsicSize,
                font: font,
                textColor: mediaTextColor,
                backgroundColor: config.backgroundColor
            )
        }
        mediaStyle.width = image.size.width
        mediaStyle.height = image.size.height
        let metrics = resolvedImageMetrics(image: image, config: config, style: mediaStyle)
        // Use the clamped draw size for the box/centering so the paragraph centers what we actually
        // draw (the placeholder reserves `metrics`, so they must agree).
        mediaStyle.width = metrics.drawWidth
        mediaStyle.height = metrics.drawHeight
        let placeholder = NSMutableAttributedString(
            attributedString: makeImagePlaceholder(
                image: image,
                config: config,
                style: mediaStyle,
                imageSource: media.sourceHref,
                imageAlt: media.title,
                displayMode: mediaStyle.isBlock ? .block : .inline,
                precomputedMetrics: metrics
            )
        )
        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttribute(Self.mediaAttachmentAttribute, value: media, range: range)
        if mediaStyle.isBlock {
            placeholder.addAttribute(
                .paragraphStyle,
                value: imageBlockParagraphStyle(
                    base: makeParagraphStyle(for: mediaStyle, config: config),
                    metrics: metrics
                ),
                range: range
            )
        }
        addSemanticTagIfNeeded(element.tag, to: placeholder)
        let output = NSMutableAttributedString(attributedString: placeholder)
        if mediaStyle.isBlock, shouldTerminateBlock(element) {
            output.append(
                NSAttributedString(
                    string: Self.paragraphSeparator,
                    attributes: paragraphTerminatorAttributes(style: mediaStyle, config: config)
                )
            )
        }
        return output
    }

    private func mediaAttachment(from element: ElementNode) -> EPUBMediaAttachment? {
        let rawSource = mediaSource(from: element)
        guard !rawSource.isEmpty else { return nil }
        let resolvedSource = mediaURLResolver?(rawSource) ?? rawSource
        let kind: EPUBMediaKind = element.tag == "video" ? .video : .audio
        let title = element.attributes["title"]
            ?? element.attributes["aria-label"]
            ?? element.attributes["alt"]
            ?? (kind == .video ? "EPUB Video" : "EPUB Audio")
        return EPUBMediaAttachment(
            kind: kind,
            sourceHref: resolvedSource,
            mediaType: mediaType(from: element),
            title: title,
            posterHref: element.attributes["poster"].flatMap { mediaURLResolver?($0) ?? $0 }
        )
    }

    private func mediaSource(from element: ElementNode) -> String {
        if let src = element.attributes["src"], !src.isEmpty {
            return src
        }
        for child in element.children {
            guard case .element(let childElement) = child else { continue }
            if childElement.tag == "source",
               let src = childElement.attributes["src"],
               !src.isEmpty {
                return src
            }
        }
        return ""
    }

    private func mediaType(from element: ElementNode) -> String? {
        if let type = element.attributes["type"], !type.isEmpty {
            return type
        }
        for child in element.children {
            guard case .element(let childElement) = child else { continue }
            if childElement.tag == "source",
               let type = childElement.attributes["type"],
               !type.isEmpty {
                return type
            }
        }
        return nil
    }

    private func addSemanticTagIfNeeded(_ tag: String, to attributedString: NSMutableAttributedString) {
        guard attributedString.length > 0, Self.isSemanticHTML5Tag(tag) else { return }
        var rangesToTag: [NSRange] = []
        attributedString.enumerateAttribute(
            Self.semanticTagAttribute,
            in: NSRange(location: 0, length: attributedString.length),
            options: []
        ) { value, range, _ in
            if value == nil {
                rangesToTag.append(range)
            }
        }
        for range in rangesToTag {
            attributedString.addAttribute(Self.semanticTagAttribute, value: tag, range: range)
        }
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

    private func renderBlockElement(
        _ element: ElementNode,
        config: Config
    ) async -> NSAttributedString {
        // hr: returns a divider placeholder carrying hrDividerAttribute
        if element.tag == "hr" {
            return makeHRDivider(style: element.resolvedStyle, config: config)
        }

        if let imageOnlyBlock = await renderImageOnlyBlockElement(element, config: config) {
            return imageOnlyBlock
        }

        let output = NSMutableAttributedString()
        var segment = NSMutableAttributedString()
        var paragraphIndex = 0
        let blockRenderID = UUID().uuidString

        // List item: prepend bullet string (hanging indent handled by makeParagraphStyle)
        if let bullet = element.resolvedStyle.listBullet {
            let bulletAttrs = baseTextAttributes(style: element.resolvedStyle, config: config)
            segment.append(NSAttributedString(string: bullet, attributes: bulletAttrs))
        }

        func appendSegment(isLast: Bool) {
            guard segment.length > 0 else { return }

            // Truncate leading and trailing whitespace and newlines at paragraph boundaries to prevent layout disruption.
            let trimCharSet = CharacterSet(charactersIn: " \n\r\t\u{000C}")
            while segment.length > 0, let first = segment.string.unicodeScalars.first, trimCharSet.contains(first) {
                segment.deleteCharacters(in: NSRange(location: 0, length: 1))
            }
            while segment.length > 0, let last = segment.string.unicodeScalars.last, trimCharSet.contains(last) {
                segment.deleteCharacters(in: NSRange(location: segment.length - 1, length: 1))
            }

            guard segment.length > 0 else { return }

            let segmentStyle = paragraphSegmentStyle(
                base: element.resolvedStyle,
                paragraphIndex: paragraphIndex,
                isLast: isLast
            )
            if segmentStyle.isVerticalWritingMode || config.writingMode.isVertical,
               paragraphIndex == 0,
               segmentStyle.visualOffsetBefore > 0 {
                segment.insert(verticalInlineSpacer(advance: segmentStyle.visualOffsetBefore, style: segmentStyle, config: config), at: 0)
            }
            let paragraphRange = NSRange(location: 0, length: segment.length)
            applyFlattenedParagraphStyle(
                makeParagraphStyle(for: segmentStyle, config: config),
                to: segment,
                range: paragraphRange
            )
            if let backgroundFillColor = segmentStyle.backgroundFillColor {
                segment.addAttribute(
                    Self.blockBackgroundColorAttribute,
                    value: backgroundFillColor,
                    range: paragraphRange
                )
            }
            if let blockRenderStyle = makeBlockRenderStyle(from: segmentStyle) {
                segment.addAttribute(
                    Self.blockRenderStyleAttribute,
                    value: blockRenderStyle,
                    range: paragraphRange
                )
                segment.addAttribute(
                    Self.blockRenderIDAttribute,
                    value: blockRenderID,
                    range: paragraphRange
                )
            }
            output.append(segment)
            if !isLast {
                output.append(
                    NSAttributedString(
                        string: Self.paragraphSeparator,
                        attributes: paragraphTerminatorAttributes(style: segmentStyle, config: config)
                    )
                )
            } else if shouldTerminateBlock(element) {
                output.append(
                    NSAttributedString(
                        string: Self.paragraphSeparator,
                        attributes: paragraphTerminatorAttributes(style: segmentStyle, config: config)
                    )
                )
            }
            segment = NSMutableAttributedString()
            paragraphIndex += 1
        }

        var hasBlockChild = false

        for child in element.children {
            switch child {
            case .pageBreak:
                appendSegment(isLast: false)
                let marker = Self.makePageBreakMarker(attributes: baseTextAttributes(style: element.resolvedStyle, config: config))
                appendNode(marker, to: output)
            case .lineBreak(let breakNode) where breakNode.resolvedStyle.isBlock:
                appendSegment(isLast: false)
            case .element(let childElement) where childElement.resolvedStyle.isBlock:
                hasBlockChild = true
                appendSegment(isLast: false)
                let rendered = await renderNode(child, inheritedStyle: element.resolvedStyle, config: config)
                if rendered.length > 0 {
                    appendNode(rendered, to: output)
                }
            default:
                let childString = await renderNode(child, inheritedStyle: element.resolvedStyle, config: config)
                if childString.length == 0 { continue }
                appendNode(childString, to: segment)
            }
        }

        // When the segment is whitespace-only but the element has visual decoration (e.g. border-top),
        // replace the empty segment with a controlled-height spacer to avoid the whitespace being
        // discarded by appendNode, and to prevent a \n character from creating unintended height.
        // When there are block children, skip the spacer: container decoration already correctly
        // encompasses the union of child block lines. Adding a spacer here would create an extra
        // decoration group, drawing an empty rectangle.
        let segStyle0 = paragraphSegmentStyle(base: element.resolvedStyle, paragraphIndex: 0, isLast: true)
        if !hasBlockChild,
           segment.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let blockRenderStyle = makeBlockRenderStyle(from: segStyle0),
           blockRenderStyle.hasVisualDecoration {
            let bTop = element.resolvedStyle.borderTopWidth
            let bBottom = element.resolvedStyle.borderBottomWidth
            let spacerHeight = max(bTop + bBottom > 0 ? max(bTop, bBottom) * 2 + 2 : 0, 6)
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = spacerHeight
            para.maximumLineHeight = spacerHeight
            para.paragraphSpacing = 0
            para.paragraphSpacingBefore = 0
            segment = NSMutableAttributedString(
                string: "\u{200B}",
                attributes: [
                    .font: makeFont(from: element.resolvedStyle, config: config),
                    .foregroundColor: UIColor.clear,
                    .paragraphStyle: para,
                ]
            )
        }

        appendSegment(isLast: true)

        // ── Container-level decoration ──
        // Only apply container-level attributes when this element contains block children,
        // so extractBlockRenderables can union all lines into a complete rectangle.
        // If there are no block children, the inline segment's blockRenderStyle is sufficient.
        if hasBlockChild,
           output.length > 0,
           let containerStyle = makeBlockRenderStyle(from: element.resolvedStyle),
           containerStyle.hasVisualDecoration {
            let containerID = "container-" + blockRenderID
            let fullRange = NSRange(location: 0, length: output.length)
            output.addAttribute(Self.containerBlockRenderStyleAttribute, value: containerStyle, range: fullRange)
            output.addAttribute(Self.containerBlockRenderIDAttribute, value: containerID, range: fullRange)
            if let bgColor = element.resolvedStyle.backgroundFillColor {
                output.addAttribute(Self.blockBackgroundColorAttribute, value: bgColor, range: fullRange)
            }
            if !element.resolvedStyle.isVerticalWritingMode {
                let s = element.resolvedStyle
                Self.reserveContainerBlockInsets(
                    in: output,
                    topInset: s.paragraphSpacingBefore + s.paddingTop + s.borderTopWidth,
                    bottomInset: s.paragraphSpacing + s.paddingBottom + s.borderBottomWidth
                )
            }
        }

        // Apply :first-letter styles to the first typographic letter unit
        if let flSizeMul = element.resolvedStyle.firstLetterFontSizeMultiplier, output.length > 0 {
            if let flRange = Self.firstLetterRange(in: output.string) {
                let baseFont = output.attribute(.font, at: flRange.location, effectiveRange: nil) as? UIFont ?? UIFont.systemFont(ofSize: element.resolvedStyle.fontSize)
                let flSize = element.resolvedStyle.fontSize * flSizeMul
                let flWeight = element.resolvedStyle.firstLetterFontWeight ?? element.resolvedStyle.fontWeight
                let system = UIFont.systemFont(ofSize: flSize, weight: uiFontWeight(from: flWeight))
                let flItalic = baseFont.fontDescriptor.symbolicTraits.contains(.traitItalic)
                if flItalic, let desc = system.fontDescriptor.withSymbolicTraits(.traitItalic) {
                    output.addAttribute(.font, value: UIFont(descriptor: desc, size: flSize), range: flRange)
                } else {
                    output.addAttribute(.font, value: system, range: flRange)
                }
                if let flColor = element.resolvedStyle.firstLetterColor {
                    output.addAttribute(.foregroundColor, value: flColor, range: flRange)
                    output.addAttribute(Self.cssSpecifiedForegroundColorAttribute, value: flColor, range: flRange)
                }

                // Relax maximumLineHeight so the first line can grow to fit the large first letter.
                // The simplified drop cap needs no line-height ceiling; otherwise CoreText clips the oversized glyph.
                if let para = output.attribute(.paragraphStyle, at: flRange.location, effectiveRange: nil) as? NSParagraphStyle,
                   let mutablePara = para.mutableCopy() as? NSMutableParagraphStyle {
                    let flRequiredHeight = flSize * 0.7
                    if mutablePara.maximumLineHeight > 0 && mutablePara.maximumLineHeight < flRequiredHeight {
                        mutablePara.maximumLineHeight = 0
                        output.addAttribute(.paragraphStyle, value: mutablePara, range: NSRange(location: 0, length: output.length))
                    }
                }
            }
        }

        return output
    }

    private func renderImageOnlyBlockElement(
        _ element: ElementNode,
        config: Config
    ) async -> NSAttributedString? {
        guard let payload = imageOnlyBlockPayload(from: element.children) else {
            return nil
        }

        let imageElement = payload.imageElement
        let src = imageSource(from: imageElement)
        let image = src.isEmpty ? nil : await imageLoader?(src)

        var attachmentStyle = element.resolvedStyle
        resolveSVGPresentationAttributes(imageElement, style: &attachmentStyle, config: config)

        // Convert percentages relative to font size for images (need render width instead)
        let percentWidth = imageElement.resolvedStyle.rawWidthPercent ?? attachmentStyle.rawWidthPercent
        if let pct = percentWidth {
            attachmentStyle.width = config.renderWidth * pct / 100.0
        }

        let percentHeight = imageElement.resolvedStyle.rawHeightPercent ?? attachmentStyle.rawHeightPercent
        if let pct = percentHeight {
            attachmentStyle.height = config.renderWidth * pct / 100.0
        }

        if attachmentStyle.width == nil, let w = imageElement.resolvedStyle.width {
            attachmentStyle.width = w
        }
        if attachmentStyle.height == nil, let h = imageElement.resolvedStyle.height {
            attachmentStyle.height = h
        }
        if let height = imageElement.resolvedStyle.height ?? attachmentStyle.height {
            attachmentStyle.height = height
        }
        attachmentStyle.paddingTop += imageElement.resolvedStyle.paddingTop
        attachmentStyle.paddingLeft += imageElement.resolvedStyle.paddingLeft
        attachmentStyle.paddingBottom += imageElement.resolvedStyle.paddingBottom
        attachmentStyle.paddingRight += imageElement.resolvedStyle.paddingRight
        attachmentStyle.opacity = imageElement.resolvedStyle.opacity

        let segmentStyle = paragraphSegmentStyle(base: attachmentStyle, paragraphIndex: 0, isLast: true)
        let imageMetrics = resolvedImageMetrics(image: image, config: config, style: segmentStyle)
        let placeholder = NSMutableAttributedString(
            attributedString: makeImagePlaceholder(
                image: image,
                config: config,
                style: segmentStyle,
                imageSource: src,
                imageAlt: imageElement.attributes["alt"],
                displayMode: .block,
                precomputedMetrics: imageMetrics
            )
        )

        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttribute(
            .paragraphStyle,
            value: imageBlockParagraphStyle(
                base: makeParagraphStyle(for: segmentStyle, config: config),
                metrics: imageMetrics
            ),
            range: range
        )
        if let backgroundFillColor = segmentStyle.backgroundFillColor {
            placeholder.addAttribute(
                Self.blockBackgroundColorAttribute,
                value: backgroundFillColor,
                range: range
            )
        }
        if let linkHref = payload.linkHref, !linkHref.isEmpty {
            placeholder.addAttribute(
                Self.internalLinkAttribute,
                value: linkHref,
                range: range
            )
        }
        if let blockRenderStyle = makeBlockRenderStyle(
            from: segmentStyle,
            blockImage: BlockRenderStyle.BlockImage(
                image: image,
                source: src,
                drawSize: CGSize(width: imageMetrics.drawWidth, height: imageMetrics.drawHeight),
                opacity: segmentStyle.opacity,
                alignment: segmentStyle.textAlign,
                paddingTop: segmentStyle.paddingTop,
                paddingLeft: segmentStyle.paddingLeft,
                paddingBottom: segmentStyle.paddingBottom,
                paddingRight: segmentStyle.paddingRight
            )
        ) {
            let blockRenderID = UUID().uuidString
            placeholder.addAttribute(
                Self.blockRenderStyleAttribute,
                value: blockRenderStyle,
                range: range
            )
            placeholder.addAttribute(
                Self.blockRenderIDAttribute,
                value: blockRenderID,
                range: range
            )
        }

        let output = NSMutableAttributedString(attributedString: placeholder)
        if shouldTerminateBlock(element) {
            output.append(
                NSAttributedString(
                    string: Self.paragraphSeparator,
                    attributes: paragraphTerminatorAttributes(style: segmentStyle, config: config)
                )
            )
        }
        return output
    }

    private func appendNode(_ node: NSAttributedString, to output: NSMutableAttributedString) {
        if output.length > 0,
           let last = output.string.unicodeScalars.last,
           let first = node.string.unicodeScalars.first,
           isCollapsibleHTMLWhitespace(last),
           isCollapsibleHTMLWhitespace(first) {
            let trimmed = NSMutableAttributedString(attributedString: node)
            while trimmed.length > 0,
                  let scalar = trimmed.string.unicodeScalars.first,
                  isCollapsibleHTMLWhitespace(scalar) {
                // Never delete a character that carries block render metadata or HR divider
                if trimmed.attribute(Self.blockRenderStyleAttribute, at: 0, effectiveRange: nil) != nil { break }
                if trimmed.attribute(Self.hrDividerAttribute, at: 0, effectiveRange: nil) != nil { break }
                if trimmed.attribute(Self.pageBreakAttribute, at: 0, effectiveRange: nil) != nil { break }
                trimmed.deleteCharacters(in: NSRange(location: 0, length: 1))
            }
            output.append(trimmed)
        } else {
            output.append(node)
        }
    }

    private func isCollapsibleHTMLWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case " ", "\n", "\r", "\t", "\u{000C}", "\u{00A0}":
            return true
        default:
            return false
        }
    }

    private func trimTrailingBreaks(in string: NSMutableAttributedString) {
        while string.length > 0 {
            guard let last = string.string.unicodeScalars.last,
                  last == "\n" || last == "\u{2028}"
            else { break }
            string.deleteCharacters(in: NSRange(location: string.length - 1, length: 1))
        }
    }

    private func shouldTerminateBlock(_ element: ElementNode) -> Bool {
        guard element.resolvedStyle.isBlock else { return false }
        if element.children.contains(where: containsSemanticBlock) {
            return false
        }
        return true
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

    private func paragraphSegmentStyle(
        base: ResolvedStyle,
        paragraphIndex: Int,
        isLast: Bool
    ) -> ResolvedStyle {
        var style = base
        if paragraphIndex > 0 {
            style.textIndent = 0
            // Subsequent segments (2nd+ within the same block element, separated by <br display:block>)
            // do not inherit paragraphSpacingBefore, to prevent repeated margin-top application.
            style.paragraphSpacingBefore = 0
            style.visualOffsetBefore = 0
            // Subsequent paragraphs of a list item omit the bullet but keep the hanging indent (marginLeft unchanged)
            style.listBullet = nil
        }
        if !isLast {
            style.paragraphSpacing = 0
        }
        return style
    }

    private func makeBlockRenderStyle(
        from style: ResolvedStyle,
        blockImage: BlockRenderStyle.BlockImage? = nil
    ) -> BlockRenderStyle? {
        let renderStyle = BlockRenderStyle(
            backgroundFillColor: style.backgroundFillColor,
            borderTopWidth: style.borderTopWidth,
            borderBottomWidth: style.borderBottomWidth,
            borderLeftWidth: style.borderLeftWidth,
            borderRightWidth: style.borderRightWidth,
            borderTopColor: style.borderTopColor,
            borderBottomColor: style.borderBottomColor,
            borderLeftColor: style.borderLeftColor,
            borderRightColor: style.borderRightColor,
            width: style.width,
            height: style.height,
            textAlign: style.textAlign,
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

    private func containsSemanticBlock(_ node: ASTNode) -> Bool {
        switch node {
        case .text, .lineBreak, .pageBreak:
            return false
        case .element(let element):
            return element.resolvedStyle.isBlock
        }
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

    private func backgroundImageSource(from body: ElementNode) -> String? {
        guard let src = body.resolvedStyle.backgroundImage, !src.isEmpty else { return nil }
        return src
    }

    private func flattenRenderableNodes(_ nodes: [ASTNode]) -> [ASTNode] {
        var result: [ASTNode] = []
        for node in nodes {
            switch node {
            case .text(let textNode):
                let trimmed = textNode.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    result.append(node)
                }
            case .lineBreak:
                continue
            case .pageBreak:
                continue
            case .element(let element):
                if element.tag == "div" || element.tag == "body" || element.tag == "svg" || element.tag == "a" {
                    result.append(contentsOf: flattenRenderableNodes(element.children))
                } else {
                    result.append(node)
                }
            }
        }
        return result
    }

    private struct ImageOnlyBlockPayload {
        let imageElement: ElementNode
        let linkHref: String?
    }

    private func imageOnlyBlockPayload(
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
            return imageOnlyBlockPayload(
                from: element.children,
                inheritedLinkHref: element.attributes["href"] ?? inheritedLinkHref
            )
        }

        if element.tag == "div" || element.tag == "body" {
            return imageOnlyBlockPayload(
                from: element.children,
                inheritedLinkHref: inheritedLinkHref
            )
        }

        return nil
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

    private func baseTextAttributes(style: ResolvedStyle, config: Config) -> [NSAttributedString.Key: Any] {
        let font = makeFont(from: style, config: config)
        let lineHeight = style.lineHeightExplicit
            ? max(style.fontSize, style.lineHeight)
            : clampLineHeight(absolute: style.lineHeight, fontSize: style.fontSize)
        // Allow text to vertically center in locked line height, reducing visual offset caused by different font built-in leading.
        var baselineOffset = ReaderTypographyCorrection.baselineOffset(
            font: font,
            targetLineHeight: lineHeight
        )
        // Extra baseline offset for superscript / subscript
        switch style.verticalAlign {
        case .super: baselineOffset += style.fontSize * 0.4
        case .sub:   baselineOffset -= style.fontSize * 0.25
        case .baseline: break
        }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.textColor,
            .baselineOffset: baselineOffset,
        ]
        if let kern = style.letterSpacing {
            attrs[.kern] = kern as NSNumber
        }
        // Synthetic italic: when CSS asks for italic but the resolved font has no italic face (common
        // with embedded EPUB fonts that ship only an upright file, e.g. `font-style:italic` on a
        // family whose only @font-face is regular), shear the glyphs the way browsers fake oblique.
        // NOTE: CoreText's CTFrameDraw ignores the `.obliqueness` attribute (it's a TextKit-only
        // attribute), so the slant must be baked into the font's transform matrix instead.
        if style.isItalic, !font.fontDescriptor.symbolicTraits.contains(.traitItalic) {
            attrs[.font] = Self.synthesizedObliqueFont(from: font)
        }
        if style.hasCSSColor {
            attrs[Self.cssSpecifiedForegroundColorAttribute] = style.textColor
        }
        if !style.isBlock, let backgroundFillColor = style.backgroundFillColor {
            attrs[.backgroundColor] = backgroundFillColor
        }
        if style.underline {
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if style.strikethrough {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    private func paragraphTerminatorAttributes(style: ResolvedStyle, config: Config) -> [NSAttributedString.Key: Any] {
        var attributes = baseTextAttributes(style: style, config: config)
        attributes[.paragraphStyle] = makeParagraphStyle(for: style, config: config)
        return attributes
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

    private func makeFont(from style: ResolvedStyle, config: Config) -> UIFont {
        resolveFontUncached(from: style, config: config)
    }

    /// Resolves the concrete `UIFont` for a style, without logging. `makeFont` wraps this so the
    /// bold/italic diagnostics see the exact font that will be used.
    private func resolveFontUncached(from style: ResolvedStyle, config: Config) -> UIFont {
        let weight = uiFontWeight(from: style.fontWeight)
        if let resolvedFont = resolvedFont?(style.fontFamilies, style.fontWeight, style.isItalic, style.fontSize) {
            return resolvedFont
        }
        for rawFamily in style.fontFamilies {
            let trimmed = rawFamily.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let normalized = normalizeFontName(trimmed)
            let candidate = resolvedFontFamily?(normalized) ?? trimmed
            if let font = exactFont(named: candidate, size: style.fontSize, weight: style.fontWeight, italic: style.isItalic) {
                return wrapCJKFont(font, size: style.fontSize)
            }
            if let font = familyFont(named: candidate, size: style.fontSize, weight: style.fontWeight, italic: style.isItalic) {
                return wrapCJKFont(font, size: style.fontSize)
            }
            // EPUBs commonly name CJK fonts only by generic/vendor names (楷体, 黑体, DK-KAITI,
            // @font-face src: local("KaiTi")) with no embedded file. None of those match an iOS
            // font, so map them onto an installed system CJK family before falling back to Latin.
            if let font = cjkSystemFont(forNormalizedName: normalized, size: style.fontSize, weight: style.fontWeight, italic: style.isItalic) {
                return wrapCJKFont(font, size: style.fontSize)
            }
        }

        let system = UIFont.systemFont(ofSize: style.fontSize, weight: weight)
        if style.isItalic {
            var traits = system.fontDescriptor.symbolicTraits
            traits.insert(.traitItalic)
            if let descriptor = system.fontDescriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: descriptor.addingAttributes(cascadeAttributes()), size: style.fontSize)
            }
        }
        return UIFont(descriptor: system.fontDescriptor.addingAttributes(cascadeAttributes()), size: style.fontSize)
    }

    /// When the primary font is a CJK font, swap the primary to Georgia so Latin glyphs
    /// (curly quotes, punctuation, letters) render with proper serif shapes. The CJK font
    /// is preserved in the cascade list so Chinese / Japanese / Korean text still uses it.
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

    private func exactFont(named name: String, size: CGFloat, weight: Int, italic: Bool) -> UIFont? {
        guard let font = UIFont(name: name, size: size) else { return nil }
        return styledEmbeddedFont(from: font, size: size, weight: weight, italic: italic)
    }

    private func familyFont(named name: String, size: CGFloat, weight: Int, italic: Bool) -> UIFont? {
        let traits = requestedSymbolicTraits(weight: weight, italic: italic)
        guard let descriptor = UIFontDescriptor(fontAttributes: [.family: name]).withSymbolicTraits(traits) else {
            return nil
        }
        let font = UIFont(descriptor: descriptor, size: size)
        guard font.familyName.caseInsensitiveCompare(name) == .orderedSame
            || font.fontName.caseInsensitiveCompare(name) == .orderedSame
        else {
            return nil
        }
        return UIFont(descriptor: font.fontDescriptor.addingAttributes(cascadeAttributes()), size: size)
    }

    /// Resolves a CJK generic family name (楷体 / 宋体 / 黑体 …) or vendor alias (DK-KAITI, kt …)
    /// to an installed iOS system CJK font. Tries concrete PostScript face names first (the most
    /// reliable instantiation), then faces enumerated from the family, then a family descriptor.
    private func cjkSystemFont(forNormalizedName name: String, size: CGFloat, weight: Int, italic: Bool) -> UIFont? {
        guard let target = Self.cjkSystemFontTarget(forNormalized: name) else { return nil }
        let wantBold = weight >= 600
        var candidates = wantBold ? target.boldFaces + target.regularFaces
                                  : target.regularFaces + target.boldFaces
        candidates += UIFont.fontNames(forFamilyName: target.family)
        for face in candidates {
            if let font = UIFont(name: face, size: size) { return font }
        }
        // Not installed (iOS ships only PingFang; Kaiti/Songti/… are downloadable system fonts).
        // Kick off a one-time download; CoreTextPageEngine re-paginates when it lands. Until then
        // this returns nil so the caller falls back to the Latin/system font for this render.
        CJKFontInstaller.shared.ensure(target.family)
        return nil
    }

    /// Maps common Chinese font names — generic (楷体/宋体/黑体/仿宋), vendor (DK-*), and the
    /// `local()` @font-face aliases used by calibre/掌阅 EPUBs — onto the CJK fonts that ship
    /// with iOS, returning the family plus its concrete PostScript faces. iOS has no FangSong,
    /// so 仿宋 maps to the nearest available serif (Songti SC). Names are pre-normalized.
    private static func cjkSystemFontTarget(
        forNormalized name: String
    ) -> (family: String, regularFaces: [String], boldFaces: [String])? {
        switch name {
        case "楷体", "楷體", "楷体_gb2312", "楷体_gbk", "楷体_gb18030", "标楷体", "標楷體",
             "kaiti", "kai", "kt", "stkaiti", "stkai", "kaiti sc", "kaiti tc",
             "dfkai-sb", "dk-kaiti":
            return ("Kaiti SC", ["STKaitiSC-Regular", "Kaiti SC"], ["STKaitiSC-Bold", "STKaitiSC-Black"])
        case "宋体", "宋體", "新宋体", "新宋體", "正文", "明体", "明體", "明朝",
             "songti", "song", "st", "zw", "stsong", "stsongti", "songti sc", "songti tc",
             "simsun", "nsimsun", "mingliu", "pmingliu",
             "方正小标宋_gbk", "方正小标宋", "xiaobiaosong", "dk-songti", "dk-xiaobiaosong":
            return ("Songti SC", ["STSongti-SC-Regular", "Songti SC"], ["STSongti-SC-Bold", "STSongti-SC-Black"])
        case "黑体", "黑體", "黑体-简", "微软雅黑", "微軟雅黑", "雅黑",
             "细黑体", "細黑體", "细黑", "細黑", "苹方", "蘋方",
             "heiti", "hei", "ht", "xihei", "xiheiti", "xht", "xh",
             "stheiti", "sthei", "heiti sc", "heiti tc",
             "microsoft yahei", "simhei", "pingfang", "pingfang sc",
             "dk-heiti", "dk-xiheiti":
            return ("PingFang SC", ["PingFangSC-Regular", "PingFang SC"], ["PingFangSC-Semibold", "PingFangSC-Medium"])
        case "仿宋", "仿宋_gb2312", "fangsong", "stfangsong", "fs", "dk-fangsong":
            return ("Songti SC", ["STSongti-SC-Regular", "Songti SC"], ["STSongti-SC-Bold", "STSongti-SC-Black"])
        default:
            return nil
        }
    }

    private func styledEmbeddedFont(from font: UIFont, size: CGFloat, weight: Int, italic: Bool) -> UIFont {
        var descriptor = font.fontDescriptor
        let requestedTraits = requestedSymbolicTraits(weight: weight, italic: italic)
        if !requestedTraits.isEmpty {
            if let styledDescriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(requestedTraits)) {
                descriptor = styledDescriptor
            } else {
                // Embedded font doesn't support requested traits — fall back to system font
                return systemFontWithTraits(size: size, weight: weight, italic: italic)
            }
        }
        descriptor = descriptor.addingAttributes(cascadeAttributes())
        return UIFont(descriptor: descriptor, size: size)
    }

    private func systemFontWithTraits(size: CGFloat, weight: Int, italic: Bool) -> UIFont {
        let sysWeight = uiFontWeight(from: weight)
        let isBold = weight >= 600
        if isBold && italic {
            let system = UIFont.systemFont(ofSize: size, weight: sysWeight)
            var traits = system.fontDescriptor.symbolicTraits
            traits.insert(.traitItalic)
            if let desc = system.fontDescriptor.withSymbolicTraits(traits) {
                return UIFont(descriptor: desc.addingAttributes(cascadeAttributes()), size: size)
            }
            return UIFont(descriptor: system.fontDescriptor.addingAttributes(cascadeAttributes()), size: size)
        } else if isBold {
            return UIFont(descriptor: UIFont.systemFont(ofSize: size, weight: sysWeight).fontDescriptor.addingAttributes(cascadeAttributes()), size: size)
        } else if italic {
            return UIFont.italicSystemFont(ofSize: size)
        }
        return UIFont(descriptor: UIFont.systemFont(ofSize: size).fontDescriptor.addingAttributes(cascadeAttributes()), size: size)
    }

    private func requestedSymbolicTraits(weight: Int, italic: Bool) -> UIFontDescriptor.SymbolicTraits {
        var traits: UIFontDescriptor.SymbolicTraits = []
        if italic {
            traits.insert(.traitItalic)
        }
        if weight >= 600 {
            traits.insert(.traitBold)
        }
        return traits
    }

    private func cascadeAttributes() -> [UIFontDescriptor.AttributeName: Any] {
        let fallbacks = ["Georgia", "PingFangSC-Regular", "STHeitiSC-Light", "AppleColorEmoji"]
            .compactMap { UIFontDescriptor(name: $0, size: 0) }
        guard !fallbacks.isEmpty else { return [:] }
        return [.cascadeList: fallbacks]
    }

    /// Applies a block's paragraph style across `range`, but skips any sub-range already locked by a
    /// nested block (see `blockParagraphLockAttribute`), then locks the whole range. For ordinary
    /// content nothing is pre-locked, so this is identical to a blanket apply; only an inline element
    /// wrapping `display:block` children (e.g. a TOC `<a>` around two spans) is affected — its child
    /// blocks keep their own indentation instead of being flattened to the enclosing block's.
    private func applyFlattenedParagraphStyle(
        _ paragraphStyle: NSParagraphStyle,
        to attributed: NSMutableAttributedString,
        range: NSRange
    ) {
        guard range.length > 0 else { return }
        attributed.enumerateAttribute(Self.blockParagraphLockAttribute, in: range, options: []) { value, subRange, _ in
            if value == nil {
                attributed.addAttribute(.paragraphStyle, value: paragraphStyle, range: subRange)
            }
        }
        attributed.addAttribute(Self.blockParagraphLockAttribute, value: true, range: range)
    }

    private func makeParagraphStyle(for style: ResolvedStyle, config: Config) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.textAlign
        paragraph.lineBreakMode = .byWordWrapping
        let isVertical = style.isVerticalWritingMode || config.writingMode.isVertical
        if isVertical {
            paragraph.paragraphSpacing = min(style.paragraphSpacing, style.fontSize)
            paragraph.paragraphSpacingBefore = 0
        } else {
            paragraph.paragraphSpacing = style.paragraphSpacing + style.paddingBottom
            paragraph.paragraphSpacingBefore = style.paragraphSpacingBefore + style.paddingTop
        }

        if let bullet = style.listBullet {
            // List item: hanging indent (bullet at marginLeft, continuation lines indented by bullet width)
            let bulletWidth = bulletMeasuredWidth(bullet, fontSize: style.fontSize)
            paragraph.firstLineHeadIndent = style.marginLeft
            paragraph.headIndent = style.marginLeft + bulletWidth
            let tabStop = NSTextTab(textAlignment: .natural, location: style.marginLeft + bulletWidth)
            paragraph.tabStops = [tabStop]
            paragraph.defaultTabInterval = style.marginLeft + bulletWidth
        } else {
            let structuralLeft = style.marginLeft + style.borderLeftWidth + style.paddingLeft + style.inheritedBlockMarginLeft
            let structuralRight = style.marginRight + style.borderRightWidth + style.paddingRight + style.inheritedBlockMarginRight
            // Center within the containing block's CONTENT box (after inherited padding/margins), not
            // the full render width. Centering against renderWidth and then ALSO adding the inherited
            // insets double-counts them, pushing the element off-centre and past the right edge
            // (e.g. a width-pinned <video>/<img> inside a padded <section>).
            let widthInset: CGFloat
            if style.isHorizontallyCentered, let width = style.width {
                let contentBoxWidth = max(width, config.renderWidth - structuralLeft - structuralRight)
                widthInset = max(0, (contentBoxWidth - width) / 2)
            } else {
                widthInset = 0
            }
            let leftInset = structuralLeft + widthInset
            let rightInset = structuralRight + widthInset
            paragraph.headIndent = leftInset
            paragraph.firstLineHeadIndent = leftInset + style.textIndent
            paragraph.tailIndent = -rightInset
        }

        // Use min/maxLineHeight to fix line height, without also setting lineSpacing (which would double the spacing).
        let lineHeight = style.lineHeightExplicit
            ? max(style.fontSize, style.lineHeight)
            : clampLineHeight(absolute: style.lineHeight, fontSize: style.fontSize)
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return paragraph
    }

    /// Estimate the rendered width of a bullet string (used for computing hanging indent distance).
    private func bulletMeasuredWidth(_ bullet: String, fontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize)
        let str = bullet + "\t"
        let size = (str as NSString).size(withAttributes: [.font: font])
        // Reserve extra spacing equivalent to one half-width space
        return ceil(size.width) + fontSize * 0.25
    }

    private struct ImageMetrics {
        let drawWidth: CGFloat
        let drawHeight: CGFloat
        let totalWidth: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    private func imageBlockParagraphStyle(base: NSParagraphStyle, metrics: ImageMetrics) -> NSParagraphStyle {
        let paragraph = base.mutableCopy() as! NSMutableParagraphStyle
        let reservedLineHeight = ceil(max(paragraph.minimumLineHeight, metrics.ascent + metrics.descent))
        paragraph.minimumLineHeight = reservedLineHeight
        paragraph.maximumLineHeight = reservedLineHeight
        return paragraph
    }

    private func resolvedImageMetrics(
        image: UIImage?,
        config: Config,
        style: ResolvedStyle
    ) -> ImageMetrics {
        // 1. Compute available max width. Subtract the element's own box insets AND the inherited
        // block margins/padding (e.g. a padded <section> the image lives in) so a width-pinned image
        // fits the real content box instead of overflowing it.
        let maxDrawWidth = max(1, config.renderWidth
            - style.paddingLeft - style.paddingRight
            - style.marginLeft - style.marginRight
            - style.borderLeftWidth - style.borderRightWidth
            - style.inheritedBlockMarginLeft - style.inheritedBlockMarginRight)
        // Estimated max safe height to prevent tall vertical images from exceeding screen bounds (capped at 1.5x width)
        let maxDrawHeight = max(1, config.renderWidth * 1.5)
        
        var dWidth: CGFloat
        var dHeight: CGFloat
        
        if let image {
            if let explicitWidth = style.width, let explicitHeight = style.height {
                dWidth = explicitWidth
                dHeight = explicitHeight
            } else if let explicitWidth = style.width {
                let ratio = explicitWidth / max(image.size.width, 1)
                dWidth = explicitWidth
                dHeight = image.size.height * ratio
            } else if let explicitHeight = style.height {
                let ratio = explicitHeight / max(image.size.height, 1)
                dWidth = image.size.width * ratio
                dHeight = explicitHeight
            } else {
                dWidth = image.size.width
                dHeight = image.size.height
            }
        } else {
            let fallbackHeight = style.height ?? (maxDrawWidth * 0.6)
            dWidth = style.width ?? maxDrawWidth
            dHeight = fallbackHeight
        }
        
        // Double clamp: both width and height must not exceed bounds.
        // Clamp width first
        if dWidth > maxDrawWidth {
            let scale = maxDrawWidth / max(dWidth, 1)
            dWidth = maxDrawWidth
            dHeight = dHeight * scale
        }
        // Then clamp height
        if dHeight > maxDrawHeight {
            let scale = maxDrawHeight / max(dHeight, 1)
            dHeight = maxDrawHeight
            dWidth = dWidth * scale
        }
        
        let drawWidth = dWidth
        let drawHeight = dHeight
        let isVertical = config.writingMode.isVertical
        let totalWidth = isVertical ? drawHeight : drawWidth + style.paddingLeft + style.paddingRight
        
        let font = makeFont(from: style, config: config)
        let lineHeight = max(style.fontSize, font.lineHeight)
        
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

    private func makeSVGPlaceholder(
        svgContent: String,
        element: ElementNode,
        config: Config
    ) async -> NSAttributedString {
        var style = element.resolvedStyle
        resolveSVGPresentationAttributes(element, style: &style, config: config)

        let targetSize = await SVGWebViewRasterizer.shared.resolveSVGSize(
            styleWidth: style.width,
            styleHeight: style.height,
            attributes: element.attributes,
            renderWidth: config.renderWidth
        )

        let image = await SVGWebViewRasterizer.shared.render(
            svgString: svgContent,
            size: targetSize,
            baseURL: nil
        )

        let alt = element.attributes["aria-label"] ?? element.attributes["alt"]
        let displayMode: ImageRunInfo.DisplayMode = style.isBlock ? .block : .inline

        if image == nil, let alt, !alt.isEmpty {
            var attrs = baseTextAttributes(style: style, config: config)
            attrs[.foregroundColor] = UIColor.secondaryLabel
            return NSAttributedString(string: "[\(alt)]", attributes: attrs)
        }

        let metrics = resolvedImageMetrics(image: image, config: config, style: style)

        let placeholder = NSMutableAttributedString(
            attributedString: makeImagePlaceholder(
                image: image,
                config: config,
                style: style,
                imageSource: "",
                imageAlt: alt,
                displayMode: displayMode,
                precomputedMetrics: metrics
            )
        )
        let range = NSRange(location: 0, length: placeholder.length)
        let paragraph = NSMutableParagraphStyle()
        if style.isHorizontallyCentered {
            paragraph.alignment = .center
        }
        let lineHeight = max(style.fontSize, metrics.ascent + metrics.descent)
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.paragraphSpacingBefore = style.paragraphSpacingBefore
        paragraph.paragraphSpacing = max(0, style.paragraphSpacing)
        placeholder.addAttribute(.paragraphStyle, value: paragraph, range: range)
        return placeholder
    }

    private func makeImagePlaceholder(
        image: UIImage?,
        config: Config,
        style: ResolvedStyle,
        imageSource: String = "",
        imageAlt: String? = nil,
        displayMode: ImageRunInfo.DisplayMode = .inline,
        precomputedMetrics: ImageMetrics? = nil
    ) -> NSAttributedString {
        var correctedStyle = style
        if let pct = style.rawWidthPercent {
            correctedStyle.width = config.renderWidth * pct / 100.0
        }
        if let pct = style.rawHeightPercent {
            correctedStyle.height = config.renderWidth * pct / 100.0
        }

        let metrics: ImageMetrics
        if let precomputedMetrics {
            metrics = precomputedMetrics
        } else {
            metrics = resolvedImageMetrics(image: image, config: config, style: correctedStyle)
        }

        return RunDelegateProvider.makeImagePlaceholder(
            image: image,
            font: makeFont(from: style, config: config),
            textColor: style.textColor,
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
    }

    /// Renders a Legado paragraph-review (段評) marker as an inline, tappable count bubble.
    /// The placeholder carries `internalLinkAttribute = href` (a `ydreview://` action) so the
    /// reader's existing link / attachment tap paths can open the review web page.
    private func makeReviewBadgePlaceholder(
        marker: ReaderHTMLUtilities.ReviewMarker,
        href: String,
        style: ResolvedStyle,
        config: Config
    ) -> NSAttributedString {
        let pointSize = makeFont(from: style, config: config).pointSize
        let color = config.textColor.withAlphaComponent(0.55)
        let image = ReviewBadgeRenderer.bubble(count: marker.count, pointSize: pointSize, color: color)
        var badgeStyle = style
        badgeStyle.width = image.size.width
        badgeStyle.height = image.size.height
        badgeStyle.rawWidthPercent = nil
        badgeStyle.rawHeightPercent = nil
        let placeholder = NSMutableAttributedString(
            attributedString: makeImagePlaceholder(
                image: image,
                config: config,
                style: badgeStyle,
                imageSource: "",
                imageAlt: marker.title,
                displayMode: .inline
            )
        )
        guard placeholder.length > 0 else { return placeholder }
        placeholder.addAttribute(
            Self.internalLinkAttribute,
            value: href,
            range: NSRange(location: 0, length: placeholder.length)
        )
        return placeholder
    }

    private func makeInlineAnnotationPlaceholder(
        _ content: NSAttributedString,
        placeholderStyle: ResolvedStyle,
        annotationStyle: ResolvedStyle,
        config: Config
    ) -> NSAttributedString {
        guard content.length > 0 else { return NSAttributedString() }
        let annotation = NSMutableAttributedString(attributedString: content)
        annotation.normalizeForVerticalLayoutInPlace()
        annotation.addAttribute(
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
            value: true,
            range: NSRange(location: 0, length: annotation.length)
        )
        if shouldLogEPUBFlow(key: "annotation.placeholder.legacy", limit: 10) {
            epubFlowLog("annotation.placeholder.legacy len=\(annotation.length) placeholderFont=\(makeFont(from: placeholderStyle, config: config).pointSize) annotationFont=\(makeFont(from: annotationStyle, config: config).pointSize) preview=\"\(debugTextPreview(annotation.string))\"")
        }
        let placeholder = NSMutableAttributedString(attributedString: RunDelegateProvider.makeInlineAnnotationPlaceholder(
            attributedString: annotation,
            placeholderFont: makeFont(from: placeholderStyle, config: config),
            textColor: annotationStyle.textColor
        ))
        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttribute(Self.inlineAnnotationRunAttribute, value: true, range: range)
        placeholder.addAttribute(Self.spacerRunAttribute, value: true, range: range)
        return placeholder
    }

    private func isInlineAnnotationElement(_ element: ElementNode) -> Bool {
        guard element.tag == "span" else { return false }
        return element.classes.contains { className in
            className == "small" || className.hasPrefix("small")
        }
    }

    private func isRubyAnnotationElement(_ element: ElementNode) -> Bool {
        element.tag == "rt" || element.tag == "rp"
    }

    private func rubyPlainText(from element: ElementNode) -> String {
        element.children.map { node -> String in
            switch node {
            case .text(let text):
                return text.text
            case .lineBreak:
                return " "
            case .pageBreak:
                return ""
            case .element(let child):
                return rubyPlainText(from: child)
            }
        }
        .joined()
        .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func inheritedStyle(from parent: ResolvedStyle, tag: String) -> ResolvedStyle {
        ResolvedStyle(
            fontSize: parent.fontSize,
            fontFamilies: parent.fontFamilies,
            fontWeight: parent.fontWeight,
            isItalic: parent.isItalic,
            textColor: parent.textColor,
            textAlign: parent.textAlign,
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
            pageBreakAfter: false
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
            pageBreakAfter: false
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
        if let border = declarations["border"] {
            applyBorderShorthand(border, edge: .top, to: &style)
            applyBorderShorthand(border, edge: .bottom, to: &style)
            applyBorderShorthand(border, edge: .left, to: &style)
            applyBorderShorthand(border, edge: .right, to: &style)
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
        // `border-style: none/hidden` removes the border regardless of any width set elsewhere.
        applyBorderStyleNone(declarations["border-style"], edges: [.top, .bottom, .left, .right], to: &style)
        applyBorderStyleNone(declarations["border-top-style"], edges: [.top], to: &style)
        applyBorderStyleNone(declarations["border-bottom-style"], edges: [.bottom], to: &style)
        applyBorderStyleNone(declarations["border-left-style"], edges: [.left], to: &style)
        applyBorderStyleNone(declarations["border-right-style"], edges: [.right], to: &style)
        if let borderRadius = declarations["border-radius"] {
            style.borderRadius = max(0, resolveLength(borderRadius, currentFontSize: style.fontSize, rootFontSize: rootFontSize, relativeBase: style.fontSize) ?? 0)
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
            setBorder(width: 0, color: nil, edge: edge, to: &style)
            return
        }

        var width: CGFloat?
        var color: UIColor?
        for token in tokens {
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

        setBorder(width: width ?? 0, color: color, edge: edge, to: &style)
    }

    private func parseBorderColor(_ raw: String, currentTextColor: UIColor) -> UIColor? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized == "currentcolor" {
            return currentTextColor
        }
        return parseColor(raw)
    }

    /// Honors `border-style: none/hidden` (any edge): zeroes the matching border widths and
    /// records that the author explicitly suppressed the border, so an `<hr>` won't draw a rule.
    private func applyBorderStyleNone(_ raw: String?, edges: [BorderEdge], to style: inout ResolvedStyle) {
        guard let raw else { return }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value == "none" || value == "hidden" else { return }
        style.borderExplicitlyNone = true
        for edge in edges {
            setBorder(width: 0, color: nil, edge: edge, to: &style)
        }
    }

    private func setBorder(width: CGFloat, color: UIColor?, edge: BorderEdge, to style: inout ResolvedStyle) {
        switch edge {
        case .top:
            style.borderTopWidth = width
            style.borderTopColor = color
        case .bottom:
            style.borderBottomWidth = width
            style.borderBottomColor = color
        case .left:
            style.borderLeftWidth = width
            style.borderLeftColor = color
        case .right:
            style.borderRightWidth = width
            style.borderRightColor = color
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
            "alt", "title", "aria-label", "poster", "type", "controls", "colspan", "rowspan", "scope"
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
