import Foundation
import SwiftSoup
#if canImport(ReadiumFuzi)
import ReadiumFuzi
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

        #if canImport(ReadiumFuzi)
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

        #if canImport(ReadiumFuzi)
        guard let doc = parseHTMLContent(content) else {
            return fallbackExtract(content: content, rule: rule, baseURL: baseURL).first ?? ""
        }
        return extractString(from: doc, rule: normalizedRule, baseURL: baseURL) ?? ""
        #else
        return fallbackExtract(content: content, rule: rule, baseURL: baseURL).first ?? ""
        #endif
    }

    // MARK: - Rules read against a list item

    /// Legado's `AnalyzeByXPath(JXNode)`: a field rule reads a list item — the node an XPath
    /// (or jsoup) list selected — with the item as its context. In JsoupXpath a rule that
    /// starts with one `/` is relative to that node: 耽美小说's `/a//h4/text()`, 飘天文学's
    /// `/a/@href`, 拷贝漫画's `/text()`, an `<option>` list's `/@value`. libxml2 reads them from
    /// the document root, where they find nothing; here they become `./…`. A `//` rule
    /// searches the item's own subtree, as the item is all its document holds.
    func extractList(fromItem item: RuleHTMLElement, rule: String, baseURL: String) -> [String] {
        let normalizedRule = normalizeRule(rule)
        guard !normalizedRule.isEmpty else { return [] }
        #if canImport(ReadiumFuzi)
        guard let found = itemContext(item) else { return [] }
        let (document, context) = found
        return withExtendedLifetime(document) {
            extractStringList(from: context, rule: normalizedRule, baseURL: baseURL, relative: true)
        }
        #else
        return fallbackExtract(content: item.outerHTML, rule: rule, baseURL: baseURL)
        #endif
    }

    /// `extractValue` for a list item: see `extractList(fromItem:rule:baseURL:)`.
    func extractValue(fromItem item: RuleHTMLElement, rule: String, baseURL: String) -> String {
        let normalizedRule = normalizeRule(rule)
        guard !normalizedRule.isEmpty else { return "" }
        #if canImport(ReadiumFuzi)
        guard let found = itemContext(item) else { return "" }
        let (document, context) = found
        return withExtendedLifetime(document) {
            extractString(from: context, rule: normalizedRule, baseURL: baseURL, relative: true) ?? ""
        }
        #else
        return fallbackExtract(content: item.outerHTML, rule: rule, baseURL: baseURL).first ?? ""
        #endif
    }

    /// Legado `AnalyzeByXPath.getElements`: the nodes a list rule selects, for the field rules
    /// to read — an element as a `RuleHTMLElement`, as a jsoup list hands its items on. Before
    /// 11-07 a list was each node's *text*, so `a@href` after `//dd` had no element to read
    /// (笔趣阁 635: 0 chapters where the same page's CSS list gives 1104; YCK1330 11-06 §4).
    /// A text or attribute node (`//h2/a//text()`, `//a/@href`) stays its value.
    func extractElements(from content: Any, rule: String, baseURL: String) -> [Any] {
        let normalizedRule = normalizeRule(rule)
        guard !normalizedRule.isEmpty else { return [] }
        #if canImport(ReadiumFuzi)
        if let item = content as? RuleHTMLElement {
            guard let found = itemContext(item) else { return [] }
            let (document, context) = found
            return withExtendedLifetime(document) {
                extractItems(from: context, rule: normalizedRule, baseURL: baseURL, relative: true)
            }
        }
        let html = (content as? String) ?? "\(content)"
        guard let document = parseHTMLContent(html) else {
            return fallbackExtract(content: html, rule: rule, baseURL: baseURL)
        }
        return extractItems(from: document, rule: normalizedRule, baseURL: baseURL, relative: false)
        #else
        return fallbackExtract(content: "\(content)", rule: rule, baseURL: baseURL)
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

    #if canImport(ReadiumFuzi)

    // MARK: HTML parsing with fragment wrapping (matches Legado strToJXDocument)

    /// Legado's `strToJXDocument`: the content, its orphan table parts wrapped, as the tree
    /// jsoup builds — JsoupXpath reads `Jsoup.parse(html)`, or jsoup's XML parser for
    /// content that opens with `<?xml`. libxml2's HTML parser builds a different tree (no
    /// implied `<tbody>`), so `//table/tbody/tr/td/h1`, the path a browser shows, found
    /// nothing; SwiftSoup's HTML5 tree builder makes the tree, libxml2 runs the XPath on it.
    /// `fromJsoup`: markup that is already a jsoup element's (a list item), which needs no
    /// second tree build.
    private func parseHTMLContent(_ html: String, fromJsoup: Bool = false) -> XMLDocument? {
        XPathDocumentCache.current.document(for: html) { html in
            let wrapped = wrapHTMLFragment(html)
            let isXML = wrapped.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().hasPrefix("<?xml")
            do {
                if isXML {
                    let soup = try SwiftSoup.parse(wrapped, "", Parser.xmlParser())
                    soup.outputSettings().prettyPrint(pretty: false)
                    try Self.declareUTF8(soup)
                    return try XMLDocument(string: try soup.outerHtml(), encoding: .utf8)
                }
                if fromJsoup {
                    return try HTMLDocument(string: wrapped, encoding: .utf8)
                }
                let soup = try SwiftSoup.parse(wrapped)
                soup.outputSettings().prettyPrint(pretty: false)
                try Self.declareUTF8(soup)
                return try HTMLDocument(string: try soup.outerHtml(), encoding: .utf8)
            } catch {
                AppLogger.parse("XPath document did not parse", context: [
                    "bytes": "\(html.utf8.count)", "error": "\(error)",
                ], level: .warning)
                return nil
            }
        }
    }

    /// The page was decoded before it got here, and libxml2 reads it as UTF-8 — but ReadiumFuzi
    /// parses with no encoding of its own (`htmlReadMemory(…, nil, …)`), so libxml2 goes by the
    /// page's declaration and decodes the UTF-8 text again as the charset the page was served
    /// in. On a GBK page (`<meta charset="gbk">`) every XPath then found nothing: 男友书屋
    /// (YCK1329) read an empty chapter from a page that had it. The markup now says what it
    /// is, as jsoup's `Document.charset(UTF_8)` makes it say — the `<meta charset>` or the
    /// `<?xml … encoding?>` — and so does an older `http-equiv` Content-Type, which jsoup
    /// leaves alone and libxml2 also reads.
    private static func declareUTF8(_ soup: SwiftSoup.Document) throws {
        // SwiftSoup's XML branch reads the first child unguarded.
        guard !soup.getChildNodes().isEmpty else { return }
        try soup.charset(.utf8)
        for meta in try soup.select("meta[http-equiv]") {
            guard try meta.attr("http-equiv").caseInsensitiveCompare("content-type") == .orderedSame else { continue }
            try meta.attr("content", "text/html; charset=UTF-8")
        }
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
    private func extractStringList(
        from doc: Queryable, rule: String, baseURL: String, relative: Bool = false
    ) -> [String] {
        let analyzer = RuleAnalyzer(data: rule)
        let rules = analyzer.splitRule("&&", "||", "%%")

        if rules.count == 1 {
            return evaluateXPathForStrings(on: doc, xpath: rules[0], baseURL: baseURL, relative: relative)
        }

        // Legado's `getStringList` reads each piece by calling itself, so a piece splits again.
        var resultSets: [[String]] = []
        for rl in rules {
            let temp = extractStringList(from: doc, rule: rl, baseURL: baseURL, relative: relative)
            if !temp.isEmpty {
                resultSets.append(temp)
                if analyzer.elementsType == "||" { break }
            }
        }

        guard !resultSets.isEmpty else { return [] }

        if analyzer.elementsType == "%%" {
            return RuleSyntaxParser.interleaveByFirst(resultSets)
        }
        return resultSets.flatMap { $0 }
    }

    /// getString equivalent — joins results with newline, respects `||`/`&&`.
    private func extractString(
        from doc: Queryable, rule: String, baseURL: String, relative: Bool = false
    ) -> String? {
        let analyzer = RuleAnalyzer(data: rule)
        let rules = analyzer.splitRule("&&", "||")

        if rules.count == 1 {
            let results = evaluateXPathForStrings(on: doc, xpath: rules[0], baseURL: baseURL, relative: relative)
            return results.isEmpty ? nil : results.joined(separator: "\n")
        }

        var textList: [String] = []
        for rl in rules {
            let temp = extractString(from: doc, rule: rl, baseURL: baseURL, relative: relative)
            if let t = temp, !t.isEmpty {
                textList.append(t)
                if analyzer.elementsType == "||" { break }
            }
        }
        return textList.isEmpty ? nil : textList.joined(separator: "\n")
    }

    /// `extractStringList` for `getElements`: the same operators over nodes.
    private func extractItems(
        from doc: Queryable, rule: String, baseURL: String, relative: Bool
    ) -> [Any] {
        let analyzer = RuleAnalyzer(data: rule)
        let rules = analyzer.splitRule("&&", "||", "%%")
        if rules.count == 1 {
            return evaluateXPathForItems(on: doc, xpath: rules[0], baseURL: baseURL, relative: relative)
        }
        // Legado's `getElements` reads each piece by calling itself, so a piece splits again.
        var resultSets: [[Any]] = []
        for rl in rules {
            let temp = extractItems(from: doc, rule: rl, baseURL: baseURL, relative: relative)
            if !temp.isEmpty {
                resultSets.append(temp)
                if analyzer.elementsType == "||" { break }
            }
        }
        if analyzer.elementsType == "%%" {
            return RuleSyntaxParser.interleaveByFirst(resultSets)
        }
        return resultSets.flatMap { $0 }
    }

    /// One XPath (unions included) as list items: elements as `RuleHTMLElement`s, any other
    /// node as its text. A rule ending in an accessor lists its values.
    private func evaluateXPathForItems(
        on queryable: Queryable, xpath: String, baseURL: String, relative: Bool
    ) -> [Any] {
        let xpath = relative ? relativized(xpath) : xpath
        let (mainXPath, accessor) = splitXPathAndAccessor(xpath)
        guard accessor == nil else {
            return evaluateXPathForStrings(on: queryable, xpath: xpath, baseURL: baseURL)
        }
        var items: [Any] = []
        for part in splitUnion(mainXPath) {
            let trimmedPart = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPart.isEmpty else { continue }
            for node in safeXPath(on: queryable, xpath: trimmedPart) {
                if node.type == .Element, let element = Self.ruleElement(from: node, baseURL: baseURL) {
                    items.append(element)
                } else {
                    let text = normalizeWhitespace(node.stringValue)
                    if !text.isEmpty { items.append(text) }
                }
            }
        }
        return items
    }

    /// A node libxml2 selected, as the jsoup element the next rule reads. It is re-parsed from
    /// its markup — the two parsers share no tree — inside the parent a table part or an
    /// option needs, or the HTML parser drops it (the 全本小說網 `<tr>` loss).
    private static func ruleElement(from node: XMLElement, baseURL: String) -> RuleHTMLElement? {
        let tag = (node.tag ?? "").lowercased()
        let raw = node.rawXML
        let wrapped: String
        switch tag {
        case "tr": wrapped = "<table><tbody>\(raw)</tbody></table>"
        case "td", "th": wrapped = "<table><tbody><tr>\(raw)</tr></tbody></table>"
        case "tbody", "thead", "tfoot", "caption", "colgroup": wrapped = "<table>\(raw)</table>"
        case "option", "optgroup": wrapped = "<select>\(raw)</select>"
        default: wrapped = raw
        }
        do {
            let document = try SwiftSoup.parseBodyFragment(wrapped, baseURL)
            let element = Self.isPlainTagName(tag)
                ? try document.getElementsByTag(tag).first()
                : document.body()?.children().first()
            return element.map(RuleHTMLElement.init)
        } catch {
            AppLogger.parse("XPath list item did not re-parse", context: [
                "tag": tag, "error": "\(error)",
            ])
            return nil
        }
    }

    private static func isPlainTagName(_ tag: String) -> Bool {
        guard let first = tag.first, first.isLetter else { return false }
        return tag.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
    }

    /// The item's markup as a document, and the item's own node in it — the context its rules
    /// read from. The document owns the node, so callers keep it alive while they read.
    private func itemContext(_ item: RuleHTMLElement) -> (XMLDocument, Queryable)? {
        guard let document = parseHTMLContent(item.outerHTML, fromJsoup: true) else { return nil }
        let tag = item.element.tagName().lowercased()
        if Self.isPlainTagName(tag), let node = document.xpath("//\(tag)").first {
            return (document, node)
        }
        return (document, document)
    }

    /// Each union part of `xpath` that starts with a single `/` made relative (`./…`).
    private func relativized(_ xpath: String) -> String {
        splitUnion(xpath).map { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.hasPrefix("/") && !trimmed.hasPrefix("//") ? "." + trimmed : part
        }.joined(separator: "|")
    }

    /// Interleave arrays round-robin (Legado `%%` operator).
    // MARK: Single XPath evaluation (with union `|` support)

    /// Evaluate a single XPath expression that may contain union `|`.
    /// Splits on `|` outside brackets/quotes, evaluates each part, merges results.
    private func evaluateXPathForStrings(
        on queryable: Queryable, xpath: String, baseURL: String, relative: Bool = false
    ) -> [String] {
        let xpath = relative ? relativized(xpath) : xpath
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
                // No accessor: JsoupXpath's `JXNode.asString()`, which Legado's `getString` and
                // `getStringList` return — an element is its outer HTML (jsoup's
                // `Element.toString()`), a text or attribute node its text. 男友书屋's content
                // rule selects the chapter's `<div>` and nothing more; as text, its `<br>`
                // paragraphs ran together into one line.
                let nodes = safeXPath(on: queryable, xpath: trimmedPart)
                for node in nodes {
                    let str = node.type == .Element
                        ? node.rawXML.trimmingCharacters(in: .whitespacesAndNewlines)
                        : normalizeWhitespace(node.stringValue)
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
        if let attrRange = trimmed.range(of: #"/@[A-Za-z_][A-Za-z0-9_:-]*$"#, options: .regularExpression) {
            var path = String(trimmed[..<attrRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let attr = String(trimmed[attrRange].dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // `X//@attr` is the attribute of X and of every element under it: JsoupXpath 2.5.3
            // (the version Legado pins) answers `//@href` on a chapter-link row with that
            // link's own href, and `//li/a//@href` on an li row with its link's. Cutting
            // `/@attr` off leaves `X/`, which is the document root when X is empty —
            // 黑岩阅读's chapterUrl `//@href` read the root's href, which no root has.
            if path.hasSuffix("/") { path += "descendant-or-self::*" }
            if !path.isEmpty, !attr.isEmpty {
                return (path, attr)
            }
        }

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

        // As written, `href`/`src`/`action` included: Legado's `AnalyzeByXPath` returns the
        // attribute's own text, and only a URL read (`getString(isUrl = true)`) makes it
        // absolute, at the end of the whole rule — see `JsoupDefaultExtractor`'s attributes.
        let raw = (node.attr(attrName) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
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

    #endif // canImport(ReadiumFuzi)
}

#if canImport(ReadiumFuzi)
/// The last document XPath rules read on this thread. A detail page's field rules, or one
/// list item's, run back to back over the same markup, and each built its tree again —
/// now a SwiftSoup tree build and a libxml2 parse. Per thread and of capacity 1 for the
/// reasons `JsoupDocumentCache` gives: a libxml2 document is not shared across threads,
/// and the access pattern is consecutive.
private final class XPathDocumentCache {
    private static let threadDictionaryKey = "com.yuedu.xpathDocumentCache"

    static var current: XPathDocumentCache {
        let storage = Thread.current.threadDictionary
        if let existing = storage[threadDictionaryKey] as? XPathDocumentCache { return existing }
        let created = XPathDocumentCache()
        storage[threadDictionaryKey] = created
        return created
    }

    private var content: String?
    private var document: XMLDocument?

    func document(for content: String, build: (String) -> XMLDocument?) -> XMLDocument? {
        if let document, self.content == content { return document }
        let built = build(content)
        self.content = built == nil ? nil : content
        document = built
        return built
    }
}
#endif
