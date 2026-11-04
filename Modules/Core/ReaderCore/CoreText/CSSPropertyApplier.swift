import Foundation
import UIKit
import YueduCoreTextTypography

struct HTMLCSSApplyContext {
    let parentStyle: HTMLAttributedStringBuilder.ResolvedStyle
    let rootFontSize: CGFloat
    let resolveLength: (_ raw: String, _ currentFontSize: CGFloat, _ rootFontSize: CGFloat, _ relativeBase: CGFloat) -> CGFloat?
    let parseColor: (String) -> UIColor?
    let cssFontWeight: (_ value: String, _ current: Int) -> Int
    let cssAlignment: (String) -> NSTextAlignment
    let cssDisplayIsBlock: (String) -> Bool
    let resolveLineHeight: (_ raw: String, _ fontSize: CGFloat, _ rootFontSize: CGFloat) -> CGFloat?
    let extractURL: (String) -> String?
    let parseEmbeddedColor: (String) -> UIColor?
}

protocol HTMLCSSPropertyApplier: Sendable {
    var key: String { get }
    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    )
}

final class HTMLCSSPropertyApplierRegistry: Sendable {
    private let appliers: [String: any HTMLCSSPropertyApplier]

    init(appliers: [any HTMLCSSPropertyApplier]) {
        self.appliers = Dictionary(uniqueKeysWithValues: appliers.map { ($0.key, $0) })
    }

    func apply(
        declarations: [String: String],
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) -> Set<String> {
        var handled = Set<String>()
        // A shorthand resets the longhands it leaves out, so it goes first: one rule's
        // `text-emphasis: sesame; text-emphasis-color: red` keeps its red whatever order the
        // dictionary hands the two back in.
        for pass in [true, false] {
            for (key, value) in declarations where Self.shorthands.contains(key) == pass {
                guard let applier = appliers[key] else { continue }
                applier.apply(value: value, style: &style, context: context)
                handled.insert(key)
            }
        }
        return handled
    }

    private static let shorthands: Set<String> = [
        "text-decoration", "-webkit-text-decoration",
        "text-emphasis", "-webkit-text-emphasis", "-epub-text-emphasis",
    ]

    static let defaultRegistry = HTMLCSSPropertyApplierRegistry(appliers: ([
        FontSizeApplier(),
        FontFamilyApplier(),
        FontWeightApplier(),
        FontStyleApplier(),
        TextAlignApplier(),
        DisplayApplier(),
        FloatApplier(),
        ColorApplier(),
        LineHeightApplier(),
        BackgroundImageApplier(),
        BackgroundColorApplier(),
        LetterSpacingApplier(),
        DirectionApplier(),
        WritingModeApplier(),
        WebkitWritingModeApplier(),
        EPUBWritingModeApplier(),
        TextCombineUprightApplier(key: "text-combine-upright", legacy: false),
        TextCombineUprightApplier(key: "-epub-text-combine-horizontal", legacy: false),
        TextCombineUprightApplier(key: "-ms-text-combine-horizontal", legacy: false),
        TextCombineUprightApplier(key: "-webkit-text-combine", legacy: true),
        TextCombineUprightApplier(key: "-epub-text-combine", legacy: true),
    ] as [any HTMLCSSPropertyApplier]) + ["", "-webkit-"].flatMap { prefix -> [any HTMLCSSPropertyApplier] in [
        TextDecorationShorthandApplier(key: prefix + "text-decoration"),
        TextDecorationLineApplier(key: prefix + "text-decoration-line"),
        TextDecorationStyleApplier(key: prefix + "text-decoration-style"),
        TextDecorationColorApplier(key: prefix + "text-decoration-color"),
        TextUnderlinePositionApplier(key: prefix + "text-underline-position"),
    ] } + ["", "-webkit-", "-epub-"].flatMap { prefix -> [any HTMLCSSPropertyApplier] in [
        TextEmphasisShorthandApplier(key: prefix + "text-emphasis"),
        TextEmphasisStyleApplier(key: prefix + "text-emphasis-style"),
        TextEmphasisColorApplier(key: prefix + "text-emphasis-color"),
        TextEmphasisPositionApplier(key: prefix + "text-emphasis-position"),
    ] })
}

enum HTMLWritingDirectionResolver {
    private static let rtlLanguageCodes: Set<String> = [
        "ar", "arc", "ckb", "dv", "fa", "ha", "he", "iw", "khw", "ks", "ku",
        "nqo", "prs", "ps", "sd", "syr", "ug", "ur", "yi"
    ]

    static func defaultDirection(forLanguage language: String?) -> NSWritingDirection {
        guard let language else { return .natural }
        let primaryCode = language
            .split { $0 == "-" || $0 == "_" }
            .first
            .map { String($0).lowercased() }
        guard let primaryCode else { return .natural }
        return rtlLanguageCodes.contains(primaryCode) ? .rightToLeft : .natural
    }

    static func resolve(
        _ raw: String,
        autoText: String? = nil,
        inherited: NSWritingDirection = .natural
    ) -> NSWritingDirection? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "rtl":
            return .rightToLeft
        case "ltr":
            return .leftToRight
        case "auto":
            return autoText.flatMap(firstStrongDirection(in:)) ?? (inherited == .natural ? nil : inherited)
        case "inherit":
            return inherited
        case "initial", "unset":
            return .natural
        default:
            return nil
        }
    }

    private static func firstStrongDirection(in text: String) -> NSWritingDirection? {
        for scalar in text.unicodeScalars {
            if isStrongRTL(scalar) {
                return .rightToLeft
            }
            if isStrongLTR(scalar) {
                return .leftToRight
            }
        }
        return nil
    }

    private static func isStrongRTL(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF,
             0x10800...0x10FFF, 0x1E800...0x1EDFF, 0x1EE00...0x1EEFF:
            return true
        default:
            return false
        }
    }

    private static func isStrongLTR(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x02AF,
             0x0370...0x052F, 0x1E00...0x1EFF:
            return true
        default:
            return false
        }
    }
}

private struct FontSizeApplier: HTMLCSSPropertyApplier {
    let key = "font-size"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        style.fontSize = context.resolveLength(
            value,
            context.parentStyle.fontSize,
            context.rootFontSize,
            context.parentStyle.fontSize
        ) ?? style.fontSize
    }
}

private struct FontFamilyApplier: HTMLCSSPropertyApplier {
    let key = "font-family"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        style.fontFamilies = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))) }
    }
}

private struct FontWeightApplier: HTMLCSSPropertyApplier {
    let key = "font-weight"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        style.fontWeight = context.cssFontWeight(value, style.fontWeight)
    }
}

private struct FontStyleApplier: HTMLCSSPropertyApplier {
    let key = "font-style"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        style.isItalic = value.lowercased().contains("italic")
    }
}

private struct TextAlignApplier: HTMLCSSPropertyApplier {
    let key = "text-align"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        style.textAlign = context.cssAlignment(value)
    }
}

private struct DisplayApplier: HTMLCSSPropertyApplier {
    let key = "display"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        // `display: none` removes the element (and its subtree) from rendering. Track it on the
        // style so the node builder can skip it; a later cascade rule (e.g. `display: block`)
        // correctly un-hides because each declaration re-evaluates this.
        style.isHidden = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none"
        style.isBlock = context.cssDisplayIsBlock(value)
    }
}

private struct FloatApplier: HTMLCSSPropertyApplier {
    let key = "float"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        // Record the float side. The builder emits a zero-width float marker for the element and the
        // paginator carves a notch out of the page so the surrounding text wraps beside it (magazine
        // style). `float` is not inherited, so children reset to nil below.
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left":
            style.floatSide = .left
        case "right":
            style.floatSide = .right
        case "none":
            style.floatSide = nil
        default:
            break
        }
    }
}

private struct ColorApplier: HTMLCSSPropertyApplier {
    let key = "color"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        if let color = context.parseColor(value) {
            style.textColor = color
            style.hasCSSColor = true
        }
    }
}

private struct LineHeightApplier: HTMLCSSPropertyApplier {
    let key = "line-height"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        guard let resolved = context.resolveLineHeight(value, style.fontSize, context.rootFontSize) else { return }
        style.lineHeight = resolved
        style.lineHeightExplicit = true
    }
}

private struct BackgroundImageApplier: HTMLCSSPropertyApplier {
    let key = "background-image"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        style.backgroundImage = context.extractURL(value)
    }
}

private struct BackgroundColorApplier: HTMLCSSPropertyApplier {
    let key = "background-color"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        if let color = context.parseColor(value) {
            style.backgroundFillColor = color
        }
    }
}

private struct LetterSpacingApplier: HTMLCSSPropertyApplier {
    let key = "letter-spacing"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed == "normal" {
            style.letterSpacing = nil
            return
        }
        if let resolved = context.resolveLength(trimmed, style.fontSize, context.rootFontSize, style.fontSize) {
            style.letterSpacing = resolved
        }
    }
}

private struct DirectionApplier: HTMLCSSPropertyApplier {
    let key = "direction"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        if let direction = HTMLWritingDirectionResolver.resolve(
            value,
            inherited: context.parentStyle.baseWritingDirection
        ) {
            style.baseWritingDirection = direction
        }
    }
}

/// `text-combine-upright` and its prefixed forms, parsed by the rules BrowserAuto uses.
/// The older `-webkit-text-combine` / `-epub-text-combine` take `horizontal` for `all`.
private struct TextCombineUprightApplier: HTMLCSSPropertyApplier {
    let key: String
    let legacy: Bool

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch v {
        case "inherit", "unset": style.textCombineUpright = context.parentStyle.textCombineUpright
        case "initial": style.textCombineUpright = .none
        default:
            let parsed = legacy ? TextCombineUpright.parseLegacy(v) : TextCombineUpright.parse(v)
            // An unknown value is invalid CSS: the declaration is dropped.
            if parsed.isSupported { style.textCombineUpright = parsed }
        }
    }
}

private struct WritingModeApplier: HTMLCSSPropertyApplier {
    let key = "writing-mode"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.contains("vertical-rl") || v.contains("vertical-lr") {
            style.isVerticalWritingMode = true
        }
    }
}

private struct WebkitWritingModeApplier: HTMLCSSPropertyApplier {
    let key = "-webkit-writing-mode"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.contains("vertical-rl") || v.contains("vertical-lr") {
            style.isVerticalWritingMode = true
        }
    }
}

private struct EPUBWritingModeApplier: HTMLCSSPropertyApplier {
    let key = "-epub-writing-mode"

    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    ) {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if v.contains("vertical-rl") || v.contains("vertical-lr") {
            style.isVerticalWritingMode = true
        }
    }
}

// MARK: - Text decoration and emphasis

/// The CSS values of the `text-decoration` properties (CSS Text Decoration 3 §2). Legacy
/// draws its own thickness, so a thickness is only told apart from an invalid token.
enum TextDecorationValues {
    static func lines(_ value: String) -> RenderTextDecoration.Lines? {
        let tokens = value.lowercased().split(whereSeparator: \.isWhitespace)
        if tokens == ["none"] { return [] }
        var lines: RenderTextDecoration.Lines = []
        for token in tokens {
            switch token {
            case "underline": lines.insert(.underline)
            case "overline": lines.insert(.overline)
            case "line-through": lines.insert(.lineThrough)
            case "blink": continue
            default: return nil
            }
        }
        return tokens.isEmpty ? nil : lines
    }

    static func style(_ value: String) -> RenderTextDecoration.Style? {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "solid": return .solid
        case "double": return .double
        case "dotted": return .dotted
        case "dashed": return .dashed
        case "wavy": return .wavy
        default: return nil
        }
    }

    /// `auto`, `from-font`, a length or a percentage.
    static func isThickness(_ token: String) -> Bool {
        if token == "auto" || token == "from-font" { return true }
        let number = token.prefix { $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }
        return !number.isEmpty && Double(number) != nil
    }

    /// The shorthand: lines, style, colour and thickness in any order; what it leaves out
    /// resets. A nil colour is `currentColor`; nil drops an invalid declaration.
    static func shorthand(_ value: String, parseColor: (String) -> UIColor?)
        -> (lines: RenderTextDecoration.Lines, style: RenderTextDecoration.Style, color: UIColor?)? {
        var lines: RenderTextDecoration.Lines = []
        var style = RenderTextDecoration.Style.solid
        var color: UIColor?
        for token in CSSValueTokens.split(value) {
            let lowered = token.lowercased()
            if let parsed = Self.lines(lowered) {
                lines.formUnion(parsed)
            } else if let parsed = Self.style(lowered) {
                style = parsed
            } else if lowered == "currentcolor" {
                color = nil
            } else if let parsed = parseColor(token) {
                color = parsed
            } else if !isThickness(lowered) {
                return nil
            }
        }
        return (lines, style, color)
    }

    /// `text-underline-position`: whether it says `right`. nil drops an invalid declaration.
    static func underlineRight(_ value: String) -> Bool? {
        var right = false
        for token in value.lowercased().split(whereSeparator: \.isWhitespace) {
            switch token {
            case "right": right = true
            case "auto", "from-font", "under", "left": continue
            default: return nil
            }
        }
        return right
    }
}

/// Splits a CSS value at its top-level spaces, keeping a function's arguments (`rgb(1, 2, 3)`)
/// and a quoted string in one token.
enum CSSValueTokens {
    static func split(_ value: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        var quote: Character?
        for character in value {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "(" {
                depth += 1
                current.append(character)
            } else if character == ")" {
                depth = max(0, depth - 1)
                current.append(character)
            } else if character.isWhitespace, depth == 0 {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

/// The element's own lines, which join those in effect when its cascade is done
/// (`ResolvedStyle.textDecorations`). Not inherited.
private struct TextDecorationLineApplier: HTMLCSSPropertyApplier {
    let key: String

    func apply(value: String, style: inout HTMLAttributedStringBuilder.ResolvedStyle, context: HTMLCSSApplyContext) {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "inherit": style.textDecorationLine = context.parentStyle.textDecorationLine
        case "initial", "unset": style.textDecorationLine = []
        default:
            if let lines = TextDecorationValues.lines(value) { style.textDecorationLine = lines }
        }
    }
}

private struct TextDecorationStyleApplier: HTMLCSSPropertyApplier {
    let key: String

    func apply(value: String, style: inout HTMLAttributedStringBuilder.ResolvedStyle, context: HTMLCSSApplyContext) {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "inherit": style.textDecorationStyle = context.parentStyle.textDecorationStyle
        case "initial", "unset": style.textDecorationStyle = .solid
        default:
            if let parsed = TextDecorationValues.style(value) { style.textDecorationStyle = parsed }
        }
    }
}

private struct TextDecorationColorApplier: HTMLCSSPropertyApplier {
    let key: String

    func apply(value: String, style: inout HTMLAttributedStringBuilder.ResolvedStyle, context: HTMLCSSApplyContext) {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "inherit": style.textDecorationColor = context.parentStyle.textDecorationColor
        case "initial", "unset", "currentcolor": style.textDecorationColor = nil
        default:
            if let color = context.parseColor(value) { style.textDecorationColor = color }
        }
    }
}

private struct TextDecorationShorthandApplier: HTMLCSSPropertyApplier {
    let key: String

    func apply(value: String, style: inout HTMLAttributedStringBuilder.ResolvedStyle, context: HTMLCSSApplyContext) {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "inherit":
            style.textDecorationLine = context.parentStyle.textDecorationLine
            style.textDecorationStyle = context.parentStyle.textDecorationStyle
            style.textDecorationColor = context.parentStyle.textDecorationColor
        case "initial", "unset":
            style.textDecorationLine = []
            style.textDecorationStyle = .solid
            style.textDecorationColor = nil
        default:
            guard let parsed = TextDecorationValues.shorthand(value, parseColor: context.parseColor) else { return }
            style.textDecorationLine = parsed.lines
            style.textDecorationStyle = parsed.style
            style.textDecorationColor = parsed.color
        }
    }
}

/// Inherited; only `right` matters to legacy, which puts every other underline where Core
/// Text's font metrics do (`ReaderTextDecorationRenderer`).
private struct TextUnderlinePositionApplier: HTMLCSSPropertyApplier {
    let key: String

    func apply(value: String, style: inout HTMLAttributedStringBuilder.ResolvedStyle, context: HTMLCSSApplyContext) {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "inherit", "unset": style.textUnderlineRight = context.parentStyle.textUnderlineRight
        case "initial": style.textUnderlineRight = false
        default:
            if let right = TextDecorationValues.underlineRight(value) { style.textUnderlineRight = right }
        }
    }
}

/// `text-emphasis-*`, all inherited, parsed as BrowserAuto parses them (`TextEmphasisValue`).
private struct TextEmphasisStyleApplier: HTMLCSSPropertyApplier {
    let key: String

    func apply(value: String, style: inout HTMLAttributedStringBuilder.ResolvedStyle, context: HTMLCSSApplyContext) {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "inherit", "unset": style.textEmphasisStyle = context.parentStyle.textEmphasisStyle
        case "initial": style.textEmphasisStyle = nil
        default:
            if let parsed = TextEmphasisValue.style(value) { style.textEmphasisStyle = parsed }
        }
    }
}

private struct TextEmphasisColorApplier: HTMLCSSPropertyApplier {
    let key: String

    func apply(value: String, style: inout HTMLAttributedStringBuilder.ResolvedStyle, context: HTMLCSSApplyContext) {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "inherit", "unset": style.textEmphasisColor = context.parentStyle.textEmphasisColor
        case "initial", "currentcolor": style.textEmphasisColor = nil
        default:
            if let color = context.parseColor(value) { style.textEmphasisColor = color }
        }
    }
}

private struct TextEmphasisPositionApplier: HTMLCSSPropertyApplier {
    let key: String

    func apply(value: String, style: inout HTMLAttributedStringBuilder.ResolvedStyle, context: HTMLCSSApplyContext) {
        let lowered = value.trimmingCharacters(in: .whitespaces).lowercased()
        switch lowered {
        case "inherit", "unset": style.textEmphasisPosition = context.parentStyle.textEmphasisPosition
        case "initial": style.textEmphasisPosition = TextEmphasisPosition()
        default:
            if let parsed = TextEmphasisValue.position(lowered) { style.textEmphasisPosition = parsed }
        }
    }
}

private struct TextEmphasisShorthandApplier: HTMLCSSPropertyApplier {
    let key: String

    func apply(value: String, style: inout HTMLAttributedStringBuilder.ResolvedStyle, context: HTMLCSSApplyContext) {
        switch value.trimmingCharacters(in: .whitespaces).lowercased() {
        case "inherit", "unset":
            style.textEmphasisStyle = context.parentStyle.textEmphasisStyle
            style.textEmphasisColor = context.parentStyle.textEmphasisColor
        case "initial":
            style.textEmphasisStyle = nil
            style.textEmphasisColor = nil
        default:
            let parsed = TextEmphasisValue.shorthand(CSSValueTokens.split(value)) { token -> UIColor?? in
                if token.lowercased() == "currentcolor" { return .some(nil) }
                return context.parseColor(token).map { .some($0) }
            }
            guard let parsed else { return }
            style.textEmphasisStyle = parsed.style
            style.textEmphasisColor = parsed.color
        }
    }
}
