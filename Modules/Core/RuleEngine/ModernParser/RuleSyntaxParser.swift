import Foundation

enum RuleSyntaxParser {
    /// Legado's `RuleAnalyzer.splitRule(...)` over a rule's list operators: the operator that
    /// occurs FIRST outside brackets decides how the rule splits, and only that operator splits
    /// it. `A&&B&&C||D` is three pieces — `A`, `B` and `C||D` — the last of which the JSONPath
    /// and XPath readers split again (`getList`/`getElements` call themselves per piece).
    /// Checking `||` before `&&` instead read 哔哩哔哩's book list
    /// `$.data.result[*].data[*]&&…live_user[*]&&…live_room[*]||$.data.result[*]` as
    /// "the first three joined, or else the groups", so the groups came back as books.
    ///
    /// - Parameters:
    ///   - operators: `getString` reads `&&` and `||` only; list reads add `%%`.
    ///   - code: JSONPath readers balance `{}` and quotes as code (`RuleAnalyzer(rule, true)`).
    /// - Returns: the operator (empty when the rule has none) and its pieces, trimmed, with
    ///   empty pieces dropped (an empty piece reads as nothing in every Legado reader). A
    ///   rule with an operator can come back with one piece (`$.a||`); callers read the
    ///   pieces whenever the type is not empty, never the whole rule again.
    static func splitRuleByOperators(
        _ rule: String, operators: [String] = ["&&", "||", "%%"], code: Bool = false
    ) -> (type: String, parts: [String]) {
        let analyzer = RuleAnalyzer(data: rule, code: code)
        let pieces = analyzer.splitRule(operators)
        guard !analyzer.elementsType.isEmpty else { return ("", [rule]) }
        let parts = pieces
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (analyzer.elementsType, parts)
    }

    /// Legado's `%%` merge: item `i` of every list in turn, for each index of the FIRST list
    /// (`for (i in results[0].indices)`), so items past the first list's length are dropped.
    /// The JSONPath and XPath readers keep only non-empty lists before merging; jsoup keeps
    /// every list, so an empty first piece merges to nothing there — callers pass what their
    /// Legado reader keeps.
    static func interleaveByFirst<Item>(_ lists: [[Item]]) -> [Item] {
        guard let first = lists.first else { return [] }
        var merged: [Item] = []
        for index in first.indices {
            for list in lists where index < list.count {
                merged.append(list[index])
            }
        }
        return merged
    }
}
