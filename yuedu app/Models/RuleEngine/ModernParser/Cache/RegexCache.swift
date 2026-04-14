import Foundation

/// Caches compiled NSRegularExpression instances to avoid repeated compilation.
final class RegexCache {
    static let shared = RegexCache()

    private let cache: LRUCache<String, NSRegularExpression>

    /// - Parameter capacity: Maximum cached patterns. Defaults to 64.
    init(capacity: Int = 64) {
        self.cache = LRUCache(capacity: capacity)
    }

    /// Get or compile a regex pattern. Returns nil if the pattern is invalid.
    /// The cache key incorporates options so the same pattern with different flags is cached separately.
    func regex(for pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let key = "\(pattern)|\(options.rawValue)"
        // Use a two-step approach because NSRegularExpression init can throw
        if let cached = cache.get(key) {
            return cached
        }
        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        cache.put(key, value: compiled)
        return compiled
    }

    /// Replace all matches of `pattern` in `string` with `replacement`.
    /// Returns nil if the pattern is invalid.
    func replaceMatches(
        in string: String,
        pattern: String,
        replacement: String,
        options: NSRegularExpression.Options = []
    ) -> String? {
        guard let regex = regex(for: pattern, options: options) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        return regex.stringByReplacingMatches(in: string, range: range, withTemplate: replacement)
    }

    /// Find the first match of `pattern` in `string`.
    /// Returns nil if the pattern is invalid or no match is found.
    func firstMatch(
        in string: String,
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSTextCheckingResult? {
        guard let regex = regex(for: pattern, options: options) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        return regex.firstMatch(in: string, range: range)
    }

    /// Clear all cached patterns.
    func clear() {
        cache.clear()
    }
}
