import Foundation

/// Extracts content using regular expressions.
/// Handles rules prefixed with `##` or used in regex mode.
final class RegexExtractor: RuleExtractor {

    /// The shared, internally locked cache. Read through rather than stored, so the
    /// extractor itself carries no state and is `Sendable` like every `RuleExtractor`.
    private var cache: RegexCache { RegexCache.shared }

    func canHandle(rule: String) -> Bool {
        return rule.hasPrefix("##")
    }

    func extractList(from content: String, rule: String, baseURL: String) throws -> [String] {
        let pattern = stripPrefix(rule)
        guard !pattern.isEmpty else { return [content] }

        guard let regex = cache.regex(for: pattern) else {
            return [content]
        }

        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)

        let matches = RegexMatching.matches(
            of: regex, in: content, range: fullRange, firstOnly: false, timeout: 2.0
        ) ?? []

        guard !matches.isEmpty else { return [] }

        var results: [String] = []
        for match in matches {
            if match.numberOfRanges > 1 {
                for i in 1..<match.numberOfRanges {
                    let groupRange = match.range(at: i)
                    if groupRange.location != NSNotFound {
                        results.append(nsContent.substring(with: groupRange))
                    }
                }
            } else {
                results.append(nsContent.substring(with: match.range))
            }
        }
        return results
    }

    func extractValue(from content: String, rule: String, baseURL: String) throws -> String {
        let pattern = stripPrefix(rule)
        guard !pattern.isEmpty else { return content }

        guard let regex = cache.regex(for: pattern) else {
            return content
        }

        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)

        guard let match = RegexMatching.matches(
            of: regex, in: content, range: fullRange, firstOnly: true, timeout: 2.0
        )?.first else {
            return ""
        }

        // Return first capture group if present, otherwise full match
        if match.numberOfRanges > 1 {
            let groupRange = match.range(at: 1)
            if groupRange.location != NSNotFound {
                return nsContent.substring(with: groupRange)
            }
        }
        return nsContent.substring(with: match.range)
    }

    // MARK: - Private

    private func stripPrefix(_ rule: String) -> String {
        if rule.hasPrefix("##") {
            return String(rule.dropFirst(2))
        }
        return rule
    }
}

// MARK: - RegexReplacer

/// Applies `##pattern##replacement` post-processing after extraction.
/// Group references `$0`–`$99` in `replacement` are resolved by NSRegularExpression.
/// Append `###` to the rule to replace only the first match.
enum RegexReplacer {

    /// Transform only the first regex match and return that transformed match.
    ///
    /// Legado uses this behavior for a rule whose extraction part is empty and
    /// whose replacement suffix is `###`, for example
    /// `##href=".../(\d+)/0/"##https://example.com/book/$1/###`.
    /// The unmatched surrounding HTML is intentionally discarded.
    static func firstMatchReplacement(
        result: String,
        pattern: String,
        replacement: String,
        timeout: TimeInterval = 2.0
    ) -> String {
        guard !pattern.isEmpty else { return "" }
        guard let regex = RegexCache.shared.regex(for: pattern) else { return "" }

        guard let match = RegexMatching.matches(
            of: regex, in: result, firstOnly: true, timeout: timeout
        )?.first else {
            return ""
        }
        return regex.replacementString(
            for: match, in: result, offset: 0, template: replacement
        )
    }

    /// Replace regex matches in `result`.
    /// - Parameters:
    ///   - result: The input string.
    ///   - pattern: The regex pattern (supports `(?i)` inline flags). Java-specific
    ///              syntax is sanitized automatically via `RegexSanitizer`.
    ///   - replacement: Template string with `$0`–`$99` group references.
    ///   - replaceFirst: If `true`, only the first match is replaced.
    ///   - timeout: Maximum seconds to allow; returns original on catastrophic backtracking.
    /// - Returns: The modified string, or the original if the pattern is empty/invalid/timed-out.
    static func replaceRegex(
        result: String,
        pattern: String,
        replacement: String,
        replaceFirst: Bool,
        timeout: TimeInterval = 2.0
    ) -> String {
        guard !pattern.isEmpty else { return result }
        guard let regex = RegexCache.shared.regex(for: pattern) else { return result }

        return RegexMatching.replacing(
            regex, in: result, template: replacement, firstOnly: replaceFirst, timeout: timeout
        ) ?? result
    }
}
