import Foundation

struct LegacyFallbackExtractor: RuleExtractor {
    func canHandle(rule: String) -> Bool {
        true
    }

    func extractList(from content: String, rule: String, baseURL: String) throws -> [String] {
        RuleEngine.extractValueList(fromHTML: content, rule: rule, baseURL: baseURL)
    }

    func extractValue(from content: String, rule: String, baseURL: String) throws -> String {
        RuleEngine.routeExtractValue(content: content, baseURL: baseURL, rule: rule)
    }
}
