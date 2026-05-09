import Foundation

struct LegadoRule {
    let cssSelector: String
    let extractAttribute: String?
}

enum LegadoRuleParser {
    /// Parse a list rule (ruleArticles). `id.content@h3` → cssSelector `[id=content] h3`.
    static func parseListRule(_ rule: String) -> LegadoRule? {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = splitAtLastAt(trimmed)
        let selectorCSS = convertToCSS(parts.selector)
        guard !selectorCSS.isEmpty else { return nil }

        if let childTag = parts.result {
            return LegadoRule(cssSelector: "\(selectorCSS) \(childTag)", extractAttribute: nil)
        } else {
            return LegadoRule(cssSelector: selectorCSS, extractAttribute: nil)
        }
    }

    /// Parse an extraction rule (ruleTitle, ruleLink, etc.). `a@href` → cssSelector `a`, extractAttribute `href`.
    static func parseExtractRule(_ rule: String) -> LegadoRule? {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = splitAtLastAt(trimmed)
        let selectorCSS = convertToCSS(parts.selector)
        guard !selectorCSS.isEmpty else { return nil }

        if let extract = parts.result {
            let normalized = normalizeExtract(extract)
            return LegadoRule(cssSelector: selectorCSS, extractAttribute: normalized)
        } else {
            return LegadoRule(cssSelector: selectorCSS, extractAttribute: "text")
        }
    }

    // MARK: - Private

    private static func splitAtLastAt(_ rule: String) -> (selector: String, result: String?) {
        guard let atIndex = rule.lastIndex(of: "@") else {
            return (rule, nil)
        }
        let selector = String(rule[..<atIndex])
        let result = String(rule[rule.index(after: atIndex)...])
        return (selector, result)
    }

    /// Convert Legado selector syntax to standard CSS.
    /// `id.content` → `#content`, `class.foo` → `.foo`, `tag` → `tag`
    private static func convertToCSS(_ legadoSelector: String) -> String {
        let trimmed = legadoSelector.trimmingCharacters(in: .whitespacesAndNewlines)

        // `id.xxx` or `id.xxx-xxx` → `#xxx`
        if trimmed.hasPrefix("id.") {
            let idValue = String(trimmed.dropFirst(3))
            return "#\(idValue)"
        }

        // `class.xxx` → `.xxx`
        if trimmed.hasPrefix("class.") {
            let classValue = String(trimmed.dropFirst(6))
            return ".\(classValue)"
        }

        return trimmed
    }

    private static func normalizeExtract(_ extract: String) -> String? {
        let trimmed = extract.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        switch trimmed {
        case "textNodes", "text":
            return "text"
        case "html", "all", "innerHtml":
            return "html"
        default:
            return trimmed
        }
    }
}
