import Foundation
import SwiftSoup

// MARK: - Shared text-extraction helper

/// Convert a SwiftSoup Element to plain text preserving newlines at block-element
/// and <br> boundaries — matching Android Jsoup's text() semantics.
///
/// SwiftSoup's built-in `text()` inserts a **space** (not `\n`) at block boundaries,
/// which causes chapter paragraphs to be crammed into a single line.
func htmlElementToText(_ element: Element) -> String {
    // 使用 element.copy() 避免污染原始 DOM，操作 clone 來插入換行標記
    guard let cloned = element.copy() as? Element else {
        return (try? element.text()) ?? ""
    }
    let marker = "__YUEDU_LINE_BREAK__"
    let blockSel =
        "br,p,div,li,blockquote,section,article,dt,dd,figcaption,pre,header,footer,tr,h1,h2,h3,h4,h5,h6"
    if let nodes = try? cloned.select(blockSel).array() {
        for node in nodes { _ = try? node.appendText(marker) }
    }
    var text = (try? cloned.text()) ?? ""
    text = text.replacingOccurrences(of: marker, with: "\n")
    while text.contains("\n\n\n") {
        text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - CssExtractor — Full Legado CSS rule parity
//
// Rule format:  [@CSS:]<selector>[@accessor]
//   selector  — any standard CSS selector (SwiftSoup / Jsoup compatible)
//   accessor  — optional extraction suffix after the last `@`:
//       text, textNodes, ownText, html, outerHtml, all,
//       href, src, data-*, attr(name), or any attribute name.
//
// Examples:
//   @CSS:div.content > p@text        → select "div.content > p", get text
//   a.link@href                      → select "a.link", get href (resolved)
//   div.item                         → select elements (default: text)
//   div.body@all                     → outerHtml of ALL matches concatenated

struct CssExtractor: RuleExtractor {

    // MARK: - Known Legado accessor keywords

    private static let knownAccessors: Set<String> = [
        "text", "textnodes", "owntext",
        "html", "outerhtml", "all",
        "href", "src",
    ]

    // MARK: - RuleExtractor

    func canHandle(rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("@css:") { return true }
        if trimmed.contains("||") || trimmed.contains("&&") || trimmed.contains("%%") {
            return false
        }
        return looksLikeCssSelector(trimmed)
    }

    func extractList(from content: String, rule: String, baseURL: String) throws -> [String] {
        let normalizedRule = normalizeRule(rule)
        if normalizedRule.contains("@@") {
            return try extractChainedList(from: content, rule: normalizedRule, baseURL: baseURL)
        }
        let (selector, accessor) = splitSelectorAndAccessor(normalizedRule)
        guard !selector.isEmpty else { return [] }

        let document = try SwiftSoup.parse(content)
        let elements = try document.select(selector).array()

        // @all: concatenate outerHtml of ALL matches into a single result
        if let acc = accessor, acc.lowercased() == "all" {
            let combined = elements.compactMap { try? $0.outerHtml() }
                .joined(separator: "\n")
            return combined.isEmpty ? [] : [combined]
        }

        return elements.compactMap { element in
            resolvedValue(from: element, accessor: accessor, baseURL: baseURL)
        }
    }

    func extractValue(from content: String, rule: String, baseURL: String) throws -> String {
        let normalizedRule = normalizeRule(rule)
        if normalizedRule.contains("@@") {
            return try extractChainedList(from: content, rule: normalizedRule, baseURL: baseURL).first ?? ""
        }
        let (selector, accessor) = splitSelectorAndAccessor(normalizedRule)
        guard !selector.isEmpty else { return "" }

        let document = try SwiftSoup.parse(content)
        let elements = try document.select(selector).array()
        guard !elements.isEmpty else { return "" }

        // @all: concatenate outerHtml of ALL matches
        if let acc = accessor, acc.lowercased() == "all" {
            return elements.compactMap { try? $0.outerHtml() }
                .joined(separator: "\n")
        }

        guard let first = elements.first else { return "" }
        return resolvedValue(from: first, accessor: accessor, baseURL: baseURL) ?? ""
    }

    private func extractChainedList(from content: String, rule: String, baseURL: String) throws -> [String] {
        let steps = rule.components(separatedBy: "@@")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstStep = steps.first else { return [] }

        let document = try SwiftSoup.parse(content)
        var current = try document.select(firstStep).array()
        guard !current.isEmpty else { return [] }

        for step in steps.dropFirst().dropLast() {
            current = try current.flatMap { try $0.select(step).array() }
            if current.isEmpty { return [] }
        }

        let finalRule = steps.last ?? firstStep
        let (selector, accessor) = splitSelectorAndAccessor(finalRule)
        let elements: [Element]
        if steps.count == 1 {
            elements = current
        } else if selector.isEmpty {
            elements = current
        } else {
            elements = try current.flatMap { try $0.select(selector).array() }
        }

        if let acc = accessor, acc.lowercased() == "all" {
            let combined = elements.compactMap { try? $0.outerHtml() }
                .joined(separator: "\n")
            return combined.isEmpty ? [] : [combined]
        }

        return elements.compactMap { element in
            resolvedValue(from: element, accessor: accessor, baseURL: baseURL)
        }
    }

    // MARK: - Rule Normalization

    private func normalizeRule(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("@css:") {
            return String(trimmed.dropFirst(5))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    // MARK: - Selector / Accessor Splitting

    /// Split `selector@accessor` into (selector, accessor).
    /// The last `@` is treated as the separator only when the suffix
    /// is a known Legado accessor keyword or a plausible attribute name.
    private func splitSelectorAndAccessor(_ rule: String) -> (selector: String, accessor: String?) {
        guard let atIndex = rule.lastIndex(of: "@") else {
            return (rule, nil)
        }
        let selectorPart = String(rule[..<atIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let accessorPart = String(rule[rule.index(after: atIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !selectorPart.isEmpty, !accessorPart.isEmpty else {
            return (rule, nil)
        }

        let lowered = accessorPart.lowercased()
        let isKnown = Self.knownAccessors.contains(lowered)
            || lowered.hasPrefix("data-")
            || lowered.hasPrefix("attr(")
            || isPlainAttributeName(accessorPart)

        return isKnown ? (selectorPart, accessorPart) : (rule, nil)
    }

    /// Plain attribute names are simple identifiers (letters, digits, hyphens, underscores).
    private func isPlainAttributeName(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    // MARK: - CSS Selector Detection

    /// Heuristic: detect standard CSS selector syntax so `canHandle` works
    /// without the explicit `@CSS:` prefix. Only matches patterns that are
    /// clearly CSS and would NOT be handled by JsoupDefaultExtractor.
    private func looksLikeCssSelector(_ rule: String) -> Bool {
        let lowered = rule.lowercased()
        // Skip rules claimed by other extractors
        if lowered.hasPrefix("@") { return false }
        if lowered.hasPrefix("$.") || lowered.hasPrefix("$[") { return false }
        if lowered.hasPrefix("//") { return false }
        if lowered.hasPrefix("{") { return false }

        // CSS-specific patterns not used in Legado JSOUP Default syntax
        if rule.hasPrefix("#") { return true }              // #id
        if rule.hasPrefix("[") { return true }              // [attr=value]
        if rule.contains(">") { return true }               // child combinator
        if rule.contains(" + ") { return true }             // adjacent sibling
        if rule.contains(" ~ ") { return true }             // general sibling
        if rule.contains(":not(") { return true }           // :not() pseudo-class
        if rule.contains(":nth-") { return true }           // :nth-child / :nth-of-type
        if rule.contains(":first-") { return true }         // :first-child / :first-of-type
        if rule.contains(":last-") { return true }          // :last-child / :last-of-type
        if looksLikeTagQualifiedSelector(rule) { return true } // div.item / a.title

        return false
    }

    private func looksLikeTagQualifiedSelector(_ rule: String) -> Bool {
        let mainRule = rule.split(separator: "@", maxSplits: 1).first.map(String.init) ?? rule
        let trimmed = mainRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstDot = trimmed.firstIndex(where: { $0 == "." || $0 == "#" }) else {
            return false
        }
        let prefix = String(trimmed[..<firstDot]).lowercased()
        guard !["class", "id", "tag", "text", "children"].contains(prefix) else {
            return false
        }
        return !prefix.isEmpty && prefix.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    // MARK: - Value Resolution

    private func resolvedValue(from element: Element, accessor: String?, baseURL: String) -> String? {
        guard let accessor = accessor, !accessor.isEmpty else {
            return nilIfEmpty(htmlElementToText(element))
        }

        let lowered = accessor.lowercased()
        switch lowered {
        case "text":
            return nilIfEmpty(htmlElementToText(element))

        case "textnodes":
            return nilIfEmpty(textNodesContent(of: element))

        case "owntext":
            return nilIfEmpty(element.ownText())

        case "html":
            return nilIfEmpty(try? element.html())

        case "outerhtml":
            return nilIfEmpty(try? element.outerHtml())

        case "href":
            let raw = (try? element.attr("href")) ?? ""
            return nilIfEmpty(resolveURLIfNeeded(raw, attrName: "href", baseURL: baseURL))

        case "src":
            let raw = (try? element.attr("src")) ?? ""
            return nilIfEmpty(resolveURLIfNeeded(raw, attrName: "src", baseURL: baseURL))

        default:
            // attr(name) syntax
            if lowered.hasPrefix("attr("), lowered.hasSuffix(")") {
                let attrName = String(accessor.dropFirst(5).dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !attrName.isEmpty else { return nil }
                let raw = (try? element.attr(attrName)) ?? ""
                return nilIfEmpty(resolveURLIfNeeded(raw, attrName: attrName, baseURL: baseURL))
            }
            // Treat as arbitrary attribute name (covers data-* and others)
            let raw = (try? element.attr(accessor)) ?? ""
            return nilIfEmpty(resolveURLIfNeeded(raw, attrName: accessor, baseURL: baseURL))
        }
    }

    // MARK: - Text Nodes

    /// Returns only direct text nodes of the element (not from children),
    /// matching Legado's `textNodes` behavior.
    private func textNodesContent(of element: Element) -> String {
        let nodes = element.textNodes()
        return nodes
            .map { $0.getWholeText().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    // MARK: - URL Resolution

    private func resolveURLIfNeeded(_ value: String, attrName: String, baseURL: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let lowered = attrName.lowercased()
        if lowered == "href" || lowered == "src" {
            return RuleEngine.resolveURL(trimmed, base: baseURL)
        }
        return trimmed
    }

    // MARK: - Helpers

    private func nilIfEmpty(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
