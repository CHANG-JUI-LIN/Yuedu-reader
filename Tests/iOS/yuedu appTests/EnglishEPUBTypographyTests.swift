import Testing
import UIKit
@testable import yuedu_app

@Suite("English EPUB typography", .serialized)
struct EnglishEPUBTypographyTests {
    @Test func normalizesDeclaredLanguage() {
        #expect(EPUBLanguageTypography.normalizedLanguage(" en_US ") == "en-US")
        #expect(EPUBLanguageTypography.normalizedLanguage("zh-Hant-TW") == "zh-hant-TW")
        #expect(EPUBLanguageTypography.normalizedLanguage("!!!") == nil)
        #expect(EPUBLanguageTypography.normalizedLanguage("en--US") == nil)
        #expect(EPUBLanguageTypography.primaryLanguage("EN-gb") == "en")
    }

    @Test func automaticHyphenationUsesSupportedDeclaredLanguagesOnly() {
        #expect(EPUBLanguageTypography.supportsAutomaticHyphenation("en-US"))
        #expect(EPUBLanguageTypography.supportsAutomaticHyphenation("fr"))
        #expect(!EPUBLanguageTypography.supportsAutomaticHyphenation("zh-Hant"))
        #expect(!EPUBLanguageTypography.supportsAutomaticHyphenation("!!!"))
        #expect(!EPUBLanguageTypography.supportsAutomaticHyphenation(nil))
    }

    @Test func parsesCSSHyphenationKeywords() {
        #expect(EPUBHyphenationPolicy(cssKeyword: " none ") == .some(.none))
        #expect(EPUBHyphenationPolicy(cssKeyword: "MANUAL") == .some(.manual))
        #expect(EPUBHyphenationPolicy(cssKeyword: "auto") == .some(.auto))
        #expect(EPUBHyphenationPolicy(cssKeyword: "initial") == .some(.unspecified))
        #expect(EPUBHyphenationPolicy(cssKeyword: "inherit") == nil)
        #expect(EPUBHyphenationPolicy(cssKeyword: "sometimes") == nil)
    }

    @Test func latinJustificationRequiresAllQualityGuards() {
        let eligible = EnglishLineJustificationInput(
            text: "Several ordinary English words fill this line",
            coverage: 0.84,
            isParagraphLastLine: false,
            alignment: .justified,
            baseWritingDirection: .leftToRight,
            sourceElementTag: "p",
            language: "en-US"
        )
        #expect(EnglishLineJustificationPolicy.shouldJustify(eligible))

        var lowCoverage = eligible
        lowCoverage.coverage = 0.81
        var finalLine = eligible
        finalLine.isParagraphLastLine = true
        var leftAligned = eligible
        leftAligned.alignment = .left
        var rtl = eligible
        rtl.baseWritingDirection = .rightToLeft
        var oneSpace = eligible
        oneSpace.text = "Only one"
        var cjkDominant = eligible
        cjkDominant.text = "中文排版內容應該保持既有規則而不是改用 English"
        var unsupportedLanguage = eligible
        unsupportedLanguage.language = "zh-Hant"

        #expect(!EnglishLineJustificationPolicy.shouldJustify(lowCoverage))
        #expect(!EnglishLineJustificationPolicy.shouldJustify(finalLine))
        #expect(!EnglishLineJustificationPolicy.shouldJustify(leftAligned))
        #expect(!EnglishLineJustificationPolicy.shouldJustify(rtl))
        #expect(!EnglishLineJustificationPolicy.shouldJustify(oneSpace))
        #expect(!EnglishLineJustificationPolicy.shouldJustify(cjkDominant))
        #expect(!EnglishLineJustificationPolicy.shouldJustify(unsupportedLanguage))
    }

    @Test func latinJustificationExcludesSemanticBlocksAndFallbacks() {
        let base = EnglishLineJustificationInput(
            text: "Several ordinary English words fill this line",
            coverage: 0.9,
            isParagraphLastLine: false,
            alignment: .justified,
            baseWritingDirection: .natural,
            sourceElementTag: "p",
            language: "en"
        )

        for tag in ["h1", "h6", "pre", "code", "math", "reader-fallback"] {
            var input = base
            input.sourceElementTag = tag
            #expect(!EnglishLineJustificationPolicy.shouldJustify(input))
        }
        #expect(EnglishLineJustificationPolicy.shouldJustify(base))
    }
}
