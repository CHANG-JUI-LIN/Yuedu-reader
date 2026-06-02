import Foundation

// MARK: - RuleEngine Replace Rule Extensions

extension RuleEngine {
    static func applyReplaceRegex(_ text: String, rules: String) -> String {
        let trimmedRules = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRules.isEmpty else { return text }

        // Try JSON array format [{"regex":"...", "replacement":"...", "isRegex":true}]
        if trimmedRules.hasPrefix("["),
           let data = trimmedRules.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var result = text
            for item in arr {
                let pattern = (item["regex"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = (item["replacement"] as? String) ?? ""
                let isRegex = (item["isRegex"] as? Bool) ?? true
                guard !pattern.isEmpty else { continue }
                if isRegex {
                    if let regex = try? NSRegularExpression(pattern: pattern) {
                        let range = NSRange(result.startIndex..., in: result)
                        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
                    }
                } else {
                    result = result.replacingOccurrences(of: pattern, with: replacement)
                }
            }
            return result
        }

        // Legado getString format: ##pattern##replacement or ##pattern##replacement## (replaceFirst)
        var result = text
        let lines = trimmedRules.components(separatedBy: "\n").filter { !$0.isEmpty }
        for line in lines {
            var pattern: String
            var replacement: String
            var replaceFirst = false
            if line.components(separatedBy: "@@@").count > 1 {
                let parts = line.components(separatedBy: "@@@")
                pattern = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                replacement = parts[1]
            } else {
                var content = line
                if content.hasPrefix("##") {
                    content = String(content.dropFirst(2))
                }
                // Legado: trailing ### indicates replaceFirst (replace only first match)
                if content.hasSuffix("###") {
                    replaceFirst = true
                    content = String(content.dropLast(3))
                }
                let hashParts = content.components(separatedBy: "##")
                pattern = hashParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                replacement = hashParts.count > 1 ? hashParts[1] : ""
            }
            guard !pattern.isEmpty else { continue }
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                if replaceFirst {
                    if let match = regex.firstMatch(in: result, range: range),
                       let matchRange = Range(match.range, in: result) {
                        let matched = String(result[matchRange])
                        let replaced = regex.stringByReplacingMatches(
                            in: matched,
                            range: NSRange(matched.startIndex..., in: matched),
                            withTemplate: replacement
                        )
                        result.replaceSubrange(matchRange, with: replaced)
                    } else {
                        result = ""
                    }
                } else {
                    result = regex.stringByReplacingMatches(
                        in: result, range: range, withTemplate: replacement)
                }
            }
        }
        return result
    }
}
