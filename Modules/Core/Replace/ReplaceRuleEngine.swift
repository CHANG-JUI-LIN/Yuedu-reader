import Foundation

/// Applies a list of `ReplaceRule` objects to a string.
///
/// Used after the book-source's per-source `##` replacement rules so
/// user-configured global rules run last.
///
/// Thread-safe: NSRegularExpression objects are reused via a simple cache.
enum ReplaceRuleEngine {

    // LRU-lite cache keyed by pattern string.
    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    /// Apply all `rules` to `content` in order and return the result.
    static func apply(_ rules: [ReplaceRule], to content: String) -> String {
        var output = content
        for rule in rules {
            guard rule.enabled, !rule.pattern.isEmpty else { continue }
            output = apply(rule, to: output)
        }
        return output
    }

    /// Apply a single rule to `content`.
    static func apply(_ rule: ReplaceRule, to content: String) -> String {
        if rule.isRegex {
            return applyRegex(pattern: rule.pattern,
                              replacement: rule.replacement,
                              to: content)
        } else {
            return content.replacingOccurrences(of: rule.pattern, with: rule.replacement)
        }
    }

    // MARK: - Private

    private static func applyRegex(pattern: String, replacement: String, to content: String) -> String {
        guard !pattern.isEmpty else { return content }

        let regex: NSRegularExpression
        lock.lock()
        if let cached = regexCache[pattern] {
            regex = cached
            lock.unlock()
        } else {
            lock.unlock()
            guard let r = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
                return content
            }
            lock.lock()
            if regexCache.count > 64 { regexCache.removeAll() } // simple eviction
            regexCache[pattern] = r
            lock.unlock()
            regex = r
        }

        let range = NSRange(content.startIndex..., in: content)
        // Convert Legado-style $1 → \1 for NSRegularExpression
        let nsReplacement = legadoToNSReplacement(replacement)
        return regex.stringByReplacingMatches(in: content, range: range, withTemplate: nsReplacement)
    }

    /// Converts `$0`, `$1` … `$9` capture-group references to `\0`, `\1` … `\9`.
    private static func legadoToNSReplacement(_ template: String) -> String {
        var result = template
        for i in stride(from: 9, through: 0, by: -1) {
            result = result.replacingOccurrences(of: "$\(i)", with: "\\\(i)")
        }
        return result
    }
}
