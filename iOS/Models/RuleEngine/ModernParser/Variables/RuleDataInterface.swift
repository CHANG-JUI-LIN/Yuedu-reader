// Port of io.legado.app.model.analyzeRule.RuleDataInterface
// Provides runtime variable storage shared across rule execution chains.

import Foundation

protocol RuleDataInterface: AnyObject {
    /// In-memory variable storage for small values
    var variableMap: [String: String] { get set }

    /// Store a variable. Small values (<10000 chars) go to variableMap,
    /// large values go to persistent storage via putBigVariable.
    /// Returns true if a value was set, or if the key previously existed when clearing.
    @discardableResult
    func putVariable(key: String, value: String?) -> Bool

    /// Retrieve a variable. Checks variableMap first, then persistent storage.
    func getVariable(key: String) -> String

    /// Store a large variable to persistent storage (DB, file, etc.)
    func putBigVariable(key: String, value: String?)

    /// Retrieve a large variable from persistent storage
    func getBigVariable(key: String) -> String?
}

extension RuleDataInterface {

    @discardableResult
    func putVariable(key: String, value: String?) -> Bool {
        guard let value else {
            let existed = variableMap.removeValue(forKey: key) != nil
            putBigVariable(key: key, value: nil)
            return existed
        }
        if value.count < 10_000 {
            putBigVariable(key: key, value: nil)
            variableMap[key] = value
            return true
        } else {
            let existed = variableMap.removeValue(forKey: key) != nil
            putBigVariable(key: key, value: value)
            return existed
        }
    }

    func getVariable(key: String) -> String {
        variableMap[key] ?? getBigVariable(key: key) ?? ""
    }
}
