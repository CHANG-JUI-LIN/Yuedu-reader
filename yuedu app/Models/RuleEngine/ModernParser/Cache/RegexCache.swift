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
    /// The pattern is sanitized via RegexSanitizer to handle Java-specific syntax
    /// (possessive quantifiers, atomic groups, \R, \e, (?d) flag, \p{javaXxx}).
    /// The cache key incorporates the sanitized pattern + options so the same pattern
    /// with different flags is cached separately.
    func regex(for pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let sanitized = RegexSanitizer.sanitize(pattern)
        let key = "\(sanitized)|\(options.rawValue)"
        if let cached = cache.get(key) {
            return cached
        }
        guard let compiled = try? NSRegularExpression(pattern: sanitized, options: options) else {
            return nil
        }
        cache.put(key, value: compiled)
        return compiled
    }

    /// Replace all matches of `pattern` in `string` with `replacement`.
    /// Protected by a 2-second timeout to guard against catastrophic backtracking.
    /// Returns nil if the pattern is invalid, or the original string on timeout.
    func replaceMatches(
        in string: String,
        pattern: String,
        replacement: String,
        options: NSRegularExpression.Options = [],
        timeout: TimeInterval = 2.0
    ) -> String? {
        guard let regex = regex(for: pattern, options: options) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        return RegexSanitizer.withTimeout(seconds: timeout, work: {
            regex.stringByReplacingMatches(in: string, range: range, withTemplate: replacement)
        }, fallback: string)
    }

    /// Find the first match of `pattern` in `string`.
    /// Protected by a 2-second timeout to guard against catastrophic backtracking.
    /// Returns nil if the pattern is invalid or no match is found within the timeout.
    func firstMatch(
        in string: String,
        pattern: String,
        options: NSRegularExpression.Options = [],
        timeout: TimeInterval = 2.0
    ) -> NSTextCheckingResult? {
        guard let regex = regex(for: pattern, options: options) else { return nil }
        let range = NSRange(string.startIndex..., in: string)
        return RegexSanitizer.withTimeout(seconds: timeout, work: {
            regex.firstMatch(in: string, range: range)
        }, fallback: nil)
    }

    /// Clear all cached patterns.
    func clear() {
        cache.clear()
    }
}
