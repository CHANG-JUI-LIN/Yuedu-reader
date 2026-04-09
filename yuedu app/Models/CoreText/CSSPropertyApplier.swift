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
        ColorApplier(),
        LineHeightApplier(),
        BackgroundImageApplier(),
        BackgroundColorApplier(),
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
        style.isBlock = context.cssDisplayIsBlock(value)
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
