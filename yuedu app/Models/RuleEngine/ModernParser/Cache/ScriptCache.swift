import Foundation
import JavaScriptCore

/// Caches compiled JavaScript functions to avoid repeated parsing/compilation.
final class ScriptCache {
    static let shared = ScriptCache()

    private let cache: LRUCache<String, JSValue>

    /// - Parameter capacity: Maximum cached compiled scripts. Defaults to 16.
    init(capacity: Int = 16) {
        self.cache = LRUCache(capacity: capacity)
    }

    /// Get a previously compiled function for the given script.
    func getCompiledFunction(_ script: String) -> JSValue? {
        return cache.get(script)
    }

    /// Cache a compiled function keyed by its source script.
    func putCompiledFunction(_ script: String, function: JSValue) {
        cache.put(script, value: function)
    }

    /// Get cached compiled function, or invoke `compile` to create and cache it.
    /// Returns nil if compilation fails.
    func getOrCompile(_ script: String, compile: (String) -> JSValue?) -> JSValue? {
        if let cached = cache.get(script) {
            return cached
        }
        guard let compiled = compile(script) else { return nil }
        cache.put(script, value: compiled)
        return compiled
    }

    /// Clear all cached compiled scripts.
    func clear() {
        cache.clear()
    }
}
