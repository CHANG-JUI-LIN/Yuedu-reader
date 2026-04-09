import Foundation
import UIKit

struct TXTLazyAttributedStringBuilder: AttributedStringBuilding {
    private let text: String
    private let chapterIndexes: [TXTChapterIndex]

    init(text: String, chapterIndexes: [TXTChapterIndex]) {
        self.text = text
        self.chapterIndexes = chapterIndexes
    }

    var chapterCount: Int { chapterIndexes.count }

    func chapterTitle(at index: Int) -> String {
        guard chapterIndexes.indices.contains(index) else { return "" }
        return chapterIndexes[index].title
    }

    func chapterSourceHref(at index: Int) -> String? {
        guard chapterIndexes.indices.contains(index) else { return nil }
        return chapterIndexes[index].sourceHref
    }

    func chapterDataSize(at index: Int) async -> Int {
        guard chapterIndexes.indices.contains(index) else { return 0 }
        let content = TXTChapterParser.chapterText(text, range: chapterIndexes[index].contentRange)
        return content.lengthOfBytes(using: .utf8)
    }

    func chapterIndex(for href: String) -> Int? {
        if let numericIndex = Int(href), chapterIndexes.indices.contains(numericIndex) {
            return numericIndex
        }
        let normalized = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsed = Int(normalized), chapterIndexes.indices.contains(parsed) {
            return parsed
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
        guard chapterIndexes.indices.contains(index) else {
            throw AttributedStringBuildingError.chapterOutOfRange(index)
        }

        let chapter = chapterIndexes[index]
        let chapterText = TXTChapterParser.chapterText(text, range: chapter.contentRange)
        let paragraphs = TXTChapterParser.paragraphsForChapterContent(chapterText)

        let titleFont = UIFont.systemFont(ofSize: settings.fontSize + 8, weight: .bold)
        let bodyFont = UIFont.systemFont(ofSize: settings.fontSize)

        let titleParaStyle = NSMutableParagraphStyle()
        titleParaStyle.alignment = .center
        titleParaStyle.paragraphSpacing = 24

        let bodyParaStyle = NSMutableParagraphStyle()
        bodyParaStyle.lineSpacing = settings.lineSpacing
        bodyParaStyle.paragraphSpacing = settings.paragraphSpacing

        let attrStr = NSMutableAttributedString()
        attrStr.append(
            NSAttributedString(
                string: chapter.title + "\n",
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
}
