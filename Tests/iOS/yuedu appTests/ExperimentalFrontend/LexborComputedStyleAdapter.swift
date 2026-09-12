@testable import YueduCoreText
import Foundation
import UIKit

/// The only conversion from Lexbor's winning longhand declarations to the
/// existing layout model. This layer never matches selectors or reruns cascade.
enum LexborComputedStyleAdapter {
    static let coveredProperties: Set<String> = [
        "display", "visibility", "float", "clear",
        "font-family", "font-size", "font-style", "font-weight", "line-height",
        "color", "background-color", "background-image", "background-size",
        "background-position", "background-repeat", "background-attachment",
        "white-space", "text-align", "text-indent",
        "width", "height", "min-width", "max-width", "min-height", "max-height",
        "margin-top", "margin-right", "margin-bottom", "margin-left",
        "padding-top", "padding-right", "padding-bottom", "padding-left",
        "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
        "border-top-style", "border-right-style", "border-bottom-style", "border-left-style",
        "border-color", "border-radius", "ruby-align", "ruby-position", "ruby-merge"
    ]

    static func apply(
        winners: [FrontendWinningDeclaration], to style: inout ComputedStyle,
        parent: ComputedStyle, config: BrowserLayoutConfig,
        facts: inout FrontendCapabilityFacts, semanticPath: String = ""
    ) {
        // Dependencies, not cascade priority: Lexbor already selected each winner.
        func phase(_ property: String) -> Int {
            switch property {
            case "font-size": return 0
            case "color": return 1
            case "display": return 2
            case "visibility": return 3
            case "background-image": return 4
            default: return 5
            }
        }
        for declaration in winners.sorted(by: {
            let a = phase($0.property), b = phase($1.property)
            return a == b ? $0.property < $1.property : a < b
        }) {
            apply(declaration, to: &style, parent: parent, config: config,
                  facts: &facts, semanticPath: semanticPath)
        }
        style.finalizeLineHeight(rootFontSize: config.rootFontSize)
        style.finalizeBorderLengths(rootFontSize: config.rootFontSize)
    }

    static func apply(
        _ declaration: FrontendWinningDeclaration, to style: inout ComputedStyle,
        parent: ComputedStyle, config: BrowserLayoutConfig,
        facts: inout FrontendCapabilityFacts, semanticPath: String = ""
    ) {
        let property = declaration.property.lowercased()
        let raw = declaration.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = unescape(raw).lowercased()
        func gap(_ reason: String = "Unsupported value") {
            facts.recordAdapterGap(declaration, semanticPath: semanticPath, reason: reason)
        }
        if ["inherit", "initial", "unset"].contains(value) {
            let inherited: Set<String> = ["visibility", "font-family", "font-size", "font-style",
                "font-weight", "line-height", "color", "white-space", "text-align", "text-indent",
                "ruby-align", "ruby-position", "ruby-merge"]
            let source = value == "inherit" || (value == "unset" && inherited.contains(property))
                ? parent : initialStyle(config: config)
            if !copy(property, from: source, to: &style, config: config) { gap("Property has no computed-style representation") }
            if ["background-size", "background-position", "background-repeat", "background-attachment"].contains(property),
               style.backgroundImage == nil {
                gap("Background component without an image cannot be retained for inheritance")
            }
            if property == "visibility", source.isHidden {
                gap("The model cannot preserve hidden boxes and independently visible descendants")
            }
            if property == "border-color", value != "inherit" { style.borderColor = style.color ?? config.textColor }
            return
        }
        switch property {
        case "display":
            switch value {
            case "block": style.display = .block
            case "inline": style.display = .inline
            case "inline-block": style.display = .inlineBlock
            case "none": style.display = .none
            default: gap(); return
            }
            style.isHidden = style.display == .none
        case "visibility":
            switch value {
            case "visible": style.isHidden = style.display == .none
            case "hidden":
                style.isHidden = true
                gap("The model cannot preserve hidden boxes and independently visible descendants")
            default: gap()
            }
        case "float":
            if let parsed = CSSFloat.parse(value) { style.cssFloat = parsed } else { gap() }
        case "clear":
            switch value {
            case "none": style.cssClear = .none
            case "left": style.cssClear = .left
            case "right": style.cssClear = .right
            case "both": style.cssClear = .both
            default: gap()
            }
        case "font-family":
            let families = components(raw, separator: ",").map { unquote($0) }
            if families.isEmpty || families.contains(where: \.isEmpty) { gap() }
            else { style.fontFamilies = families }
        case "font-size":
            let sizes: [String: CGFloat] = ["xx-small": 0.6, "x-small": 0.75, "small": 0.833,
                "medium": 1, "large": 1.2, "x-large": 1.5, "xx-large": 2, "xxx-large": 3]
            if let scale = sizes[value] { style.fontSize = config.rootFontSize * scale }
            else if value == "smaller" { style.fontSize = parent.fontSize / 1.2 }
            else if value == "larger" { style.fontSize = parent.fontSize * 1.2 }
            else if let length = length(value, allowAuto: false, allowNegative: false),
                    let resolved = CSSLengthResolver.resolve(length, emBase: parent.fontSize,
                        remBase: config.rootFontSize, percentBase: parent.fontSize) { style.fontSize = resolved }
            else { gap() }
        case "font-style":
            switch value {
            case "normal": style.isItalic = false
            case "italic", "oblique": style.isItalic = true
            default: gap()
            }
        case "font-weight":
            switch value {
            case "normal": style.fontWeight = 400
            case "bold": style.fontWeight = 700
            case "bolder": style.fontWeight = parent.fontWeight < 350 ? 400 : parent.fontWeight < 550 ? 700 : 900
            case "lighter": style.fontWeight = parent.fontWeight < 550 ? 100 : parent.fontWeight < 750 ? 400 : 700
            default:
                if let number = Int(value), (1...1000).contains(number) { style.fontWeight = number }
                else { gap() }
            }
        case "line-height":
            if value == "normal" {
                style.lineHeight = nil; style.lineHeightMultiplier = nil; style.pendingLineHeightLength = nil
            } else if let number = Double(value), number.isFinite, number >= 0 {
                style.lineHeight = nil; style.lineHeightMultiplier = CGFloat(number); style.pendingLineHeightLength = nil
            } else if let parsed = length(value, allowAuto: false, allowNegative: false) {
                style.lineHeight = nil; style.lineHeightMultiplier = nil; style.pendingLineHeightLength = parsed
            } else { gap() }
        case "color", "background-color", "border-color":
            let current = property == "color" ? parent.color ?? config.textColor : style.color ?? config.textColor
            guard let parsed = color(value, current: current) else { gap(); return }
            switch property {
            case "color": style.color = parsed
            case "background-color": style.backgroundColor = parsed
            default: style.borderColor = parsed
            }
        case "background-image":
            if value == "none" { style.backgroundImage = nil }
            else if let source = imageSource(raw) {
                var image = style.backgroundImage ?? BackgroundImageStyle(source: source)
                image.source = source; style.backgroundImage = image
            } else { gap() }
        case "background-size":
            let size: BackgroundImageStyle.BackgroundSize
            switch value {
            case "auto", "auto auto": size = .auto
            case "cover": size = .cover
            case "contain": size = .contain
            default: gap(); return
            }
            if style.backgroundImage == nil, size != .auto { gap("Background component without an image cannot be retained for inheritance") }
            style.backgroundImage?.size = size
        case "background-position":
            guard let position = backgroundPosition(value, style: style, config: config) else { gap(); return }
            if style.backgroundImage == nil {
                gap("Background component without an image cannot be retained for inheritance")
            }
            style.backgroundImage?.positionX = position.0
            style.backgroundImage?.positionY = position.1
        case "background-repeat":
            switch value {
            case "repeat", "repeat repeat": style.backgroundImage?.repeatMode = .repeat
            case "no-repeat", "no-repeat no-repeat":
                if style.backgroundImage == nil { gap("Background component without an image cannot be retained for inheritance") }
                style.backgroundImage?.repeatMode = .noRepeat
            default: gap()
            }
        case "background-attachment":
            switch value {
            case "scroll": style.backgroundImage?.attachment = .scroll
            case "fixed":
                if style.backgroundImage == nil { gap("Background component without an image cannot be retained for inheritance") }
                style.backgroundImage?.attachment = .fixed
            default: gap()
            }
        case "white-space":
            switch value {
            case "normal": style.whiteSpace = .normal
            case "nowrap": style.whiteSpace = .nowrap
            case "pre": style.whiteSpace = .pre
            case "pre-wrap": style.whiteSpace = .preWrap
            case "pre-line": style.whiteSpace = .preLine
            default: gap()
            }
        case "text-align":
            switch value {
            case "left": style.textAlign = .left
            case "right": style.textAlign = .right
            case "center": style.textAlign = .center
            case "justify": style.textAlign = .justified
            case "start": style.textAlign = .natural
            default: gap()
            }
        case "text-indent":
            style.textIndent = CSSTextIndent.parse(value)
            if style.textIndent == .unsupported { gap() }
        case "width", "height", "max-width", "margin-top", "margin-right", "margin-bottom", "margin-left",
             "padding-top", "padding-right", "padding-bottom", "padding-left":
            if property == "max-width", value == "none" { style.maxWidth = nil; return }
            let margin = property.hasPrefix("margin-")
            guard let parsed = length(value, allowAuto: margin || property == "width" || property == "height", allowNegative: margin) else { gap(); return }
            switch property {
            case "width": style.width = parsed
            case "height": style.height = parsed
            case "max-width": style.maxWidth = parsed
            case "margin-top": style.marginTop = parsed
            case "margin-right": style.marginRight = parsed
            case "margin-bottom": style.marginBottom = parsed
            case "margin-left": style.marginLeft = parsed
            case "padding-top": style.paddingTop = parsed
            case "padding-right": style.paddingRight = parsed
            case "padding-bottom": style.paddingBottom = parsed
            default: style.paddingLeft = parsed
            }
        case "min-width", "min-height", "max-height": gap("Property has no computed-style representation")
        case "border-top-width", "border-right-width", "border-bottom-width", "border-left-width", "border-radius":
            let keywords: [String: CSSLength] = ["thin": .px(1), "medium": .px(3), "thick": .px(5)]
            let parsed = property == "border-radius" ? length(value, allowAuto: false, allowNegative: false, allowPercent: false)
                : keywords[value] ?? length(value, allowAuto: false, allowNegative: false, allowPercent: false)
            guard let parsed else { gap(); return }
            switch property {
            case "border-top-width": style.pendingBorderTopWidth = parsed
            case "border-right-width": style.pendingBorderRightWidth = parsed
            case "border-bottom-width": style.pendingBorderBottomWidth = parsed
            case "border-left-width": style.pendingBorderLeftWidth = parsed
            default: style.pendingBorderRadius = parsed
            }
        case "border-top-style", "border-right-style", "border-bottom-style", "border-left-style":
            guard ["none", "hidden", "solid", "dotted", "dashed"].contains(value) else { gap(); return }
            let parsed = BorderStyle.from(cssRaw: value)
            switch property {
            case "border-top-style": style.borderTopStyle = parsed
            case "border-right-style": style.borderRightStyle = parsed
            case "border-bottom-style": style.borderBottomStyle = parsed
            default: style.borderLeftStyle = parsed
            }
        case "ruby-align", "-epub-ruby-align", "-webkit-ruby-align":
            style.rubyAlign = RubyAlignment.parse(value)
            if style.rubyAlign != .center { gap() }
        case "ruby-position", "-epub-ruby-position", "-webkit-ruby-position":
            style.rubyPosition = RubyPosition.parse(value)
            if style.rubyPosition != .over { gap() }
        case "ruby-merge", "-epub-ruby-merge", "-webkit-ruby-merge":
            style.rubyMerge = RubyMerge.parse(value)
            if style.rubyMerge != .separate { gap() }
        default: gap("Property has no computed-style representation")
        }
    }

    private static func initialStyle(config: BrowserLayoutConfig) -> ComputedStyle {
        var style = ComputedStyle(fontSize: config.rootFontSize, fontFamilies: config.fontFamilies, color: config.textColor)
        style.display = .inline
        style.borderTopWidth = 3; style.borderRightWidth = 3; style.borderBottomWidth = 3; style.borderLeftWidth = 3
        style.borderTopStyle = .none; style.borderRightStyle = .none; style.borderBottomStyle = .none; style.borderLeftStyle = .none
        return style
    }

    private static func copy(_ property: String, from source: ComputedStyle, to style: inout ComputedStyle,
                             config: BrowserLayoutConfig) -> Bool {
        // The model retains authored em/rem for layout, but CSS inheritance
        // copies the parent's computed value, not a unit rebased on the child.
        // Percentages and auto still need the child's containing block.
        func computedLength(_ length: CSSLength) -> CSSLength {
            switch length {
            case .em(let value): return .px(value * source.fontSize)
            case .rem(let value): return .px(value * config.rootFontSize)
            default: return length
            }
        }
        switch property {
        case "display": style.display = source.display; style.isHidden = source.display == .none
        case "visibility": style.isHidden = source.isHidden || style.display == .none
        case "float": style.cssFloat = source.cssFloat
        case "clear": style.cssClear = source.cssClear
        case "font-family": style.fontFamilies = source.fontFamilies
        case "font-size": style.fontSize = source.fontSize
        case "font-style": style.isItalic = source.isItalic
        case "font-weight": style.fontWeight = source.fontWeight
        case "line-height":
            style.lineHeight = source.lineHeight; style.lineHeightMultiplier = source.lineHeightMultiplier
            style.pendingLineHeightLength = source.pendingLineHeightLength
        case "color": style.color = source.color
        case "background-color": style.backgroundColor = source.backgroundColor
        case "background-image":
            if let sourceImage = source.backgroundImage {
                var image = style.backgroundImage ?? BackgroundImageStyle(source: sourceImage.source)
                image.source = sourceImage.source; style.backgroundImage = image
            } else { style.backgroundImage = nil }
        case "background-size": style.backgroundImage?.size = source.backgroundImage?.size ?? .auto
        case "background-position":
            style.backgroundImage?.positionX = source.backgroundImage?.positionX ?? .percent(0)
            style.backgroundImage?.positionY = source.backgroundImage?.positionY ?? .percent(0)
        case "background-repeat": style.backgroundImage?.repeatMode = source.backgroundImage?.repeatMode ?? .repeat
        case "background-attachment": style.backgroundImage?.attachment = source.backgroundImage?.attachment ?? .scroll
        case "white-space": style.whiteSpace = source.whiteSpace
        case "text-align": style.textAlign = source.textAlign
        case "text-indent":
            if case .length(let length) = source.textIndent { style.textIndent = .length(computedLength(length)) }
            else { style.textIndent = source.textIndent }
        case "width": style.width = computedLength(source.width)
        case "height": style.height = computedLength(source.height)
        case "max-width": style.maxWidth = source.maxWidth.map(computedLength)
        case "margin-top": style.marginTop = computedLength(source.marginTop)
        case "margin-right": style.marginRight = computedLength(source.marginRight)
        case "margin-bottom": style.marginBottom = computedLength(source.marginBottom)
        case "margin-left": style.marginLeft = computedLength(source.marginLeft)
        case "padding-top": style.paddingTop = computedLength(source.paddingTop)
        case "padding-right": style.paddingRight = computedLength(source.paddingRight)
        case "padding-bottom": style.paddingBottom = computedLength(source.paddingBottom)
        case "padding-left": style.paddingLeft = computedLength(source.paddingLeft)
        case "border-top-width": style.borderTopWidth = source.borderTopWidth; style.pendingBorderTopWidth = nil
        case "border-right-width": style.borderRightWidth = source.borderRightWidth; style.pendingBorderRightWidth = nil
        case "border-bottom-width": style.borderBottomWidth = source.borderBottomWidth; style.pendingBorderBottomWidth = nil
        case "border-left-width": style.borderLeftWidth = source.borderLeftWidth; style.pendingBorderLeftWidth = nil
        case "border-top-style": style.borderTopStyle = source.borderTopStyle
        case "border-right-style": style.borderRightStyle = source.borderRightStyle
        case "border-bottom-style": style.borderBottomStyle = source.borderBottomStyle
        case "border-left-style": style.borderLeftStyle = source.borderLeftStyle
        case "border-color": style.borderColor = source.borderColor ?? source.color
        case "border-radius": style.borderRadius = source.borderRadius; style.pendingBorderRadius = nil
        case "ruby-align", "-epub-ruby-align", "-webkit-ruby-align": style.rubyAlign = source.rubyAlign
        case "ruby-position", "-epub-ruby-position", "-webkit-ruby-position": style.rubyPosition = source.rubyPosition
        case "ruby-merge", "-epub-ruby-merge", "-webkit-ruby-merge": style.rubyMerge = source.rubyMerge
        default: return false
        }
        return true
    }

    private static func length(_ value: String, allowAuto: Bool, allowNegative: Bool, allowPercent: Bool = true) -> CSSLength? {
        guard let parsed = CSSLengthResolver.parse(value) else { return nil }
        let number: CGFloat
        switch parsed {
        case .auto: return allowAuto ? parsed : nil
        case .percent(let magnitude): guard allowPercent else { return nil }; number = magnitude
        case .px(let magnitude), .pt(let magnitude), .em(let magnitude), .rem(let magnitude): number = magnitude
        }
        // CSSLengthResolver's legacy unitless-pixel allowance is not valid CSS.
        if let unitless = Double(value), unitless != 0 { return nil }
        return number.isFinite && (allowNegative || number >= 0) ? parsed : nil
    }

    private static func backgroundPosition(_ value: String, style: ComputedStyle, config: BrowserLayoutConfig)
        -> (BackgroundImageStyle.BackgroundPosition, BackgroundImageStyle.BackgroundPosition)? {
        var parts = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard (1...2).contains(parts.count) else { return nil }
        if parts.count == 1 { parts = ["top", "bottom"].contains(parts[0]) ? ["center", parts[0]] : [parts[0], "center"] }
        if ["top", "bottom"].contains(parts[0]) || ["left", "right"].contains(parts[1]) { parts.swapAt(0, 1) }
        func component(_ value: String, horizontal: Bool) -> BackgroundImageStyle.BackgroundPosition? {
            if value == "center" { return .keyword(0.5) }
            if value == (horizontal ? "left" : "top") { return .keyword(0) }
            if value == (horizontal ? "right" : "bottom") { return .keyword(1) }
            guard let parsed = length(value, allowAuto: false, allowNegative: true) else { return nil }
            if case .percent(let fraction) = parsed { return .percent(fraction) }
            return CSSLengthResolver.resolve(parsed, emBase: style.fontSize, remBase: config.rootFontSize, percentBase: 0).map { .length($0) }
        }
        guard let x = component(parts[0], horizontal: true), let y = component(parts[1], horizontal: false) else { return nil }
        return (x, y)
    }

    private static func imageSource(_ raw: String) -> String? {
        guard raw.lowercased().hasPrefix("url("), raw.hasSuffix(")") else { return nil }
        let payload = String(raw.dropFirst(4).dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return nil }
        let characters = Array(payload)
        var quote: Character?, index = 0
        while index < characters.count {
            let character = characters[index]
            index += 1
            if character == "\\" {
                guard index < characters.count else { return nil }
                var digits = 0
                while index < characters.count, digits < 6, characters[index].isHexDigit { index += 1; digits += 1 }
                if digits == 0 { index += 1 }
                else if index < characters.count, characters[index].isWhitespace { index += 1 }
                continue
            }
            if let active = quote {
                if character == active {
                    guard index == characters.count else { return nil }
                    quote = nil
                }
            } else if character == "\"" || character == "'" {
                guard index == 1 else { return nil }
                quote = character
            } else if character == "(" || character == ")" || character.isWhitespace { return nil }
        }
        guard quote == nil else { return nil }
        return unquote(payload)
    }

    /// Split a single serialized CSS value without splitting quoted strings or functions.
    private static func components(_ value: String, separator: Character) -> [String] {
        var result: [String] = [], current = "", quote: Character?, depth = 0, escaped = false
        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if let active = quote { current.append(character); if character == active { quote = nil }; continue }
            if character == "\"" || character == "'" { quote = character; current.append(character); continue }
            if character == "(" { depth += 1 }; if character == ")" { depth -= 1 }
            if character == separator, depth == 0 { result.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); current = "" }
            else { current.append(character) }
        }
        result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return result
    }

    private static func unquote(_ value: String) -> String {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, (first == "\"" || first == "'"), text.last == first { return unescape(String(text.dropFirst().dropLast())) }
        return unescape(text)
    }

    /// CSS escapes are decoded after token boundaries have been identified so
    /// escaped commas/spaces cannot become font-family separators.
    private static func unescape(_ value: String) -> String {
        let characters = Array(value)
        var result = "", index = 0
        while index < characters.count {
            let character = characters[index]; index += 1
            guard character == "\\", index < characters.count else { result.append(character); continue }
            var hex = ""
            while index < characters.count, hex.count < 6, characters[index].isHexDigit {
                hex.append(characters[index]); index += 1
            }
            if !hex.isEmpty {
                if index < characters.count, characters[index].isWhitespace { index += 1 }
                if let code = UInt32(hex, radix: 16), code != 0, let scalar = UnicodeScalar(code) { result.unicodeScalars.append(scalar) }
                else { result.append("\u{FFFD}") }
            } else { result.append(characters[index]); index += 1 }
        }
        return result
    }

    private static func color(_ value: String, current: UIColor) -> UIColor? {
        if value == "currentcolor" { return current }
        if value == "transparent" { return .clear }
        let named: [String: UInt32] = ["black": 0x000000, "silver": 0xC0C0C0, "gray": 0x808080, "grey": 0x808080,
            "white": 0xFFFFFF, "maroon": 0x800000, "red": 0xFF0000, "purple": 0x800080, "fuchsia": 0xFF00FF,
            "magenta": 0xFF00FF, "green": 0x008000, "lime": 0x00FF00, "olive": 0x808000, "yellow": 0xFFFF00,
            "navy": 0x000080, "blue": 0x0000FF, "teal": 0x008080, "aqua": 0x00FFFF, "cyan": 0x00FFFF,
            "orange": 0xFFA500, "rebeccapurple": 0x663399]
        var hex = value.hasPrefix("#") ? String(value.dropFirst()) : ""
        if let rgb = named[value] { hex = String(format: "%06x", rgb) }
        if !hex.isEmpty {
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard (hex.count == 6 || hex.count == 8), let number = UInt32(hex, radix: 16) else { return nil }
            let rgba = hex.count == 6 ? (number << 8) | 255 : number
            return UIColor(red: CGFloat((rgba >> 24) & 255) / 255, green: CGFloat((rgba >> 16) & 255) / 255,
                blue: CGFloat((rgba >> 8) & 255) / 255, alpha: CGFloat(rgba & 255) / 255)
        }
        guard (value.hasPrefix("rgb(") || value.hasPrefix("rgba(")), value.hasSuffix(")"), let start = value.firstIndex(of: "(") else { return nil }
        let inner = value[value.index(after: start)..<value.index(before: value.endIndex)]
        let parts = inner.split { $0 == "," || $0 == "/" || $0.isWhitespace }.map(String.init)
        guard parts.count == 3 || parts.count == 4 else { return nil }
        func channel(_ token: String, alpha: Bool) -> CGFloat? {
            let percent = token.hasSuffix("%")
            guard let number = Double(percent ? String(token.dropLast()) : token), number.isFinite else { return nil }
            return CGFloat(min(1, max(0, number / (percent ? 100 : alpha ? 1 : 255))))
        }
        guard let r = channel(parts[0], alpha: false), let g = channel(parts[1], alpha: false), let b = channel(parts[2], alpha: false),
              let a = channel(parts.count == 4 ? parts[3] : "1", alpha: true) else { return nil }
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}
