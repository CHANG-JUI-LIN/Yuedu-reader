import Foundation

// MARK: - Rule Auto-Complete (Legado `RuleComplete` port)

/// Port of Legado's `io.legado.app.help.RuleComplete.autoComplete`.
///
/// Completes simple JSOUP / XPath / CSS rules so authors can write shorthand like
/// `a` instead of `a@text`, `img` instead of `img@src`. Mirrors the Kotlin source
/// exactly (including the `##` / `,{` tail split and the img→alt fix), so rules
/// completed here match what Legado produces for the same input.
enum RuleAutoComplete {

    /// Result type of the completion, matching Legado's `type` parameter:
    /// 1 = text (default), 2 = link, 3 = image.
    enum CompletionType: Int {
        case text = 1
        case link = 2
        case image = 3
    }

    // 需要補全: a `&&`/`%%`/`||` separator (or end of string) that is NOT preceded by
    // a completed attribute token like `a@href` / `//div`.
    private static let needCompletePattern =
        #"(?<!(@|/|^|[|%&]{2})(attr|text|ownText|textNodes|href|content|html|alt|all|value|src)(\(\))?)(?<seq>\&{2}|%%|\|{2}|$)"#

    // 不能補全: complex rules (js/json/{{xx}}/jpath) are returned unchanged.
    private static let notCompletePattern = #"^:|^##|\{\{|@js:|<js>|@Json:|\$\."#

    // 修正從圖片獲取信息: `img[/]text` → `img@alt` (a text fetch on an img node is
    // almost always meant to read its alt text).
    private static let fixImgInfoPattern =
        #"(?<=(^|tag\.|[\+/@>~| &]))img(?<at>(\[@?.+\]|\.[-\w]+)?)[@/]+text(\(\))?(?<seq>\&{2}|%%|\|{2}|$)"#

    private static let isXpathPattern = #"^//|^@Xpath:"#

    /// Completes `rules` per Legado semantics. Returns the input unchanged when it is
    /// blank, already complete, or too complex (JS / JSON / `{{}}`), and when `preRule`
    /// is itself too complex.
    static func autoComplete(
        _ rules: String?,
        preRule: String? = nil,
        type: CompletionType = .text
    ) -> String {
        guard let rules, !rules.isEmpty else { return rules ?? "" }
        if contains(rules, notCompletePattern) || contains(preRule ?? "", notCompletePattern) {
            return rules
        }

        // Tail split on `##` (regex replacement) or `,{` (request params) — the split
        // separator and the remainder ride along untouched.
        let tailParts = splitTail(of: rules)
        let cleanedRule = tailParts.cleaned
        let tailString = tailParts.tail

        let isXPath = contains(cleanedRule, isXpathPattern)
        let textRule: String
        let linkRule: String
        let imgRule: String
        if isXPath {
            textRule = "//text()"
            linkRule = "//@href"
            imgRule = "//@src"
        } else {
            textRule = "@text"
            linkRule = "@href"
            imgRule = "@src"
        }

        let completed: String
        switch type {
        case .text:
            completed = replaceNeedComplete(cleanedRule, insertion: textRule)
                .replacingMatches(fixImgInfoPattern) { match in
                    let at = match.range(withName: "at")
                    let atText = at.location == NSNotFound ? "" : (cleanedRule as NSString).substring(with: at)
                    let seq = match.range(withName: "seq")
                    let seqText = seq.location == NSNotFound ? "" : (cleanedRule as NSString).substring(with: seq)
                    // Legado: XPath keeps the `/` (`img$at/@alt`), CSS does not (`img$at@alt`).
                    return isXPath
                        ? "img" + atText + "/@alt" + seqText
                        : "img" + atText + "@alt" + seqText
                }
        case .link:
            completed = replaceNeedComplete(cleanedRule, insertion: linkRule)
        case .image:
            completed = replaceNeedComplete(cleanedRule, insertion: imgRule)
        }
        return completed + tailString
    }

    // MARK: - Private

    private static func contains(_ text: String, _ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Splits `rules` at the first `##` or `,{` occurrence. Returns the cleaned head and
    /// the separator+tail (empty when there is no tail).
    private static func splitTail(of rules: String) -> (cleaned: String, tail: String) {
        guard let regex = try? NSRegularExpression(pattern: #"##|,\{"#),
              let match = regex.firstMatch(in: rules, range: NSRange(rules.startIndex..., in: rules)),
              let matchRange = Range(match.range, in: rules)
        else { return (rules, "") }
        let splitStr = String(rules[matchRange])
        let tail = rules[matchRange.upperBound...]
        return (String(rules[..<matchRange.lowerBound]), splitStr + tail)
    }

    /// Inserts `insertion` before every `&&` / `%%` / `||` separator (and the end of the
    /// string) that is not already an attribute fetch. This mirrors Legado's
    /// `needComplete.replace(rule, textRule)` — the lookbehind in the pattern rejects
    /// already-complete segments, so only missing attributes get filled in.
    private static func replaceNeedComplete(_ rule: String, insertion: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: needCompletePattern) else { return rule }
        let ns = rule as NSString
        let matches = regex.matches(in: rule, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return rule }

        var result = ns as String
        for match in matches.reversed() {
            let seq = ns.substring(with: match.range)
            guard let r = Range(match.range, in: result) else { continue }
            result.replaceSubrange(r, with: insertion + seq)
        }
        return result
    }
}

private extension String {
    /// Applies `transform` to every match of `pattern`, replacing each match with the
    /// transform's output. Used for the img→alt fix where the replacement is composed
    /// from a captured group.
    func replacingMatches(_ pattern: String, transform: (NSTextCheckingResult) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        let ns = self as NSString
        let matches = regex.matches(in: self, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return self }
        var result = self
        for match in matches.reversed() {
            guard let r = Range(match.range, in: result) else { continue }
            result.replaceSubrange(r, with: transform(match))
        }
        return result
    }
}
