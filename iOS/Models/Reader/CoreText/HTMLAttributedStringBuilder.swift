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
    /// 容器層裝飾（與 blockRenderStyle 並存，用於父 div 的 border/background 跨越 block 子元素）。
    static let containerBlockRenderStyleAttribute = NSAttributedString.Key("ReaderContainerBlockRenderStyle")
    static let containerBlockRenderIDAttribute = NSAttributedString.Key("ReaderContainerBlockRenderID")
    /// Marker attribute: CSS 明確指定的前景色。withUpdatedColors() 不會覆蓋帶有此標記的 range。
    static let cssSpecifiedForegroundColorAttribute = NSAttributedString.Key("ReaderCSSSpecifiedForegroundColor")
    private static let paragraphSeparator = "\n"
    private static let lineSeparator = "\u{2028}"

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
        /// CSS 是否明確指定了 line-height（true = 不做 clamp）
        var lineHeightExplicit: Bool
        var paragraphSpacing: CGFloat
        var paragraphSpacingBefore: CGFloat
        var visualOffsetBefore: CGFloat
        /// margin-left（blockquote / 巢狀列表縮排）
        var marginLeft: CGFloat
        /// list item 的 bullet 或序號字串（如 "•" / "1."），nil 表示非列表項
        var listBullet: String?
        var verticalAlign: VerticalAlign
        var isBlock: Bool
        var backgroundImage: String?
        var backgroundFillColor: UIColor?
        var width: CGFloat?
        var height: CGFloat?
        var rawWidthPercent: CGFloat?
        var rawHeightPercent: CGFloat?
        var marginRight: CGFloat
        var paddingLeft: CGFloat
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
        /// CSS letter-spacing（px 值），nil = 使用預設字距
        var letterSpacing: CGFloat?
        /// CSS 是否明確指定了 `color`（含繼承自 CSS 父層），
        /// withUpdatedColors() 會據此判斷是否保留原色。
        var hasCSSColor: Bool
        /// 使用者設定的段距，從 root 傳播，不受 CSS margin 覆蓋。
        /// 用於確保 <p> 預設段距不被 EPUB CSS body/div margin:0 歸零。
        var configParagraphSpacing: CGFloat
    }

    /// HR 分隔線的視覺樣式（儲存在 hrDividerAttribute 中）。
    struct HRDividerStyle {
        let color: UIColor?
        let lineWidth: CGFloat?
    }

    struct BlockRenderStyle {
        struct BlockImage {
            let image: UIImage?
            let source: String
            let drawSize: CGSize
            let opacity: CGFloat
            let alignment: NSTextAlignment
            let paddingLeft: CGFloat
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
        let paddingLeft: CGFloat
        let paddingRight: CGFloat
        let blockImage: BlockImage?

        var hasVisualDecoration: Bool {
            backgroundFillColor != nil
                || borderTopWidth > 0 || borderBottomWidth > 0
                || borderLeftWidth > 0 || borderRightWidth > 0
                || blockImage != nil
        }
    }

    indirect enum ASTNode {
        case text(TextNode)
        case lineBreak(BreakNode)
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
    }

    var imageLoader: ((String) async -> UIImage?)?
    var cssLoader: ((String) async -> String?)?
    var resolvedFontFamily: ((String) -> String?)?
    var resolvedFont: (([String], Int, Bool, CGFloat) -> UIFont?)?

    private let domParser = HTMLBuilderDOMParser()
    private let styleResolver = HTMLBuilderStyleResolver()
    private let coreTextRenderer = HTMLBuilderCoreTextRenderer()
    private let cssPropertyRegistry = HTMLCSSPropertyApplierRegistry.defaultRegistry
    private static let dirtyCJKSpaceRegex: NSRegularExpression? = {
        // 清洗「漢字 + 空白(含 NBSP / &nbsp;) + 漢字」的轉檔髒資料，避免 justify 拉爆間距。
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
            debugLog: { result in
                self.debugLog(result: result)
            }
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
        let sanitizedHTML = cleanDirtySpacesInHTML(html)
        guard let parsed = await domParser.parse(
            html: sanitizedHTML,
            collectStyles: { document in
                await self.collectStyles(from: document)
            }
        ) else {
            return nil
        }

        return await styleResolver.buildAST(
            from: parsed,
            config: config,
            makeRootStyle: { config in
                self.makeRootStyle(config: config)
            },
            resolveStyle: { element, parent, rules, rootFontSize, parentElement in
                self.resolvedStyle(
                    for: element,
                    parent: parent,
                    rules: rules,
                    rootFontSize: rootFontSize,
                    parentElement: parentElement
                )
            },
            buildChildren: { nodes, parentStyle, rules, rootFontSize, parentElement in
                return await self.buildChildren(
                    from: nodes,
                    parentStyle: parentStyle,
                    rules: rules,
                    rootFontSize: rootFontSize,
                    parentElement: parentElement
                )
            },
            makeAttributeMap: { element in
                self.makeAttributeMap(for: element)
            }
        )
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
            for styleTag in styleTags {
                let css = (try? styleTag.html()) ?? ""
                if !css.isEmpty { styles.append(css) }
            }

            let links = (try? head.select("link[rel=stylesheet]").array()) ?? []
            print("[HTMLBuilder] injectLinkedCSS: found \(links.count) stylesheet link(s)")
            for link in links {
                let href = (try? link.attr("href")) ?? ""
                guard !href.isEmpty else { continue }
                print("[HTMLBuilder] injectLinkedCSS: fetching CSS href=\(href)")
                guard let cssText = await cssLoader?(href), !cssText.isEmpty else {
                    print("[HTMLBuilder] injectLinkedCSS: FAILED or empty CSS for href=\(href)")
                    continue
                }
                print("[HTMLBuilder] injectLinkedCSS: injected CSS len=\(cssText.count) for href=\(href)")
                styles.append(cssText)
            }
        }
        return styles
    }

    private func buildChildren(
        from nodes: [Node],
        parentStyle: ResolvedStyle,
        rules: [CSSRule],
        rootFontSize: CGFloat,
        parentElement: Element?
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
                    parentElement: parentElement
                )
                result.append(.lineBreak(BreakNode(resolvedStyle: style)))
                continue
            }

            let style = resolvedStyle(
                for: element,
                parent: parentStyle,
                rules: rules,
                rootFontSize: rootFontSize,
                parentElement: parentElement
            )
            let children = await buildChildren(
                from: element.getChildNodes(),
                parentStyle: style,
                rules: rules,
                rootFontSize: rootFontSize,
                parentElement: element
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
            if rendered.length == 0 { continue }
            // 跳過 block 頂層的純空白 text node（body 與 block 元素之間的縮排空白），
            // 避免它們被 CoreText 歸入下一個 paragraph，污染該段落的 paragraphStyle
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

    private func containsRenderableMetadata(_ string: NSAttributedString) -> Bool {
        guard string.length > 0 else { return false }
        let range = NSRange(location: 0, length: string.length)
        let keys: [NSAttributedString.Key] = [
            Self.blockBackgroundColorAttribute,
            Self.blockRenderStyleAttribute,
            Self.blockRenderIDAttribute,
            Self.hrDividerAttribute,
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
            if element.tag == "img" || element.tag == "image" {
                let src = imageSource(from: element)
                let image = src.isEmpty ? nil : await imageLoader?(src)
                return makeImagePlaceholder(
                    image: image,
                    config: config,
                    style: element.resolvedStyle,
                    imageSource: src
                )
            }

            if element.resolvedStyle.isBlock {
                return await renderBlockElement(element, config: config)
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

            if element.tag == "a",
               let href = element.attributes["href"],
               !href.isEmpty {
                childResult.addAttribute(
                    Self.internalLinkAttribute,
                    value: href,
                    range: NSRange(location: 0, length: childResult.length)
                )
            }

            if !element.id.isEmpty {
                childResult.addAttribute(
                    Self.anchorIDAttribute,
                    value: element.id,
                    range: NSRange(location: 0, length: min(1, childResult.length))
                )
            }

            return childResult
        }
    }

    private func makeHRDivider(style: ResolvedStyle, config: Config) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = style.fontSize * 0.5
        paragraph.paragraphSpacing = style.fontSize * 0.5
        paragraph.minimumLineHeight = style.fontSize
        paragraph.maximumLineHeight = style.fontSize

        // 從 CSS 推斷 HR 顏色：border-top-color > border-bottom-color > text color > separator
        let hrColor = style.borderTopColor
            ?? style.borderBottomColor
            ?? (style.hasCSSColor ? style.textColor : nil)
            ?? style.backgroundFillColor
            ?? UIColor.separator
        // 從 CSS 推斷 HR 粗細：border-top-width > height > 預設 0.5pt
        let hrLineWidth = style.borderTopWidth > 0
            ? style.borderTopWidth
            : (style.height.flatMap { $0 > 0 ? $0 : nil } ?? 0.5)
        let hrStyle = HRDividerStyle(color: hrColor, lineWidth: hrLineWidth)

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

    private func renderBlockElement(
        _ element: ElementNode,
        config: Config
    ) async -> NSAttributedString {
        // hr: 回傳帶有 hrDividerAttribute 的分隔線佔位
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

        // 列表項：前置 bullet 字串（hanging indent 由 makeParagraphStyle 處理）
        if let bullet = element.resolvedStyle.listBullet {
            let bulletAttrs = baseTextAttributes(style: element.resolvedStyle, config: config)
            segment.append(NSAttributedString(string: bullet, attributes: bulletAttrs))
        }

        func appendSegment(isLast: Bool) {
            guard segment.length > 0 else { return }

            // ⚠️【關鍵修復 2】：剔除段落開頭與結尾的半形空白與換行，避免排版大亂。
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
            let paragraphRange = NSRange(location: 0, length: segment.length)
            segment.addAttribute(
                .paragraphStyle,
                value: makeParagraphStyle(for: segmentStyle, config: config),
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

        // 若 segment 只有空白字元但元素有視覺裝飾（如 border-top），
        // 把空白 segment 換成受控高度的 spacer，避免空白被 appendNode 丟棄，
        // 也避免 \n 字元撐出不必要的高度。
        // ⚠️ 有 block 子元素時不做 spacer：容器裝飾透過 union block 子元素的行
        // 已能正確包覆整體範圍。若仍建 spacer，appendSegment 會套上 blockRenderStyleAttribute
        // 形成額外的 decoration group，導致多畫一個空白框。
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

        // ── 容器層裝飾 ──
        // 僅當此元素包含 block 子元素時，才套用容器層 attribute，
        // 讓 extractBlockRenderables 能將所有行 union 成一個完整的矩形。
        // 若無 block 子元素，inline segment 的 blockRenderStyle 已足夠。
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
        }

        return output
    }

    private func renderImageOnlyBlockElement(
        _ element: ElementNode,
        config: Config
    ) async -> NSAttributedString? {
        let renderables = flattenRenderableNodes(element.children)
        guard renderables.count == 1,
              case .element(let imageElement) = renderables[0],
              imageElement.tag == "img" || imageElement.tag == "image"
        else {
            return nil
        }

        let src = imageSource(from: imageElement)
        let image = src.isEmpty ? nil : await imageLoader?(src)

        var attachmentStyle = element.resolvedStyle
        if let widthValue = imageElement.resolvedStyle.rawWidthPercent {
            // Re-resolve percentage widths relative to render width, not font size
            attachmentStyle.width = config.renderWidth * widthValue / 100.0
        } else if let width = imageElement.resolvedStyle.width {
            attachmentStyle.width = width
        }
        if let height = imageElement.resolvedStyle.height {
            attachmentStyle.height = height
        }
        attachmentStyle.paddingLeft += imageElement.resolvedStyle.paddingLeft
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
                displayMode: .block,
                precomputedMetrics: imageMetrics
            )
        )

        let range = NSRange(location: 0, length: placeholder.length)
        placeholder.addAttribute(
            .paragraphStyle,
            value: makeParagraphStyle(for: segmentStyle, config: config),
            range: range
        )
        if let backgroundFillColor = segmentStyle.backgroundFillColor {
            placeholder.addAttribute(
                Self.blockBackgroundColorAttribute,
                value: backgroundFillColor,
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
                paddingLeft: segmentStyle.paddingLeft,
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
           CharacterSet.whitespacesAndNewlines.contains(last),
           CharacterSet.whitespacesAndNewlines.contains(first) {
            let trimmed = NSMutableAttributedString(attributedString: node)
            while trimmed.length > 0,
                  let scalar = trimmed.string.unicodeScalars.first,
                  CharacterSet.whitespacesAndNewlines.contains(scalar) {
                // Never delete a character that carries block render metadata
                if trimmed.attribute(Self.blockRenderStyleAttribute, at: 0, effectiveRange: nil) != nil { break }
                trimmed.deleteCharacters(in: NSRange(location: 0, length: 1))
            }
            output.append(trimmed)
        } else {
            output.append(node)
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

    private func paragraphSegmentStyle(
        base: ResolvedStyle,
        paragraphIndex: Int,
        isLast: Bool
    ) -> ResolvedStyle {
        var style = base
        if paragraphIndex > 0 {
            style.textIndent = 0
            // 連續段（同一 block element 被 <br display:block> 切開後的第 2+ 段）
            // 不繼承 paragraphSpacingBefore，避免 margin-top 重複施加
            style.paragraphSpacingBefore = 0
            style.visualOffsetBefore = 0
            // 列表項的後續段落不加 bullet，但保留 hanging indent（marginLeft 不變）
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
            paddingLeft: style.paddingLeft,
            paddingRight: style.paddingRight,
            blockImage: blockImage
        )
        return renderStyle.hasVisualDecoration ? renderStyle : nil
    }

    private func containsSemanticBlock(_ node: ASTNode) -> Bool {
        switch node {
        case .text, .lineBreak:
            return false
        case .element(let element):
            return element.resolvedStyle.isBlock
        }
    }

    private func extractImagePage(from body: ElementNode) async -> ImagePage? {
        let candidates = flattenRenderableNodes(body.children)
        guard candidates.count == 1,
              case .element(let imageNode) = candidates[0],
              imageNode.tag == "img" || imageNode.tag == "image"
        else {
            return nil
        }

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
            case .element(let element):
                if element.tag == "div" || element.tag == "body" || element.tag == "svg" {
                    result.append(contentsOf: flattenRenderableNodes(element.children))
                } else {
                    result.append(node)
                }
            }
        }
        return result
    }

    private func imageSource(from element: ElementNode) -> String {
        element.attributes["src"]
            ?? element.attributes["xlink:href"]
            ?? element.attributes["href"]
            ?? ""
    }

    private func baseTextAttributes(style: ResolvedStyle, config: Config) -> [NSAttributedString.Key: Any] {
        let font = makeFont(from: style, config: config)
        let lineHeight = style.lineHeightExplicit
            ? max(style.fontSize, style.lineHeight)
            : clampLineHeight(absolute: style.lineHeight, fontSize: style.fontSize)
        // 讓文字在鎖定行高中垂直居中，減少不同字體內建 leading 造成的視覺偏移。
        var baselineOffset = ReaderTypographyCorrection.baselineOffset(
            font: font,
            targetLineHeight: lineHeight
        )
        // sup / sub 的額外基線偏移
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
        if style.hasCSSColor {
            attrs[Self.cssSpecifiedForegroundColorAttribute] = style.textColor
        }
        return attrs
    }

    private func paragraphTerminatorAttributes(style: ResolvedStyle, config: Config) -> [NSAttributedString.Key: Any] {
        var attributes = baseTextAttributes(style: style, config: config)
        attributes[.paragraphStyle] = makeParagraphStyle(for: style, config: config)
        return attributes
    }

    private func makeFont(from style: ResolvedStyle, config: Config) -> UIFont {
        let weight = uiFontWeight(from: style.fontWeight)
        if let resolvedFont = resolvedFont?(style.fontFamilies, style.fontWeight, style.isItalic, style.fontSize) {
            return resolvedFont
        }
        let familyCandidates = style.fontFamilies
            .compactMap { family -> String? in
                let trimmed = family.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return resolvedFontFamily?(normalizeFontName(trimmed)) ?? trimmed
            }

        for family in familyCandidates {
            if let font = exactFont(named: family, size: style.fontSize, weight: style.fontWeight, italic: style.isItalic) {
                return font
            }
            if let font = familyFont(named: family, size: style.fontSize, weight: style.fontWeight, italic: style.isItalic) {
                return font
            }
        }

        let system = UIFont.systemFont(ofSize: style.fontSize, weight: weight)
        if style.isItalic,
           let descriptor = system.fontDescriptor.withSymbolicTraits(.traitItalic) {
            return UIFont(descriptor: descriptor.addingAttributes(cascadeAttributes()), size: style.fontSize)
        }
        return UIFont(descriptor: system.fontDescriptor.addingAttributes(cascadeAttributes()), size: style.fontSize)
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

    private func styledEmbeddedFont(from font: UIFont, size: CGFloat, weight: Int, italic: Bool) -> UIFont {
        var descriptor = font.fontDescriptor
        let requestedTraits = requestedSymbolicTraits(weight: weight, italic: italic)
        if !requestedTraits.isEmpty,
           let styledDescriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(requestedTraits)) {
            descriptor = styledDescriptor
        }
        descriptor = descriptor.addingAttributes(cascadeAttributes())
        return UIFont(descriptor: descriptor, size: size)
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
        let fallbacks = ["PingFangSC-Regular", "STHeitiSC-Light", "AppleColorEmoji"]
            .compactMap { UIFontDescriptor(name: $0, size: 0) }
        guard !fallbacks.isEmpty else { return [:] }
        return [.cascadeList: fallbacks]
    }

    private func makeParagraphStyle(for style: ResolvedStyle, config: Config) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.textAlign
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.paragraphSpacing = style.paragraphSpacing
        paragraph.paragraphSpacingBefore = style.paragraphSpacingBefore

        if let bullet = style.listBullet {
            // 列表項：懸掛縮排（bullet 在 marginLeft，續行縮排 bullet 寬度）
            let bulletWidth = bulletMeasuredWidth(bullet, fontSize: style.fontSize)
            paragraph.firstLineHeadIndent = style.marginLeft
            paragraph.headIndent = style.marginLeft + bulletWidth
            let tabStop = NSTextTab(textAlignment: .natural, location: style.marginLeft + bulletWidth)
            paragraph.tabStops = [tabStop]
            paragraph.defaultTabInterval = style.marginLeft + bulletWidth
        } else {
            let widthInset: CGFloat
            if style.isHorizontallyCentered, let width = style.width {
                widthInset = max(0, (config.renderWidth - width) / 2)
            } else {
                widthInset = 0
            }
            let leftInset = widthInset + style.marginLeft + style.paddingLeft
            let rightInset = widthInset + style.marginRight + style.paddingRight
            paragraph.headIndent = leftInset
            paragraph.firstLineHeadIndent = leftInset + style.textIndent
            paragraph.tailIndent = -rightInset
        }

        // 用 min/maxLineHeight 固定行高，不再重複設 lineSpacing（會導致行距雙重計算）
        let lineHeight = style.lineHeightExplicit
            ? max(style.fontSize, style.lineHeight)
            : clampLineHeight(absolute: style.lineHeight, fontSize: style.fontSize)
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        return paragraph
    }

    /// 估算 bullet 字串的渲染寬度（用於計算懸掛縮排距離）
    private func bulletMeasuredWidth(_ bullet: String, fontSize: CGFloat) -> CGFloat {
        let font = UIFont.systemFont(ofSize: fontSize)
        let str = bullet + "\t"
        let size = (str as NSString).size(withAttributes: [.font: font])
        // 預留一個半形空格的額外間距
        return ceil(size.width) + fontSize * 0.25
    }

    private struct ImageMetrics {
        let drawWidth: CGFloat
        let drawHeight: CGFloat
        let totalWidth: CGFloat
        let ascent: CGFloat
        let descent: CGFloat
    }

    private func resolvedImageMetrics(
        image: UIImage?,
        config: Config,
        style: ResolvedStyle
    ) -> ImageMetrics {
        // 1. 計算可用最大寬度
        let maxDrawWidth = max(1, config.renderWidth - style.paddingLeft - style.paddingRight)
        // ⚠️ 預估最大安全高度，防止直式長圖超出螢幕上下邊界 (以寬度的 1.5 倍為極限)
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
        
        // ⚠️【關鍵修復 3】：雙重限制，寬度與高度都不可越界
        // 先限制寬度
        if dWidth > maxDrawWidth {
            let scale = maxDrawWidth / max(dWidth, 1)
            dWidth = maxDrawWidth
            dHeight = dHeight * scale
        }
        // 再限制高度
        if dHeight > maxDrawHeight {
            let scale = maxDrawHeight / max(dHeight, 1)
            dHeight = maxDrawHeight
            dWidth = dWidth * scale
        }
        
        let drawWidth = dWidth
        let drawHeight = dHeight
        let totalWidth = drawWidth + style.paddingLeft + style.paddingRight
        
        let font = makeFont(from: style, config: config)
        let lineHeight = max(style.fontSize, font.lineHeight)
        
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

    private func makeImagePlaceholder(
        image: UIImage?,
        config: Config,
        style: ResolvedStyle,
        imageSource: String = "",
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
            displayMode: displayMode,
            opacity: style.opacity
        )
    }

    private func resolvedStyle(
        for element: Element,
        parent: ResolvedStyle,
        rules: [CSSRule],
        rootFontSize: CGFloat,
        parentElement: Element?
    ) -> ResolvedStyle {
        var style = inheritedStyle(from: parent, tag: element.tagName().lowercased())
        apply(
            declarations: userAgentDeclarations(for: element.tagName().lowercased(), config: parent),
            to: &style,
            parentStyle: parent,
            rootFontSize: rootFontSize
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
                rootFontSize: rootFontSize
            )
        }

        let inlineStyle = CSSParser.parseDeclarations((try? element.attr("style")) ?? "")
        apply(
            declarations: inlineStyle,
            to: &style,
            parentStyle: parent,
            rootFontSize: rootFontSize
        )

        // 列表項：根據父元素類型決定 bullet 字串
        if element.tagName().lowercased() == "li" {
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
            marginLeft: parent.marginLeft,
            listBullet: nil,
            verticalAlign: .baseline,
            isBlock: false,
            backgroundImage: nil,
            backgroundFillColor: nil,
            width: nil,
            height: nil,
            marginRight: 0,
            paddingLeft: 0,
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
            configParagraphSpacing: parent.configParagraphSpacing
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
            verticalAlign: .baseline,
            isBlock: true,
            backgroundImage: nil,
            backgroundFillColor: nil,
            width: nil,
            height: nil,
            marginRight: 0,
            paddingLeft: 0,
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
            configParagraphSpacing: config.paragraphSpacing
        )
    }

    private func userAgentDeclarations(for tag: String, config: ResolvedStyle) -> [String: String] {
        switch tag {
        case "body":
            return ["display": "block"]
        case "div", "section", "article":
            return [
                "display": "block",
                "line-height": "\(config.lineHeight / max(config.fontSize, 1))",
            ]
        case "p":
            return [
                "display": "block",
                "line-height": "\(config.lineHeight / max(config.fontSize, 1))",
                // 使用者設定段距作為 <p> 預設值，不受 EPUB CSS body/div margin:0 影響
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
        case "i", "em":
            return ["font-style": "italic"]
        case "sup":
            return ["font-size": "0.75em", "vertical-align": "super"]
        case "sub":
            return ["font-size": "0.75em", "vertical-align": "sub"]
        default:
            return [:]
        }
    }

    private func apply(
        declarations: [String: String],
        to style: inout ResolvedStyle,
        parentStyle: ResolvedStyle,
        rootFontSize: CGFloat
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
            style.isBlock = cssDisplayIsBlock(display)
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
                relativeBase: style.fontSize
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
                relativeBase: style.fontSize
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
                relativeBase: style.fontSize
           ) {
            style.textIndent = value
        }
        if !handledProperties.contains("line-height"), let lineHeight = declarations["line-height"] {
            if let resolved = resolveLineHeight(lineHeight, fontSize: style.fontSize, rootFontSize: rootFontSize) {
                // CSS 明確指定時不做 clamp，尊重 EPUB 排版意圖
                style.lineHeight = resolved
                style.lineHeightExplicit = true
            }
        }
        if let paragraphSpacing = declarations["margin-bottom"] ?? declarations["paragraph-spacing"],
           let value = resolveLength(
                paragraphSpacing,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize
           ) {
            style.paragraphSpacing = max(0, value)
        }
        if let marginTop = declarations["margin-top"],
           let value = resolveLength(
                marginTop,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize
           ) {
            style.paragraphSpacingBefore = max(0, value)
            style.visualOffsetBefore = max(0, value)
        }
        if let margin = declarations["margin"] {
            applyMarginShorthand(
                margin,
                to: &style,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize
            )
        }
        if let marginLeft = declarations["margin-left"],
           let value = resolveLength(
                marginLeft,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize
           ) {
            style.marginLeft = max(0, value)
        }
        if let marginRight = declarations["margin-right"],
           let value = resolveLength(
                marginRight,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize
           ) {
            style.marginRight = max(0, value)
        }
        if let padding = declarations["padding"] {
            applyPaddingShorthand(
                padding,
                to: &style,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize
            )
        }
        if let paddingLeft = declarations["padding-left"],
           let value = resolveLength(
                paddingLeft,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize
           ) {
            style.paddingLeft = max(0, value)
        }
        if let paddingRight = declarations["padding-right"],
           let value = resolveLength(
                paddingRight,
                currentFontSize: style.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: style.fontSize
           ) {
            style.paddingRight = max(0, value)
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
        if lowered.contains("none") {
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
        relativeBase: CGFloat
    ) -> CGFloat? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            return CGFloat(number / 100.0) * relativeBase
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
        rootFontSize: CGFloat
    ) {
        let tokens = raw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return }
        let resolved = expandBoxShorthand(tokens)
        if let top = resolved.top, let topValue = resolveBoxValue(top, currentFontSize: currentFontSize, rootFontSize: rootFontSize) {
            style.paragraphSpacingBefore = max(0, topValue)
            style.visualOffsetBefore = max(0, topValue)
        }
        if let bottom = resolved.bottom, let bottomValue = resolveBoxValue(bottom, currentFontSize: currentFontSize, rootFontSize: rootFontSize) {
            style.paragraphSpacing = max(0, bottomValue)
        }
        if let left = resolved.left {
            if left.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto" {
                style.isHorizontallyCentered = true
            } else if let leftValue = resolveBoxValue(left, currentFontSize: currentFontSize, rootFontSize: rootFontSize) {
                style.marginLeft = max(0, leftValue)
            }
        }
        if let right = resolved.right {
            if right.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "auto" {
                style.isHorizontallyCentered = true
            } else if let rightValue = resolveBoxValue(right, currentFontSize: currentFontSize, rootFontSize: rootFontSize) {
                style.marginRight = max(0, rightValue)
            }
        }
    }

    private func applyPaddingShorthand(
        _ raw: String,
        to style: inout ResolvedStyle,
        currentFontSize: CGFloat,
        rootFontSize: CGFloat
    ) {
        let tokens = raw
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return }
        let resolved = expandBoxShorthand(tokens)
        if let left = resolved.left, let leftValue = resolveBoxValue(left, currentFontSize: currentFontSize, rootFontSize: rootFontSize) {
            style.paddingLeft = max(0, leftValue)
        }
        if let right = resolved.right, let rightValue = resolveBoxValue(right, currentFontSize: currentFontSize, rootFontSize: rootFontSize) {
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
        rootFontSize: CGFloat
    ) -> CGFloat? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value != "auto" else { return nil }
        return resolveLength(
            value,
            currentFontSize: currentFontSize,
            rootFontSize: rootFontSize,
            relativeBase: currentFontSize
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
        let collapsed = text.replacingOccurrences(of: "[ \\n\\r\\t\\u{000C}]+", with: " ", options: .regularExpression)
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
        if let hexRange = value.range(of: #"#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})"#, options: .regularExpression) {
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

    private func debugLog(result: NSAttributedString) {
        print("[HTMLBuilder] build: rawAttrStr.length=\(result.length)")
        if result.length > 0 {
            let attrs = result.attributes(at: 0, effectiveRange: nil)
            let font = attrs[.font] as? UIFont
            let paragraph = attrs[.paragraphStyle] as? NSParagraphStyle
            print("[HTMLBuilder] build: first-char font=\(font?.fontName ?? "nil") size=\(font?.pointSize ?? 0)")
            print("[HTMLBuilder] build: first-char alignment=\(paragraph?.alignment.rawValue ?? -999)")
        }
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
        for key in ["id", "class", "style", "src", "href", "xlink:href", "width", "height", "alt"] {
            let value = (try? element.attr(key)) ?? ""
            if !value.isEmpty {
                attributes[key] = value
            }
        }
        return attributes
    }
}

struct CSSRule {
    let selector: CSSSelector
    let declarations: [String: String]
    let specificity: Int
    let order: Int
}

struct CSSSelector {
    struct Component {
        let tag: String?
        let id: String?
        let classes: Set<String>
        let firstChild: Bool
    }

    let components: [Component]

    func matches(element: Element, parent: Element?) -> Bool {
        guard let last = components.last, matches(component: last, element: element, parent: parent) else {
            return false
        }
        guard components.count == 2, let first = components.first else { return true }
        var ancestor = parent
        while let current = ancestor {
            let currentParent = current.parent()
            if matches(component: first, element: current, parent: currentParent) {
                return true
            }
            ancestor = currentParent
        }
        return false
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
        if component.firstChild, !isFirstElementChild(element, parent: parent) {
            return false
        }
        return true
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
    static func parse(css: String, orderOffset: Int = 0) -> [CSSRule] {
        let stripped = css.replacingOccurrences(of: #"/\*.*?\*/"#, with: "", options: .regularExpression)
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

    private static func parseSelector(_ raw: String) -> CSSSelector? {
        let pieces = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !pieces.isEmpty, pieces.count <= 2 else { return nil }

        let components = pieces.compactMap(parseComponent)
        guard components.count == pieces.count else { return nil }
        return CSSSelector(components: components)
    }

    private static func parseComponent(_ raw: String) -> CSSSelector.Component? {
        if raw.contains(">") || raw.contains("+") || raw.contains("~") || raw.contains("*") || raw.contains("[") {
            return nil
        }

        var token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var firstChild = false
        if token.lowercased().hasSuffix(":first-child") {
            firstChild = true
            token = String(token.dropLast(":first-child".count))
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

        return CSSSelector.Component(tag: tag, id: id, classes: classes, firstChild: firstChild)
    }

    private static func specificity(of selector: CSSSelector) -> Int {
        selector.components.reduce(0) { partial, component in
            partial
            + (component.id == nil ? 0 : 100)
            + component.classes.count * 10
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
