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

/// Applies `##pattern##replacement` post-processing after extraction, as Legado's
/// `AnalyzeRule.replaceRegex` does (legado-E, MD3 and upstream agree).
/// Group references `$0`–`$99` in `replacement` are resolved by NSRegularExpression.
enum RegexReplacer {

    /// Replace regex matches in `result`.
    /// - Parameters:
    ///   - result: The input string.
    ///   - pattern: The regex pattern (supports `(?i)` inline flags). Java-specific
    ///              syntax is sanitized automatically via `RegexSanitizer`.
    ///   - replacement: Template string with `$0`–`$99` group references.
    ///   - replaceFirst: The rule ended in `###`: the result is the first match alone,
    ///     transformed — `match.value.replaceFirst(regex, replacement)` — and the text around
    ///     it is dropped; no match gives "". This holds whatever extraction rule came before
    ///     the `##`: `.mubtn@a@href##/(\d+)##https://host/info.php?aid=$1###` turns the href
    ///     `chapter/172275/` into `https://host/info.php?aid=172275`, not
    ///     `chapterhttps://host/info.php?aid=172275/`.
    ///   - timeout: Maximum seconds to allow; on catastrophic backtracking the original comes
    ///     back (`""` under `replaceFirst`, as for no match).
    /// - Returns: The modified string. A pattern that does not compile gives `replacement`
    ///   under `replaceFirst`, and otherwise a literal (non-regex) replacement, as in Legado.
    static func replaceRegex(
        result: String,
        pattern: String,
        replacement: String,
        replaceFirst: Bool,
        timeout: TimeInterval = 2.0
    ) -> String {
        guard !pattern.isEmpty else { return result }
        guard let regex = RegexCache.shared.regex(for: pattern) else {
            return replaceFirst
                ? replacement
                : result.replacingOccurrences(of: pattern, with: replacement)
        }

        let fullRange = NSRange(result.startIndex..., in: result)

        if replaceFirst {
            guard let match = RegexMatching.matches(
                of: regex, in: result, range: fullRange, firstOnly: true, timeout: timeout
            )?.first, let range = Range(match.range, in: result) else {
                return ""
            }
            // Kotlin's `match.value.replaceFirst(regex, replacement)`: the regex runs again
            // on the matched text alone, so a lookaround that needed the surrounding text
            // leaves the match as it is.
            let value = String(result[range])
            return RegexMatching.replacing(
                regex, in: value, template: replacement, firstOnly: true, timeout: timeout
            ) ?? ""
        }
        return RegexMatching.replacing(
            regex, in: result, template: replacement, firstOnly: false, timeout: timeout
        ) ?? result
    }
}
