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
    let readerDialogueHighlightEnabled: Bool
    let readerDialogueHighlightColorHex: UInt32
    let readerDialogueBoxEnabled: Bool
    let readerDialogueBoxColorHex: UInt32
    let readerDialogueBoxStyleRaw: Int
}

extension ReaderRenderSettings {
    /// Classifies a settings snapshot without making the SwiftUI layer know
    /// which fields affect pagination and which only recolor an existing page.
    /// Dialogue colors are intentionally omitted: those are attributed-content
    /// inputs and are routed by `ReaderDocumentStyleFingerprint`.
    func refreshIntent(comparedTo old: ReaderRenderSettings) -> ReaderRenderRefreshIntent? {
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

        if layoutChanged { return .layout }

        let appearanceChanged =
            theme != old.theme
            || textColor != old.textColor
            || backgroundColor != old.backgroundColor
            || readerBackgroundImageURL != old.readerBackgroundImageURL

        return appearanceChanged ? .appearance : nil
    }
}

enum ReaderVisibleRefreshOutcome: Equatable {
    case applied
    case failed(ReaderRenderRefreshFailure)
}
