import Foundation
#if canImport(Fuzi)
import Fuzi
#endif

// MARK: - XPathExtractor

/// XPath-based extractor ported from Legado's AnalyzeByXPath.kt.
/// Supports union `|`, Legado multi-rule operators (`||`, `&&`, `%%`),
/// accessor suffixes (`@text`, `@html`, `@href`, …), and HTML fragment wrapping.
struct XPathExtractor: RuleExtractor {

    // MARK: - RuleExtractor conformance

    func canHandle(rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("@xpath:") || trimmed.hasPrefix("//") { return true }
        let xpathAxes = [
            "following-sibling::", "preceding-sibling::",
            "ancestor::", "descendant::", "parent::", "self::",
            "child::", "attribute::", "following::", "preceding::"
        ]
        return xpathAxes.contains(where: { lowered.contains($0) })
    }

    func extractList(from content: String, rule: String, baseURL: String) throws -> [String] {
        let normalizedRule = normalizeRule(rule)
        guard !normalizedRule.isEmpty else { return [] }

        #if canImport(Fuzi)
        guard let doc = parseHTMLContent(content) else {
            return fallbackExtract(content: content, rule: rule, baseURL: baseURL)
        }
        return extractStringList(from: doc, rule: normalizedRule, baseURL: baseURL)
        #else
        return fallbackExtract(content: content, rule: rule, baseURL: baseURL)
        #endif
    }

    func extractValue(from content: String, rule: String, baseURL: String) throws -> String {
        let normalizedRule = normalizeRule(rule)
        guard !normalizedRule.isEmpty else { return "" }

        #if canImport(Fuzi)
        guard let doc = parseHTMLContent(content) else {
            return fallbackExtract(content: content, rule: rule, baseURL: baseURL).first ?? ""
        }
        return extractString(from: doc, rule: normalizedRule, baseURL: baseURL) ?? ""
        #else
        return fallbackExtract(content: content, rule: rule, baseURL: baseURL).first ?? ""
        #endif
    }

    // MARK: - Rule normalisation

    private func normalizeRule(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("@xpath:") {
            return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    // MARK: - Fallback

    private func fallbackExtract(content: String, rule: String, baseURL: String) -> [String] {
        return RuleEngine.extractValueList(fromHTML: content, rule: rule, baseURL: baseURL)
    }

    // MARK: - Fuzi implementation

    #if canImport(Fuzi)

    // MARK: HTML parsing with fragment wrapping (matches Legado strToJXDocument)

    private func parseHTMLContent(_ html: String) -> HTMLDocument? {
        let wrapped = wrapHTMLFragment(html)
        return try? HTMLDocument(string: wrapped, encoding: .utf8)
    }

    /// Wraps orphan `<td>` / `<tr>` / `<tbody>` fragments so the HTML parser keeps them.
    private func wrapHTMLFragment(_ html: String) -> String {
        var result = html
        let lower = html.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasSuffix("</td>") {
            result = "<tr>" + result + "</tr>"
        }
        let lowerResult = result.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowerResult.hasSuffix("</tr>") || lowerResult.hasSuffix("</tbody>") {
            result = "<table>" + result + "</table>"
        }
        return result
    }

    // MARK: Multi-rule split (Legado `||`, `&&`, `%%`)

    /// Splits by Legado operators via RuleAnalyzer and merges per operator semantics.
    private func extractStringList(from doc: HTMLDocument, rule: String, baseURL: String) -> [String] {
        let analyzer = RuleAnalyzer(data: rule)
        let rules = analyzer.splitRule("&&", "||", "%%")

        if rules.count == 1 {
            return evaluateXPathForStrings(on: doc, xpath: rules[0], baseURL: baseURL)
        }

        var resultSets: [[String]] = []
        for rl in rules {
            let temp = evaluateXPathForStrings(on: doc, xpath: rl, baseURL: baseURL)
            if !temp.isEmpty {
                resultSets.append(temp)
                if analyzer.elementsType == "||" { break }
            }
        }

        guard !resultSets.isEmpty else { return [] }

        if analyzer.elementsType == "%%" {
            return interleave(resultSets)
        }
        return resultSets.flatMap { $0 }
    }

    /// getString equivalent — joins results with newline, respects `||`/`&&`.
    private func extractString(from doc: HTMLDocument, rule: String, baseURL: String) -> String? {
        let analyzer = RuleAnalyzer(data: rule)
        let rules = analyzer.splitRule("&&", "||")

        if rules.count == 1 {
            let results = evaluateXPathForStrings(on: doc, xpath: rules[0], baseURL: baseURL)
            return results.isEmpty ? nil : results.joined(separator: "\n")
        }

        var textList: [String] = []
        for rl in rules {
            let temp = extractString(from: doc, rule: rl, baseURL: baseURL)
            if let t = temp, !t.isEmpty {
                textList.append(t)
                if analyzer.elementsType == "||" { break }
            }
        }
        return textList.isEmpty ? nil : textList.joined(separator: "\n")
    }

    /// Interleave arrays round-robin (Legado `%%` operator).
    private func interleave(_ arrays: [[String]]) -> [String] {
        guard let maxLen = arrays.map({ $0.count }).max() else { return [] }
        var result: [String] = []
        for i in 0..<maxLen {
            for arr in arrays where i < arr.count {
                result.append(arr[i])
            }
        }
        return result
    }

    // MARK: Single XPath evaluation (with union `|` support)

    /// Evaluate a single XPath expression that may contain union `|`.
    /// Splits on `|` outside brackets/quotes, evaluates each part, merges results.
    private func evaluateXPathForStrings(on queryable: Queryable, xpath: String, baseURL: String) -> [String] {
        let (mainXPath, accessor) = splitXPathAndAccessor(xpath)
        guard !mainXPath.isEmpty else { return [] }

        let parts = splitUnion(mainXPath)
        var results: [String] = []

        for part in parts {
            let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPart.isEmpty else { continue }

            if let acc = accessor {
                let nodes = safeXPath(on: queryable, xpath: trimmedPart)
                for node in nodes {
                    if let value = resolvedValue(from: node, accessor: acc, baseURL: baseURL) {
                        results.append(value)
                    }
                }
            } else {
                // Default: string value of each matched node
                let nodes = safeXPath(on: queryable, xpath: trimmedPart)
                for node in nodes {
                    let str = normalizeWhitespace(node.stringValue)
                    if !str.isEmpty { results.append(str) }
                }
            }
        }
        return results
    }

    // MARK: XPath accessor split

    /// Splits `//div/a/@text` into (`//div/a`, `text`).
    /// Recognises Legado-style accessors after the last `@` that are *not* part of
    /// an XPath attribute selector (e.g. `[@class='foo']` stays intact).
    private func splitXPathAndAccessor(_ rule: String) -> (xpath: String, accessor: String?) {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)

        // Walk to find `@` that is an accessor (outside brackets/quotes, at depth 0).
        var depth = 0
        var inSingle = false
        var inDouble = false
        var lastAtOutside: String.Index?

        for idx in trimmed.indices {
            let c = trimmed[idx]
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            if inSingle || inDouble { continue }
            if c == "[" || c == "(" { depth += 1 }
            else if c == "]" || c == ")" { depth -= 1 }
            else if c == "@" && depth == 0 { lastAtOutside = idx }
        }

        guard let atIdx = lastAtOutside else {
            return (trimmed, nil)
        }

        let prefix = String(trimmed[..<atIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = String(trimmed[trimmed.index(after: atIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty, !suffix.isEmpty else {
            return (trimmed, nil)
        }

        let lowered = suffix.lowercased()
        let knownAccessors: Set<String> = [
            "text", "alltext", "textnodes", "owntext",
            "html", "innerhtml", "outerhtml",
            "href", "src", "class", "id", "title", "alt", "value", "name", "type", "action"
        ]
        let isKnown = knownAccessors.contains(lowered) || lowered.hasPrefix("attr(")
        return isKnown ? (prefix, suffix) : (trimmed, nil)
    }

    // MARK: Union `|` splitting

    /// Split XPath by `|` while respecting brackets and quotes.
    private func splitUnion(_ xpath: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inSingle = false
        var inDouble = false

        for ch in xpath {
            if ch == "'" && !inDouble { inSingle.toggle() }
            else if ch == "\"" && !inSingle { inDouble.toggle() }

            if inSingle || inDouble {
                current.append(ch)
                continue
            }

            if ch == "[" || ch == "(" { depth += 1 }
            else if ch == "]" || ch == ")" { depth -= 1 }

            if ch == "|" && depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: Safe XPath wrapper

    /// Runs XPath on a Queryable, returning empty set on error.
    private func safeXPath(on queryable: Queryable, xpath: String) -> NodeSet {
        return queryable.xpath(xpath)
    }

    // MARK: Node value resolution

    /// Resolve the value of a matched XMLElement based on the accessor keyword.
    private func resolvedValue(from node: XMLElement, accessor: String, baseURL: String) -> String? {
        let lowered = accessor.lowercased()

        switch lowered {
        case "text":
            return nonEmpty(normalizeWhitespace(node.stringValue))

        case "alltext":
            return nonEmpty(normalizeWhitespace(node.stringValue))

        case "textnodes":
            let textNodes = node.childNodes(ofTypes: [.Text, .CDataSection])
            let combined = textNodes.map { normalizeWhitespace($0.stringValue) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            return nonEmpty(combined)

        case "owntext":
            let textNodes = node.childNodes(ofTypes: [.Text])
            let combined = textNodes.map { normalizeWhitespace($0.stringValue) }
                .filter { !$0.isEmpty }
                .joined()
            return nonEmpty(combined)

        case "html", "innerhtml":
            let inner = node.children.map { $0.rawXML }.joined()
            let trimmedInner = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            return nonEmpty(trimmedInner)

        case "outerhtml":
            return nonEmpty(node.rawXML.trimmingCharacters(in: .whitespacesAndNewlines))

        default:
            return resolveAttribute(node: node, accessor: accessor, baseURL: baseURL)
        }
    }

    /// Extract attribute value, resolving URLs for href/src/action.
    private func resolveAttribute(node: XMLElement, accessor: String, baseURL: String) -> String? {
        let attrName: String
        let lowered = accessor.lowercased()

        if lowered.hasPrefix("attr("), lowered.hasSuffix(")") {
            attrName = String(accessor.dropFirst(5).dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            attrName = accessor
        }
        guard !attrName.isEmpty else { return nil }

        let raw = (node.attr(attrName) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let attrLower = attrName.lowercased()
        if attrLower == "href" || attrLower == "src" || attrLower == "action" {
            return RuleEngine.resolveURL(raw, base: baseURL)
        }
        return raw
    }

    // MARK: Whitespace helpers

    /// Trim and collapse runs of whitespace into single spaces.
    private func normalizeWhitespace(_ str: String) -> String {
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
    }

    private func nonEmpty(_ str: String) -> String? {
        str.isEmpty ? nil : str
    }

    #endif // canImport(Fuzi)
}
