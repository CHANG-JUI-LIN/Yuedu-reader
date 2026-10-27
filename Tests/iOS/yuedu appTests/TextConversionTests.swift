import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 繁簡轉換的契約：
/// - 不改變 UTF-16 長度。閱讀位置、劃線、書籤都以字元位移保存，切換模式不能讓它們錯位；
///   繁轉簡會把 168 個罕用字（例如「勣」）轉成擴充區的字，這些字保留原字。
/// - ICU 會看上下文選字（复制 → 複製），所以整段一起轉，不能逐字轉。
/// - 替換規則在轉換之後套用（legado 同順序）：從選取建立的規則，用的是畫面上已轉換的字。
@Suite("Text conversion", .serialized)
struct TextConversionTests {

    @Test("conversion keeps every character's UTF-16 width")
    func conversionKeepsUTF16Width() {
        let text = "李勣與國語"
        let converted = text.converted(to: .toSimplified)

        #expect(converted.utf16.count == text.utf16.count)
        #expect(converted == "李勣与国语")
    }

    @Test("conversion runs over the whole text so ICU can pick characters by context")
    func conversionUsesContext() {
        #expect("复制".converted(to: .toTraditional) == "複製")
    }

    @Test("attributed conversion keeps each attribute on its character")
    func attributedConversionKeepsAttributes() {
        let attributed = NSMutableAttributedString(string: "学习国语")
        let marker = NSAttributedString.Key("TextConversionTestsMarker")
        attributed.addAttribute(marker, value: "middle", range: NSRange(location: 1, length: 2))

        TextConversion.toTraditional.apply(to: attributed)

        #expect(attributed.string == "學習國語")
        var effective = NSRange()
        let value = attributed.attribute(marker, at: 1, effectiveRange: &effective) as? String
        #expect(value == "middle")
        #expect(effective == NSRange(location: 1, length: 2))
        #expect(attributed.attribute(marker, at: 0, effectiveRange: nil) == nil)
    }

    @Test("changing the conversion mode re-runs layout")
    func conversionChangeIsLayoutRefresh() {
        let original = Self.settings()
        var converted = original
        converted.textConversion = .toTraditional

        let intent = converted.refreshIntent(comparedTo: original)

        #expect({ if case .layout? = intent { return true } else { return false } }())
    }

    @Test("TXT chapters convert body and title before replace rules run")
    @MainActor
    func txtConvertsBeforeReplaceRules() async throws {
        // 規則用繁體寫，就像從已轉換的畫面上選取文字建立的規則。
        let rule = ReplaceRule(
            name: "TextConversionTests",
            pattern: "學習",
            replacement: "研讀",
            isRegex: false,
            enabled: true,
            scope: "global"
        )
        ReplaceRuleStore.shared.add(rule)
        defer { ReplaceRuleStore.shared.delete(id: rule.id) }

        let body = "学习国语。"
        let builder = TXTLazyAttributedStringBuilder(
            text: body,
            chapterIndexes: [
                TXTChapterIndex(
                    index: 0,
                    title: "第一章 国语",
                    contentRange: NSRange(location: 0, length: (body as NSString).length)
                )
            ]
        )
        var settings = Self.settings()
        settings.textConversion = .toTraditional

        let result = try await builder.buildChapter(
            at: 0,
            settings: settings,
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        let text = result.attributedString.string

        #expect(text.contains("研讀國語。"))
        // 標題和正文都不能留下簡體的「国」。
        #expect(!text.contains("国"))
    }

    @Test("HTML-rendered chapters (EPUB, online, Markdown) convert their text")
    @MainActor
    func nodeRendererConvertsText() async {
        var settings = Self.settings()
        settings.textConversion = .toTraditional
        let renderer = NodeAttributedStringRenderer(
            config: NodeAttributedStringRenderer.Config(from: settings, textColor: .black, renderWidth: 320)
        )

        let rendered = await renderer.render([.paragraph([.text("学习国语")], style: .body)])

        #expect(rendered.string.contains("學習國語"))
    }

    @Test("conversion cost for a long chapter and a large table of contents")
    func conversionCost() {
        let sentence = "他打开窗户，看见远处的山峦在雾里若隐若现。"
        let chapter = String(repeating: sentence, count: 1_000)
        let clock = ContinuousClock()

        let textStart = clock.now
        let converted = chapter.converted(to: .toTraditional)
        let textElapsed = clock.now - textStart

        let attributed = NSMutableAttributedString(string: chapter)
        let attributedStart = clock.now
        TextConversion.toTraditional.apply(to: attributed)
        let attributedElapsed = clock.now - attributedStart

        let titles = (0..<3_000).map { "第\($0 + 1)章 远方的山峦" }
        let titlesStart = clock.now
        let convertedTitles = titles.map { $0.converted(to: .toTraditional) }
        let titlesElapsed = clock.now - titlesStart

        print("⏱ textConversion chars=\(chapter.count) text=\(textElapsed) attributed=\(attributedElapsed) titles3000=\(titlesElapsed)")
        #expect(converted.utf16.count == chapter.utf16.count)
        #expect(convertedTitles.count == titles.count)
    }

    private static func settings() -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test",
            textColor: .black,
            backgroundColor: .white,
            fontSize: 18,
            lineHeightMultiple: 1.5,
            lineSpacing: 0,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 0,
            marginV: 0,
            footerHeight: 0,
            contentInsets: .zero
        )
    }
}
