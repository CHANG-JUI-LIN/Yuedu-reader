import Foundation

// MARK: - RuleMode

/// Rule execution mode, ported from Legado's `AnalyzeRule.Mode`.
enum RuleMode: Equatable, Sendable {
    /// CSS / JSoup (default parser)
    case `default`
    /// XPath query
    case xpath
    /// JSONPath query
    case json
    /// JavaScript execution
    case js
    /// Regular expression
    case regex
}

// MARK: - SourceRule

/// A parsed rule segment produced by splitting a raw rule string.
///
/// Ported from the inner class `SourceRule` inside Legado's `AnalyzeRule.kt`.
/// Each segment carries its execution mode, an optional regex replacement,
/// `@put` variable directives, and template parameters resolved at execution
/// time via ``makeUpRule(result:getData:evalJS:analyzeRule:)``.
final class SourceRule {

    // MARK: Public properties

    /// The rule text (prefixes stripped, `@put` removed; `##` parts retained
    /// until ``makeUpRule(result:getData:evalJS:analyzeRule:)`` is called).
    var rule: String

    /// Execution mode for this rule segment.
    var mode: RuleMode

    /// Regex pattern used to post-process extraction results.
    var replaceRegex: String = ""

    /// Replacement string applied with ``replaceRegex``.
    var replacement: String = ""

    /// When `true`, only the first regex match is replaced (`###` suffix).
    var replaceFirst: Bool = false

    /// Key-value pairs extracted from `@put:{…}` directives.
    var putMap: [String: String] = [:]

    /// Number of template parameters found during parsing.
    var paramSize: Int { ruleParam.count }

    // MARK: Private storage

    /// Template parameter values (interleaved with literal segments).
    private var ruleParam: [String] = []

    /// Parallel array indicating each `ruleParam` entry's type:
    /// - `getRuleType` (−2): `@get:{key}` reference
    /// - `jsRuleType`  (−1): `{{expression}}` template
    /// - `defaultRuleType` (0): literal text
    /// - positive `N`: regex group `$N` reference
    private var ruleType: [Int] = []

    private static let getRuleType     = -2
    private static let jsRuleType      = -1
    private static let defaultRuleType =  0

    // MARK: Pattern constants

    /// Matches `@put:{…}` directives.
    static let putPattern = try! NSRegularExpression(
        pattern: #"@put:(\{[^}]+?\})"#,
        options: .caseInsensitive
    )

    /// Matches `@get:{…}` and `{{…}}` template expressions.
    static let evalPattern = try! NSRegularExpression(
        pattern: #"@get:\{[^}]+?\}|\{\{[\w\W]*?\}\}"#,
        options: .caseInsensitive
    )

    /// Matches `$0`–`$99` regex group references.
    static let regexPattern = try! NSRegularExpression(
        pattern: #"\$\d{1,2}"#
    )

    // MARK: - Initialisation

    /// Parse a raw rule string into a ``SourceRule``.
    ///
    /// - Parameters:
    ///   - ruleStr:  The raw rule text.
    ///   - mainMode: Default mode (overridden when a prefix is detected).
    ///   - isJSON:   Whether the content being parsed is JSON.
    init(ruleStr: String, mainMode: RuleMode = .default, isJSON: Bool = false) {
        self.mode = mainMode

        // 1. Detect mode from prefix and strip it.
        let detected: String
        if mode == .js || mode == .regex {
            detected = ruleStr
        } else {
            detected = Self.detectMode(ruleStr, mode: &mode, isJSON: isJSON)
        }

        // 2. Extract @put:{…} directives.
        self.rule = Self.extractPutDirectives(detected, into: &putMap)

        // 3. Parse template parameters (@get:{}, {{}}, $N).
        parseTemplateParameters()
    }

    // MARK: - makeUpRule

    /// Resolve template variables and extract the `##` regex-replacement tail.
    ///
    /// Call this at execution time, once the supporting closures are available.
    ///
    /// - Parameters:
    ///   - result:      Current extraction result (`[String?]` for `$N` groups).
    ///   - getData:     Resolves `@get:{key}` references.
    ///   - evalJS:      Evaluates `{{jsExpression}}` templates.
    ///   - analyzeRule: Evaluates `{{ruleExpression}}` templates whose text
    ///                  starts with `@`, `$.`, `$[`, or `//`.
    func makeUpRule(
        result: Any?,
        getData: (String) -> String,
        evalJS: (String) -> String?,
        analyzeRule: (String) -> String?
    ) {
        // Rebuild rule from template parameters.
        if !ruleParam.isEmpty {
            var parts: [String] = []
            parts.reserveCapacity(ruleParam.count)

            for index in 0..<ruleParam.count {
                let regType = ruleType[index]

                switch regType {
                case let n where n > Self.defaultRuleType:
                    // $N regex group reference
                    if let groups = result as? [String?],
                       groups.count > n,
                       let value = groups[n] {
                        parts.append(value)
                    } else {
                        parts.append(ruleParam[index])
                    }

                case Self.jsRuleType:
                    // {{expression}}
                    let expression = ruleParam[index]
                    if Self.looksLikeRule(expression) {
                        parts.append(analyzeRule(expression) ?? "")
                    } else if let value = evalJS(expression) {
                        parts.append(value)
                    }

                case Self.getRuleType:
                    // @get:{key}
                    parts.append(getData(ruleParam[index]))

                default:
                    // Literal text
                    parts.append(ruleParam[index])
                }
            }
            rule = parts.joined()
        }

        // Split by ## to extract regex replacement info.
        let segments = rule.components(separatedBy: "##")
        rule = segments[0].trimmingCharacters(in: .whitespaces)

        if segments.count > 1 {
            replaceRegex = segments[1]
        }
        if segments.count > 2 {
            replacement = segments[2]
        }
        if segments.count > 3 {
            replaceFirst = true
        }
    }
}

// MARK: - Private helpers

private extension SourceRule {

    // MARK: Mode detection

    /// Detect rule mode from known prefixes and return the rule with the
    /// prefix stripped.
    static func detectMode(
        _ ruleStr: String,
        mode: inout RuleMode,
        isJSON: Bool
    ) -> String {
        let lower = ruleStr.lowercased()

        if lower.hasPrefix("@css:") {
            mode = .default
            return String(ruleStr.dropFirst(5))
        }
        if ruleStr.hasPrefix("@@") {
            mode = .default
            return String(ruleStr.dropFirst(2))
        }
        if lower.hasPrefix("@xpath:") {
            mode = .xpath
            return String(ruleStr.dropFirst(7))
        }
        if lower.hasPrefix("@json:") {
            mode = .json
            return String(ruleStr.dropFirst(6))
        }
        if lower.hasPrefix("@js:") {
            mode = .js
            return String(ruleStr.dropFirst(4))
        }
        if lower.hasPrefix("<js>") && lower.hasSuffix("</js>") {
            mode = .js
            let start = ruleStr.index(ruleStr.startIndex, offsetBy: 4)
            let end   = ruleStr.index(ruleStr.endIndex, offsetBy: -5)
            return start <= end ? String(ruleStr[start..<end]) : ""
        }
        if isJSON || ruleStr.hasPrefix("$.") || ruleStr.hasPrefix("$[") {
            mode = .json
            return ruleStr
        }
        if ruleStr.hasPrefix("/") || ruleStr.hasPrefix("!/") {
            mode = .xpath
            return ruleStr
        }
        return ruleStr
    }

    // MARK: @put extraction

    /// Remove all `@put:{…}` directives from the rule, parsing each JSON body
    /// into `putMap`.
    static func extractPutDirectives(
        _ ruleStr: String,
        into putMap: inout [String: String]
    ) -> String {
        let nsRule = ruleStr as NSString
        let fullRange = NSRange(location: 0, length: nsRule.length)
        let matches = putPattern.matches(in: ruleStr, range: fullRange)
        guard !matches.isEmpty else { return ruleStr }

        var result = ruleStr
        for match in matches {
            // Remove the full @put:{…} from the rule text.
            let fullMatch = nsRule.substring(with: match.range)
            result = result.replacingOccurrences(of: fullMatch, with: "")

            // Parse JSON inside the braces (capture group 1).
            guard match.numberOfRanges > 1 else { continue }
            let jsonRange = match.range(at: 1)
            guard jsonRange.location != NSNotFound else { continue }
            let jsonStr = nsRule.substring(with: jsonRange)

            guard let data = jsonStr.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            for (key, value) in obj {
                putMap[key] = value is String ? (value as! String) : "\(value)"
            }
        }
        return result
    }

    // MARK: Template parameter parsing

    /// Scan `rule` for `@get:{…}`, `{{…}}`, and `$N` patterns, recording
    /// their positions for later replacement in ``makeUpRule``.
    func parseTemplateParameters() {
        let nsRule = rule as NSString
        let fullRange = NSRange(location: 0, length: nsRule.length)
        let evalMatches = Self.evalPattern.matches(in: rule, range: fullRange)

        var start = 0

        if let firstMatch = evalMatches.first {
            // If an eval template is present, potentially switch to regex mode.
            let textBefore = nsRule.substring(
                with: NSRange(location: 0, length: firstMatch.range.location)
            )
            if mode != .js && mode != .regex
                && (firstMatch.range.location == 0 || !textBefore.contains("##"))
            {
                mode = .regex
            }

            for match in evalMatches {
                let matchLoc = match.range.location
                let matchEnd = matchLoc + match.range.length

                // Literal segment before this template.
                if matchLoc > start {
                    let literal = nsRule.substring(
                        with: NSRange(location: start, length: matchLoc - start)
                    )
                    splitRegex(literal)
                }

                let matchText = nsRule.substring(with: match.range)

                if matchText.lowercased().hasPrefix("@get:") {
                    // @get:{key} → strip "@get:{" (6 chars) and trailing "}".
                    let keyStart = matchText.index(matchText.startIndex, offsetBy: 6)
                    let keyEnd   = matchText.index(before: matchText.endIndex)
                    if keyStart < keyEnd {
                        ruleType.append(Self.getRuleType)
                        ruleParam.append(String(matchText[keyStart..<keyEnd]))
                    }
                } else if matchText.hasPrefix("{{") {
                    // {{expr}} → strip "{{" and "}}".
                    let exprStart = matchText.index(matchText.startIndex, offsetBy: 2)
                    let exprEnd   = matchText.index(matchText.endIndex, offsetBy: -2)
                    if exprStart <= exprEnd {
                        ruleType.append(Self.jsRuleType)
                        ruleParam.append(String(matchText[exprStart..<exprEnd]))
                    }
                } else {
                    splitRegex(matchText)
                }

                start = matchEnd
            }
        }

        // Remaining text after the last template (or the entire rule if none).
        if nsRule.length > start {
            splitRegex(nsRule.substring(from: start))
        }
    }

    /// Parse a literal segment for `$N` regex-group references.
    ///
    /// The `##` separator is intentionally kept in the literal text; it will
    /// be split out later in ``makeUpRule``.  Only the portion **before** the
    /// first `##` is scanned for `$N` patterns (matching Legado behaviour).
    func splitRegex(_ ruleStr: String) {
        let nsStr = ruleStr as NSString

        // Only search for $N in the part before the first ##.
        let firstPart = ruleStr.components(separatedBy: "##")[0]
        let nsFirst = firstPart as NSString
        let firstRange = NSRange(location: 0, length: nsFirst.length)
        let matches = Self.regexPattern.matches(in: firstPart, range: firstRange)

        var start = 0

        if !matches.isEmpty {
            if mode != .js && mode != .regex {
                mode = .regex
            }
            for match in matches {
                let matchLoc = match.range.location
                let matchEnd = matchLoc + match.range.length

                if matchLoc > start {
                    let literal = nsStr.substring(
                        with: NSRange(location: start, length: matchLoc - start)
                    )
                    ruleType.append(Self.defaultRuleType)
                    ruleParam.append(literal)
                }

                let groupRef = nsStr.substring(with: match.range)
                let groupNum = Int(groupRef.dropFirst()) ?? 0
                ruleType.append(groupNum)
                ruleParam.append(groupRef)

                start = matchEnd
            }
        }

        if nsStr.length > start {
            ruleType.append(Self.defaultRuleType)
            ruleParam.append(nsStr.substring(from: start))
        }
    }

    // MARK: Helpers

    /// Return `true` when the expression looks like a structured rule
    /// (CSS / XPath / JSONPath) rather than JavaScript.
    static func looksLikeRule(_ expression: String) -> Bool {
        expression.hasPrefix("@")
            || expression.hasPrefix("$.")
            || expression.hasPrefix("$[")
            || expression.hasPrefix("//")
    }
}
