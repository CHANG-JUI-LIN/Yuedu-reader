import CoreText
import SwiftSoup
import UIKit

/// HTML/CSS -> NSAttributedString builder for local EPUB.
/// This path intentionally avoids DTCoreText so that font mapping,
/// image-page detection, and style precedence stay under our control.
final class HTMLAttributedStringBuilder {
    static let internalLinkAttribute = NSAttributedString.Key("ReaderInternalLink")
    static let anchorIDAttribute = NSAttributedString.Key("ReaderAnchorID")
    private static let paragraphSeparator = "\n"
    private static let lineSeparator = "\u{2028}"

    struct Config {
        var fontSize: CGFloat
        var lineSpacing: CGFloat
        var paragraphSpacing: CGFloat
        var firstLineIndent: CGFloat
        var textColor: UIColor
        var backgroundColor: UIColor
        var fontFamilyName: String?
        var renderWidth: CGFloat = UIScreen.main.bounds.width - 32
    }

    struct ImagePage {
        let source: String
        let image: UIImage?
    }

    struct BuildResult {
        let attributedString: NSAttributedString
        let imagePage: ImagePage?
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
        /// margin-left（blockquote / 巢狀列表縮排）
        var marginLeft: CGFloat
        /// list item 的 bullet 或序號字串（如 "•" / "1."），nil 表示非列表項
        var listBullet: String?
        var verticalAlign: VerticalAlign
        var isBlock: Bool
        var backgroundImage: String?
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

    func build(html: String, config: Config) async -> BuildResult {
        guard let document = try? SwiftSoup.parse(html),
              let body = document.body()
        else {
            return BuildResult(attributedString: NSAttributedString(), imagePage: nil, anchorOffsets: [:])
        }

        let stylesheetTexts = await collectStyles(from: document)
        let rules = stylesheetTexts.enumerated().flatMap { index, css in
            CSSParser.parse(css: css, orderOffset: index * 10_000)
        }

        let bodyStyle = resolvedStyle(
            for: body,
            parent: makeRootStyle(config: config),
            rules: rules,
            rootFontSize: config.fontSize,
            parentElement: nil
        )
        let astChildren = await buildChildren(
            from: body.getChildNodes(),
            parentStyle: bodyStyle,
            rules: rules,
            rootFontSize: config.fontSize,
            parentElement: body
        )

        let ast = ElementNode(
            tag: "body",
            id: body.id(),
            classes: Array((try? body.classNames()) ?? []),
            attributes: makeAttributeMap(for: body),
            resolvedStyle: bodyStyle,
            children: astChildren
        )

        if let imagePage = await extractImagePage(from: ast) {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: makeFont(from: bodyStyle, config: config),
                .foregroundColor: config.textColor,
                .backgroundColor: config.backgroundColor,
            ]
            return BuildResult(
                attributedString: NSAttributedString(string: "\u{FFFC}", attributes: attrs),
                imagePage: imagePage,
                anchorOffsets: [:]
            )
        }

        let rendered = await renderBlockChildren(ast.children, parentStyle: ast.resolvedStyle, config: config)
        let mutable = NSMutableAttributedString(attributedString: rendered)
        if mutable.length > 0 {
            mutable.addAttribute(
                .backgroundColor,
                value: config.backgroundColor,
                range: NSRange(location: 0, length: mutable.length)
            )
        }
        let anchorOffsets = collectAnchorOffsets(in: mutable)
        debugLog(result: mutable)
        // CJK 標點擠壓（相鄰全形標點施加負 kern）
        let processed = CJKTypographyProcessor.apply(to: mutable)
        return BuildResult(attributedString: processed, imagePage: nil, anchorOffsets: anchorOffsets)
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
            let rendered = await renderNode(node, inheritedStyle: parentStyle, config: config)
            if rendered.length == 0 { continue }
            appendNode(rendered, to: output)
        }
        trimTrailingBreaks(in: output)
        return output
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
                return makeImagePlaceholder(image: image, config: config, style: element.resolvedStyle)
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

    private func renderBlockElement(
        _ element: ElementNode,
        config: Config
    ) async -> NSAttributedString {
        let output = NSMutableAttributedString()
        var segment = NSMutableAttributedString()
        var paragraphIndex = 0

        func appendSegment(isLast: Bool) {
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

        for child in element.children {
            switch child {
            case .lineBreak(let breakNode) where breakNode.resolvedStyle.isBlock:
                appendSegment(isLast: false)
            case .element(let childElement) where childElement.resolvedStyle.isBlock:
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

        appendSegment(isLast: true)
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
        }
        if !isLast {
            style.paragraphSpacing = 0
        }
        return style
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
        let lineHeight = style.lineHeightExplicit
            ? max(style.fontSize, style.lineHeight)
            : clampLineHeight(absolute: style.lineHeight, fontSize: style.fontSize)
        // 讓文字在行高內垂直置中（CoreText 預設貼底部）
        var baselineOffset = (lineHeight - style.fontSize) / 4
        // sup / sub 的額外基線偏移
        switch style.verticalAlign {
        case .super: baselineOffset += style.fontSize * 0.4
        case .sub:   baselineOffset -= style.fontSize * 0.25
        case .baseline: break
        }
        return [
            .font: makeFont(from: style, config: config),
            .foregroundColor: style.textColor,
            .baselineOffset: baselineOffset,
        ]
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
            // 一般段落：marginLeft 控制左邊距，textIndent 控制首行額外縮排
            paragraph.headIndent = style.marginLeft
            paragraph.firstLineHeadIndent = style.marginLeft + style.textIndent
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

    private func makeImagePlaceholder(image: UIImage?, config: Config, style: ResolvedStyle) -> NSAttributedString {
        let maxWidth = config.renderWidth
        let (width, height): (CGFloat, CGFloat)
        if let image {
            let ratio = min(1.0, maxWidth / max(image.size.width, 1))
            width = image.size.width * ratio
            height = image.size.height * ratio
        } else {
            width = maxWidth
            height = maxWidth * 0.6
        }

        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { pointer in
                Unmanaged<ImageRunInfo>.fromOpaque(pointer).release()
            },
            getAscent: { pointer in
                Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue().height
            },
            getDescent: { _ in 0 },
            getWidth: { pointer in
                Unmanaged<ImageRunInfo>.fromOpaque(pointer).takeUnretainedValue().width
            }
        )
        let info = ImageRunInfo(image: image, width: width, height: height)
        let retained = Unmanaged.passRetained(info).toOpaque()
        guard let delegate = CTRunDelegateCreate(&callbacks, retained) else {
            return NSAttributedString(string: "\u{FFFC}")
        }

        let string = NSMutableAttributedString(
            string: "\u{FFFC}",
            attributes: [
                .font: makeFont(from: style, config: config),
                .foregroundColor: style.textColor,
            ]
        )
        string.addAttribute(
            NSAttributedString.Key(kCTRunDelegateAttributeName as String),
            value: delegate,
            range: NSRange(location: 0, length: string.length)
        )
        return string
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
            textIndent: tag == "p" ? parent.textIndent : 0,
            lineHeight: parent.lineHeight,
            lineHeightExplicit: parent.lineHeightExplicit,
            paragraphSpacing: parent.paragraphSpacing,
            paragraphSpacingBefore: 0,
            marginLeft: parent.marginLeft,
            listBullet: nil,
            verticalAlign: .baseline,
            isBlock: false,
            backgroundImage: nil
        )
    }

    private func makeRootStyle(config: Config) -> ResolvedStyle {
        let defaultLineHeight = clampLineHeight(
            absolute: config.fontSize + config.lineSpacing,
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
            marginLeft: 0,
            listBullet: nil,
            verticalAlign: .baseline,
            isBlock: true,
            backgroundImage: nil
        )
    }

    private func userAgentDeclarations(for tag: String, config: ResolvedStyle) -> [String: String] {
        switch tag {
        case "body":
            return ["display": "block"]
        case "div", "p", "section", "article":
            return [
                "display": "block",
                "line-height": "\(config.lineHeight / max(config.fontSize, 1))",
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
            return ["display": "block"]
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
        if let fontSize = declarations["font-size"] {
            style.fontSize = resolveLength(
                fontSize,
                currentFontSize: parentStyle.fontSize,
                rootFontSize: rootFontSize,
                relativeBase: parentStyle.fontSize
            ) ?? style.fontSize
        }

        if let fontFamily = declarations["font-family"] {
            style.fontFamilies = fontFamily
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) }
        }
        if let weight = declarations["font-weight"] {
            style.fontWeight = cssFontWeight(weight, current: style.fontWeight)
        }
        if let fontStyle = declarations["font-style"] {
            style.isItalic = fontStyle.lowercased().contains("italic")
        }
        if let textAlign = declarations["text-align"] {
            style.textAlign = cssAlignment(textAlign)
        }
        if let display = declarations["display"] {
            style.isBlock = display.lowercased().contains("block")
        }
        if let color = declarations["color"], let resolved = parseColor(color) {
            style.textColor = resolved
        }
        if let backgroundImage = declarations["background-image"] {
            style.backgroundImage = extractURL(from: backgroundImage)
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
        if let lineHeight = declarations["line-height"] {
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
        if let verticalAlign = declarations["vertical-align"] {
            switch verticalAlign.trimmingCharacters(in: .whitespaces).lowercased() {
            case "super": style.verticalAlign = .super
            case "sub":   style.verticalAlign = .sub
            default:      style.verticalAlign = .baseline
            }
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
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
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

private struct CSSRule {
    let selector: CSSSelector
    let declarations: [String: String]
    let specificity: Int
    let order: Int
}

private struct CSSSelector {
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

private enum CSSParser {
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

final class ImageRunInfo {
    let image: UIImage?
    let width: CGFloat
    let height: CGFloat

    init(image: UIImage?, width: CGFloat, height: CGFloat) {
        self.image = image
        self.width = width
        self.height = height
    }
}
