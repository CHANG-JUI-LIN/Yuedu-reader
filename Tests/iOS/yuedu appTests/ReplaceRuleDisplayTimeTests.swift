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

    /// Organizer, 2.0.7 (104): a broad rule aborted the app out of memory inside
    /// `ReplaceRuleEngine`. The display-time path then built every replacement before
    /// checking the budget, so the allocation it guards against had already happened.
    @Test("an over-budget rule stops at the match that passes the budget", arguments: [true, false])
    func overBudgetStopsEarly(regex: Bool) {
        let text = String(repeating: "a", count: 10_000) as NSString
        let rule = Self.rule(regex ? "(?=a)" : "a", String(repeating: "x", count: 100), regex: regex)
        let result = ReplaceRuleEngine.edits(of: rule, in: text, range: NSRange(location: 0, length: text.length), limit: 1_000)
        guard case .overBudget(let scanned) = result else {
            Issue.record("expected the rule to be refused, got \(String(describing: result))")
            return
        }
        // Each match adds about 100 units against a 1,000 budget: it must give up near
        // the tenth match, not after all ten thousand.
        #expect(scanned <= 11)
    }

    @Test("both entry points refuse the same over-budget rule and keep the text")
    func overBudgetKeepsText() {
        let source = String(repeating: "永夜", count: 20)
        let rules = [Self.rule("(?=.)", String(repeating: "x", count: 100))]
        #expect(ReplaceRuleEngine.replacing(rules[0], in: source, limit: 1_000) == nil)
        let text = Self.attributed(source)
        // The attributed entry's budget is fixed at 8M units, so use a rule that passes it.
        let huge = [Self.rule("(?=.)", String(repeating: "x", count: 300_000))]
        #expect(!ReplaceRuleEngine.apply(huge, to: text, from: 0))
        #expect(text.string == source)
        #expect(ReplaceRuleEngine.apply(huge, to: source) == source)
    }

    @Test("a literal rule obeys the same budget as a regex one")
    func literalBudget() {
        let rule = Self.rule("a", "xyz", regex: false)
        #expect(ReplaceRuleEngine.replacing(rule, in: "aaaa", limit: 12) == "xyzxyzxyzxyz")
        #expect(ReplaceRuleEngine.replacing(rule, in: "aaaa", limit: 11) == nil)
    }
}

