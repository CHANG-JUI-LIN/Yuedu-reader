import Foundation
import UIKit

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

protocol HTMLCSSPropertyApplier {
    var key: String { get }
    func apply(
        value: String,
        style: inout HTMLAttributedStringBuilder.ResolvedStyle,
        context: HTMLCSSApplyContext
    )
}

final class HTMLCSSPropertyApplierRegistry {
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
        for (key, value) in declarations {
            guard let applier = appliers[key] else { continue }
            applier.apply(value: value, style: &style, context: context)
            handled.insert(key)
        }
        return handled
    }

    static let defaultRegistry = HTMLCSSPropertyApplierRegistry(appliers: [
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
        WritingModeApplier(),
        WebkitWritingModeApplier(),
        EPUBWritingModeApplier(),
    ])
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
