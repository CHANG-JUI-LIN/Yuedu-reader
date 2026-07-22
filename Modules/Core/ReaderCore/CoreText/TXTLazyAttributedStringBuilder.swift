import Foundation
import UIKit

struct TXTLazyAttributedStringBuilder: AttributedStringBuilding {
    private let text: String?
    private let chapterIndexes: [TXTChapterIndex]
    private let mappedTextFile: TXTMappedTextFile?
    private let mappedChapterIndexes: [TXTMappedChapterIndex]

    init(text: String, chapterIndexes: [TXTChapterIndex]) {
        self.text = text
        self.chapterIndexes = chapterIndexes
        self.mappedTextFile = nil
        self.mappedChapterIndexes = []
    }

    init(mappedTextFile: TXTMappedTextFile, chapterIndexes: [TXTMappedChapterIndex]) {
        self.text = nil
        self.chapterIndexes = []
        self.mappedTextFile = mappedTextFile
        self.mappedChapterIndexes = chapterIndexes
    }

    var chapterCount: Int {
        if !mappedChapterIndexes.isEmpty {
            return mappedChapterIndexes.count
        }
        return chapterIndexes.count
    }

    func chapterTitle(at index: Int) -> String {
        if mappedChapterIndexes.indices.contains(index) {
            return mappedChapterIndexes[index].title
        }
        guard chapterIndexes.indices.contains(index) else { return "" }
        return chapterIndexes[index].title
    }

    func chapterSourceHref(at index: Int) -> String? {
        if mappedChapterIndexes.indices.contains(index) {
            return mappedChapterIndexes[index].sourceHref
        }
        guard chapterIndexes.indices.contains(index) else { return nil }
        return chapterIndexes[index].sourceHref
    }

    func chapterDataSize(at index: Int) async -> Int {
        if mappedChapterIndexes.indices.contains(index) {
            return mappedChapterIndexes[index].byteRange.count
        }
        guard let chapterText = chapterText(at: index) else { return 0 }
        return chapterText.lengthOfBytes(using: .utf8)
    }

    func chapterIndex(for href: String) -> Int? {
        if let numericIndex = Int(href), numericIndex >= 0, numericIndex < chapterCount {
            return numericIndex
        }
        let normalized = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Int(normalized), parsed >= 0, parsed < chapterCount {
            return parsed
        }
        if !mappedChapterIndexes.isEmpty {
            return mappedChapterIndexes.firstIndex { $0.sourceHref == normalized }
        }
        return chapterIndexes.firstIndex { $0.sourceHref == normalized }
    }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        _ = themeBackgroundColor
        guard let chapterText = chapterText(at: index) else {
            throw AttributedStringBuildingError.chapterOutOfRange(index)
        }

        let chapterTitle = chapterTitle(at: index)
        let paragraphs = TXTChapterParser.paragraphsForChapterContent(chapterText)

        let bodyFont = UserReaderFontResolver.bodyFont(size: settings.fontSize, isBold: settings.isBold)
        let bodyTargetLineHeight = ReaderTypographyCorrection.targetLineHeight(
            font: bodyFont,
            fontSize: settings.fontSize,
            lineHeightMultiple: settings.lineHeightMultiple
        )
        let bodyBaselineOffset = ReaderTypographyCorrection.baselineOffset(
            font: bodyFont,
            targetLineHeight: bodyTargetLineHeight
        )

        let bodyParaStyle = NSMutableParagraphStyle()
        bodyParaStyle.alignment = .justified // full justification: both margins align, CJK + Latin alike
        bodyParaStyle.hyphenationFactor = ReaderHyphenation.factor // break long Latin words instead of gapping the line
        bodyParaStyle.lineBreakMode = .byWordWrapping
        bodyParaStyle.minimumLineHeight = bodyTargetLineHeight
        bodyParaStyle.maximumLineHeight = bodyTargetLineHeight
        bodyParaStyle.paragraphSpacing = settings.paragraphSpacing
        bodyParaStyle.firstLineHeadIndent = settings.fontSize * 2

        let attrStr = NSMutableAttributedString()
        await ChapterTitleAttributedBuilder.append(
            title: chapterTitle,
            style: settings.chapterTitleStyle,
            settings: settings,
            renderWidth: max(1, UIScreen.main.bounds.width - settings.contentInsets.left - settings.contentInsets.right),
            themeTextColor: themeTextColor,
            themeBackgroundColor: themeBackgroundColor,
            letterSpacing: settings.letterSpacing,
            to: attrStr
        )

        for para in paragraphs {
            let paragraphText = para.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            attrStr.append(
                NSAttributedString(
                    string: paragraphText,
                    attributes: ReaderHyphenation.tagging(
                        [
                            .font: bodyFont,
                            .foregroundColor: themeTextColor,
                            .baselineOffset: bodyBaselineOffset,
                            .paragraphStyle: bodyParaStyle,
                            .kern: settings.letterSpacing as NSNumber,
                        ],
                        forText: para
                    )
                )
            )
        }

        return AttributedChapterBuildResult(
            attributedString: attrStr,
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }

    private func chapterText(at index: Int) -> String? {
        if mappedChapterIndexes.indices.contains(index), let mappedTextFile {
            return TXTChapterParser.chapterText(mappedTextFile, byteRange: mappedChapterIndexes[index].byteRange)
        }

        guard chapterIndexes.indices.contains(index), let text else { return nil }
        return TXTChapterParser.chapterText(text, range: chapterIndexes[index].contentRange)
    }
}
