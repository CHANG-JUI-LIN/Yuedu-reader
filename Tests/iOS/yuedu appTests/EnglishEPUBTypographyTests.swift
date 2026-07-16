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

    @Test @MainActor func elementLanguageOverridesPackageWithoutChangingTextRanges() async throws {
        let attributed = try await Self.render(EPUBTestFixtures.englishLanguagePrecedence())

        #expect(Self.language(in: attributed, near: "colour") == "en-GB")
        #expect(Self.language(in: attributed, near: "français") == "fr")
        #expect(Self.language(in: attributed, near: "fallback language") == "en-GB")
        #expect(Self.sourceTag(in: attributed, near: "colour") == "p")
        #expect(Self.sourceTag(in: attributed, near: "français") == "span")
        #expect(Self.sourceTag(in: attributed, near: "sample code") == "code")

        let string = attributed.string as NSString
        let colour = string.range(of: "colour")
        let french = string.range(of: "français")
        let fallback = string.range(of: "fallback language")
        #expect(colour.location != NSNotFound)
        #expect(french.location > colour.location)
        #expect(fallback.location > french.location)
    }

    @Test @MainActor func packageLanguageProvidesDocumentFallback() async throws {
        let attributed = try await Self.render(EPUBTestFixtures.englishPackageLanguageOnly())
        #expect(Self.language(in: attributed, near: "package language") == "en-US")
        #expect(Self.sourceTag(in: attributed, near: "package language") == "p")
    }

    @MainActor
    private static func render(_ sample: EPUBTestFixtures.Sample) async throws -> NSAttributedString {
        let epubURL = try await EPUBTestFixtures.makeArchive(entries: sample.entries)
        let session = try await PublicationSession.open(sourceURL: epubURL)
        return try await EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 320, height: 640)
        ).buildChapter(
            at: 0,
            settings: EPUBTestFixtures.renderSettings(),
            themeTextColor: .black,
            themeBackgroundColor: .white
        ).attributedString
    }

    private static func language(in attributed: NSAttributedString, near text: String) -> String? {
        attribute(EPUBLanguageTypography.languageAttribute, in: attributed, near: text) as? String
    }

    private static func sourceTag(in attributed: NSAttributedString, near text: String) -> String? {
        attribute(EPUBLanguageTypography.sourceElementTagAttribute, in: attributed, near: text) as? String
    }

    private static func attribute(
        _ key: NSAttributedString.Key,
        in attributed: NSAttributedString,
        near text: String
    ) -> Any? {
        let range = (attributed.string as NSString).range(of: text)
        guard range.location != NSNotFound else { return nil }
        return attributed.attribute(key, at: range.location, effectiveRange: nil)
    }
}
