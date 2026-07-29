import SwiftUI
import UIKit

enum GlobalAppTypography {
    nonisolated(unsafe) static var activePostScriptName: String?

    enum Style {
        case caption2
        case caption
        case footnote
        case subheadline
        case callout
        case body
        case headline
        case title3
        case title2
        case title
        case largeTitle

        fileprivate var swiftUIStyle: Font.TextStyle {
            switch self {
            case .caption2: .caption2
            case .caption: .caption
            case .footnote: .footnote
            case .subheadline: .subheadline
            case .callout: .callout
            case .body: .body
            case .headline: .headline
            case .title3: .title3
            case .title2: .title2
            case .title: .title
            case .largeTitle: .largeTitle
            }
        }

        fileprivate var uiKitStyle: UIFont.TextStyle {
            switch self {
            case .caption2: .caption2
            case .caption: .caption1
            case .footnote: .footnote
            case .subheadline: .subheadline
            case .callout: .callout
            case .body: .body
            case .headline: .headline
            case .title3: .title3
            case .title2: .title2
            case .title: .title1
            case .largeTitle: .largeTitle
            }
        }

        fileprivate var basePointSize: CGFloat {
            switch self {
            case .caption2: 11
            case .caption: 12
            case .footnote: 13
            case .subheadline: 15
            case .callout: 16
            case .body, .headline: 17
            case .title3: 20
            case .title2: 22
            case .title: 28
            case .largeTitle: 34
            }
        }

        fileprivate var systemFont: Font {
            switch self {
            case .caption2: .caption2
            case .caption: .caption
            case .footnote: .footnote
            case .subheadline: .subheadline
            case .callout: .callout
            case .body: .body
            case .headline: .headline
            case .title3: .title3
            case .title2: .title2
            case .title: .title
            case .largeTitle: .largeTitle
            }
        }

        fileprivate var defaultSwiftUIWeight: Font.Weight? {
            switch self {
            case .headline: .semibold
            default: nil
            }
        }

        fileprivate var defaultUIKitWeight: UIFont.Weight {
            switch self {
            case .headline: .semibold
            default: .regular
            }
        }
    }

    static func activate(postScriptName: String?) {
        let trimmed = postScriptName?.trimmingCharacters(in: .whitespacesAndNewlines)
        activePostScriptName = trimmed.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func font(_ style: Style, weight: Font.Weight? = nil) -> Font {
        font(style, postScriptName: activePostScriptName, weight: weight)
    }

    static func font(
        _ style: Style,
        postScriptName: String?,
        weight: Font.Weight? = nil
    ) -> Font {
        guard let postScriptName,
              UIFont(name: postScriptName, size: style.basePointSize) != nil else {
            return weight.map { style.systemFont.weight($0) } ?? style.systemFont
        }

        let custom = Font.custom(
            postScriptName,
            size: style.basePointSize,
            relativeTo: style.swiftUIStyle
        )
        return (weight ?? style.defaultSwiftUIWeight).map { custom.weight($0) } ?? custom
    }

    static func fixedFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        systemDesign: Font.Design = .default
    ) -> Font {
        if case .monospaced = systemDesign {
            return .system(size: size, weight: weight, design: systemDesign)
        }
        guard let activePostScriptName,
              UIFont(name: activePostScriptName, size: size) != nil else {
            return .system(size: size, weight: weight, design: systemDesign)
        }
        return Font.custom(activePostScriptName, fixedSize: size).weight(weight)
    }

    /// The point size UIKit's own font for `style` reaches at
    /// `.extraExtraExtraLarge` — the largest non-accessibility category, and
    /// where the system stops growing bar chrome.
    ///
    /// Bar chrome (tab bar, navigation bar) lays out at a fixed height, so its
    /// labels must stop growing where UIKit's do. An unclamped scaled font
    /// overflows the item and draws on top of the tab icon.
    static func chromeMaximumPointSize(_ style: Style) -> CGFloat {
        UIFont.preferredFont(
            forTextStyle: style.uiKitStyle,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: .extraExtraExtraLarge)
        ).pointSize
    }

    static func uiFont(
        _ style: Style,
        postScriptName: String?,
        weight: UIFont.Weight? = nil,
        maximumPointSize: CGFloat? = nil,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        let baseFont = baseUIFont(style, postScriptName: postScriptName, weight: weight)

        let metrics = UIFontMetrics(forTextStyle: style.uiKitStyle)
        guard let maximumPointSize else {
            return metrics.scaledFont(for: baseFont, compatibleWith: traits)
        }
        return metrics.scaledFont(
            for: baseFont,
            maximumPointSize: maximumPointSize,
            compatibleWith: traits
        )
    }

    /// Resolves a semantic UIKit font at its base point size without applying
    /// Dynamic Type. Use only for fixed-height chrome such as tab bar titles.
    static func unscaledUIFont(
        _ style: Style,
        postScriptName: String?,
        weight: UIFont.Weight? = nil
    ) -> UIFont {
        baseUIFont(style, postScriptName: postScriptName, weight: weight)
    }

    private static func baseUIFont(
        _ style: Style,
        postScriptName: String?,
        weight: UIFont.Weight?
    ) -> UIFont {
        let resolvedWeight = weight ?? style.defaultUIKitWeight
        guard let postScriptName,
              let customFont = UIFont(name: postScriptName, size: style.basePointSize) else {
            return UIFont.systemFont(ofSize: style.basePointSize, weight: resolvedWeight)
        }

        if resolvedWeight.rawValue >= UIFont.Weight.semibold.rawValue,
           let descriptor = customFont.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: style.basePointSize)
        }
        return customFont
    }
}
