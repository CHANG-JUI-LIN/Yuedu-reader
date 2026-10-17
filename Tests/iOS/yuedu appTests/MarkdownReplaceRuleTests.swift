import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Replace rules act on the text a Markdown reader sees, never on the Markdown syntax that
/// holds it together. They used to run over the raw source, where the first-launch preset
/// 清除全形空格開頭 (`^[　\s]+`, line-anchored) matched every blank line and deleted it, so
/// each section's paragraphs were joined into one: a Markdown book rendered every chapter as
/// a single paragraph (found 2026-10-18 through ContinuousScrollRestoreTests on iPad).
@Suite("Markdown replace rules")
struct MarkdownReplaceRuleTests {

    private static func rule(_ pattern: String, _ replacement: String, regex: Bool = true) -> ReplaceRule {
        ReplaceRule(name: "MarkdownReplaceRuleTests", pattern: pattern, replacement: replacement, isRegex: regex)
    }

    /// The rules `ReplaceRuleStore.installPresets` gives every new install.
    private static let presets: [ReplaceRule] = [
        rule("^\\s*本章節.*?(?=\\n)", ""),
        rule("(?<=\\n).*?閱讀\\s*$", ""),
        rule("\\n{3,}", "\n\n"),
        rule("^[\\u3000\\s]+", ""),
        rule("[\\t ]+$", ""),
    ]

    @Test("the preset rules keep every paragraph a paragraph")
    func presetsKeepParagraphs() {
        let builder = MarkdownAttributedStringBuilder(
            markdown: "# 起始\n\n短句0。\n\n短句1。\n\n短句2。", fallbackTitle: "T", replaceRules: Self.presets)
        #expect(builder.unifiedChapters.first?.paragraphs == ["短句0。", "短句1。", "短句2。"])
    }

    @Test("block structure survives the presets")
    func presetsKeepBlocks() {
        let builder = MarkdownAttributedStringBuilder(
            markdown: "# 起始\n\n段一\n\n---\n\n#### 小標\n\n> 引用\n\n- 項目\n\n段二",
            fallbackTitle: "T", replaceRules: Self.presets)
        #expect(builder.unifiedChapters.first?.paragraphs == ["段一", "小標", "引用", "• 項目", "段二"])
    }

    @Test("rules still rewrite the text, and drawn and plain text agree")
    func rulesStillApply() async throws {
        let rules = Self.presets + [Self.rule("永夜", "長夜", regex: false)]
        let builder = MarkdownAttributedStringBuilder(
            markdown: "# 起始\n\n　　永夜降臨。\n\n- 永夜\n\n#### 永夜", fallbackTitle: "T", replaceRules: rules)
        #expect(builder.unifiedChapters.first?.paragraphs == ["長夜降臨。", "• 長夜", "長夜"])
        #expect(await builder.chapterPlainText(at: 0) == "長夜降臨。\n• 長夜\n長夜")
        let built = try await builder.buildChapter(at: 0, settings: EPUBTestFixtures.renderSettings(),
                                                   themeTextColor: .black, themeBackgroundColor: .white)
        #expect(built.attributedString.string.contains("長夜降臨。\n"))
        #expect(!built.attributedString.string.contains("永夜"))
    }

    @Test("section titles are not rule input, as in the TXT and online readers")
    func titlesAreNotRewritten() {
        let builder = MarkdownAttributedStringBuilder(
            markdown: "# 永夜\n\n永夜降臨。", fallbackTitle: "T",
            replaceRules: [Self.rule("永夜", "長夜", regex: false)])
        #expect(builder.chapterTitle(at: 0) == "永夜")
        #expect(builder.unifiedChapters.first?.paragraphs == ["長夜降臨。"])
    }
}
