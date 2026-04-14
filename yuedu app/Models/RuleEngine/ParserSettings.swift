import Foundation

/// Feature flag controlling which rule engine is used for book source parsing.
enum ParserSettings {
    private static let key = "useModernParser"

    /// When true, uses ModernRuleEngine; when false, falls back to legacy RuleEngine.
    /// Defaults to true (modern engine).
    static var useModernParser: Bool {
        get {
            if UserDefaults.standard.object(forKey: key) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: key)
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
