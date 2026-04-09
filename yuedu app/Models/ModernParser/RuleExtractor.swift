import Foundation

protocol RuleExtractor {
    func canHandle(rule: String) -> Bool
    func extractList(from content: String, rule: String, baseURL: String) throws -> [String]
    func extractValue(from content: String, rule: String, baseURL: String) throws -> String
}

enum ModernRuleEngineError: Error {
    case unsupportedRule(String)
}
