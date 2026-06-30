import Foundation
import SwiftSoup

// MARK: - JsoupDefaultExtractor

/// Complete implementation of Legado's custom JSOUP-like syntax — the DEFAULT
/// extraction mode when no prefix is specified.
///
/// ## Syntax Overview
///
/// **Element selection** (steps chained with `@`):
/// - `class.className`  — select by class name
/// - `id.idName`        — select by ID
/// - `tag.tagName`      — select by tag
/// - `text.keyword`     — select elements containing text
/// - `children`         — get child elements
/// - bare `tagName`     — fallback to CSS select
///
/// **Index/filter** (appended to a step):
/// - `.0`, `.-1`             — legacy dot-index
/// - `!0:3`                  — legacy exclude-index
/// - `[0]`, `[-1]`           — bracket single index
/// - `[0,2,5]`               — bracket multiple indices
/// - `[!0]`, `[!0:3]`        — bracket exclude
/// - `[0:5]`, `[0:10:2]`     — bracket range (start:end:step)
///
/// **Attribute extraction** (last step after `@`):
/// - `text`, `textNodes`, `ownText`
/// - `html` / `innerHtml`, `outerHtml`, `all`
/// - any attribute name (e.g. `href`, `src`, `data-id`)
///
/// Reference: `io.legado.app.model.analyzeRule.AnalyzeByJSoup`
struct JsoupDefaultExtractor: RuleExtractor {

    // MARK: - RuleExtractor Protocol

    func canHandle(rule: String) -> Bool {
        let mainRule = rule.components(separatedBy: "##").first ?? rule
        return Self.isJsoupDefaultRule(mainRule.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func extractList(from content: String, rule: String, baseURL: String) throws -> [String] {
        guard !rule.isEmpty else { return [] }
        let doc = try SwiftSoup.parse(content, baseURL)
        if shouldExtractValuesForList(rule: rule) {
            return try getStringList(from: doc, rule: rule, baseURL: baseURL)
        }
        let elements = try getElements(from: doc, rule: rule)
        return try elements.array().compactMap { el in
            let html = try el.outerHtml()
            return html.isEmpty ? nil : html
        }
    }

    func extractValue(from content: String, rule: String, baseURL: String) throws -> String {
        guard !rule.isEmpty else { return "" }
        let doc = try SwiftSoup.parse(content, baseURL)
        let results = try getStringList(from: doc, rule: rule, baseURL: baseURL)
        if results.isEmpty { return "" }
        return results[0]
    }

    // MARK: - Rule Detection

    /// Determines whether a rule uses Legado's custom JSOUP-default syntax.
    static func isJsoupDefaultRule(_ rule: String) -> Bool {
        let stripped = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return false }

        let segments = stripped.components(separatedBy: "@")
        for seg in segments {
            let s = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }

            // Strip trailing bracket index like [0:5]
            let cleaned: String
            if let bracketStart = s.range(of: "[", options: .backwards), s.hasSuffix("]") {
                cleaned = String(s[..<bracketStart.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                cleaned = s
            }

            // Strip trailing dot-index / bang-index like .0, .-1:3, !0
            let noIndex = cleaned.replacingOccurrences(
                of: #"[.!](-?\d+)(:-?\d+)*$"#, with: "", options: .regularExpression
            )
            let check = noIndex.isEmpty ? cleaned : noIndex

            // Pure alphanumeric tag name (e.g. "div", "dt", "children", "text")
            if !check.contains(".") && !check.isEmpty
                && check.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return true
            }

            // type.name pattern
            let parts = check.components(separatedBy: ".")
            guard parts.count >= 2 else { continue }
            let type = parts[0].lowercased()
            if ["class", "id", "tag", "text", "children"].contains(type) {
                return true
            }
        }
        return false
    }

    // MARK: - Element Selection Pipeline

    /// Chain ALL rule steps as element selections. Used by `extractList`.
    private func getElements(from element: Element, rule: String) throws -> Elements {
        let analyzer = RuleAnalyzer(data: rule)
        analyzer.trim()
        let steps = analyzer.splitRule("@")

        if steps.count <= 1 {
            let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            return try getElementsSingle(from: element, rule: trimmed)
        }

        var current = [element]
        for step in steps {
            var next: [Element] = []
            for el in current {
                next.append(contentsOf: try getElementsSingle(from: el, rule: step).array())
            }
            current = next
        }

        let result = Elements()
        for el in current { result.add(el) }
        return result
    }

    /// Chain all-but-last steps as element selection, last step as attribute
    /// extraction. Used by `extractValue`.
    private func getStringList(
        from element: Element,
        rule: String,
        baseURL: String
    ) throws -> [String] {
        guard !rule.isEmpty else {
            let data = element.data()
            return data.isEmpty ? [] : [data]
        }

        let analyzer = RuleAnalyzer(data: rule)
        analyzer.trim()
        let steps = analyzer.splitRule("@")
        guard !steps.isEmpty else { return [] }

        var current = [element]
        let lastIndex = steps.count - 1

        for i in 0..<lastIndex {
            var next: [Element] = []
            for el in current {
                next.append(contentsOf: try getElementsSingle(from: el, rule: steps[i]).array())
            }
            current = next
        }

        // No element-selection steps and the last rule is a bare attribute (e.g. a
        // bookUrl rule of `href` where the list element already IS the `<a>`).
        // `extractValue` re-parsed that element's outerHtml into a synthetic
        // `<html><body>…</body></html>` document, so reading `href` off the
        // document root yields "". Descend to the fragment's single root element
        // so the attribute resolves against the original element — matching
        // Legado, which keeps the element instead of re-serialising it.
        // Content keywords (text/html/…) read from the subtree and already work
        // on the document wrapper, so they are intentionally left untouched.
        if lastIndex == 0, let document = element as? Document, let body = document.body() {
            let lastStep = steps[lastIndex].trimmingCharacters(in: .whitespaces).lowercased()
            let contentKeywords: Set<String> = [
                "text", "textnodes", "owntext", "html", "innerhtml", "outerhtml", "all",
            ]
            if !contentKeywords.contains(lastStep) {
                let roots = body.children().array()
                if roots.count == 1 {
                    current = roots
                }
            }
        }

        guard !current.isEmpty else { return [] }

        let elements = Elements()
        for el in current { elements.add(el) }
        return try getResultLast(from: elements, lastRule: steps[lastIndex], baseURL: baseURL)
    }

    // MARK: - Single-Step Element Selection (port of ElementsSingle)

    /// Process one rule step like `class.content`, `tag.div.0`, `tag.p[-1]`.
    private func getElementsSingle(from element: Element, rule: String) throws -> Elements {
        let parsed = Self.parseSingleRule(rule)

        var elements: [Element]

        if parsed.beforeRule.isEmpty {
            // Empty prefix or pure index → children
            elements = element.children().array()
        } else {
            let dotIdx = parsed.beforeRule.firstIndex(of: ".")
            let type: String
            let name: String

            if let di = dotIdx {
                type = String(parsed.beforeRule[..<di]).lowercased()
                name = String(parsed.beforeRule[parsed.beforeRule.index(after: di)...])
            } else {
                type = parsed.beforeRule.lowercased()
                name = ""
            }

            switch type {
            case "children":
                elements = element.children().array()
            case "class":
                if name.contains(" ") {
                    // Legado multi-class: `class.a b c` matches an element carrying
                    // ALL of classes a, b, c (e.g. yodu's `class.g_row lis-mn j_bookList`).
                    // SwiftSoup's getElementsByClass takes a single class name, so a
                    // space-joined name matches nothing — translate to a CSS compound
                    // selector `.a.b.c` instead.
                    let selector = "." + name
                        .split(separator: " ")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: ".")
                    elements = (try? element.select(selector).array()) ?? []
                } else {
                    elements = try element.getElementsByClass(name).array()
                }
            case "tag":
                elements = try element.getElementsByTag(name).array()
            case "id":
                if let found = try element.getElementById(name) {
                    elements = [found]
                } else {
                    elements = []
                }
            case "text":
                elements = try element.getElementsContainingOwnText(name).array()
            default:
                // Unrecognised prefix → treat whole string as CSS selector
                elements = try element.select(parsed.beforeRule).array()
            }
        }

        return Self.applyIndexFilter(parsed: parsed, to: elements)
    }

    // MARK: - Index Filtering

    /// Build a de-duplicated, ordered index set and apply select / exclude.
    ///
    /// Port of the index-resolution logic in `AnalyzeByJSoup.getElementsSingle`.
    static func applyIndexFilter(parsed: ParsedSingleRule, to elements: [Element]) -> Elements {
        let len = elements.count
        let result = Elements()
        guard len > 0 else { return result }

        // No filter requested
        if parsed.split == " " {
            for el in elements { result.add(el) }
            return result
        }

        // Resolve raw index descriptors → concrete, in-bounds indices
        var indexList: [Int] = []
        var seen = Set<Int>()

        /// Append `idx` if within bounds and not yet seen.
        func addResolved(_ raw: Int) {
            let resolved: Int
            if raw >= 0 && raw < len {
                resolved = raw
            } else if raw < 0 && len >= -raw {
                resolved = raw + len
            } else {
                return
            }
            if seen.insert(resolved).inserted {
                indexList.append(resolved)
            }
        }

        if parsed.indexes.isEmpty {
            // Legacy dot-notation — stored right-to-left, iterate backward
            for ix in stride(from: parsed.indexDefault.count - 1, through: 0, by: -1) {
                addResolved(parsed.indexDefault[ix])
            }
        } else {
            // Bracket notation — stored right-to-left, iterate backward
            for ix in stride(from: parsed.indexes.count - 1, through: 0, by: -1) {
                switch parsed.indexes[ix] {
                case .range(let startX, let endX, let stepX):
                    var s = startX ?? 0
                    if s < 0 { s += len }
                    var e = endX ?? (len - 1)
                    if e < 0 { e += len }

                    // Both endpoints out of bounds on the same side → skip
                    if (s < 0 && e < 0) || (s >= len && e >= len) { continue }

                    // Clamp to valid range
                    s = max(0, min(s, len - 1))
                    e = max(0, min(e, len - 1))

                    if s == e || stepX >= len {
                        if seen.insert(s).inserted { indexList.append(s) }
                        continue
                    }

                    let step: Int
                    if stepX > 0 {
                        step = stepX
                    } else if -stepX < len {
                        step = stepX + len
                    } else {
                        step = 1
                    }

                    if e > s {
                        var i = s
                        while i <= e {
                            if seen.insert(i).inserted { indexList.append(i) }
                            i += step
                        }
                    } else {
                        var i = s
                        while i >= e {
                            if seen.insert(i).inserted { indexList.append(i) }
                            i -= step
                        }
                    }

                case .single(let raw):
                    addResolved(raw)
                }
            }
        }

        // Apply select vs. exclude
        if parsed.split == "!" {
            let excludeSet = Set(indexList)
            for i in 0..<len where !excludeSet.contains(i) {
                result.add(elements[i])
            }
        } else {
            for idx in indexList {
                result.add(elements[idx])
            }
        }

        return result
    }

    // MARK: - Attribute Extraction

    /// Extract text / attribute from elements based on the last rule step.
    ///
    /// Port of `AnalyzeByJSoup.getResultLast`.
    private func getResultLast(
        from elements: Elements,
        lastRule: String,
        baseURL: String
    ) throws -> [String] {
        var results: [String] = []
        let rule = lastRule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = rule.lowercased()

        switch lowered {
        case "text":
            for element in elements.array() {
                let text = htmlElementToText(element)
                if !text.isEmpty { results.append(text) }
            }

        case "textnodes":
            for element in elements.array() {
                let texts = element.textNodes().compactMap { node -> String? in
                    let t = node.getWholeText().trimmingCharacters(in: .whitespaces)
                    return t.isEmpty ? nil : t
                }
                if !texts.isEmpty {
                    results.append(texts.joined(separator: "\n"))
                }
            }

        case "owntext":
            for element in elements.array() {
                let text = element.ownText()
                if !text.isEmpty { results.append(text) }
            }

        case "html", "innerhtml":
            // Matches Legado: strip scripts/styles then return outerHtml
            try elements.select("script").remove()
            try elements.select("style").remove()
            let html = try elements.outerHtml()
            if !html.isEmpty { results.append(html) }

        case "all":
            let html = try elements.outerHtml()
            results.append(html)

        case "outerhtml":
            for element in elements.array() {
                let html = try element.outerHtml()
                if !html.isEmpty { results.append(html) }
            }

        default:
            // Generic attribute extraction (href, src, data-*, etc.)
            for element in elements.array() {
                let value = try element.attr(rule)
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty || results.contains(trimmed) { continue }

                if lowered == "href" || lowered == "src" {
                    results.append(RuleEngine.resolveURL(trimmed, base: baseURL))
                } else {
                    results.append(trimmed)
                }
            }
        }

        return results
    }

    private func shouldExtractValuesForList(rule: String) -> Bool {
        let analyzer = RuleAnalyzer(data: rule)
        analyzer.trim()
        let steps = analyzer.splitRule("@")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let last = steps.last else { return false }
        let lowered = last.lowercased()
        return [
            "text", "textnodes", "owntext",
            "html", "innerhtml", "all", "outerhtml",
            "href", "src",
        ].contains(lowered)
        || lowered.hasPrefix("data-")
        || (lowered.hasPrefix("attr(") && lowered.hasSuffix(")"))
    }

    // MARK: - Rule Parsing Types

    /// Result of parsing a single rule step's index notation.
    struct ParsedSingleRule {
        var beforeRule: String = ""
        /// `.` = select, `!` = exclude, ` ` = no filter
        var split: Character = "."
        /// Legacy dot-notation indices (populated right-to-left).
        var indexDefault: [Int] = []
        /// Bracket-notation indices (populated right-to-left).
        var indexes: [IndexItem] = []

        enum IndexItem {
            case single(Int)
            case range(start: Int?, end: Int?, step: Int)
        }
    }

    // MARK: - Index Notation Parser

    /// Parse a single rule step, separating the element selector from index
    /// notation.
    ///
    /// Handles two formats:
    /// 1. **Bracket**: `tag.div[-1, 0:5:2]`
    /// 2. **Legacy**:  `tag.div.-1:10:2` or `tag.div!0:3`
    ///
    /// Faithful port of `AnalyzeByJSoup.ElementsSingle.findIndexSet()`.
    static func parseSingleRule(_ rule: String) -> ParsedSingleRule {
        var result = ParsedSingleRule()
        let chars = Array(rule.trimmingCharacters(in: .whitespaces))
        var len = chars.count
        var curMinus = false
        var numStr = ""
        var curList: [Int?] = []

        guard !chars.isEmpty else {
            result.split = " "
            return result
        }

        let isBracket = chars.last == "]"

        if isBracket {
            // ── Bracket notation: [index,...] ──
            len -= 1 // skip trailing ']'

            bracketLoop: while len > 0 {
                len -= 1
                let ch = chars[len]
                if ch == " " { continue }

                if ch >= "0" && ch <= "9" {
                    numStr = String(ch) + numStr
                } else if ch == "-" {
                    curMinus = true
                } else {
                    let curInt: Int?
                    if numStr.isEmpty {
                        curInt = nil
                    } else {
                        let n = Int(numStr) ?? 0
                        curInt = curMinus ? -n : n
                    }

                    switch ch {
                    case ":":
                        // Right end of a range or the step value
                        curList.append(curInt)

                    default:
                        // Finish one index entry
                        if curList.isEmpty {
                            guard let ci = curInt else {
                                // Not a valid index → break out
                                break bracketLoop
                            }
                            result.indexes.append(.single(ci))
                        } else {
                            // Build range Triple(start, end, step)
                            // curList was filled right-to-left:
                            //   1 item  → [end]           → step = 1
                            //   2 items → [step, end]     → step = curList[0]
                            let step = curList.count >= 2 ? (curList[0] ?? 1) : 1
                            let end = curList.last!
                            result.indexes.append(.range(start: curInt, end: end, step: step))
                            curList.removeAll()
                        }

                        if ch == "!" {
                            result.split = "!"
                            // Skip whitespace to reach '['
                            while len > 0 {
                                len -= 1
                                if chars[len] != " " { break }
                            }
                            if len >= 0 && chars[len] == "[" {
                                result.beforeRule = len > 0
                                    ? String(chars[0..<len])
                                    : ""
                                return result
                            }
                            // Malformed → fall through
                            break bracketLoop
                        }

                        if ch == "[" {
                            result.beforeRule = len > 0
                                ? String(chars[0..<len])
                                : ""
                            return result
                        }

                        if ch != "," {
                            break bracketLoop
                        }
                    }

                    numStr = ""
                    curMinus = false
                }
            }

        } else {
            // ── Legacy dot / bang notation ──
            legacyLoop: while len > 0 {
                len -= 1
                let ch = chars[len]
                if ch == " " { continue }

                if ch >= "0" && ch <= "9" {
                    numStr = String(ch) + numStr
                } else if ch == "-" {
                    curMinus = true
                } else {
                    if (ch == "!" || ch == "." || ch == ":") && !numStr.isEmpty {
                        let n = Int(numStr) ?? 0
                        result.indexDefault.append(curMinus ? -n : n)
                        if ch != ":" {
                            result.split = ch
                            result.beforeRule = String(chars[0..<len])
                            return result
                        }
                    } else {
                        break legacyLoop
                    }

                    numStr = ""
                    curMinus = false
                }
            }
        }

        // No valid index found — entire string is the selector
        result.split = " "
        result.beforeRule = String(chars)
        return result
    }
}
