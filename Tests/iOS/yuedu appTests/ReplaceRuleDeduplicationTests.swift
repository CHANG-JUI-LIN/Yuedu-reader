import Testing
@testable import yuedu_app

/// Covers the cleanup for the duplicated-presets bug: every install used to mint fresh
/// UUIDs for the same five preset rules, so iCloud's id-keyed merge kept each install's
/// copy and the list grew by five on every reinstall.
@Suite("Replace rule deduplication")
struct ReplaceRuleDeduplicationTests {

    private func rule(
        id: String,
        pattern: String,
        replacement: String = "",
        scope: String = "global",
        isRegex: Bool = true,
        sortOrder: Int = 0
    ) -> ReplaceRule {
        ReplaceRule(
            id: id,
            name: id,
            pattern: pattern,
            replacement: replacement,
            isRegex: isRegex,
            scope: scope,
            sortOrder: sortOrder
        )
    }

    @Test("Rules performing the same substitution collapse to one")
    func collapsesIdenticalRules() {
        let deduped = ReplaceRuleStore.deduplicated([
            rule(id: "b", pattern: "\\n{3,}", replacement: "\n\n"),
            rule(id: "a", pattern: "\\n{3,}", replacement: "\n\n"),
            rule(id: "c", pattern: "\\n{3,}", replacement: "\n\n"),
        ])

        #expect(deduped.count == 1)
    }

    @Test("The lowest id survives, so two devices pick the same one")
    func keepsLowestID() {
        let fromDeviceOrder = ReplaceRuleStore.deduplicated([
            rule(id: "zzz", pattern: "廣告"),
            rule(id: "aaa", pattern: "廣告"),
        ])
        let fromOtherDeviceOrder = ReplaceRuleStore.deduplicated([
            rule(id: "aaa", pattern: "廣告"),
            rule(id: "zzz", pattern: "廣告"),
        ])

        #expect(fromDeviceOrder.map(\.id) == ["aaa"])
        #expect(fromOtherDeviceOrder.map(\.id) == ["aaa"])
    }

    @Test("Same pattern in a different scope is a different rule")
    func keepsDistinctScopes() {
        let deduped = ReplaceRuleStore.deduplicated([
            rule(id: "a", pattern: "廣告", scope: "global"),
            rule(id: "b", pattern: "廣告", scope: "https://example.com"),
        ])

        #expect(deduped.count == 2)
    }

    @Test("Regex and literal rules with the same pattern both survive")
    func keepsRegexAndLiteralApart() {
        let deduped = ReplaceRuleStore.deduplicated([
            rule(id: "a", pattern: "a.b", isRegex: true),
            rule(id: "b", pattern: "a.b", isRegex: false),
        ])

        #expect(deduped.count == 2)
    }

    @Test("A different replacement is a different rule")
    func keepsDistinctReplacements() {
        let deduped = ReplaceRuleStore.deduplicated([
            rule(id: "a", pattern: "\\n{3,}", replacement: "\n\n"),
            rule(id: "b", pattern: "\\n{3,}", replacement: ""),
        ])

        #expect(deduped.count == 2)
    }

    @Test("Order of the surviving rules is preserved")
    func preservesOrder() {
        let deduped = ReplaceRuleStore.deduplicated([
            rule(id: "first", pattern: "one"),
            rule(id: "second", pattern: "two"),
            rule(id: "dup", pattern: "one"),
            rule(id: "third", pattern: "three"),
        ])

        #expect(deduped.map(\.pattern) == ["one", "two", "three"])
    }

    @Test("A list with no duplicates is returned untouched")
    func leavesCleanListAlone() {
        let input = [
            rule(id: "a", pattern: "one"),
            rule(id: "b", pattern: "two"),
        ]

        #expect(ReplaceRuleStore.deduplicated(input).map(\.id) == ["a", "b"])
    }
}
