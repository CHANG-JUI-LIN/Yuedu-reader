import SwiftUI
import UIKit

enum GlobalAppTypography {
    nonisolated(unsafe) static var activePostScriptName: String?
    /// Bold Text (Settings › Accessibility) is on. The system font turns heavier by
    /// itself; a custom one SwiftUI never touches — measured 2026-09-29: with
    /// `legibilityWeight` set to `.bold`, a custom font drew exactly as without — so the
    /// fonts below take one step heavier themselves, as Apple's HIG asks of custom fonts.
    /// A single-weight font has no heavier face and SwiftUI synthesizes none, so
    /// `effectivePostScriptName(_:boldText:)` sets it aside for the system font meanwhile.
    nonisolated(unsafe) static var isBoldTextActive = false

    /// Registers the calling view's body as depending on the global font and Bold Text.
    /// The fonts are drawn from the statics above, which nothing observes; `ContentView`
    /// bumps `GlobalSettings.typographyRevision` when either changes, and every builder here
    /// reads it so a view that sets its own font redraws with the new face or weight.
    @MainActor
    private static func observeTypography() {
        _ = GlobalSettings.shared.typographyRevision
    }
    nonisolated(unsafe) private static var bolderFaceCache: [String: Bool] = [:]

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

    static func activate(postScriptName: String?, boldText: Bool) {
        let trimmed = postScriptName?.trimmingCharacters(in: .whitespacesAndNewlines)
        activePostScriptName = trimmed.flatMap { $0.isEmpty ? nil : $0 }
        isBoldTextActive = boldText
    }

    /// The global font to draw with: the one chosen, except that while Bold Text is on a
    /// font with no bolder face gives way to the system font, which does turn bold — the
    /// user's call (2026-09-29): Bold Text is on to make the interface readable.
    static func effectivePostScriptName(_ postScriptName: String?, boldText: Bool) -> String? {
        guard let postScriptName, boldText else { return postScriptName }
        return hasBolderFace(postScriptName) ? postScriptName : nil
    }

    /// Whether the font's family has a bold face to step to. Asked on every font change,
    /// so the answer is kept per name — a family's faces do not change while it is
    /// installed.
    static func hasBolderFace(_ postScriptName: String) -> Bool {
        if let known = bolderFaceCache[postScriptName] { return known }
        let answer: Bool
        if let font = UIFont(name: postScriptName, size: 17),
           let descriptor = font.fontDescriptor.withSymbolicTraits(
               font.fontDescriptor.symbolicTraits.union(.traitBold)
           ) {
            answer = UIFont(descriptor: descriptor, size: 17).fontName != font.fontName
        } else {
            answer = false
        }
        bolderFaceCache[postScriptName] = answer
        return answer
    }

    /// One step heavier, for Bold Text on a custom font.
    static func boldTextWeight(_ weight: Font.Weight) -> Font.Weight {
        switch weight {
        case .ultraLight: .light
        case .thin: .regular
        case .light: .medium
        case .regular: .semibold
        case .medium, .semibold: .bold
        case .bold: .heavy
        default: .black
        }
    }

    /// The UIKit side of `boldTextWeight(_:)`, for the bar fonts — the same steps.
    static func boldTextWeight(_ weight: UIFont.Weight) -> UIFont.Weight {
        let steps: [(from: UIFont.Weight, to: UIFont.Weight)] = [
            (.ultraLight, .light), (.thin, .regular), (.light, .medium), (.regular, .semibold),
            (.medium, .bold), (.semibold, .bold), (.bold, .heavy), (.heavy, .black),
        ]
        return steps.first { weight.rawValue <= $0.from.rawValue }?.to ?? .black
    }

    /// - Parameter systemDesign: the design of the system font (serif for New York). It
    ///   applies only while no interface font is chosen; a chosen font draws as itself.
    @MainActor
    static func font(
        _ style: Style,
        weight: Font.Weight? = nil,
        systemDesign: Font.Design = .default
    ) -> Font {
        observeTypography()
        return font(style, postScriptName: activePostScriptName, weight: weight, systemDesign: systemDesign)
    }

    @MainActor
    static func font(
        _ style: Style,
        postScriptName: String?,
        weight: Font.Weight? = nil,
        systemDesign: Font.Design = .default
    ) -> Font {
        observeTypography()
        guard let postScriptName,
              UIFont(name: postScriptName, size: style.basePointSize) != nil else {
            let system = systemDesign == .default
                ? style.systemFont
                : .system(style.swiftUIStyle, design: systemDesign)
            return weight.map { system.weight($0) } ?? system
        }

        let custom = Font.custom(
            postScriptName,
            size: style.basePointSize,
            relativeTo: style.swiftUIStyle
        )
        let requested = weight ?? style.defaultSwiftUIWeight
        guard isBoldTextActive else {
            return requested.map { custom.weight($0) } ?? custom
        }
        return custom.weight(boldTextWeight(requested ?? .regular))
    }

    @MainActor
    static func fixedFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        systemDesign: Font.Design = .default
    ) -> Font {
        observeTypography()
        if case .monospaced = systemDesign {
            return .system(size: size, weight: weight, design: systemDesign)
        }
        guard let activePostScriptName,
              UIFont(name: activePostScriptName, size: size) != nil else {
            return .system(size: size, weight: weight, design: systemDesign)
        }
        return Font.custom(activePostScriptName, fixedSize: size)
            .weight(isBoldTextActive ? boldTextWeight(weight) : weight)
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

    @MainActor
    static func uiFont(
        _ style: Style,
        postScriptName: String?,
        weight: UIFont.Weight? = nil,
        maximumPointSize: CGFloat? = nil,
        compatibleWith traits: UITraitCollection? = nil
    ) -> UIFont {
        observeTypography()
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
    @MainActor
    static func unscaledUIFont(
        _ style: Style,
        postScriptName: String?,
        weight: UIFont.Weight? = nil
    ) -> UIFont {
        observeTypography()
        return baseUIFont(style, postScriptName: postScriptName, weight: weight)
    }

    private static func baseUIFont(
        _ style: Style,
        postScriptName: String?,
        weight: UIFont.Weight?
    ) -> UIFont {
        guard let postScriptName,
              let customFont = UIFont(name: postScriptName, size: style.basePointSize) else {
            // The system font: UIKit applies Bold Text to it by itself.
            return UIFont.systemFont(ofSize: style.basePointSize, weight: weight ?? style.defaultUIKitWeight)
        }
        let requested = weight ?? style.defaultUIKitWeight
        let resolvedWeight = isBoldTextActive ? boldTextWeight(requested) : requested

        if resolvedWeight.rawValue >= UIFont.Weight.semibold.rawValue,
           let descriptor = customFont.fontDescriptor.withSymbolicTraits(.traitBold) {
            return UIFont(descriptor: descriptor, size: style.basePointSize)
        }
        return customFont
    }
}
