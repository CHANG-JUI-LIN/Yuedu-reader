// Port of io.legado.app.model.analyzeRule.RuleData
// Default implementation of RuleDataInterface for transient rule execution.

import Foundation

class RuleData: RuleDataInterface {

    lazy var variableMap: [String: String] = [:]

    func putBigVariable(key: String, value: String?) {
        // No persistent storage; fall back to variableMap
        if let value {
            variableMap[key] = value
        } else {
            variableMap.removeValue(forKey: key)
        }
    }

    func getBigVariable(key: String) -> String? {
        // Subclasses (e.g. BookSource) can override for DB-backed storage
        nil
    }

    /// Serialize all variables to a JSON string for persistence or transfer
    func getVariableJSON() -> String? {
        guard !variableMap.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: variableMap),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Load variables from a JSON string
    func loadVariables(from json: String?) {
        guard let json,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return
        }
        variableMap = dict
    }
}
