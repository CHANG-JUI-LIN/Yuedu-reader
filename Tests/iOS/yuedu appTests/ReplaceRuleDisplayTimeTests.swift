import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Replace rules run once, at display time, with one set of semantics. The online reader
/// used to carry its own copy of the replace loop that had drifted from
/// `ReplaceRuleEngine` (reported 2026-10-10), and the chapter fetcher also baked rules into
/// the cache, so plain-text online chapters got them twice.
@Suite("Replace rules at display time", .serialized)
struct ReplaceRuleDisplayTimeTests {

    private static func rule(_ pattern: String, _ replacement: String, regex: Bool = true) -> ReplaceRule {
        ReplaceRule(name: "ReplaceRuleDisplayTimeTests", pattern: pattern, replacement: replacement, isRegex: regex)
    }

    private static func attributed(_ text: String) -> NSMutableAttributedString {
        NSMutableAttributedString(string: text, attributes: [.foregroundColor: UIColor.red])
    }

    @Test("a replacement as long as its match still applies")
    func sameLengthReplacement() {
        let text = Self.attributed("永夜降臨。")
        #expect(ReplaceRuleEngine.apply([Self.rule("永夜", "長夜", regex: false)], to: text, from: 0))
        #expect(text.string == "長夜降臨。")
    }

    @Test("$n expands to the capture, as on the string path")
    func captureGroups() {
        let text = Self.attributed("第12章")
        let rules = [Self.rule("第(\\d+)章", "Chapter $1")]
        ReplaceRuleEngine.apply(rules, to: text, from: 0)
        #expect(text.string == "Chapter 12")
        #expect(text.string == ReplaceRuleEngine.apply(rules, to: "第12章"))
    }

    @Test("^ anchors at every line, as on the string path")
    func anchorsMatchLines() {
        let source = "甲\n  乙\n　丙"
        let rules = [Self.rule("^[\\u3000 ]+", "")]
        let text = Self.attributed(source)
        ReplaceRuleEngine.apply(rules, to: text, from: 0)
        #expect(text.string == "甲\n乙\n丙")
        #expect(text.string == ReplaceRuleEngine.apply(rules, to: source))
    }

    @Test("text before the start offset is never touched, and styling survives")
    func respectsStartAndAttributes() {
        let text = Self.attributed("永夜\n永夜")
        ReplaceRuleEngine.apply([Self.rule("永夜", "長夜長夜", regex: false)], to: text, from: 3)
        #expect(text.string == "永夜\n長夜長夜")
        let color = text.attribute(.foregroundColor, at: text.length - 1, effectiveRange: nil) as? UIColor
        #expect(color == .red)
    }

    @Test("no match reports no change")
    func noMatch() {
        let text = Self.attributed("天地漆黑")
        #expect(!ReplaceRuleEngine.apply([Self.rule("永夜", "長夜")], to: text, from: 0))
    }

    @Test("the chapter fetcher keeps the source's text; rules wait for display")
    func fetcherDoesNotBakeRules() async {
        let rule = Self.rule("永夜", "長夜", regex: false)
        ReplaceRuleStore.shared.add(rule)
        defer { ReplaceRuleStore.shared.delete(id: rule.id) }

        let content = await ChapterFetcher.shared.resolveContent(
            parsed: ChapterParsePayload(content: "永夜，天地漆黑。", title: "第1章", sourceMatched: true, isPay: false)
        )
        #expect(content.contains("永夜"))
        #expect(!content.contains("長夜"))
    }
}
