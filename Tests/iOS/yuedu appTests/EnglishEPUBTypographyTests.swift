import CoreText
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

    @Test @MainActor func cssHyphenationAliasesCascadeIntoNativeParagraphPolicy() async {
        var config = EPUBTestFixtures.htmlConfig(renderWidth: 320)
        config.documentLanguage = "en-US"
        let html = EPUBTestFixtures.xhtml(
            title: "Hyphenation cascade",
            body: """
            <p id="standard">standard alias winner ordinary typography words</p>
            <p id="epub">epub alias winner ordinary typography words</p>
            <p id="webkit">webkit alias winner ordinary typography words</p>
            <p id="none">none policy ordinary typography words</p>
            <p id="manual">manual policy ordinary typography words</p>
            <p id="default-justify">default justified ordinary typography words</p>
            <p id="default-left">default left ordinary typography words</p>
            <p id="important" style="hyphens:auto">important winner ordinary typography words</p>
            <p id="inherit" style="hyphens:auto">parent auto <span style="hyphens:inherit">inherited policy words</span></p>
            <p id="unsupported" lang="zh-Hant">unsupported auto ordinary typography words</p>
            """,
            head: """
            <style>
              p { text-align: justify; }
              #standard { -webkit-hyphens:none; -epub-hyphens:manual; hyphens:auto; }
              #epub { -webkit-hyphens:none; -epub-hyphens:auto; }
              #webkit { -webkit-hyphens:auto; }
              #none { hyphens:none; }
              #manual { hyphens:manual; }
              #default-left { text-align:left; }
              #important { hyphens:none !important; }
              #unsupported { hyphens:auto; }
            </style>
            """,
            bodyAttributes: #"lang="en-US""#
        )
        let attributed = await EPUBTestFixtures.renderIR(html: html, config: config)

        #expect(Self.hyphenationPolicy(in: attributed, near: "standard alias") == .auto)
        #expect(Self.hyphenationPolicy(in: attributed, near: "epub alias") == .auto)
        #expect(Self.hyphenationPolicy(in: attributed, near: "webkit alias") == .auto)
        #expect(Self.hyphenationPolicy(in: attributed, near: "none policy") == .some(.none))
        #expect(Self.hyphenationPolicy(in: attributed, near: "manual policy") == .manual)
        #expect(Self.hyphenationPolicy(in: attributed, near: "default justified") == .unspecified)
        #expect(Self.hyphenationPolicy(in: attributed, near: "default left") == .unspecified)
        #expect(Self.hyphenationPolicy(in: attributed, near: "important winner") == .some(.none))
        #expect(Self.hyphenationPolicy(in: attributed, near: "inherited policy") == .auto)
        #expect(Self.hyphenationPolicy(in: attributed, near: "unsupported auto") == .auto)

        #expect(Self.hyphenationFactor(in: attributed, near: "standard alias") == 1)
        #expect(Self.hyphenationFactor(in: attributed, near: "epub alias") == 1)
        #expect(Self.hyphenationFactor(in: attributed, near: "webkit alias") == 1)
        #expect(Self.hyphenationFactor(in: attributed, near: "none policy") == 0)
        #expect(Self.hyphenationFactor(in: attributed, near: "manual policy") == 0)
        #expect(Self.hyphenationFactor(in: attributed, near: "default justified") == 1)
        #expect(Self.hyphenationFactor(in: attributed, near: "default left") == 0)
        #expect(Self.hyphenationFactor(in: attributed, near: "important winner") == 0)
        #expect(Self.hyphenationFactor(in: attributed, near: "unsupported auto") == 0)
    }

    @Test func noneSuppressesSoftHyphenBreakWithoutChangingSourceOffsets() throws {
        let authored = "extra\u{00AD}ordinary marker"
        let manual = Self.softHyphenProbe(policy: .manual, language: "en-US")
        let none = Self.softHyphenProbe(policy: .none, language: "en-US")
        let manualPrepared = CoreTextPaginator.preparedAttributedString(
            manual,
            writingMode: .horizontal,
            fontSize: 17,
            maxInlineAnnotationAdvance: nil
        )
        let nonePrepared = CoreTextPaginator.preparedAttributedString(
            none,
            writingMode: .horizontal,
            fontSize: 17,
            maxInlineAnnotationAdvance: nil
        )
        let authoredString = authored as NSString
        let softHyphenLocation = authoredString.range(of: "\u{00AD}").location
        let markerLocation = authoredString.range(of: "marker").location

        #expect(manualPrepared.string == authored)
        #expect(nonePrepared.length == authoredString.length)
        #expect((nonePrepared.string as NSString).range(of: "marker").location == markerLocation)
        #expect((nonePrepared.string as NSString).character(at: softHyphenLocation) == 0x2060)
        #expect(
            nonePrepared.attribute(
                EPUBLanguageTypography.originalSoftHyphenAttribute,
                at: softHyphenLocation,
                effectiveRange: nil
            ) as? Bool == true
        )
        #expect(
            EPUBLanguageTypography.sourceText(
                in: nonePrepared,
                range: NSRange(location: 0, length: nonePrepared.length)
            ) == authored
        )

        let softHyphenLineEnd = softHyphenLocation + 1
        #expect(Self.lineEndOffsets(in: manualPrepared, width: 48).contains(softHyphenLineEnd))
        #expect(!Self.lineEndOffsets(in: nonePrepared, width: 48).contains(softHyphenLineEnd))

        let selection = TextSelectionManager()
        selection.setSelection(
            range: NSRange(location: 0, length: nonePrepared.length),
            maxLength: nonePrepared.length
        )
        #expect(selection.selectedText(in: nonePrepared) == authored)
    }

    @Test @MainActor func hyphenationPolicyAndLanguageInvalidatePaginatorCache() async throws {
        let paginator = CoreTextPaginator()
        let manual = Self.softHyphenProbe(policy: .manual, language: "en-US")
        let none = Self.softHyphenProbe(policy: .none, language: "en-US")
        _ = await paginator.paginate(
            spineIndex: 31,
            attrStr: manual,
            renderSize: CGSize(width: 96, height: 320),
            fontSize: 17
        )
        let noneLayout = await paginator.paginate(
            spineIndex: 31,
            attrStr: none,
            renderSize: CGSize(width: 96, height: 320),
            fontSize: 17
        )
        let softHyphenLocation = (none.string as NSString).range(of: "\u{00AD}").location
        #expect((noneLayout.attributedString.string as NSString).character(at: softHyphenLocation) == 0x2060)

        let languagePaginator = CoreTextPaginator()
        let english = Self.softHyphenProbe(policy: .auto, language: "en-US")
        let unsupported = Self.softHyphenProbe(policy: .auto, language: "zh-Hant")
        _ = await languagePaginator.paginate(
            spineIndex: 32,
            attrStr: english,
            renderSize: CGSize(width: 96, height: 320),
            fontSize: 17
        )
        let unsupportedLayout = await languagePaginator.paginate(
            spineIndex: 32,
            attrStr: unsupported,
            renderSize: CGSize(width: 96, height: 320),
            fontSize: 17
        )
        #expect(
            unsupportedLayout.attributedString.attribute(
                EPUBLanguageTypography.languageAttribute,
                at: 0,
                effectiveRange: nil
            ) as? String == "zh-Hant"
        )
        let paragraph = try #require(
            unsupportedLayout.attributedString.attribute(
                .paragraphStyle,
                at: 0,
                effectiveRange: nil
            ) as? NSParagraphStyle
        )
        #expect(paragraph.hyphenationFactor == 0)
    }

    @Test func guardedEnglishLinesJustifyToTheParagraphEdge() throws {
        for availableWidth: CGFloat in [280, 320, 390] {
            let attributed = try #require(Self.eligibleEnglishLine(for: availableWidth))
            let natural = CTLineCreateWithAttributedString(attributed)
            let resolved = CoreTextHorizontalLineDrawer.resolveJustifiedLine(
                line: natural,
                lineStart: 0,
                lineRange: CFRange(location: 0, length: attributed.length),
                isJustified: true,
                isParagraphLastLine: false,
                availableWidth: availableWidth,
                attrStr: attributed,
                nsString: attributed.string as NSString
            )
            #expect(abs(Self.lineWidth(resolved) - availableWidth) <= 1)

            let finalLine = CoreTextHorizontalLineDrawer.resolveJustifiedLine(
                line: natural,
                lineStart: 0,
                lineRange: CFRange(location: 0, length: attributed.length),
                isJustified: true,
                isParagraphLastLine: true,
                availableWidth: availableWidth,
                attrStr: attributed,
                nsString: attributed.string as NSString
            )
            #expect(abs(Self.lineWidth(finalLine) - Self.lineWidth(natural)) <= 0.5)
        }
    }

    @Test func EnglishJustificationKeepsQualityAndSemanticGuards() throws {
        let availableWidth: CGFloat = 390
        let short = Self.justificationLine("Short line words", tag: "p")
        #expect(Self.resolvedWidth(short, availableWidth: availableWidth) == Self.lineWidth(short))

        let eligible = try #require(Self.eligibleEnglishLine(for: availableWidth))
        for tag in ["h1", "pre", "code", "math"] {
            let excluded = NSMutableAttributedString(attributedString: eligible)
            excluded.addAttribute(
                EPUBLanguageTypography.sourceElementTagAttribute,
                value: tag,
                range: NSRange(location: 0, length: excluded.length)
            )
            #expect(
                abs(Self.resolvedWidth(excluded, availableWidth: availableWidth)
                    - Self.lineWidth(excluded)) <= 0.5
            )
        }
    }

    @Test func existingCJKJustificationStillReachesTheParagraphEdge() throws {
        let availableWidth: CGFloat = 320
        let attributed = try #require(Self.eligibleCJKLine(for: availableWidth))
        #expect(abs(Self.resolvedWidth(attributed, availableWidth: availableWidth) - availableWidth) <= 1)
    }

    @Test @MainActor func fullPipelineKeepsEnglishInteractionOffsetsStable() async throws {
        let epubURL = try await EPUBTestFixtures.makeArchive(
            entries: EPUBTestFixtures.englishTypography().entries
        )
        let session = try await PublicationSession.open(sourceURL: epubURL)
        let settings = EPUBTestFixtures.renderSettings()
        let result = try await EPUBAttributedStringBuilder(
            session: session,
            renderSize: CGSize(width: 220, height: 320)
        ).buildChapter(
            at: 0,
            settings: settings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let source = result.attributedString.string as NSString
        let linkRange = try #require(Self.range(of: "linked words", in: source))
        let authoredProbe = "extra\u{00AD}ordinary marker after"
        let probeRange = try #require(Self.range(of: authoredProbe, in: source))
        let softHyphenOffset = probeRange.location + (authoredProbe as NSString).range(of: "\u{00AD}").location
        let markerOffset = try #require(Self.range(of: "marker", in: source)).location
        let targetOffset = try #require(Self.range(of: "Anchor target", in: source)).location

        #expect(Self.language(in: result.attributedString, near: "marker") == "en-US")
        #expect(Self.hyphenationPolicy(in: result.attributedString, near: "marker") == .some(.none))
        #expect(HTMLAttributedStringBuilder.linkHref(
            at: linkRange.location,
            in: result.attributedString
        ) == "#target")
        #expect(result.anchorOffsets["target"] == targetOffset)

        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: result.attributedString,
            anchorOffsets: result.anchorOffsets,
            renderSize: CGSize(width: 220, height: 320),
            fontSize: settings.fontSize
        )
        let paged = layout.attributedString
        #expect(paged.length == result.attributedString.length)
        #expect((paged.string as NSString).character(at: softHyphenOffset) == 0x2060)
        #expect((paged.string as NSString).range(of: "marker").location == markerOffset)
        #expect(HTMLAttributedStringBuilder.linkHref(at: linkRange.location, in: paged) == "#target")
        #expect(layout.anchorOffsets["target"] == targetOffset)
        #expect(Self.language(in: paged, near: "marker") == "en-US")
        #expect(Self.hyphenationPolicy(in: paged, near: "marker") == .some(.none))

        let selection = TextSelectionManager()
        selection.setSelection(range: probeRange, maxLength: paged.length)
        #expect(selection.selectedText(in: paged) == authoredProbe)
        #expect(EPUBLanguageTypography.sourceText(in: paged, range: probeRange) == authoredProbe)
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

    private static func hyphenationPolicy(
        in attributed: NSAttributedString,
        near text: String
    ) -> EPUBHyphenationPolicy? {
        guard let raw = attribute(
            EPUBLanguageTypography.hyphenationPolicyAttribute,
            in: attributed,
            near: text
        ) as? String else { return nil }
        return EPUBHyphenationPolicy(rawValue: raw)
    }

    private static func hyphenationFactor(in attributed: NSAttributedString, near text: String) -> Float? {
        (attribute(.paragraphStyle, in: attributed, near: text) as? NSParagraphStyle)?.hyphenationFactor
    }

    private static func softHyphenProbe(
        policy: EPUBHyphenationPolicy,
        language: String
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.hyphenationFactor = policy == .auto && language.hasPrefix("en") ? 1 : 0
        return NSAttributedString(
            string: "extra\u{00AD}ordinary marker",
            attributes: [
                .font: UIFont.systemFont(ofSize: 17),
                .paragraphStyle: paragraph,
                EPUBLanguageTypography.languageAttribute: language,
                EPUBLanguageTypography.hyphenationPolicyAttribute: policy.rawValue,
            ]
        )
    }

    private static func lineEndOffsets(in attributed: NSAttributedString, width: CGFloat) -> [Int] {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 500), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        return (CTFrameGetLines(frame) as! [CTLine]).map {
            let range = CTLineGetStringRange($0)
            return range.location + range.length
        }
    }

    private static func eligibleEnglishLine(for availableWidth: CGFloat) -> NSAttributedString? {
        let words = ["a", "to", "in", "we", "go"]
        var text = ""
        for index in 0..<80 {
            text += text.isEmpty ? words[index % words.count] : " " + words[index % words.count]
            let attributed = justificationLine(text, tag: "p")
            let coverage = lineWidth(attributed) / availableWidth
            if coverage >= 0.84, coverage <= 0.97 { return attributed }
            if coverage > 0.97 { return nil }
        }
        return nil
    }

    private static func eligibleCJKLine(for availableWidth: CGFloat) -> NSAttributedString? {
        var text = ""
        for _ in 0..<80 {
            text += "文"
            let attributed = justificationLine(text, tag: "p", language: "zh-Hant")
            let coverage = lineWidth(attributed) / availableWidth
            if coverage > 0.86, coverage <= 0.97 { return attributed }
            if coverage > 0.97 { return nil }
        }
        return nil
    }

    private static func justificationLine(
        _ text: String,
        tag: String,
        language: String = "en-US"
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .justified
        paragraph.baseWritingDirection = .leftToRight
        return NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.systemFont(ofSize: 17),
                .paragraphStyle: paragraph,
                EPUBLanguageTypography.languageAttribute: language,
                EPUBLanguageTypography.sourceElementTagAttribute: tag,
            ]
        )
    }

    private static func resolvedWidth(
        _ attributed: NSAttributedString,
        availableWidth: CGFloat
    ) -> CGFloat {
        let line = CTLineCreateWithAttributedString(attributed)
        let resolved = CoreTextHorizontalLineDrawer.resolveJustifiedLine(
            line: line,
            lineStart: 0,
            lineRange: CFRange(location: 0, length: attributed.length),
            isJustified: true,
            isParagraphLastLine: false,
            availableWidth: availableWidth,
            attrStr: attributed,
            nsString: attributed.string as NSString
        )
        return lineWidth(resolved)
    }

    private static func lineWidth(_ line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
    }

    private static func lineWidth(_ attributed: NSAttributedString) -> CGFloat {
        lineWidth(CTLineCreateWithAttributedString(attributed))
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

    private static func range(of text: String, in string: NSString) -> NSRange? {
        let range = string.range(of: text)
        return range.location == NSNotFound ? nil : range
    }
}
