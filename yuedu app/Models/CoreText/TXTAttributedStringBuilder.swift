import Foundation
import UIKit

struct TXTAttributedStringBuilder: AttributedStringBuilding {
    private let chapters: [UnifiedChapter]

    init(chapters: [UnifiedChapter]) {
        self.chapters = chapters
    }

    var chapterCount: Int { chapters.count }

    func chapterTitle(at index: Int) -> String {
        guard chapters.indices.contains(index) else { return "" }
        return chapters[index].title
    }

    func chapterSourceHref(at index: Int) -> String? {
        guard chapters.indices.contains(index) else { return nil }
        return chapters[index].sourceHref
    }

    func chapterDataSize(at index: Int) async -> Int {
        guard chapters.indices.contains(index) else { return 0 }
        return chapters[index].plainText.lengthOfBytes(using: .utf8)
    }

    func chapterIndex(for href: String) -> Int? {
        if let numericIndex = Int(href), chapters.indices.contains(numericIndex) {
            return numericIndex
        }

        let target = normalizedURLKey(href)
        guard !target.isEmpty else { return nil }
        return chapters.firstIndex { chapter in
            normalizedURLKey(chapter.sourceHref) == target
        }
    }

    func buildChapter(
        at index: Int,
        settings: ReaderRenderSettings,
        themeTextColor: UIColor,
        themeBackgroundColor: UIColor
    ) async throws -> AttributedChapterBuildResult {
        guard chapters.indices.contains(index) else {
            throw AttributedStringBuildingError.chapterOutOfRange(index)
        }

        let chapter = chapters[index]
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
                string: chapter.title + "\n",
                attributes: [
                    .font: titleFont,
                    .foregroundColor: themeTextColor,
                    .paragraphStyle: titleParaStyle,
                    .kern: settings.letterSpacing as NSNumber,
                ]
            )
        )

        for para in chapter.paragraphs {
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

    private func normalizedURLKey(_ raw: String?) -> String {
        guard let raw, var components = URLComponents(string: raw) else { return "" }
        components.fragment = nil
        components.queryItems = components.queryItems?.sorted { $0.name < $1.name }
        return (components.string ?? raw).lowercased()
    }
}
