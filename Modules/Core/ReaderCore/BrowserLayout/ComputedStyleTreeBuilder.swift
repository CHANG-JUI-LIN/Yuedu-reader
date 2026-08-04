import Foundation
import SwiftSoup
import UIKit

/// One node of the computed-style tree. `element` is nil only for the synthetic
/// root the builder creates for `<body>` matching.
final class ComputedStyleNode {
    let tag: String
    let element: Element?
    let style: ComputedStyle
    let children: [StyleTreeChild]
    /// Stable identity assigned by `ComputedStyleTreeBuilder` (document order).
    /// Fragments carry it so a rendered character can be traced back to its DOM node.
    let nodeID: Int
    /// Resolved href from the nearest ancestor `<a>` (nil when not inside a link).
    let linkTarget: String?
    /// This element's own `id` attribute (anchor target), nil when absent.
    let anchorID: String?
    init(
        tag: String,
        element: Element?,
        style: ComputedStyle,
        children: [StyleTreeChild],
        nodeID: Int,
        linkTarget: String?,
        anchorID: String?
    ) {
        self.tag = tag
        self.element = element
        self.style = style
        self.children = children
        self.nodeID = nodeID
        self.linkTarget = linkTarget
        self.anchorID = anchorID
    }
}

enum StyleTreeChild {
    case element(ComputedStyleNode)
    case text(String)
}

/// Reader-provided configuration that feeds computed styles: the root font size
/// (rem base), the fallback text/background colors, and the config font family
/// list. Layout stages read `renderWidth`/`renderHeight`/`contentInsets`.
struct BrowserLayoutConfig: Equatable {
    var renderWidth: CGFloat = 320     // body containing-block width (reader content width)
    var renderHeight: CGFloat = 480    // page content height before page margins apply
    var rootFontSize: CGFloat = 17
    var fontFamilies: [String] = []
    var textColor: UIColor = .black
    var backgroundColor: UIColor = .white
    var contentInsets: UIEdgeInsets = .zero   // page margins from reader settings
    var lineHeight: CGFloat? = nil     // reader line-height override (applied after author CSS)
}

/// Turns the DOM `<body>` subtree + CSS rule list into a `ComputedStyleNode`
/// tree. Reruns the full cascade per element, mirroring the proven order in
/// `HTMLAttributedStringBuilder.resolvedStyle`:
/// base(inheritance+UA) → normal author rules → normal inline → important
/// author rules → important inline. Selector matching reuses the existing
/// `CSSParser`/`CSSSelector` so behavior stays identical to the legacy renderer.
final class ComputedStyleTreeBuilder {

    private let rules: [CSSRule]
    private let rootFontSize: CGFloat
    private let textColor: UIColor
    private let backgroundColor: UIColor
    private let configFontFamilies: [String]
    private var nextNodeID = 1

    init(rules: [CSSRule], config: BrowserLayoutConfig) {
        self.rules = rules
        self.rootFontSize = config.rootFontSize
        self.textColor = config.textColor
        self.backgroundColor = config.backgroundColor
        self.configFontFamilies = config.fontFamilies
    }

    func buildTree(body: Element) -> ComputedStyleNode {
        let rootStyle = baseStyle(for: body)
        let root = ComputedStyleNode(
            tag: "body", element: body, style: rootStyle,
            children: children(of: body, parentStyle: rootStyle, parentElement: body, inheritedLink: nil),
            nodeID: nextNodeID,
            linkTarget: nil,
            anchorID: linkAnchorID(of: body)
        )
        nextNodeID += 1
        return root
    }

    // MARK: - Children

    private func children(
        of element: Element,
        parentStyle: ComputedStyle,
        parentElement: Element,
        inheritedLink: String?
    ) -> [StyleTreeChild] {
        var result: [StyleTreeChild] = []
        for node in element.getChildNodes() {
            if let text = node as? TextNode {
                result.append(.text(text.getWholeText()))
            } else if let child = node as? Element {
                let style = resolvedStyle(for: child, parent: parentStyle, parentElement: element)
                if style.isHidden { continue }
                let childLink: String?
                if child.tagName().lowercased() == "a", let href = try? child.attr("href"), !href.isEmpty {
                    childLink = href
                } else {
                    childLink = inheritedLink
                }
                let childNode = ComputedStyleNode(
                    tag: child.tagName().lowercased(), element: child, style: style,
                    children: children(of: child, parentStyle: style, parentElement: child, inheritedLink: childLink),
                    nodeID: nextNodeID,
                    linkTarget: childLink,
                    anchorID: linkAnchorID(of: child)
                )
                nextNodeID += 1
                result.append(.element(childNode))
            }
        }
        return result
    }

    private func linkAnchorID(of element: Element) -> String? {
        guard element.hasAttr("id") else { return nil }
        let value = (try? element.attr("id")) ?? ""
        return value.isEmpty ? nil : value
    }

    // MARK: - Cascade for one element

    private func resolvedStyle(for element: Element, parent: ComputedStyle, parentElement: Element) -> ComputedStyle {
        var style = parent.inherited(from: parent)
        let ua = UserAgentStyle.basis(for: element.tagName().lowercased())
        style = style.applyingUA(ua)

        let ctx = ApplyContext(parent: parent, rootFontSize: rootFontSize, textColor: textColor, backgroundColor: backgroundColor, configFontFamilies: configFontFamilies)

        let matched = rules
            .filter { $0.selector.matches(element: element, parent: parentElement) }
            .sorted { lhs, rhs in
                if lhs.specificity == rhs.specificity { return lhs.order < rhs.order }
                return lhs.specificity < rhs.specificity
            }

        for rule in matched { cascadeApply(rule.declarations, to: &style, ctx: ctx) }

        let inlineDecl = CSSParser.parseDeclarationBlock((try? element.attr("style")) ?? "")
        cascadeApply(inlineDecl.normal, to: &style, ctx: ctx)

        for rule in matched { cascadeApply(rule.importantDeclarations, to: &style, ctx: ctx) }
        cascadeApply(inlineDecl.important, to: &style, ctx: ctx)

        if element.hasAttr("hidden") { style.isHidden = true }
        return style
    }

    private func baseStyle(for element: Element) -> ComputedStyle {
        var style = UserAgentStyle.basis(for: element.tagName().lowercased())
        style.configParagraphSpacing = 6
        style.color = style.color ?? textColor
        style.backgroundColor = style.backgroundColor ?? backgroundColor
        return style
    }
}

fileprivate struct ApplyContext {
    let parent: ComputedStyle
    let rootFontSize: CGFloat
    let textColor: UIColor
    let backgroundColor: UIColor
    let configFontFamilies: [String]
}

private extension ComputedStyle {
    /// Applies UA defaults onto an inherited style: UA sets non-inherited box
    /// props, and UA font-size overrides are *absolute* unless UA said relative.
    mutating func applyingUA(_ ua: ComputedStyle) -> ComputedStyle {
        display = ua.display
        isHidden = ua.isHidden
        width = ua.width
        height = ua.height
        marginTop = ua.marginTop
        marginRight = ua.marginRight
        marginBottom = ua.marginBottom
        marginLeft = ua.marginLeft
        paddingTop = ua.paddingTop
        paddingRight = ua.paddingRight
        paddingBottom = ua.paddingBottom
        paddingLeft = ua.paddingLeft
        if ua.fontSize != 17 { fontSize = ua.fontSize }
        if ua.fontWeight != 400 { fontWeight = ua.fontWeight }
        if ua.isItalic { isItalic = true }
        return self
    }
}

private extension ComputedStyleTreeBuilder {
    func cascadeApply(_ declarations: [String: String], to style: inout ComputedStyle, ctx: ApplyContext) {
        for (key, value) in declarations {
            ComputedStylePropertyApplier.apply(key: key, value: value, to: &style, ctx: ctx)
        }
    }
}

enum ComputedStylePropertyApplier {
    fileprivate static func apply(key: String, value raw: String, to style: inout ComputedStyle, ctx: ApplyContext) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return }
        switch key {
        case "display":
            switch value {
            case "none": style.display = .none; style.isHidden = true
            case "block": style.display = .block
            case "inline": style.display = .inline
            case "inline-block": style.display = .inlineBlock
            default: break
            }
        case "color":
            if let c = parseColor(value) { style.color = c }
        case "background-color":
            if let c = parseColor(value) { style.backgroundColor = c }
        case "font-size":
            if let px = resolveFontSize(value, parentSize: ctx.parent.fontSize, root: ctx.rootFontSize) {
                style.fontSize = px
            }
        case "font-family":
            style.fontFamilies = value
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) }
        case "font-weight":
            style.fontWeight = cssFontWeight(value, current: style.fontWeight)
        case "font-style":
            style.isItalic = value.contains("italic") || value.contains("oblique")
        case "text-align":
            style.textAlign = cssAlignment(value)
        case "line-height":
            if let lh = resolveLineHeight(value, fontSize: style.fontSize, root: ctx.rootFontSize) {
                style.lineHeight = lh
            }
        case "white-space":
            switch value {
            case "normal": style.whiteSpace = .normal
            case "nowrap": style.whiteSpace = .nowrap
            case "pre": style.whiteSpace = .pre
            case "pre-wrap": style.whiteSpace = .preWrap
            case "pre-line": style.whiteSpace = .preLine
            default: break
            }
        case "width": if let l = CSSLengthResolver.parse(value) { style.width = l }
        case "height": if let l = CSSLengthResolver.parse(value) { style.height = l }
        case "max-width": if let l = CSSLengthResolver.parse(value) { style.maxWidth = l }
        case "margin": applyMarginShorthand(value, to: &style)
        case "margin-top": if let l = CSSLengthResolver.parse(value) { style.marginTop = l }
        case "margin-right": if let l = CSSLengthResolver.parse(value) { style.marginRight = l }
        case "margin-bottom": if let l = CSSLengthResolver.parse(value) { style.marginBottom = l }
        case "margin-left": if let l = CSSLengthResolver.parse(value) { style.marginLeft = l }
        case "padding":
            let parts = value.split(separator: " ").map(String.init).map { CSSLengthResolver.parse($0) }
            assignPadding(parts, to: &style)
        case "padding-top": if let l = CSSLengthResolver.parse(value) { style.paddingTop = l }
        case "padding-right": if let l = CSSLengthResolver.parse(value) { style.paddingRight = l }
        case "padding-bottom": if let l = CSSLengthResolver.parse(value) { style.paddingBottom = l }
        case "padding-left": if let l = CSSLengthResolver.parse(value) { style.paddingLeft = l }
        case "border-top-width": style.borderTopWidth = numericWidth(value) ?? style.borderTopWidth
        case "border-right-width": style.borderRightWidth = numericWidth(value) ?? style.borderRightWidth
        case "border-bottom-width": style.borderBottomWidth = numericWidth(value) ?? style.borderBottomWidth
        case "border-left-width": style.borderLeftWidth = numericWidth(value) ?? style.borderLeftWidth
        case "border-color": style.borderColor = parseColor(value)
        case "border-radius": style.borderRadius = numericWidth(value) ?? 0
        case "background": if let c = parseColor(shorthandBackgroundColor(value)) { style.backgroundColor = c }
        default:
            break // unimplemented properties are ignored (Phase 1)
        }
    }

    fileprivate static func applyMarginShorthand(_ value: String, to style: inout ComputedStyle) {
        let parts = value.split(separator: " ").map(String.init).map(CSSLengthResolver.parse)
        switch parts.count {
        case 1: if let v = parts[0] { style.marginTop = v; style.marginRight = v; style.marginBottom = v; style.marginLeft = v }
        case 2:
            if let v = parts[0] { style.marginTop = v; style.marginBottom = v }
            if let v = parts[1] { style.marginLeft = v; style.marginRight = v }
        case 3:
            if let v = parts[0] { style.marginTop = v }
            if let v = parts[1] { style.marginLeft = v; style.marginRight = v }
            if let v = parts[2] { style.marginBottom = v }
        case 4:
            if let v = parts[0] { style.marginTop = v }
            if let v = parts[1] { style.marginRight = v }
            if let v = parts[2] { style.marginBottom = v }
            if let v = parts[3] { style.marginLeft = v }
        default: break
        }
    }

    fileprivate static func assignPadding(_ parts: [CSSLength?], to style: inout ComputedStyle) {
        guard !parts.isEmpty else { return }
        func value(_ i: Int) -> CSSLength { if let v = parts[i] { return v }; return .px(0) }
        switch parts.count {
        case 1: style.paddingTop = value(0); style.paddingRight = value(0); style.paddingBottom = value(0); style.paddingLeft = value(0)
        case 2: style.paddingTop = value(0); style.paddingRight = value(1); style.paddingBottom = value(0); style.paddingLeft = value(1)
        case 3: style.paddingTop = value(0); style.paddingRight = value(1); style.paddingBottom = value(2); style.paddingLeft = value(1)
        default: style.paddingTop = value(0); style.paddingRight = value(1); style.paddingBottom = value(2); style.paddingLeft = value(3)
        }
    }

    fileprivate static func numericWidth(_ value: String) -> CGFloat? {
        CSSLengthResolver.resolve(CSSLengthResolver.parse(value) ?? .auto, emBase: 17, remBase: 17, percentBase: 400)
    }

    fileprivate static func shorthandBackgroundColor(_ value: String) -> String {
        value.split(separator: " ")
            .map(String.init)
            .first { $0.hasPrefix("#") || $0.hasPrefix("rgb") || $0.hasPrefix("hsl") }
            ?? ""
    }

    fileprivate static func resolveFontSize(_ raw: String, parentSize: CGFloat, root: CGFloat) -> CGFloat? {
        switch raw {
        case "small": return root * 0.833
        case "medium": return root
        case "large": return root * 1.2
        case "x-large": return root * 1.5
        case "xx-large": return root * 2
        case "smaller": return parentSize * 0.833
        case "larger": return parentSize * 1.2
        default:
            guard let parsed = CSSLengthResolver.parse(raw) else { return nil }
            return CSSLengthResolver.resolve(parsed, emBase: parentSize, remBase: root, percentBase: parentSize)
        }
    }

    fileprivate static func resolveLineHeight(_ raw: String, fontSize: CGFloat, root: CGFloat) -> CGFloat? {
        if raw == "normal" { return nil }
        if let unitless = Double(raw), abs(Double(fontSize) * unitless).isFinite {
            return fontSize * CGFloat(unitless)
        }
        guard let parsed = CSSLengthResolver.parse(raw) else { return nil }
        return CSSLengthResolver.resolve(parsed, emBase: fontSize, remBase: root, percentBase: fontSize)
    }

    fileprivate static func cssFontWeight(_ raw: String, current: Int) -> Int {
        switch raw {
        case "normal": return 400
        case "bold": return 700
        case "bolder": return min(900, current + 100)
        case "lighter": return max(100, current - 100)
        default: return Int(raw).map { min(900, max(100, $0)) } ?? current
        }
    }

    fileprivate static func cssAlignment(_ raw: String) -> NSTextAlignment {
        switch raw {
        case "left": return .left
        case "right": return .right
        case "center": return .center
        case "justify": return .justified
        default: return .natural
        }
    }

    fileprivate static func parseColor(_ raw: String) -> UIColor? {
        if raw == "transparent" { return nil }
        if raw == "currentcolor" { return nil }
        if raw.hasPrefix("#") {
            let hex = raw.replacingOccurrences(of: "#", with: "")
            guard let value = UInt64(hex, radix: 16) else { return nil }
            switch hex.count {
            case 3:
                let r = CGFloat((value >> 8) & 0xF) / 15
                let g = CGFloat((value >> 4) & 0xF) / 15
                let b = CGFloat(value & 0xF) / 15
                return UIColor(red: r, green: g, blue: b, alpha: 1)
            case 6:
                let r = CGFloat((value >> 16) & 0xFF) / 255
                let g = CGFloat((value >> 8) & 0xFF) / 255
                let b = CGFloat(value & 0xFF) / 255
                return UIColor(red: r, green: g, blue: b, alpha: 1)
            default: return nil
            }
        }
        if raw.hasPrefix("rgb(") {
            let inner = raw.dropFirst(4).dropLast()
            let comps = inner.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard comps.count == 3 else { return nil }
            return UIColor(red: comps[0]/255, green: comps[1]/255, blue: comps[2]/255, alpha: 1)
        }
        switch raw {
        case "black": return .black
        case "white": return .white
        case "red": return .red
        case "green": return .green
        case "blue": return .blue
        case "gray", "grey": return .gray
        case "yellow": return .yellow
        case "orange": return .orange
        case "purple": return .purple
        case "cyan": return .cyan
        case "magenta": return .magenta
        default: return nil
        }
    }
}