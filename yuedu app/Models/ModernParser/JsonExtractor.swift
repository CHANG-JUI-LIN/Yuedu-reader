import Foundation

struct JsonExtractor: RuleExtractor {
    func canHandle(rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        return lowered.hasPrefix("@json:") || trimmed.hasPrefix("$.")
    }

    func extractList(from content: String, rule: String, baseURL: String) throws -> [String] {
        RuleEngine.extractValueList(fromHTML: content, rule: rule, baseURL: baseURL)
    }

    func extractValue(from content: String, rule: String, baseURL: String) throws -> String {
        RuleEngine.routeExtractValue(content: content, baseURL: baseURL, rule: rule)
    }
}
