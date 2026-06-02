import Foundation
import UIKit

/// Wraps `BookContentProvider` (online book source) as `AttributedStringBuilding`,
/// allowing `CoreTextScrollEngine` to directly consume online chapters.
///
/// Content handling:
///   - If `payload.renderHTML` is non-nil → use `HTMLAttributedStringBuilder` (preserves styling)
///   - Otherwise → fall back to TXT pattern (title + paragraphs + indent)
@MainActor
final class OnlineProviderAttributedStringBuilder: @preconcurrency AttributedStringBuilding {

    private let provider: any BookContentProvider
    private var renderSize: CGSize

    init(provider: any BookContentProvider, renderSize: CGSize) {
        self.provider = provider
        self.renderSize = renderSize
    }

    func updateRenderSize(_ size: CGSize) {
        renderSize = size
    }

    var chapterCount: Int { provider.totalChapters }

    var prefersLazyByteScan: Bool { false }

    func chapterTitle(at index: Int) -> String {
        provider.chapterTitle(at: index)
    }

    func chapterSourceHref(at index: Int) -> String? {
        // No reliable source; not exposed externally.
        nil
    }

    func chapterIndex(for href: String) -> Int? {
        if let n = Int(href), n >= 0, n < chapterCount { return n }
        return nil
    }

    func chapterDataSize(at index: Int) async -> Int { 0 }

    func cssResourceHrefs() -> [String] { [] }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        let payload = try await provider.contentForChapter(index: index)

        // HTML pipeline
        if let rawHTML = payload.renderHTML, !rawHTML.isEmpty {
            // Rewrite Legado iOS paragraph-review markers (<comment …>) into anchors the
            // renderer can carry. Idempotent + covers chapters cached before this feature.
            let html = ReaderHTMLUtilities.rewriteReviewComments(rawHTML)
            let cfg = HTMLAttributedStringBuilder.Config(
                fontSize: settings.fontSize,
                lineHeightMultiple: settings.lineHeightMultiple,
                lineSpacing: settings.lineSpacing,
                paragraphSpacing: settings.paragraphSpacing,
                firstLineIndent: 0,
                textColor: themeTextColor,
                backgroundColor: themeBackgroundColor,
                fontFamilyName: UserReaderFontResolver.selectedPostScriptName,
                renderWidth: max(0, renderSize.width),
                writingMode: settings.writingMode
            )
            let builder = HTMLAttributedStringBuilder()
            let result = await builder.build(html: html, config: cfg)
            return AttributedChapterBuildResult(
                attributedString: result.attributedString,
                imagePage: result.imagePage,
                pageBackgroundImage: result.pageBackgroundImage,
                anchorOffsets: result.anchorOffsets
            )
        }

        // TXT-style fallback: title + paragraphs
        let titleFont = UserReaderFontResolver.titleFont(size: settings.fontSize + 8)
        let bodyFont = UserReaderFontResolver.bodyFont(size: settings.fontSize)
        let bodyTargetLineHeight = ReaderTypographyCorrection.targetLineHeight(
            font: bodyFont,
            fontSize: settings.fontSize,
            lineHeightMultiple: settings.lineHeightMultiple
        )
        let bodyBaselineOffset = ReaderTypographyCorrection.baselineOffset(
            font: bodyFont,
            targetLineHeight: bodyTargetLineHeight
        )

        let titleParaStyle = NSMutableParagraphStyle()
        titleParaStyle.alignment = .center
        titleParaStyle.paragraphSpacing = 24

        let bodyParaStyle = NSMutableParagraphStyle()
        bodyParaStyle.alignment = .natural
        bodyParaStyle.lineBreakMode = .byWordWrapping
        bodyParaStyle.minimumLineHeight = bodyTargetLineHeight
        bodyParaStyle.maximumLineHeight = bodyTargetLineHeight
        bodyParaStyle.paragraphSpacing = settings.paragraphSpacing

        let attr = NSMutableAttributedString()
        attr.append(NSAttributedString(
            string: payload.title + "\n",
            attributes: [
                .font: titleFont,
                .foregroundColor: themeTextColor,
                .paragraphStyle: titleParaStyle,
                .kern: settings.letterSpacing as NSNumber
            ]
        ))

        let paragraphs = ReaderHTMLUtilities.bodyParagraphs(
            fromPlainText: payload.content,
            excludingLeadingTitle: payload.title
        )

        for para in paragraphs {
            let line = "\u{3000}\u{3000}" + para + "\n"
            attr.append(NSAttributedString(
                string: line,
                attributes: [
                    .font: bodyFont,
                    .foregroundColor: themeTextColor,
                    .baselineOffset: bodyBaselineOffset,
                    .paragraphStyle: bodyParaStyle,
                    .kern: settings.letterSpacing as NSNumber
                ]
            ))
        }

        return AttributedChapterBuildResult(
            attributedString: attr,
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }
}
