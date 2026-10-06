import Foundation
import Testing
import YueduCoreTextTypography
@testable import yuedu_app

/// Each book's CJK typography comes from its text's script
/// (docs/superpowers/plans/2026-10-06-vertical-typography.md, Task 3).
@Suite("CJK typography style")
struct CJKTypographyStyleTests {
    static let traditional = "這裡說的是舊時候的事，誰也記不清楚了。後來聽說，那邊的園子裡還開著花。"
    static let simplified = "这里说的是旧时候的事，谁也记不清楚了。后来听说，那边的园子里还开着花。"
    static let japanese = "これは昔の話である。誰もよく覚えていない。あの庭にはまだ花が咲いているそうだ。"
    /// Characters both scripts write alike.
    static let shared = "我的天，你在不在？"

    @Test func detectsTheScript() {
        #expect(CJKTypographyStyle.detect(in: Self.traditional) == .traditional)
        #expect(CJKTypographyStyle.detect(in: Self.simplified) == .simplified)
        #expect(CJKTypographyStyle.detect(in: Self.japanese) == .japanese)
        #expect(CJKTypographyStyle.detect(in: "我的天") == nil)
        #expect(CJKTypographyStyle.detect(in: "Hello world.") == nil)
    }

    @Test func aStrayCharacterDoesNotOutvoteTheText() {
        // 公里 is written alike in both scripts, but ICU's Hans-Hant still changes 里, so
        // this sentence on its own votes Simplified. The Traditional ones around it win.
        let text = Self.traditional + "走了三公里。" + Self.traditional
        #expect(CJKTypographyStyle.detect(in: text) == .traditional)
    }

    @Test func aFewKanaInChineseTextStayChinese() {
        #expect(CJKTypographyStyle.detect(in: Self.traditional + "（アニメ）" + Self.traditional) == .traditional)
    }

    @Test(arguments: [
        ("zh-cn", CJKTypographyStyle.simplified), ("zh", .simplified), ("zh-Hans", .simplified),
        ("zh-TW", .traditional), ("zh-HK", .traditional), ("zh-Hant", .traditional), ("zh_MO", .traditional),
        ("ja", .japanese), ("ja-jp", .japanese),
    ])
    func declaredLanguages(tag: String, style: CJKTypographyStyle) {
        #expect(CJKTypographyStyle.declared(tag) == style)
    }

    @Test func undeclaredOrOtherLanguagesSayNothing() {
        #expect(CJKTypographyStyle.declared(nil) == nil)
        #expect(CJKTypographyStyle.declared("") == nil)
        #expect(CJKTypographyStyle.declared("en") == nil)
    }

    @Test func theTextOutranksTheDeclaredLanguage() {
        let resolver = CJKTypographyStyleResolver()
        #expect(resolver.style(for: Self.traditional, book: nil, conversion: .original, declaredLanguage: "zh-cn") == .traditional)
        #expect(resolver.style(for: Self.simplified, book: nil, conversion: .original, declaredLanguage: "zh-TW") == .simplified)
        #expect(resolver.style(for: Self.japanese, book: nil, conversion: .original, declaredLanguage: "zh") == .japanese)
    }

    @Test func theConvertedTextDecides() {
        // Builders pass the text the reader shows, after 繁簡轉換.
        let resolver = CJKTypographyStyleResolver()
        let shown = Self.traditional.converted(to: .toSimplified)
        #expect(resolver.style(for: shown, book: nil, conversion: .toSimplified, declaredLanguage: nil) == .simplified)
    }

    @Test func textThatShowsNoScriptFallsBack() {
        let resolver = CJKTypographyStyleResolver()
        #expect(resolver.style(for: Self.shared, book: nil, conversion: .original, declaredLanguage: "zh-HK") == .traditional)
        #expect(resolver.style(for: Self.shared, book: nil, conversion: .original, declaredLanguage: nil)
            == CJKTypographyStyleResolver.interfaceStyle)
    }

    @Test func aBookKeepsTheStyleItsTextGaveIt() {
        let resolver = CJKTypographyStyleResolver()
        let book = UUID()
        // A title page that shows no script, before the book is decided: it decides for itself.
        #expect(resolver.style(for: "第一回", book: book, conversion: .original, declaredLanguage: "zh-cn") == .simplified)
        #expect(resolver.style(for: Self.traditional, book: book, conversion: .original, declaredLanguage: "zh-cn") == .traditional)
        // From then on the book is Traditional, titles included.
        #expect(resolver.style(for: "第二回", book: book, conversion: .original, declaredLanguage: "zh-cn") == .traditional)
        // Switching 繁簡轉換 asks the text again.
        #expect(resolver.style(for: Self.simplified, book: book, conversion: .toSimplified, declaredLanguage: "zh-cn") == .simplified)
    }

    @Test func theAIAnswerRuleIsUnchanged() {
        #expect(ChineseScript.of("這是什麼") == .traditional)
        #expect(ChineseScript.of("这是什么") == .simplified)
        #expect(ChineseScript.of("我的天") == nil)
    }

    @Test func htmlSamplesDropMarkupAndReadings() {
        let html = """
        <html><head><title>標題</title><style>p { color: red }</style></head>
        <body><p><ruby>漢<rt>かん</rt></ruby>字</p><script>var a = "あいう";</script></body></html>
        """
        let sample = CJKTypographyStyleResolver.textSample(fromHTML: html)
        #expect(sample.contains("漢"))
        #expect(sample.contains("字"))
        #expect(!sample.contains("かん"))
        #expect(!sample.contains("あいう"))
        #expect(!sample.contains("color"))
        #expect(!sample.contains("標題"))
    }
}
