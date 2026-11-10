import Foundation
import SwiftSoup

// MARK: - Shared text-extraction helper

/// Convert a SwiftSoup Element to plain text preserving newlines at block-element
/// and <br> boundaries — matching Android Jsoup's text() semantics.
///
/// SwiftSoup's built-in `text()` inserts a **space** (not `\n`) at block boundaries,
/// which causes chapter paragraphs to be crammed into a single line.
func htmlElementToText(_ element: Element) -> String {
    // Clone the element to avoid mutating the original DOM; insert line-break markers on the clone
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

    /// Only an `@CSS:` rule, as Legado's `AnalyzeByJSoup.SourceRule.isCss` decides. Every other
    /// HTML rule is default mode (`JsoupDefaultExtractor`), CSS selectors included: Legado hands
    /// a step it does not recognise to `select` after taking its `.N` / `!N` / `[…]` index off.
    /// Guessing CSS from the rule's shape sent `.txt-list li!0` (格格党, 森林文学 and the
    /// template they share, YCK1330 indices 142 and 170) to `select` with its `!0` still on.
    func canHandle(rule: String) -> Bool {
        rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("@css:")
    }

    func extractList(from content: String, rule: String, baseURL: String) throws -> [String] {
        let document = try JsoupDocumentCache.current.document(for: content, baseURL: "")
        return try extractList(from: document, rule: rule, baseURL: baseURL)
    }

    /// `AnalyzeByJSoup(element)`: the rule selects within `root` itself — the page's document,
    /// or an element an earlier rule step selected (`RuleHTMLElement`).
    func extractList(from root: Element, rule: String, baseURL: String) throws -> [String] {
        let normalizedRule = normalizeRule(rule)
        let (elements, accessor) = try selectedElements(from: root, rule: normalizedRule)

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

    /// The elements a list rule selects, for `getElements`, or nil when the rule ends in an
    /// accessor (`selector@href`): such a list is its values, read with `extractList`.
    func extractElements(from root: Element, rule: String) throws -> [Element]? {
        let (elements, accessor) = try selectedElements(from: root, rule: normalizeRule(rule))
        return accessor == nil ? elements : nil
    }

    /// Legado reads a CSS rule with `AnalyzeByJSoup.getString`: every value, joined with "\n".
    func extractValue(from content: String, rule: String, baseURL: String) throws -> String {
        try extractList(from: content, rule: rule, baseURL: baseURL).joined(separator: "\n")
    }

    /// The elements `rule` selects within `root` and the accessor its last step reads, if any.
    /// A `@@` rule chains selections: each step selects within the previous step's matches.
    private func selectedElements(from root: Element, rule: String) throws -> (elements: [Element], accessor: String?) {
        guard rule.contains("@@") else {
            let (selector, accessor) = splitSelectorAndAccessor(rule)
            guard !selector.isEmpty else { return ([], accessor) }
            return (try root.select(selector).array(), accessor)
        }
        let steps = rule.components(separatedBy: "@@")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let firstStep = steps.first else { return ([], nil) }

        var current = try root.select(firstStep).array()
        guard !current.isEmpty else { return ([], nil) }

        for step in steps.dropFirst().dropLast() {
            current = try current.flatMap { try $0.select(step).array() }
            if current.isEmpty { return ([], nil) }
        }

        let finalRule = steps.last ?? firstStep
        let (selector, accessor) = splitSelectorAndAccessor(finalRule)
        if steps.count == 1 || selector.isEmpty {
            return (current, accessor)
        }
        return (try current.flatMap { try $0.select(selector).array() }, accessor)
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

        default:
            // Any attribute, `href` and `src` included, as written — see `attributeValue`.
            // attr(name) syntax
            if lowered.hasPrefix("attr("), lowered.hasSuffix(")") {
                let attrName = String(accessor.dropFirst(5).dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !attrName.isEmpty else { return nil }
                return attributeValue(element, attrName)
            }
            // Treat as arbitrary attribute name (covers href, src, data-* and others)
            return attributeValue(element, accessor)
        }
    }

    /// An attribute as written, trimmed. Legado's `AnalyzeByJSoup` returns
    /// `element.attr(lastRule)`; only a URL read (`getString(isUrl = true)`) makes it absolute,
    /// at the end of the whole rule (legado-E, MD3, Sigma and upstream agree). Resolving here
    /// handed the absolute URL to a following `<js>` that prefixes the host itself — 瀚海书阁's
    /// `a@href` + `<js>'https://host' + result` fetched `https://hosthttps://host/…`.
    private func attributeValue(_ element: Element, _ name: String) -> String? {
        nilIfEmpty(((try? element.attr(name)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
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

    // MARK: - Helpers

    private func nilIfEmpty(_ s: String?) -> String? {
        guard let s = s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
