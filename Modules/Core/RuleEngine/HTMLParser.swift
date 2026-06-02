import Foundation

// MARK: - Lightweight HTML Parser (Pure Swift, No Dependencies)
// Supports CSS selectors: tag, .class, #id, [attr], descendant, direct child
// Supports pseudo-classes: :nth-child(n), :eq(n), :first-child, :last-child, :contains(text)

// MARK: HTML Node

final class HTMLNode {
    var tag: String           // Lowercase; "#text" for text nodes
    var attrs: [String: String]
    var children: [HTMLNode]
    weak var parent: HTMLNode?
    var rawText: String       // Valid only for text nodes

    init(tag: String, attrs: [String: String] = [:]) {
        self.tag = tag
        self.attrs = attrs
        self.children = []
        self.rawText = ""
    }

    // Direct child text (corresponds to Jsoup ownText)
    var directText: String {
        children.filter { $0.tag == "#text" }
            .map { $0.rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Direct child text, one text node per line (corresponds to Legado textNodes)
    var textNodesContent: String {
        children.filter { $0.tag == "#text" }
            .map { $0.rawText.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Recursively collect all text content
    var innerText: String {
        if tag == "#text" { return rawText }
        let parts = children.map { $0.innerText }.filter { !$0.isEmpty }
        return parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Retrieve an attribute value
    func attr(_ name: String) -> String {
        attrs[name.lowercased()] ?? ""
    }

    // CSS selector query (returns all matches)
    func select(_ css: String) -> [HTMLNode] {
        let selectors = parseSelectorList(css)
        var result: [HTMLNode] = []
        for sel in selectors {
            result.append(contentsOf: selectDescendants(sel))
        }
        var seen = Set<ObjectIdentifier>()
        return result.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    func selectFirst(_ css: String) -> HTMLNode? { select(css).first }

    var elements: [HTMLNode] { children.filter { $0.tag != "#text" } }
}

// MARK: - Selector Parsing

private struct AttrFilter {
    var name: String
    var op: String   // "=", "*=", "^=", "$=", "|=", "~=", "exists"
    var val: String
}

private struct SimpleSelector {
    var tag: String?
    var id: String?
    var classes: [String]
    var childOnly: Bool
    var attrFilters: [AttrFilter] = []
    // Pseudo-classes
    var nthChild: Int? = nil       // 1-indexed; -1 = last-child
    var containsText: String? = nil
}

private func parseSelectorList(_ css: String) -> [[SimpleSelector]] {
    splitTopLevel(css, by: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        .map { parseSelectorChain($0) }
}

/// Split by space / > without entering [] and () delimiters
private func parseSelectorChain(_ chain: String) -> [SimpleSelector] {
    var parts: [SimpleSelector] = []
    let tokens = splitTopLevel(chain, by: " ")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    var childOnly = false
    for token in tokens {
        if token == ">" { childOnly = true; continue }
        var sel = parseSingleSelector(token)
        sel.childOnly = childOnly
        parts.append(sel)
        childOnly = false
    }
    return parts
}

private func parseSingleSelector(_ token: String) -> SimpleSelector {
    var tag: String? = nil
    var id: String? = nil
    var classes: [String] = []
    var attrFilters: [AttrFilter] = []
    var nthChild: Int? = nil
    var containsText: String? = nil

    // 1. Extract [...] attribute selectors
    var cleanToken = ""
    var rest = token
    while let lbIdx = rest.firstIndex(of: "["),
          let rbIdx = rest[lbIdx...].firstIndex(of: "]") {
        cleanToken += rest[rest.startIndex..<lbIdx]
        let bracketContent = String(rest[rest.index(after: lbIdx)..<rbIdx])
        attrFilters.append(parseAttrFilter(bracketContent))
        rest = String(rest[rest.index(after: rbIdx)...])
    }
    cleanToken += rest

    // 2. Parse pseudo-classes (:nth-child / :eq / :first-child / :last-child / :contains / :not, etc.)
    while let colonIdx = cleanToken.firstIndex(of: ":") {
        let beforeColon = String(cleanToken[..<colonIdx])
        let afterColon  = String(cleanToken[cleanToken.index(after: colonIdx)...])

        var pseudoName = ""
        var pseudoArg  = ""
        var remainder  = ""

        if let parenOpen = afterColon.firstIndex(of: "(") {
            pseudoName = String(afterColon[..<parenOpen]).lowercased()
            let insideStart = afterColon.index(after: parenOpen)
            // Find matching closing paren with bracket depth tracking
            var depth = 1
            var scanIdx = insideStart
            while scanIdx < afterColon.endIndex {
                let c = afterColon[scanIdx]
                if c == "(" { depth += 1 }
                else if c == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                scanIdx = afterColon.index(after: scanIdx)
            }
            pseudoArg = String(afterColon[insideStart..<scanIdx])
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            let afterParen = scanIdx < afterColon.endIndex
                ? afterColon.index(after: scanIdx) : afterColon.endIndex
            remainder = String(afterColon[afterParen...])
        } else {
            // Pseudo-class without parentheses (:first-child, etc.)
            let nameEnd = afterColon.firstIndex(of: ":") ?? afterColon.endIndex
            pseudoName = String(afterColon[..<nameEnd]).lowercased()
            remainder  = nameEnd < afterColon.endIndex
                ? String(afterColon[afterColon.index(after: nameEnd)...]) : ""
        }

        cleanToken = beforeColon + (remainder.isEmpty ? "" : ":\(remainder)")

        switch pseudoName {
        case "nth-child", "nth-of-type":
            nthChild = Int(pseudoArg)
        case "eq":
            // Jsoup 0-indexed to 1-indexed
            if let n = Int(pseudoArg) { nthChild = n + 1 }
        case "first-child", "first-of-type":
            nthChild = 1
        case "last-child", "last-of-type":
            nthChild = -1
        case "contains", "has-text":
            containsText = pseudoArg
        case "not", "link", "hover", "focus", "active", "visited",
             "checked", "disabled", "enabled", "empty", "root":
            break  // Ignored pseudo-classes
        default:
            break
        }

        // Prevent infinite loop
        if cleanToken.firstIndex(of: ":") == colonIdx { cleanToken = beforeColon; break }
    }

    // 3. Parse tag / .class / #id
    var buf = ""
    var mode: Character = "t"

    func flush() {
        let s = buf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        switch mode {
        case "t": if s != "*" { tag = s.lowercased() }
        case "#": id = s
        case ".": classes.append(s)
        default: break
        }
        buf = ""
    }

    for ch in cleanToken {
        if ch == "#" || ch == "." { flush(); mode = ch }
        else { buf.append(ch) }
    }
    flush()

    return SimpleSelector(tag: tag, id: id, classes: classes, childOnly: false,
                          attrFilters: attrFilters, nthChild: nthChild, containsText: containsText)
}

private func parseAttrFilter(_ s: String) -> AttrFilter {
    let ops = ["*=", "^=", "$=", "|=", "~=", "="]
    for op in ops {
        if let r = s.range(of: op) {
            let name = String(s[..<r.lowerBound]).lowercased().trimmingCharacters(in: .whitespaces)
            var val  = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            if (val.hasPrefix("\"") && val.hasSuffix("\"")) ||
               (val.hasPrefix("'")  && val.hasSuffix("'")) {
                val = String(val.dropFirst().dropLast())
            }
            return AttrFilter(name: name, op: op, val: val)
        }
    }
    return AttrFilter(name: s.lowercased().trimmingCharacters(in: .whitespaces), op: "exists", val: "")
}

/// Split at the top level by a given separator (ignoring delimiters inside (), [])
private func splitTopLevel(_ s: String, by sep: Character) -> [String] {
    var result: [String] = []
    var buf = ""
    var depth = 0
    for ch in s {
        if ch == "(" || ch == "[" { depth += 1; buf.append(ch) }
        else if ch == ")" || ch == "]" { depth -= 1; buf.append(ch) }
        else if ch == sep && depth == 0 { result.append(buf); buf = "" }
        else { buf.append(ch) }
    }
    result.append(buf)
    return result
}

// MARK: - Selector Matching

extension HTMLNode {

    fileprivate func selectDescendants(_ chain: [SimpleSelector]) -> [HTMLNode] {
        guard !chain.isEmpty else { return [] }
        var results: [HTMLNode] = [self]
        for (i, sel) in chain.enumerated() {
            var next: [HTMLNode] = []
            for node in results {
                // Step 1: candidate set includes the node itself (consistent with Jsoup Element.select)
                // Subsequent steps only search descendants, no longer include self
                var candidates: [HTMLNode]
                if sel.childOnly {
                    candidates = node.elements
                } else if i == 0 {
                    candidates = [node] + node.allDescendants
                } else {
                    candidates = node.allDescendants
                }
                next.append(contentsOf: candidates.filter { matches($0, sel: sel) })
            }
            results = next
        }
        return results
    }

    var allDescendants: [HTMLNode] {
        var list: [HTMLNode] = []
        for child in children where child.tag != "#text" {
            list.append(child)
            list.append(contentsOf: child.allDescendants)
        }
        return list
    }
}

private func matches(_ node: HTMLNode, sel: SimpleSelector) -> Bool {
    if let tag = sel.tag, node.tag != tag { return false }
    if let id  = sel.id,  node.attr("id") != id { return false }
    if !sel.classes.isEmpty {
        let nodeClasses = node.attr("class")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        for cls in sel.classes {
            if !nodeClasses.contains(cls) { return false }
        }
    }
    for f in sel.attrFilters {
        let v = node.attr(f.name)
        switch f.op {
        case "exists": if v.isEmpty { return false }
        case "=":      if v != f.val { return false }
        case "*=":     if !v.contains(f.val) { return false }
        case "^=":     if !v.hasPrefix(f.val) { return false }
        case "$=":     if !v.hasSuffix(f.val) { return false }
        case "~=":     if !v.components(separatedBy: .whitespaces).contains(f.val) { return false }
        case "|=":     if v != f.val && !v.hasPrefix(f.val + "-") { return false }
        default:       if v != f.val { return false }
        }
    }
    // Pseudo-class: :nth-child / :first-child / :last-child
    if let nth = sel.nthChild {
        guard let parent = node.parent else { return false }
        let siblings = parent.elements
        if nth == -1 {
            if siblings.last !== node { return false }
        } else {
            let idx = nth - 1
            guard idx >= 0, idx < siblings.count, siblings[idx] === node else { return false }
        }
    }
    // Pseudo-class: :contains(text)
    if let text = sel.containsText, !text.isEmpty {
        if !node.innerText.localizedCaseInsensitiveContains(text) { return false }
    }
    return true
}

// MARK: - HTML Parser

private let voidTags: Set<String> = [
    "area","base","br","col","embed","hr","img","input","link","meta",
    "param","source","track","wbr","frame","keygen"
]

func parseHTML(_ html: String) -> HTMLNode {
    let root = HTMLNode(tag: "#document")
    var stack: [HTMLNode] = [root]

    var i = html.startIndex

    func current() -> HTMLNode { stack.last ?? root }

    func appendText(_ t: String) {
        let decoded = decodeHTMLEntities(t)
        // Preserve fullwidth spaces, strip \r\n only
        let trimmed = decoded.trimmingCharacters(in: CharacterSet.newlines)
        guard !trimmed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let node = HTMLNode(tag: "#text")
        node.rawText = trimmed
        node.parent = current()
        current().children.append(node)
    }

    while i < html.endIndex {
        if html[i] == "<" {
            let next = html.index(after: i)
            guard next < html.endIndex else { break }

            // Find tag close > (skipping quoted attribute values)
            guard let closeAngle = findTagClose(html, from: next) else { break }
            let tagContent = String(html[next..<closeAngle])

            // Skip HTML comments <!-- -->
            if tagContent.hasPrefix("!--") {
                if let commentEnd = html[i...].range(of: "-->") {
                    i = commentEnd.upperBound; continue
                }
            }

            let tagLower = tagContent.lowercased()
            if tagLower.hasPrefix("!") || tagLower.hasPrefix("?") {
                i = html.index(after: closeAngle); continue
            }

            if tagContent.hasPrefix("/") {
                let closingTag = String(tagContent.dropFirst())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                    .components(separatedBy: .whitespacesAndNewlines).first ?? ""
                if let idx = stack.indices.reversed().first(where: { stack[$0].tag == closingTag }) {
                    stack.removeSubrange(idx...)
                }
                i = html.index(after: closeAngle)
            } else {
                let selfClosing = tagContent.hasSuffix("/")
                let cleanContent = selfClosing ? String(tagContent.dropLast()) : tagContent
                let (tagName, attrs) = parseTagAttributes(cleanContent)
                let node = HTMLNode(tag: tagName, attrs: attrs)
                node.parent = current()
                current().children.append(node)

                if !selfClosing && !voidTags.contains(tagName) {
                    stack.append(node)
                }
                i = html.index(after: closeAngle)

                if tagName == "script" || tagName == "style" || tagName == "noscript" {
                    let endTag = "</\(tagName)"
                    if let endRange = html[i...].range(of: endTag, options: .caseInsensitive) {
                        i = endRange.lowerBound
                    }
                }
            }
        } else {
            guard let nextTag = html[i...].firstIndex(of: "<") else {
                appendText(String(html[i...])); break
            }
            appendText(String(html[i..<nextTag]))
            i = nextTag
        }
    }

    return root
}

/// Find the > closing position, skipping quoted values (prevents misparsing href="a>b")
private func findTagClose(_ html: String, from start: String.Index) -> String.Index? {
    var i = start
    var inQuote: Character? = nil
    while i < html.endIndex {
        let c = html[i]
        if let q = inQuote {
            if c == q { inQuote = nil }
        } else if c == "\"" || c == "'" {
            inQuote = c
        } else if c == ">" {
            return i
        }
        i = html.index(after: i)
    }
    return nil
}

// MARK: Parse Tag Attributes

private func parseTagAttributes(_ raw: String) -> (String, [String: String]) {
    var scanner = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    var attrs: [String: String] = [:]

    var tagName = ""
    var idx = scanner.startIndex
    while idx < scanner.endIndex && !scanner[idx].isWhitespace {
        tagName.append(scanner[idx])
        idx = scanner.index(after: idx)
    }
    let tag = tagName.lowercased()
    scanner = String(scanner[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)

    var pos = scanner.startIndex
    while pos < scanner.endIndex {
        while pos < scanner.endIndex && scanner[pos].isWhitespace { pos = scanner.index(after: pos) }
        guard pos < scanner.endIndex else { break }

        var attrName = ""
        while pos < scanner.endIndex && scanner[pos] != "=" && !scanner[pos].isWhitespace && scanner[pos] != "/" {
            attrName.append(scanner[pos])
            pos = scanner.index(after: pos)
        }
        attrName = attrName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attrName.isEmpty else { if pos < scanner.endIndex { pos = scanner.index(after: pos) }; continue }

        while pos < scanner.endIndex && scanner[pos].isWhitespace { pos = scanner.index(after: pos) }

        if pos < scanner.endIndex && scanner[pos] == "=" {
            pos = scanner.index(after: pos)
            while pos < scanner.endIndex && scanner[pos].isWhitespace { pos = scanner.index(after: pos) }

            var attrValue = ""
            if pos < scanner.endIndex && (scanner[pos] == "\"" || scanner[pos] == "'") {
                let quote = scanner[pos]
                pos = scanner.index(after: pos)
                while pos < scanner.endIndex && scanner[pos] != quote {
                    attrValue.append(scanner[pos])
                    pos = scanner.index(after: pos)
                }
                if pos < scanner.endIndex { pos = scanner.index(after: pos) }
            } else {
                while pos < scanner.endIndex && !scanner[pos].isWhitespace {
                    attrValue.append(scanner[pos])
                    pos = scanner.index(after: pos)
                }
            }
            attrs[attrName] = decodeHTMLEntities(attrValue)
        } else {
            attrs[attrName] = attrName
        }
    }

    return (tag, attrs)
}

// MARK: HTML Entity Decoding

private func decodeHTMLEntities(_ s: String) -> String {
    var result = s
    // Common named entities (includes &emsp; and &mdash; used in web novels)
    let entities: [(String, String)] = [
        ("&amp;",    "&"),
        ("&lt;",     "<"),
        ("&gt;",     ">"),
        ("&quot;",   "\""),
        ("&#39;",    "'"),
        ("&apos;",   "'"),
        ("&nbsp;",   "\u{00A0}"),
        ("&ensp;",   "\u{2002}"),   // EN SPACE
        ("&emsp;",   "\u{2003}"),   // EM SPACE (used for indentation in web novels)
        ("&thinsp;", "\u{2009}"),
        ("&mdash;",  "—"),
        ("&ndash;",  "–"),
        ("&hellip;", "…"),
        ("&ldquo;",  "\u{201C}"),
        ("&rdquo;",  "\u{201D}"),
        ("&lsquo;",  "\u{2018}"),
        ("&rsquo;",  "\u{2019}"),
        ("&middot;", "·"),
        ("&bull;",   "•"),
        ("&times;",  "×"),
        ("&divide;", "÷"),
        ("&laquo;",  "«"),
        ("&raquo;",  "»"),
        ("&copy;",   "©"),
        ("&reg;",    "®"),
        ("&trade;",  "™"),
        ("&deg;",    "°"),
        ("&plusmn;", "±"),
        ("&para;",   "¶"),
        ("&sect;",   "§"),
    ]
    for (entity, char) in entities {
        result = result.replacingOccurrences(of: entity, with: char, options: .caseInsensitive)
    }
    // Numeric entities &#123; or &#x7B;
    if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
        let ns = result as NSString
        let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let codeRange = Range(match.range(at: 1), in: result)
            else { continue }
            let code = String(result[codeRange])
            let codePoint: UInt32?
            if code.hasPrefix("x") || code.hasPrefix("X") {
                codePoint = UInt32(code.dropFirst(), radix: 16)
            } else {
                codePoint = UInt32(code)
            }
            if let cp = codePoint, let scalar = Unicode.Scalar(cp) {
                result.replaceSubrange(range, with: String(scalar))
            }
        }
    }
    return result
}
