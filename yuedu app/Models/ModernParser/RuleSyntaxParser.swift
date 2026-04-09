import Foundation

enum RuleSyntaxParser {
    /// Bracket-aware split where separators inside [] or () are ignored.
    static func bracketAwareSplit(_ rule: String, separator: String) -> [String] {
        guard !separator.isEmpty else { return [rule] }

        var parts: [String] = []
        var depth = 0
        var current = ""
        var index = rule.startIndex

        while index < rule.endIndex {
            let character = rule[index]
            if character == "[" || character == "(" {
                depth += 1
                current.append(character)
                index = rule.index(after: index)
            } else if character == "]" || character == ")" {
                depth = max(0, depth - 1)
                current.append(character)
                index = rule.index(after: index)
            } else if depth == 0, rule[index...].hasPrefix(separator) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                }
                current = ""
                index = rule.index(index, offsetBy: separator.count)
            } else {
                current.append(character)
                index = rule.index(after: index)
            }
        }

        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            parts.append(trimmed)
        }
        return parts
    }

    /// Split by rule operators in priority order: ||, &&, %%.
    static func splitRuleByOperators(_ rule: String) -> (type: String, parts: [String]) {
        for op in ["||", "&&", "%%"] {
            let parts = bracketAwareSplit(rule, separator: op)
            if parts.count > 1 {
                return (op, parts)
            }
        }
        return ("", [rule])
    }
}
