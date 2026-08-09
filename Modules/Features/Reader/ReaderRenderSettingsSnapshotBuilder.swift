import UIKit

struct ReaderRenderSettingsSnapshotInput {
    let theme: String
    let textColor: UIColor
    let backgroundColor: UIColor
    let fontSize: CGFloat
    let lineHeightMultiple: CGFloat
    let lineSpacing: CGFloat
    let paragraphSpacing: CGFloat
    let letterSpacing: CGFloat
    let marginH: CGFloat
    let writingMode: ReaderWritingMode
    let fontPostScriptName: String?
    let isBold: Bool
    var chapterTitleStyle: ChapterTitleStyle
    let readerBackgroundImageURL: URL?
    let regexHighlightConfiguration: RegexHighlightConfiguration
    let readerStyleAppearance: ReaderStyleAppearance
    let readerStyleAssetRevision: UInt64
}

enum ReaderRenderSurface {
    case paged(contentInsets: UIEdgeInsets, marginV: CGFloat, footerHeight: CGFloat)
    case scroll(contentInsets: UIEdgeInsets, marginV: CGFloat, footerHeight: CGFloat)
}

enum ReaderRenderSettingsSnapshotBuilder {
    static func make(
        input: ReaderRenderSettingsSnapshotInput,
        surface: ReaderRenderSurface
    ) -> ReaderRenderSettings {
        let contentInsets: UIEdgeInsets
        let marginV: CGFloat
        let footerHeight: CGFloat
        switch surface {
        case let .paged(insets, verticalMargin, height),
             let .scroll(insets, verticalMargin, height):
            contentInsets = insets
            marginV = verticalMargin
            footerHeight = height
        }

        return ReaderRenderSettings(
            theme: input.theme,
            textColor: input.textColor,
            backgroundColor: input.backgroundColor,
            fontSize: input.fontSize,
            lineHeightMultiple: input.lineHeightMultiple,
            lineSpacing: input.lineSpacing,
            paragraphSpacing: input.paragraphSpacing,
            letterSpacing: input.letterSpacing,
            marginH: input.marginH,
            marginV: marginV,
            footerHeight: footerHeight,
            contentInsets: contentInsets,
            writingMode: input.writingMode,
            fontPostScriptName: input.fontPostScriptName,
            isBold: input.isBold,
            chapterTitleStyle: input.chapterTitleStyle,
            readerBackgroundImageURL: input.readerBackgroundImageURL,
            regexHighlightConfiguration: input.regexHighlightConfiguration,
            readerStyleAppearance: input.readerStyleAppearance,
            readerStyleAssetRevision: input.readerStyleAssetRevision
        )
    }
}
