import Foundation

/// Extracts content using regular expressions.
/// Handles rules prefixed with `##` or used in regex mode.
final class RegexExtractor: RuleExtractor {

    private let cache = RegexCache.shared

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

        let matches = RegexSanitizer.withTimeout(seconds: 2.0, work: {
            regex.matches(in: content, range: fullRange)
        }, fallback: [] as [NSTextCheckingResult])

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

        guard let match = RegexSanitizer.withTimeout(seconds: 2.0, work: {
            regex.firstMatch(in: content, range: fullRange)
        }, fallback: nil) else {
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

        let fullRange = NSRange(result.startIndex..., in: result)
        return RegexSanitizer.withTimeout(seconds: timeout, work: {
            guard let match = regex.firstMatch(in: result, range: fullRange) else {
                return ""
            }
            return regex.replacementString(
                for: match, in: result, offset: 0, template: replacement
            )
        }, fallback: "")
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

        let fullRange = NSRange(result.startIndex..., in: result)

        return RegexSanitizer.withTimeout(seconds: timeout, work: {
            if replaceFirst {
                guard let match = regex.firstMatch(in: result, range: fullRange) else {
                    return result
                }
                let template = regex.replacementString(
                    for: match, in: result, offset: 0, template: replacement
                )
                let mutable = NSMutableString(string: result)
                mutable.replaceCharacters(in: match.range, with: template)
                return mutable as String
            } else {
                return regex.stringByReplacingMatches(
                    in: result, range: fullRange, withTemplate: replacement
                )
            }
        }, fallback: result)
    }
}
