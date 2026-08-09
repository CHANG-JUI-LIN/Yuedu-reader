import CoreGraphics
import Foundation

enum ReaderDisplayMode: Equatable {
    case paged
    case scroll
}

enum ReaderRenderRefreshIntent: Equatable {
    case layout
    case appearance
    case chapterContent(Int)
    case modeActivation
}

struct ReaderRenderRefreshRequest: Equatable {
    let intent: ReaderRenderRefreshIntent
    let mode: ReaderDisplayMode
    let settings: ReaderRenderSettings
    let position: CoreTextReadingPosition
    let viewportSize: CGSize
}

enum ReaderRenderRefreshFailure: Error, Equatable {
    case engineUnavailable(ReaderDisplayMode)
    case layoutUnavailable(Int)
    case scrollViewportUnavailable
    case scrollLayoutUnavailable(Int)
}

enum ReaderRenderRefreshResult: Equatable {
    case completed(transactionID: UInt64)
    case superseded(transactionID: UInt64)
    case failed(transactionID: UInt64, failure: ReaderRenderRefreshFailure)

    var isCompleted: Bool {
        if case .completed = self {
            return true
        }
        return false
    }
}

struct ReaderVisibleRefreshCommit: Equatable {
    let transactionID: UInt64
    let mode: ReaderDisplayMode
    let position: CoreTextReadingPosition
}

struct ReaderScrollNavigationRequest: Equatable {
    let version: UInt64
    let position: CoreTextReadingPosition
}

/// Values read from global settings while CoreText builds chapter content.
/// They are intentionally separate from `ReaderRenderSettings`: these values
/// change the attributed chapter output, but do not describe pagination
/// geometry or the active renderer's viewport.
struct ReaderDocumentStyleFingerprint: Equatable {
    let commentBubbleFollowsSourceSVG: Bool
    let commentBubblePresetMode: ReaderCommentBubblePresetMode
    let commentBubbleCustomStyles: [ReaderCommentBubbleCustomStyle]
    let commentBubbleSelectedCustomStyleID: UUID?
    let commentBubbleScale: Double
    let commentBubbleTextScale: Double
    let readerTextUnderlineDecorationEnabled: Bool
    let readerTextUnderlineDecorationColorHex: UInt32
    let readerTextUnderlineStyle: ReaderTextUnderlineStyle
    let readerTextUnderlineThickness: Double
    let readerTextUnderlineOffset: Double
}

enum RegexHighlightRefreshKind: Equatable, Sendable {
    case redraw
    case relayout
}

enum RegexHighlightRefreshPolicy {
    private struct ActiveRuleSignature: Equatable {
        let id: String
        let pattern: String
        let options: RegexHighlightOptions
    }

    private struct TypographySignature: Equatable {
        let fontPostScriptName: String?
        let fontSize: Double?
        let fontWeight: Int?
        let italic: Bool?
        let letterSpacing: Double?
        let lineHeight: Double?
    }

    static func classify(
        from old: RegexHighlightConfiguration,
        to new: RegexHighlightConfiguration
    ) -> RegexHighlightRefreshKind {
        guard old.version == new.version, old.isEnabled == new.isEnabled else {
            return .relayout
        }

        let oldEnabled = old.isEnabled ? old.evaluationRules.filter(\.isEnabled) : []
        let newEnabled = new.isEnabled ? new.evaluationRules.filter(\.isEnabled) : []
        let oldRules = oldEnabled.map {
            ActiveRuleSignature(id: $0.id, pattern: $0.pattern, options: $0.options)
        }
        let newRules = newEnabled.map {
            ActiveRuleSignature(id: $0.id, pattern: $0.pattern, options: $0.options)
        }
        guard oldRules == newRules else { return .relayout }

        for (oldRule, newRule) in zip(oldEnabled, newEnabled) {
            if typography(oldRule.lightStyle.text) != typography(newRule.lightStyle.text)
                || typography(oldRule.darkStyle.text) != typography(newRule.darkStyle.text) {
                return .relayout
            }
        }
        return .redraw
    }

    private static func typography(_ style: ReaderStyleTextStyle) -> TypographySignature {
        TypographySignature(
            fontPostScriptName: style.fontPostScriptName,
            fontSize: style.fontSize,
            fontWeight: style.fontWeight,
            italic: style.italic,
            letterSpacing: style.letterSpacing,
            lineHeight: style.lineHeight
        )
    }
}

extension ReaderRenderSettings {
    /// Classifies a settings snapshot without making the SwiftUI layer know
    /// which fields affect pagination and which only recolor an existing page.
    func refreshIntent(comparedTo old: ReaderRenderSettings) -> ReaderRenderRefreshIntent? {
        let regexRefresh = regexHighlightConfiguration == old.regexHighlightConfiguration
            ? nil
            : RegexHighlightRefreshPolicy.classify(
                from: old.regexHighlightConfiguration,
                to: regexHighlightConfiguration
            )
        let layoutChanged =
            fontSize != old.fontSize
            || lineHeightMultiple != old.lineHeightMultiple
            || lineSpacing != old.lineSpacing
            || paragraphSpacing != old.paragraphSpacing
            || letterSpacing != old.letterSpacing
            || marginH != old.marginH
            || marginV != old.marginV
            || footerHeight != old.footerHeight
            || contentInsets != old.contentInsets
            || writingMode != old.writingMode
            || fontPostScriptName != old.fontPostScriptName
            || isBold != old.isBold
            || chapterTitleStyle != old.chapterTitleStyle
            || regexRefresh == .relayout

        if layoutChanged { return .layout }

        let appearanceChanged =
            theme != old.theme
            || textColor != old.textColor
            || backgroundColor != old.backgroundColor
            || readerBackgroundImageURL != old.readerBackgroundImageURL
            || readerStyleAppearance != old.readerStyleAppearance
            || readerStyleAssetRevision != old.readerStyleAssetRevision
            || regexRefresh == .redraw

        return appearanceChanged ? .appearance : nil
    }
}

enum ReaderVisibleRefreshOutcome: Equatable {
    case applied
    case failed(ReaderRenderRefreshFailure)
}
