import Foundation
import UIKit
import YueduCoreTextTypography

struct TXTLazyAttributedStringBuilder: AttributedStringBuilding {
    private let text: String?
    private let chapterIndexes: [TXTChapterIndex]
    private let mappedTextFile: TXTMappedTextFile?
    private let mappedChapterIndexes: [TXTMappedChapterIndex]
    private let parsesAozoraMarkup: Bool

    init(text: String, chapterIndexes: [TXTChapterIndex], parsesAozoraMarkup: Bool = true) {
        self.text = text
        self.parsesAozoraMarkup = parsesAozoraMarkup
        self.chapterIndexes = chapterIndexes
        self.mappedTextFile = nil
        self.mappedChapterIndexes = []
    }

    init(mappedTextFile: TXTMappedTextFile, chapterIndexes: [TXTMappedChapterIndex], parsesAozoraMarkup: Bool = true) {
        self.text = nil
        self.parsesAozoraMarkup = parsesAozoraMarkup
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
        guard let chapterText = chapterText(at: index, conversion: settings.textConversion) else {
            throw AttributedStringBuildingError.chapterOutOfRange(index)
        }

        let chapterTitle = chapterTitle(at: index)
        let paragraphs = TXTChapterParser.paragraphsForChapterContent(chapterText)

        let bodyFont = UserReaderFontResolver.bodyFont(size: settings.fontSize, isBold: settings.isBold)
        let syntheticBoldAttributes = UserReaderFontResolver.syntheticBoldAttributes(
            for: bodyFont,
            isBoldRequested: UserReaderFontResolver.bodyBoldRequested(isBold: settings.isBold)
        )
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

        let body = paragraphs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }.joined()
        // Historical v5/v6 builders retain source markup only for proven location
        // migration. Every active reader uses the same Aozora parser and ruby path.
        let nodes = parsesAozoraMarkup ? AozoraMarkupParser.parse(body).nodes : [.text(body)]
        let renderer = NodeAttributedStringRenderer(config: .init(from: settings, textColor: themeTextColor))
        let renderedBody = await renderer.renderInlineContent(nodes) { paragraphText in
            ReaderHyphenation.tagging(
                [
                    .font: bodyFont,
                    .foregroundColor: themeTextColor,
                    .baselineOffset: bodyBaselineOffset,
                    .paragraphStyle: bodyParaStyle,
                    .kern: settings.letterSpacing as NSNumber,
                ].merging(syntheticBoldAttributes) { _, new in new },
                forText: paragraphText
            )
        }
        attrStr.append(renderedBody)

        if settings.regexHighlightConfiguration.isEnabled {
            await ReaderStyleAssetStore.shared.prewarmRegexHighlightAssets(
                configuration: settings.regexHighlightConfiguration,
                appearance: settings.readerStyleAppearance
            )
            do {
                let result = try RegexHighlightEngine.apply(
                    configuration: settings.regexHighlightConfiguration,
                    appearance: settings.readerStyleAppearance,
                    assetRevision: settings.readerStyleAssetRevision,
                    to: attrStr
                )
                for diagnostic in result.diagnostics {
                    AppLogger.render(
                        "regex highlight diagnostic in TXT renderer",
                        context: ["diagnostic": String(describing: diagnostic)]
                    )
                }
            } catch {
                AppLogger.render(
                    "regex highlight apply failed in TXT renderer",
                    context: ["error": String(describing: error)]
                )
            }
        }

        if settings.dialogueBubbleStyle.isEnabled {
            await ReaderStyleAssetStore.shared.prewarmDialogueBubbleAssets(
                style: settings.dialogueBubbleStyle
            )
            // Same width the chapter title above is composed against.
            await ReaderDialogueBubbleMarker.apply(
                style: settings.dialogueBubbleStyle,
                columnWidth: max(
                    1,
                    UIScreen.main.bounds.width
                        - settings.contentInsets.left
                        - settings.contentInsets.right
                ),
                bodyFontSize: settings.fontSize,
                writingMode: settings.writingMode,
                to: attrStr
            )
        }

        return AttributedChapterBuildResult(
            attributedString: attrStr,
            imagePage: nil,
            pageBackgroundImage: nil,
            anchorOffsets: [:]
        )
    }

    func localChapterText(at index: Int) async -> AILocalChapterText {
        .extracted(await chapterPlainText(at: index))
    }

    func chapterPlainText(at index: Int) async -> String? {
        guard let text = chapterText(at: index), !text.isEmpty else { return nil }
        return parsesAozoraMarkup ? AozoraMarkupParser.parse(text).plainText : text
    }

    private func chapterText(at index: Int, conversion: TextConversion = .original) -> String? {
        let rawText: String?
        if mappedChapterIndexes.indices.contains(index), let mappedTextFile {
            rawText = TXTChapterParser.chapterText(mappedTextFile, byteRange: mappedChapterIndexes[index].byteRange)
        } else if chapterIndexes.indices.contains(index), let text {
            rawText = TXTChapterParser.chapterText(text, range: chapterIndexes[index].contentRange)
        } else {
            rawText = nil
        }

        guard var result = rawText else { return nil }

        // 繁簡轉換 runs before replace rules, as in legado's ContentProcessor: a rule made from
        // a selection holds the characters the reader saw, which are the converted ones.
        result = result.converted(to: conversion)

        let globalRules = ReplaceRuleStore.shared.rules(for: "")
        if !globalRules.isEmpty {
            result = ReplaceRuleEngine.apply(globalRules, to: result)
        }

        return result
    }
}
