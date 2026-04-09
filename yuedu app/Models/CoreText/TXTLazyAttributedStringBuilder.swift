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

        let titleFont = UIFont.systemFont(ofSize: settings.fontSize + 8, weight: .bold)
        let bodyFont = UIFont.systemFont(ofSize: settings.fontSize)
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
        bodyParaStyle.alignment = .justified
        bodyParaStyle.minimumLineHeight = bodyTargetLineHeight
        bodyParaStyle.maximumLineHeight = bodyTargetLineHeight
        bodyParaStyle.paragraphSpacing = settings.paragraphSpacing

        let attrStr = NSMutableAttributedString()
        attrStr.append(
            NSAttributedString(
                string: chapterTitle + "\n",
                attributes: [
                    .font: titleFont,
                    .foregroundColor: themeTextColor,
                    .paragraphStyle: titleParaStyle,
                    .kern: settings.letterSpacing as NSNumber,
                ]
            )
        )

        for para in paragraphs {
            let indentedPara = "\u{3000}\u{3000}" + para.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            attrStr.append(
                NSAttributedString(
                    string: indentedPara,
                    attributes: [
                        .font: bodyFont,
                        .foregroundColor: themeTextColor,
                        .baselineOffset: bodyBaselineOffset,
                        .paragraphStyle: bodyParaStyle,
                        .kern: settings.letterSpacing as NSNumber,
                    ]
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
