import Foundation

protocol RuleExtractor {
    func canHandle(rule: String) -> Bool
    func extractList(from content: String, rule: String, baseURL: String) throws -> [String]
    func extractValue(from content: String, rule: String, baseURL: String) throws -> String
}

enum ModernRuleEngineError: LocalizedError {
    case unsupportedRule(String)
    case extractionFailed(rule: String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedRule(let rule):
            return "ModernRuleEngine unsupported rule syntax: \(rule)"
        case .extractionFailed(let rule, let err):
            return "ModernRuleEngine extraction failed (rule: \(rule)): \(err.localizedDescription)"
        }
    }
}
