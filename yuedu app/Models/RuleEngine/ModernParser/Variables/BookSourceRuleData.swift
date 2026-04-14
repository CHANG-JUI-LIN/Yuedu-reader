import Foundation

/// Wrapper that adapts a BookSource (value-type struct) to conform to
/// RuleDataInterface (class-only protocol required by ModernRuleEngine,
/// AnalyzeUrl, and JSCoreEngine).
///
/// BookSource cannot directly conform to RuleDataInterface because it is
/// a struct while the protocol requires AnyObject (for weak references in
/// AnalyzeUrl and the engine's variable chain). This class bridges the gap.
final class BookSourceRuleData: RuleDataInterface {

    let source: BookSource

    lazy var variableMap: [String: String] = [:]

    init(source: BookSource) {
        self.source = source
    }

    func putBigVariable(key: String, value: String?) {
        if let value {
            variableMap[key] = value
        } else {
            variableMap.removeValue(forKey: key)
        }
    }

    func getBigVariable(key: String) -> String? {
        nil
    }
}
