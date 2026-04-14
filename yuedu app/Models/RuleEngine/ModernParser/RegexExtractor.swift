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
        let matches = regex.matches(in: content, range: fullRange)
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
        guard let match = regex.firstMatch(in: content, range: fullRange) else {
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

    /// Replace regex matches in `result`.
    /// - Parameters:
    ///   - result: The input string.
    ///   - pattern: The regex pattern (supports `(?i)` inline flags).
    ///   - replacement: Template string with `$0`–`$99` group references.
    ///   - replaceFirst: If `true`, only the first match is replaced.
    /// - Returns: The modified string, or the original if the pattern is empty/invalid.
    static func replaceRegex(
        result: String,
        pattern: String,
        replacement: String,
        replaceFirst: Bool
    ) -> String {
        guard !pattern.isEmpty else { return result }
        guard let regex = RegexCache.shared.regex(for: pattern) else { return result }

        let fullRange = NSRange(result.startIndex..., in: result)

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
    }
}
