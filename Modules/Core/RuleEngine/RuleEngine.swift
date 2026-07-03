import Foundation
import JavaScriptCore


// MARK: - Rule Engine (aligned with Legado https://github.com/gedoor/legado book source parsing)
// References app/model/analyzeRule/: AnalyzeRule, AnalyzeByJSoup, AnalyzeByXPath, AnalyzeByJSonPath, AnalyzeByRegex
//   "div.content"         → CSS selector, get innerText
//   "a.title@href"        → CSS selector + @href attribute
//   "@text"               → Get text from current node
//   "@href" / "@src"      → Get attribute value
//   "@attr(name)"         → Get any attribute
//   "@outerHtml"          → Get outer HTML (preserves tags)
//   "##pattern"           → Regex extract first capture group
//   "##pattern##replace"  → Regex replace
//   "@xpath://div[@class='x']" → XPath parsing
//   "@css:div.content"    → Explicit CSS selector
//   "@json:$.data.list"   → Explicit JSONPath

enum RuleEngine {

    // MARK: - Thread-safe Regex Cache
    //
    // NSRegularExpression initialization involves NFA compilation, which can cause
    // significant CPU spikes during batch chapter parsing (each capture group and
    // each replacement rule calls applyRegex / extractRegexAllInOneMatches).
    // NSCache is thread-safe and auto-evicts entries under memory pressure.
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    /// Get a compiled NSRegularExpression, preferring the cache.
    /// - Returns: Compiled instance, or nil if the pattern is invalid.
    static func cachedRegex(pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let cacheKey = "\(options.rawValue):\(pattern)" as NSString
        if let cached = regexCache.object(forKey: cacheKey) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache.setObject(regex, forKey: cacheKey)
        return regex
    }

    // MARK: - Bracket-aware Rule Splitting (Legado RuleAnalyzer.splitRule counterpart)

    /// Bracket-aware split: does not split inside `[...]` and `(...)`.
    /// Corresponds to Legado's RuleAnalyzer.splitRule("&&", "||", "%%")
    /// - Returns: (type, parts). type is the matched separator ("||"/"&&"/"%%" or "" for none), parts are the segments.
    static func splitRuleByOperators(_ rule: String) -> (type: String, parts: [String]) {
        // Scan by priority: check || first, then &&, then %% (consistent with Legado)
        for op in ["||", "&&", "%%"] {
            let parts = bracketAwareSplit(rule, separator: op)
            if parts.count > 1 {
                return (op, parts)
            }
        }
        return ("", [rule])
    }

    /// Perform a bracket-aware split using the given separator.
    static func bracketAwareSplit(_ rule: String, separator: String) -> [String] {
        guard !separator.isEmpty else { return [rule] }
        var parts: [String] = []
        var depth = 0 // Nesting depth for [] and ()
        var current = ""
        var i = rule.startIndex
        while i < rule.endIndex {
            let ch = rule[i]
            if ch == "[" || ch == "(" {
                depth += 1
                current.append(ch)
                i = rule.index(after: i)
            } else if ch == "]" || ch == ")" {
                depth = max(0, depth - 1)
                current.append(ch)
                i = rule.index(after: i)
            } else if depth == 0,
                      rule[i...].hasPrefix(separator) {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { parts.append(trimmed) }
                current = ""
                i = rule.index(i, offsetBy: separator.count)
            } else {
                current.append(ch)
                i = rule.index(after: i)
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { parts.append(trimmed) }
        return parts
    }

    // MARK: - Parser Router (auto-detect CSS / XPath / JSONPath)

    /// Route extraction to return a list: automatically selects the parsing strategy based on rule prefix.
    static func routeExtractList(content: String, baseURL: String, rule: String) -> [HTMLNode] {
        var trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Legado: @@ prefix means Default, strip it
        if trimmed.hasPrefix("@@") {
            trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        // Reverse syntax: leading `-` means reverse the result list (common Legado convention)
        var shouldReverse = false
        if trimmed.hasPrefix("-") {
            shouldReverse = true
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Bracket-aware split for ||, &&, %% (Legado RuleAnalyzer.splitRule counterpart)
        let (opType, opParts) = splitRuleByOperators(trimmed)
        if opParts.count > 1 {
            switch opType {
            case "||":
                for alt in opParts {
                    let nodes = routeExtractList(content: content, baseURL: baseURL, rule: alt)
                    if !nodes.isEmpty { return shouldReverse ? nodes.reversed() : nodes }
                }
                return []
            case "%%":
                let lists = opParts.map { routeExtractList(content: content, baseURL: baseURL, rule: $0) }
                guard lists.allSatisfy({ !$0.isEmpty }) else { return [] }
                var interleaved: [HTMLNode] = []
                var idx = 0
                while true {
                    var any = false
                    for list in lists where idx < list.count {
                        interleaved.append(list[idx])
                        any = true
                    }
                    if !any { break }
                    idx += 1
                }
                return shouldReverse ? interleaved.reversed() : interleaved
            case "&&":
                var merged: [HTMLNode] = []
                for part in opParts {
                    merged.append(contentsOf: routeExtractList(content: content, baseURL: baseURL, rule: part))
                }
                return shouldReverse ? merged.reversed() : merged
            default: break
            }
        }

        // JSON content → caller should use extractJSONArray directly
        if isJSON(content) { return [] }

        let nodes: [HTMLNode]

        // @xpath: prefix or // opening → XPath
        if trimmed.hasPrefix("@xpath:") || trimmed.hasPrefix("@XPath:") {
            nodes = extractListByXPath(html: content, xpath: String(trimmed.dropFirst(7)))
        } else if trimmed.hasPrefix("//") && !trimmed.hasPrefix("//@") {
            nodes = extractListByXPath(html: content, xpath: trimmed)
        } else if trimmed.hasPrefix("@css:") || trimmed.hasPrefix("@CSS:") {
            // @css: prefix → CSS
            nodes = extractList(html: content, baseURL: baseURL, rule: String(trimmed.dropFirst(5)))
        } else if isJsoupDefaultRule(trimmed) {
            // Legado JSOUP Default: class.xxx@tag.li, etc.
            nodes = extractListByJsoupDefault(html: content, baseURL: baseURL, rule: trimmed)
        } else {
            // Default → CSS
            nodes = extractList(html: content, baseURL: baseURL, rule: trimmed)
        }

        return shouldReverse ? nodes.reversed() : nodes
    }

    /// Route extraction to return a single value: automatically selects the parsing strategy based on rule prefix.
    static func routeExtractValue(content: String, baseURL: String, rule: String) -> String {
        var trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Legado: @@ prefix means Default, strip it
        if trimmed.hasPrefix("@@") {
            trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        // Bracket-aware split for ||, && (Legado RuleAnalyzer counterpart)
        let (opType, opParts) = splitRuleByOperators(trimmed)
        if opParts.count > 1 {
            switch opType {
            case "&&":
                let arr = opParts.compactMap { part -> String? in
                    let s = routeExtractValue(content: content, baseURL: baseURL, rule: part)
                    return s.isEmpty ? nil : s
                }
                return arr.joined(separator: "\n")
            case "||":
                for alt in opParts {
                    let s = routeExtractValue(content: content, baseURL: baseURL, rule: alt)
                    if !s.isEmpty { return s }
                }
                return ""
            default: break
            }
        }

        // JSON content → JSONPath
        if isJSON(content) {
            return extractValueFromJSON(content, rule: trimmed, baseURL: baseURL)
        }

        // @json: prefix (case-insensitive)
        if trimmed.lowercased().hasPrefix("@json:") {
            return extractValueFromJSON(
                content, rule: String(trimmed.dropFirst(6)), baseURL: baseURL)
        }

        // @xpath: prefix or // opening → XPath
        if trimmed.hasPrefix("@xpath:") || trimmed.hasPrefix("@XPath:") {
            return extractValueByXPath(
                html: content, xpath: String(trimmed.dropFirst(7)), baseURL: baseURL)
        }
        if trimmed.hasPrefix("//") && !trimmed.hasPrefix("//@") {
            return extractValueByXPath(html: content, xpath: trimmed, baseURL: baseURL)
        }

        // @css: prefix
        if trimmed.hasPrefix("@css:") || trimmed.hasPrefix("@CSS:") {
            return extractValue(
                fromHTML: content, rule: String(trimmed.dropFirst(5)), baseURL: baseURL)
        }

        // $.path → JSONPath
        if trimmed.hasPrefix("$.") {
            return extractValueFromJSON(content, rule: trimmed, baseURL: baseURL)
        }

        // Legado JSOUP Default
        if isJsoupDefaultRule(trimmed) {
            return extractValueByJsoupDefault(html: content, baseURL: baseURL, rule: trimmed)
        }

        // Default → CSS
        return extractValue(fromHTML: content, rule: trimmed, baseURL: baseURL)
    }

    /// Route extraction from a node (with context node).
    static func routeExtractValue(from node: HTMLNode, rule: String, baseURL: String) -> String {
        var trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return node.innerText }

        // Legado: @@ prefix means Default, strip it
        if trimmed.hasPrefix("@@") {
            trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        // Bracket-aware split for ||, &&
        let (opType, opParts) = splitRuleByOperators(trimmed)
        if opParts.count > 1 {
            switch opType {
            case "&&":
                let arr = opParts.compactMap { part -> String? in
                    let s = routeExtractValue(from: node, rule: part, baseURL: baseURL)
                    return s.isEmpty ? nil : s
                }
                return arr.joined(separator: "\n")
            case "||":
                for alt in opParts {
                    let s = routeExtractValue(from: node, rule: alt, baseURL: baseURL)
                    if !s.isEmpty { return s }
                }
                return ""
            default: break
            }
        }

        // @xpath: → XPath (re-parse from node's outerHTML)
        if trimmed.hasPrefix("@xpath:") || trimmed.hasPrefix("@XPath:") {
            let html = buildOuterHTML(node)
            return extractValueByXPath(
                html: html, xpath: String(trimmed.dropFirst(7)), baseURL: baseURL)
        }

        // @css: prefix
        if trimmed.hasPrefix("@css:") || trimmed.hasPrefix("@CSS:") {
            return extractValue(from: node, rule: String(trimmed.dropFirst(5)), baseURL: baseURL)
        }

        // Legado JSOUP Default (from current node downward)
        if isJsoupDefaultRule(trimmed) {
            return extractValueByJsoupDefault(from: node, rule: trimmed, baseURL: baseURL)
        }

        // Default → CSS
        return extractValue(from: node, rule: trimmed, baseURL: baseURL)
    }

    // MARK: - Legado JSOUP Default (type.name.index@type.name.index@content)

    /// Whether the rule uses JSOUP Default syntax: at least one segment is
    /// type.name or type.name.index (type = class/id/tag), or a plain tag name (e.g., dl@dt@a).
    static func isJsoupDefaultRule(_ rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("@css:")
            || lowered.hasPrefix("@xpath:")
            || lowered.hasPrefix("@json:")
            || lowered.hasPrefix("@js:")
        {
            return false
        }

        let segments = trimmed.components(separatedBy: "@")
        for seg in segments {
            let s = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            // Plain tag name (no dot) such as dl, dt, a → treat as JSOUP
            if !s.contains(".") && s.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return true
            }
            let parts = s.components(separatedBy: ".")
            guard parts.count >= 2 else { continue }
            let type = parts[0].lowercased()
            if type == "class" || type == "id" || type == "tag" || type == "text" || type == "children" {
                return true
            }
        }
        return false
    }

    /// Legado index spec: supports [0,2,-1] select, [!0,2] exclude, [0:2] range, tag.div.0 legacy index
    private enum JsoupIndexSpec {
        case none                                     // No filtering
        case select([Int])                            // [0,2,-1] select specific indices
        case exclude([Int])                           // [!0,2] exclude specific indices
        case range(start: Int?, end: Int?, step: Int) // [0:2] or [0:10:2] range
        case single(Int)                              // Legacy class.name.0
    }

    /// Parse a JSOUP segment: class.xxx / tag.li / text.next_page
    /// Full Legado index syntax: [0,2,-1], [!0,2], [0:2], [0:10:2], tag.div.0
    private static func parseJsoupSegment(_ segment: String) -> (css: String?, indexSpec: JsoupIndexSpec, text: String?, directChildren: Bool)? {
        var s = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Extract trailing [...] index first
        var indexSpec: JsoupIndexSpec = .none
        if s.hasSuffix("]"), let bracketStart = s.lastIndex(of: "[") {
            let inside = String(s[s.index(after: bracketStart)..<s.index(before: s.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            s = String(s[s.startIndex..<bracketStart]).trimmingCharacters(in: .whitespaces)
            indexSpec = parseIndexExpression(inside)
        }

        // Legado legacy exclude syntax: p!0, p!-1, p!0:-1 (tag name followed by ! and index)
        if case .none = indexSpec, let bangIdx = s.firstIndex(of: "!"), !s.hasPrefix("!") {
            let tagPart = String(s[s.startIndex..<bangIdx]).trimmingCharacters(in: .whitespaces)
            let idxPart = String(s[s.index(after: bangIdx)...]).trimmingCharacters(in: .whitespaces)
            if !tagPart.isEmpty, !idxPart.isEmpty {
                // Parse exclude index
                if idxPart.contains(":") {
                    // Range exclude p!0:-1
                    let colonParts = idxPart.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                    let start = colonParts.count > 0 && !colonParts[0].isEmpty ? Int(colonParts[0]) : nil
                    let end = colonParts.count > 1 && !colonParts[1].isEmpty ? Int(colonParts[1]) : nil
                    indexSpec = .range(start: start, end: end, step: 1)
                } else if idxPart.contains(",") {
                    let indices = idxPart.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    indexSpec = .exclude(indices)
                } else if let idx = Int(idxPart) {
                    indexSpec = .exclude([idx])
                }
                s = tagPart
            }
        }

        let parts = s.components(separatedBy: ".")
        // Single word without dots (dl, dt, a) → tag selector
        // Also supports CSS format: #id, .class (with prefix but no dot separator)
        if parts.count == 1 {
            let tag = s.lowercased()
            if tag.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return (tag, indexSpec, nil, false)
            }
            // #id format → CSS selector
            if s.hasPrefix("#") {
                return (s, indexSpec, nil, false)
            }
            return nil
        }

        let type = parts[0].lowercased()
        let name = parts[1]

        // Legacy Legado index: class.name.0 or class.name.0:2 (when there's no [] index)
        if case .none = indexSpec, parts.count >= 3 {
            let tail = parts[2...].joined(separator: ".")
            indexSpec = parseLegacyIndex(tail)
        }

        var css: String
        switch type {
        case "class":
            // Legado format class.name1 name2 means multiple classes (e.g., class.lb_mulu chapterList)
            // Must convert to CSS .name1.name2, not .name1 name2 (which would be a descendant selector)
            let classNames = name.components(separatedBy: " ").filter { !$0.isEmpty }
            css = classNames.map { "." + $0 }.joined()
        case "id":    css = "#" + name
        case "tag":   css = name.lowercased()
        case "text":  return (nil, indexSpec, name, false)
        case "children": return (nil, indexSpec, nil, true)
        case "":
            // .className format (split by "." gives empty parts[0]) → CSS class selector
            css = "." + name
        default:
            // Unknown type → try using the original segment as a CSS selector
            css = s
        }
        return (css, indexSpec, nil, false)
    }

    /// Parse the index expression inside [...].
    private static func parseIndexExpression(_ expr: String) -> JsoupIndexSpec {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .none }

        // [!...] exclude pattern
        if trimmed.hasPrefix("!") {
            let inner = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            let indices = inner.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return indices.isEmpty ? .none : .exclude(indices)
        }

        // Contains : → range pattern [start:end] or [start:end:step]
        if trimmed.contains(":") {
            let colonParts = trimmed.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            let start = colonParts.count > 0 && !colonParts[0].isEmpty ? Int(colonParts[0]) : nil
            let end = colonParts.count > 1 && !colonParts[1].isEmpty ? Int(colonParts[1]) : nil
            let step = colonParts.count > 2 && !colonParts[2].isEmpty ? (Int(colonParts[2]) ?? 1) : 1
            return .range(start: start, end: end, step: max(step, 1))
        }

        // Contains , → multi-index select [0,2,-1]
        if trimmed.contains(",") {
            let indices = trimmed.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return indices.isEmpty ? .none : .select(indices)
        }

        // Single number
        if let idx = Int(trimmed) {
            return .single(idx)
        }

        return .none
    }

    /// Parse legacy Legado index: .0 or .0:2 (numeric part after a dot)
    private static func parseLegacyIndex(_ tail: String) -> JsoupIndexSpec {
        // Range 0:2 or 0:10:2
        if tail.contains(":") {
            let colonParts = tail.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            let start = colonParts.count > 0 && !colonParts[0].isEmpty ? Int(colonParts[0]) : nil
            let end = colonParts.count > 1 && !colonParts[1].isEmpty ? Int(colonParts[1]) : nil
            let step = colonParts.count > 2 && !colonParts[2].isEmpty ? (Int(colonParts[2]) ?? 1) : 1
            return .range(start: start, end: end, step: max(step, 1))
        }
        // Exclude !0
        if tail.hasPrefix("!"), let idx = Int(String(tail.dropFirst())) {
            return .exclude([idx])
        }
        // Single index
        if let idx = Int(tail) {
            return .single(idx)
        }
        return .none
    }

    /// Filter candidate elements according to an index spec.
    private static func applyIndexSpec(_ spec: JsoupIndexSpec, to elements: [HTMLNode]) -> [HTMLNode] {
        let len = elements.count
        guard len > 0 else { return [] }
        switch spec {
        case .none:
            return elements
        case .single(let idx):
            let i = idx >= 0 ? idx : len + idx
            return (i >= 0 && i < len) ? [elements[i]] : []
        case .select(let indices):
            var result: [HTMLNode] = []
            var seen = Set<Int>()
            for idx in indices {
                let i = idx >= 0 ? idx : len + idx
                if i >= 0, i < len, !seen.contains(i) {
                    result.append(elements[i])
                    seen.insert(i)
                }
            }
            return result
        case .exclude(let indices):
            let normalized = Set(indices.map { $0 >= 0 ? $0 : len + $0 })
            return elements.enumerated().compactMap { normalized.contains($0.offset) ? nil : $0.element }
        case .range(let startOpt, let endOpt, let step):
            var start = startOpt ?? 0
            if start < 0 { start += len }
            var end = endOpt ?? (len - 1)
            if end < 0 { end += len }
            start = max(0, min(start, len - 1))
            end = max(0, min(end, len - 1))
            guard start <= end else {
                // Reverse range
                var result: [HTMLNode] = []
                var i = start
                while i >= end {
                    result.append(elements[i])
                    i -= step
                }
                return result
            }
            var result: [HTMLNode] = []
            var i = start
            while i <= end {
                result.append(elements[i])
                i += step
            }
            return result
        }
    }

    /// Whether a segment is a "content specifier": text, href, src, html, all, ownText, textNodes
    private static func isJsoupContentSpec(_ segment: String) -> Bool {
        let s = segment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "text" || s == "href" || s == "src" || s == "html" || s == "all"
            || s == "owntext" || s == "textnodes"
    }

    /// Apply one JSOUP segment to a node list, getting the next level of nodes (with full index filtering).
    static func applyJsoupSegment(nodes: [HTMLNode], segment: String) -> [HTMLNode] {
        guard let parsed = parseJsoupSegment(segment) else { return [] }
        var list: [HTMLNode] = []
        for node in nodes {
            let selected: [HTMLNode]
            if let css = parsed.css {
                selected = node.select(css)
            } else if parsed.directChildren {
                selected = node.elements
            } else if let text = parsed.text {
                selected = node.allDescendants.filter {
                    let haystack = ($0.directText.isEmpty ? $0.innerText : $0.directText)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return !haystack.isEmpty && haystack.contains(text)
                }
            } else {
                selected = []
            }
            list.append(contentsOf: applyIndexSpec(parsed.indexSpec, to: selected))
        }
        return list
    }

    /// Legado JSOUP Default list: class.update_con@tag.li → select .update_con first, then li within each
    static func extractListByJsoupDefault(html: String, baseURL: String, rule: String) -> [HTMLNode] {
        let (mainRule, _) = splitRuleAndRegex(rule)
        let segments = mainRule.components(separatedBy: "@")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return [] }
        let doc = parseHTML(html)
        var current: [HTMLNode] = [doc]
        for seg in segments {
            if isJsoupContentSpec(seg) {
                break
            }
            current = applyJsoupSegment(nodes: current, segment: seg)
        }
        let result = current
        Task { @MainActor in
            WebCrawlerDebugger.shared.logParse(rule: rule, matchCount: result.count, url: baseURL)
        }
        return result
    }

    /// Legado JSOUP Default single value (from HTML).
    static func extractValueByJsoupDefault(html: String, baseURL: String, rule: String) -> String {
        let (mainRule, regexParts) = splitRuleAndRegex(rule)
        let segments = mainRule.components(separatedBy: "@")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return "" }
        let doc = parseHTML(html)
        var current: [HTMLNode] = [doc]
        var contentSpec: String? = nil
        for seg in segments {
            if isJsoupContentSpec(seg) {
                contentSpec = seg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                break
            }
            current = applyJsoupSegment(nodes: current, segment: seg)
            if current.isEmpty { break }
        }
        guard let first = current.first else { return "" }
        // Legado behavior: if no contentSpec is specified and the target node is <a>, default to href
        let contentSpecFinal: String
        if let spec = contentSpec {
            contentSpecFinal = spec
        } else if first.tag.lowercased() == "a" && !first.attr("href").isEmpty {
            contentSpecFinal = "href"
        } else {
            contentSpecFinal = "text"
        }
        var value: String
        switch contentSpecFinal {
        case "href":  value = first.attr("href"); if !value.isEmpty { value = resolveURL(value, base: baseURL) }
        case "src":   value = first.attr("src");  if !value.isEmpty { value = resolveURL(value, base: baseURL) }
        case "html":  value = buildOuterHTML(first)
        case "all":   value = buildOuterHTML(first)
        case "owntext": value = first.directText
        case "textnodes": value = first.textNodesContent
        default:      value = cleanText(first.innerText)
        }
        value = applyRegex(to: value, parts: regexParts)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Legado JSOUP Default single value (from a node).
    static func extractValueByJsoupDefault(from node: HTMLNode, rule: String, baseURL: String) -> String {
        let (mainRule, regexParts) = splitRuleAndRegex(rule)
        let segments = mainRule.components(separatedBy: "@")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return node.innerText }
        var current: [HTMLNode] = [node]
        var contentSpec: String? = nil
        for seg in segments {
            if isJsoupContentSpec(seg) {
                contentSpec = seg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                break
            }
            current = applyJsoupSegment(nodes: current, segment: seg)
            if current.isEmpty { break }
        }
        guard let first = current.first else { return "" }
        // Legado behavior: if no contentSpec is specified and the target node is <a>, default to href
        let contentSpecFinal: String
        if let spec = contentSpec {
            contentSpecFinal = spec
        } else if first.tag.lowercased() == "a" && !first.attr("href").isEmpty {
            contentSpecFinal = "href"
        } else {
            contentSpecFinal = "text"
        }
        var value: String
        switch contentSpecFinal {
        case "href":  value = first.attr("href"); if !value.isEmpty { value = resolveURL(value, base: baseURL) }
        case "src":   value = first.attr("src");  if !value.isEmpty { value = resolveURL(value, base: baseURL) }
        case "html":  value = buildOuterHTML(first)
        case "all":   value = buildOuterHTML(first)
        case "owntext": value = first.directText
        case "textnodes": value = first.textNodesContent
        default:      value = cleanText(first.innerText)
        }
        value = applyRegex(to: value, parts: regexParts)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Extract node list from HTML (for bookList, chapterList)
    static func extractList(html: String, baseURL: String, rule: String) -> [HTMLNode] {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Split off CSS portion (list rules typically don't have regex post-processing)
        let (cssRule, _) = splitRuleAndRegex(trimmed)

        // Support Legado @@ multi-step selector: "A@@B" selects A first, then B from each result
        let steps = cssRule.components(separatedBy: "@@")
        guard let firstStep = steps.first else { return [] }
        let (firstSelector, _) = splitSelectorAndAttr(
            firstStep.trimmingCharacters(in: .whitespaces))
        guard !firstSelector.isEmpty else { return [] }

        let doc = parseHTML(html)
        var nodes = doc.select(firstSelector)
        for step in steps.dropFirst() {
            let (subSel, _) = splitSelectorAndAttr(step.trimmingCharacters(in: .whitespaces))
            guard !subSel.isEmpty else { continue }
            nodes = nodes.flatMap { $0.select(subSel) }
        }

        // --- Debug Hook: Parse Event ---
        Task { @MainActor in
            WebCrawlerDebugger.shared.logParse(rule: rule, matchCount: nodes.count, url: baseURL)
        }

        return nodes
    }

    // MARK: - Extract string value from a node
    static func extractValue(from node: HTMLNode, rule: String, baseURL: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return node.innerText }

        // Separate CSS selector + attribute extraction + regex post-processing
        let (cssAndAttr, regexParts) = splitRuleAndRegex(trimmed)
        let (selector, attrName) = splitSelectorAndAttr(cssAndAttr)

        // 1. Find target node via CSS selector (use current node if selector is empty)
        let targetNode: HTMLNode
        if selector.isEmpty {
            targetNode = node
        } else {
            guard let found = node.selectFirst(selector) else { return "" }
            targetNode = found
        }

        // 2. Extract attribute or text
        var value = extractAttr(from: targetNode, attr: attrName)

        // 3. URL resolution (for href/src types)
        if attrName == "href" || attrName == "src" || attrName.hasPrefix("data-") {
            if !value.isEmpty {
                value = resolveURL(value, base: baseURL)
            }
        }

        // 4. Regex post-processing
        value = applyRegex(to: value, parts: regexParts)

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Extract single value from HTML string (auto-parse HTML)
    static func extractValue(fromHTML html: String, rule: String, baseURL: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Legado JSOUP Default rules (e.g., class.read-content@text) are not valid CSS,
        // must be routed to the dedicated parser
        let (mainPart, _) = splitRuleAndRegex(trimmed)
        let (selectorPart, _) = splitSelectorAndAttr(mainPart)
        if isJsoupDefaultRule(selectorPart) {
            return extractValueByJsoupDefault(html: html, baseURL: baseURL, rule: trimmed)
        }

        let (cssAndAttr, regexParts) = splitRuleAndRegex(trimmed)
        let (selector, attrName) = splitSelectorAndAttr(cssAndAttr)

        let doc = parseHTML(html)
        let targetNode: HTMLNode
        if selector.isEmpty {
            targetNode = doc
        } else {
            guard let found = doc.selectFirst(selector) else {
                // Only fall back to raw HTML processing when ##regex is present; otherwise return empty
                guard !regexParts.isEmpty else { return "" }
                var raw = html
                raw = applyRegex(to: raw, parts: regexParts)
                return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            targetNode = found
        }

        var value = extractAttr(from: targetNode, attr: attrName)

        if attrName == "href" || attrName == "src" {
            value = resolveURL(value, base: baseURL)
        }

        value = applyRegex(to: value, parts: regexParts)
        let finalValue = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // --- Debug Hook: Parse Event ---
        Task { @MainActor in
            WebCrawlerDebugger.shared.logParse(
                rule: rule, matchCount: finalValue.isEmpty ? 0 : 1, url: baseURL)
        }

        return finalValue
    }

    static func extractContentValue(fromHTML html: String, rule: String, baseURL: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // For rules with @css: / @xpath: / @json: / || / && prefixes, route through the unified router
        if trimmed.hasPrefix("@css:") || trimmed.hasPrefix("@CSS:")
            || trimmed.hasPrefix("@xpath:") || trimmed.hasPrefix("@XPath:")
            || trimmed.hasPrefix("@json:") || trimmed.hasPrefix("@Json:")
            || trimmed.contains("||") || trimmed.contains("&&")
        {
            return routeExtractValue(content: html, baseURL: baseURL, rule: trimmed)
        }

        let (mainPart, _) = splitRuleAndRegex(trimmed)
        let (selectorPart, _) = splitSelectorAndAttr(mainPart)
        if isJsoupDefaultRule(selectorPart) {
            return extractJoinedValueByJsoupDefault(html: html, baseURL: baseURL, rule: trimmed)
        }

        let (cssAndAttr, regexParts) = splitRuleAndRegex(trimmed)
        let (selector, attrName) = splitSelectorAndAttr(cssAndAttr)
        let doc = parseHTML(html)
        let nodes: [HTMLNode]
        if selector.isEmpty {
            nodes = [doc]
        } else {
            nodes = doc.select(selector)
            if nodes.isEmpty {
                guard !regexParts.isEmpty else { return "" }
                return applyRegex(to: html, parts: regexParts).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let joined = joinNodeValues(nodes, attr: attrName, baseURL: baseURL)
        return applyRegex(to: joined, parts: regexParts).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractValueList(fromHTML html: String, rule: String, baseURL: String) -> [String] {
        var trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix("@@") {
            trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        let (opType, opParts) = splitRuleByOperators(trimmed)
        if opParts.count > 1 {
            switch opType {
            case "||":
                for alt in opParts {
                    let values = extractValueList(fromHTML: html, rule: alt, baseURL: baseURL)
                    if !values.isEmpty { return values }
                }
                return []
            case "&&":
                return opParts.flatMap { extractValueList(fromHTML: html, rule: $0, baseURL: baseURL) }
            case "%%":
                let lists = opParts.map { extractValueList(fromHTML: html, rule: $0, baseURL: baseURL) }
                guard lists.allSatisfy({ !$0.isEmpty }) else { return [] }
                var interleaved: [String] = []
                var idx = 0
                while true {
                    var any = false
                    for list in lists where idx < list.count {
                        interleaved.append(list[idx])
                        any = true
                    }
                    if !any { break }
                    idx += 1
                }
                return interleaved
            default: break
            }
        }

        if isJSON(html) {
            let values = extractJSONArray(jsonStr: html, rule: trimmed)
            if !values.isEmpty {
                return values.compactMap { value in
                    let text: String
                    if let string = value as? String {
                        text = string
                    } else if JSONSerialization.isValidJSONObject(value),
                        let data = try? JSONSerialization.data(withJSONObject: value),
                        let string = String(data: data, encoding: .utf8)
                    {
                        text = string
                    } else {
                        text = String(describing: value)
                    }
                    let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmedText.isEmpty ? nil : trimmedText
                }
            }
            let single = extractValueFromJSON(html, rule: trimmed, baseURL: baseURL)
            return single.isEmpty ? [] : [single]
        }

        if trimmed.hasPrefix("@xpath:") || trimmed.hasPrefix("@XPath:") {
            return extractValueListByXPath(
                html: html,
                xpath: String(trimmed.dropFirst(7)),
                baseURL: baseURL
            )
        }
        if trimmed.hasPrefix("//") && !trimmed.hasPrefix("//@") {
            return extractValueListByXPath(html: html, xpath: trimmed, baseURL: baseURL)
        }

        if trimmed.lowercased().hasPrefix("@css:") {
            trimmed = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let (mainPart, _) = splitRuleAndRegex(trimmed)
        let (selectorPart, _) = splitSelectorAndAttr(mainPart)
        if isJsoupDefaultRule(selectorPart) {
            return extractValueListByJsoupDefault(html: html, baseURL: baseURL, rule: trimmed)
        }

        let (cssAndAttr, regexParts) = splitRuleAndRegex(trimmed)
        let (selector, attrName) = splitSelectorAndAttr(cssAndAttr)
        let doc = parseHTML(html)
        let nodes = selector.isEmpty ? [doc] : doc.select(selector)
        return nodes.compactMap { node in
            var value = extractAttr(from: node, attr: attrName)
            if attrName == "href" || attrName == "src" || attrName.hasPrefix("data-") {
                value = resolveURL(value, base: baseURL)
            }
            value = applyRegex(to: value, parts: regexParts)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? nil : trimmedValue
        }
    }

    // MARK: - Extract attribute from node
    static func extractAttr(from node: HTMLNode, attr: String) -> String {
        switch attr.lowercased() {
        case "", "text", "innertext":
            return cleanText(node.innerText)
        case "href":
            return node.attr("href")
        case "src":
            return node.attr("src")
        case "outerhtml", "html", "all":
            return buildOuterHTML(node)
        case "owntext":
            return cleanText(node.directText)
        case "textnodes":
            return cleanText(node.textNodesContent)
        default:
            if attr.hasPrefix("attr(") && attr.hasSuffix(")") {
                let name = String(attr.dropFirst(5).dropLast(1))
                return node.attr(name)
            }
            return node.attr(attr)
        }
    }

    // MARK: - URL Resolution
    static func resolveURL(_ raw: String, base: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let optionRange = trimmed.range(
            of: #",\s*(\{[\s\S]*\}|%7B[\s\S]*%7D)\s*$"#,
            options: .regularExpression
        )
        let optionSuffix = optionRange.map { String(trimmed[$0]) } ?? ""
        let urlPart =
            optionRange.map { String(trimmed[..<$0.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? trimmed
        guard !urlPart.isEmpty else { return trimmed }
        if urlPart.hasPrefix("http://") || urlPart.hasPrefix("https://") {
            return urlPart + optionSuffix
        }
        guard let baseURL = URL(string: base) else { return trimmed }

        if urlPart.hasPrefix("//") {
            return (baseURL.scheme ?? "https") + ":" + urlPart + optionSuffix
        }
        if urlPart.hasPrefix("/") {
            let host = (baseURL.scheme ?? "https") + "://" + (baseURL.host ?? "")
            return host + urlPart + optionSuffix
        }
        // Relative path
        if let resolved = URL(string: urlPart, relativeTo: baseURL)?.absoluteString {
            return resolved + optionSuffix
        }
        return trimmed
    }

    /// Clean extracted URL: if it contains HTML tags (e.g., `<a href="...">Ch1</a>`),
    /// attempt to extract the href attribute. Also handles percent-encoded HTML.
    static func sanitizeExtractedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try percent-decode first, then check
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        let workingStr: String
        let needsDecode: Bool
        if decoded.contains("<") && decoded.contains(">") {
            workingStr = decoded
            needsDecode = true
        } else if trimmed.contains("<") && trimmed.contains(">") {
            workingStr = trimmed
            needsDecode = false
        } else {
            return trimmed
        }

        // Try extracting from href="..." or href='...'
        if let hrefRegex = cachedRegex(pattern: #"href\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive) {
            let nsRange = NSRange(workingStr.startIndex..., in: workingStr)
            if let match = hrefRegex.firstMatch(in: workingStr, range: nsRange),
               let urlRange = Range(match.range(at: 1), in: workingStr) {
                let extracted = String(workingStr[urlRange])
                // If the original URL had a base path, preserve it
                if needsDecode, let hrefStart = decoded.range(of: "<") {
                    let basePart = String(decoded[..<hrefStart.lowerBound])
                    if !basePart.isEmpty && extracted.hasPrefix("/") {
                        // href is a relative path, return as-is (resolveURL will handle it)
                        return extracted
                    }
                    if !basePart.isEmpty && !extracted.hasPrefix("http") {
                        return extracted
                    }
                }
                return extracted
            }
        }
        // Try extracting from src="..."
        if let srcRegex = cachedRegex(pattern: #"src\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive) {
            let nsRange = NSRange(workingStr.startIndex..., in: workingStr)
            if let match = srcRegex.firstMatch(in: workingStr, range: nsRange),
               let urlRange = Range(match.range(at: 1), in: workingStr) {
                return String(workingStr[urlRange])
            }
        }
        // Strip all HTML tags as a last resort
        let stripped = workingStr.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? trimmed : stripped
    }

    /// Legado Regex AllInOne: match regex against full text, return each match
    /// as [fullMatch, group1, group2, ...]
    static func extractRegexAllInOneMatches(html: String, pattern: String) -> [[String]] {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, let regex = cachedRegex(pattern: p) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)
        return matches.map { match in
            (0..<match.numberOfRanges).compactMap { i -> String? in
                guard let r = Range(match.range(at: i), in: html) else { return nil }
                return String(html[r])
            }
        }
    }

    /// Substitute $1, $2, ... in a template with groups[1], groups[2], ... (Legado TOC regex usage)
    static func substituteGroupRefs(template: String, groups: [String]) -> String {
        var s = template
        for i in 1..<groups.count {
            s = s.replacingOccurrences(of: "$\(i)", with: groups[i])
        }
        return s
    }

    // MARK: - XPath Parsing

    /// Extract node list from HTML via XPath.
    static func extractListByXPath(html: String, xpath: String) -> [HTMLNode] {
        let (xpathClean, _) = splitRuleAndRegex(xpath)
        let doc = parseHTML(html)
        return evaluateXPath(node: doc, xpath: xpathClean)
    }

    /// Extract single value from HTML via XPath.
    static func extractValueByXPath(html: String, xpath: String, baseURL: String) -> String {
        let (xpathClean, regexParts) = splitRuleAndRegex(xpath)
        let doc = parseHTML(html)

        let (pathPart, attrPart) = splitXPathAttr(xpathClean)
        let nodes = evaluateXPath(node: doc, xpath: pathPart)
        guard let first = nodes.first else {
            if !regexParts.isEmpty { return applyRegex(to: html, parts: regexParts) }
            return ""
        }

        var value = extractAttr(from: first, attr: attrPart)
        let lower = attrPart.lowercased()
        if lower == "href" || lower == "src" || lower.hasPrefix("data-") {
            value = resolveURL(value, base: baseURL)
        }
        value = applyRegex(to: value, parts: regexParts)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Simple XPath evaluation engine.
    /// Supports: /html/body/div, //div, //div[@class='x'], //div[@id='y'], /text(), /@attr, [n]
    static func evaluateXPath(node: HTMLNode, xpath: String) -> [HTMLNode] {
        let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [node] }

        let steps = parseXPathSteps(trimmed)
        var current: [HTMLNode] = [node]

        for step in steps {
            var next: [HTMLNode] = []
            for n in current {
                next.append(contentsOf: applyXPathStep(node: n, step: step))
            }
            current = next
        }
        return current
    }

    // MARK: - Private XPath Utilities

    private struct XPathStep {
        var axis: XPathAxis
        var tag: String
        var predicates: [XPathPredicate]
    }

    private enum XPathAxis {
        case child, descendantOrSelf
    }

    private struct XPathPredicate {
        var attrName: String
        var op: String
        var value: String
    }

    /// Parse an XPath string into a list of steps.
    private static func parseXPathSteps(_ xpath: String) -> [XPathStep] {
        var result: [XPathStep] = []
        var remaining = xpath

        while remaining.hasPrefix("/") { remaining = String(remaining.dropFirst()) }

        var parts: [(axis: XPathAxis, segment: String)] = []
        var current = ""
        var i = remaining.startIndex

        while i < remaining.endIndex {
            if remaining[i] == "/" {
                if !current.isEmpty {
                    parts.append((.child, current))
                    current = ""
                }
                let next = remaining.index(after: i)
                if next < remaining.endIndex && remaining[next] == "/" {
                    i = remaining.index(after: next)
                    var descSeg = ""
                    while i < remaining.endIndex && remaining[i] != "/" {
                        if remaining[i] == "[" {
                            descSeg.append(remaining[i])
                            i = remaining.index(after: i)
                            var depth = 1
                            while i < remaining.endIndex && depth > 0 {
                                if remaining[i] == "[" { depth += 1 }
                                if remaining[i] == "]" { depth -= 1 }
                                descSeg.append(remaining[i])
                                i = remaining.index(after: i)
                            }
                            continue
                        }
                        descSeg.append(remaining[i])
                        i = remaining.index(after: i)
                    }
                    if !descSeg.isEmpty { parts.append((.descendantOrSelf, descSeg)) }
                    continue
                }
                i = next
                continue
            }
            if remaining[i] == "[" {
                current.append(remaining[i])
                i = remaining.index(after: i)
                var depth = 1
                while i < remaining.endIndex && depth > 0 {
                    if remaining[i] == "[" { depth += 1 }
                    if remaining[i] == "]" { depth -= 1 }
                    current.append(remaining[i])
                    i = remaining.index(after: i)
                }
                continue
            }
            current.append(remaining[i])
            i = remaining.index(after: i)
        }
        if !current.isEmpty { parts.append((.child, current)) }

        if xpath.hasPrefix("//") && !parts.isEmpty {
            parts[0].axis = .descendantOrSelf
        }

        for part in parts {
            result.append(parseXPathSegment(part.segment, axis: part.axis))
        }
        return result
    }

    /// Parse a single XPath segment.
    private static func parseXPathSegment(_ segment: String, axis: XPathAxis) -> XPathStep {
        var tag = ""
        var predicates: [XPathPredicate] = []
        var rest = segment

        if let bracketIdx = rest.firstIndex(of: "[") {
            tag = String(rest[..<bracketIdx]).trimmingCharacters(in: .whitespaces)
            rest = String(rest[bracketIdx...])
        } else {
            tag = rest.trimmingCharacters(in: .whitespaces)
            rest = ""
        }

        while let lBracket = rest.firstIndex(of: "["),
            let rBracket = rest[lBracket...].firstIndex(of: "]")
        {
            let inside = String(rest[rest.index(after: lBracket)..<rBracket])
                .trimmingCharacters(in: .whitespaces)

            if inside.hasPrefix("@") {
                let attrExpr = String(inside.dropFirst())
                if let eqIdx = attrExpr.firstIndex(of: "=") {
                    let attrName = String(attrExpr[..<eqIdx]).trimmingCharacters(in: .whitespaces)
                    var attrVal = String(attrExpr[attrExpr.index(after: eqIdx)...])
                        .trimmingCharacters(in: .whitespaces)
                    if (attrVal.hasPrefix("'") && attrVal.hasSuffix("'"))
                        || (attrVal.hasPrefix("\"") && attrVal.hasSuffix("\""))
                    {
                        attrVal = String(attrVal.dropFirst().dropLast())
                    }
                    predicates.append(XPathPredicate(attrName: attrName, op: "=", value: attrVal))
                } else {
                    predicates.append(XPathPredicate(attrName: attrExpr, op: "exists", value: ""))
                }
            } else if let idx = Int(inside) {
                predicates.append(
                    XPathPredicate(attrName: "_position", op: "=", value: String(idx)))
            } else if inside.hasPrefix("contains(") {
                let inner = String(inside.dropFirst(9).dropLast(1))
                let cParts = inner.components(separatedBy: ",").map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"@"))
                }
                if cParts.count >= 2 {
                    predicates.append(
                        XPathPredicate(attrName: cParts[0], op: "contains", value: cParts[1]))
                }
            }
            rest = String(rest[rest.index(after: rBracket)...])
        }

        if tag.isEmpty { tag = "*" }
        return XPathStep(axis: axis, tag: tag.lowercased(), predicates: predicates)
    }

    /// Apply a single XPath step to a node.
    private static func applyXPathStep(node: HTMLNode, step: XPathStep) -> [HTMLNode] {
        let candidates: [HTMLNode] = step.axis == .child ? node.elements : node.allDescendants

        var matched = candidates.filter { n in
            step.tag == "*" || n.tag == step.tag
        }

        for pred in step.predicates {
            if pred.attrName == "_position" {
                if let pos = Int(pred.value), pos >= 1, pos <= matched.count {
                    matched = [matched[pos - 1]]
                } else {
                    matched = []
                }
            } else {
                matched = matched.filter { n in
                    let val = n.attr(pred.attrName)
                    switch pred.op {
                    case "=": return val == pred.value
                    case "exists": return !val.isEmpty
                    case "contains": return val.contains(pred.value)
                    default: return true
                    }
                }
            }
        }
        return matched
    }

    /// Split trailing attribute extraction from XPath (/text() or /@href)
    private static func splitXPathAttr(_ xpath: String) -> (String, String) {
        if xpath.hasSuffix("/text()") {
            return (String(xpath.dropLast(7)), "text")
        }
        if let lastSlash = xpath.lastIndex(of: "/"),
            lastSlash < xpath.endIndex
        {
            let afterSlash = String(xpath[xpath.index(after: lastSlash)...])
            if afterSlash.hasPrefix("@") {
                return (String(xpath[..<lastSlash]), String(afterSlash.dropFirst()))
            }
        }
        return (xpath, "text")
    }

    // MARK: - Private Utilities

    /// Separate "cssSelector@attr" from "##regex##replace" portions of a rule.
    private static func splitRuleAndRegex(_ rule: String) -> (String, [String]) {
        let parts = rule.components(separatedBy: "##")
        let cssAndAttr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let regexParts = Array(parts.dropFirst())
        return (cssAndAttr, regexParts)
    }

    /// Split "div.title@href" → ("div.title", "href")
    private static func splitSelectorAndAttr(_ s: String) -> (String, String) {
        // Split at the last @
        if let atRange = s.range(of: "@", options: .backwards) {
            let selector = String(s[s.startIndex..<atRange.lowerBound])
            let attr = String(s[atRange.upperBound...])
            return (selector.trimmingCharacters(in: .whitespacesAndNewlines), attr.lowercased())
        }
        return (s, "text")
    }

    /// Apply regex: ["pattern"] or ["pattern", "replacement"]
    private static func applyRegex(to text: String, parts: [String]) -> String {
        guard !parts.isEmpty else { return text }
        let pattern = parts[0]
        guard !pattern.isEmpty else { return text }

        if parts.count >= 2 {
            // Replacement mode
            let replacement = parts[1]
            if let regex = cachedRegex(pattern: pattern) {
                let range = NSRange(text.startIndex..., in: text)
                return regex.stringByReplacingMatches(
                    in: text, range: range, withTemplate: replacement)
            }
        } else {
            // Legado compatible: single ##pattern is removal mode (replace all with empty string)
            if let regex = cachedRegex(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            }
        }
        return text
    }

    /// Clean text: strip leading/trailing ASCII whitespace per line,
    /// but preserve fullwidth spaces (U+3000) for Japanese/Chinese indentation.
    private static func cleanText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line -> String in
                var s = line
                // Only strip ASCII whitespace (space/tab), leave fullwidth spaces alone
                while let f = s.first, f == " " || f == "\t" || f == "\r" { s.removeFirst() }
                while let l = s.last, l == " " || l == "\t" || l == "\r" { s.removeLast() }
                return s
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    /// Reconstruct outer HTML (simplified).
    static func buildOuterHTML(_ node: HTMLNode) -> String {
        if node.tag == "#text" { return node.rawText }
        var attrStr = node.attrs.map { key, val in "\(key)=\"\(val)\"" }.joined(separator: " ")
        if !attrStr.isEmpty { attrStr = " " + attrStr }
        let inner = node.children.map { buildOuterHTML($0) }.joined()
        return "<\(node.tag)\(attrStr)>\(inner)</\(node.tag)>"
    }

    private static func joinNodeValues(_ nodes: [HTMLNode], attr: String, baseURL: String) -> String {
        let lowered = attr.lowercased()
        let joiner = (lowered == "html" || lowered == "all" || lowered == "outerhtml") ? "\n" : "\n"
        return nodes.compactMap { node -> String? in
            var value = extractAttr(from: node, attr: attr)
            if lowered == "href" || lowered == "src" || lowered.hasPrefix("data-") {
                value = resolveURL(value, base: baseURL)
            }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: joiner)
    }

    private static func extractJoinedValueByJsoupDefault(html: String, baseURL: String, rule: String) -> String {
        let (mainRule, regexParts) = splitRuleAndRegex(rule)
        let segments = mainRule.components(separatedBy: "@")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return "" }
        let doc = parseHTML(html)
        var current: [HTMLNode] = [doc]
        var contentSpec: String? = nil
        for (_, seg) in segments.enumerated() {
            if isJsoupContentSpec(seg) {
                contentSpec = seg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                break
            }
            current = applyJsoupSegment(nodes: current, segment: seg)
            if current.isEmpty { break }
        }
        guard !current.isEmpty else { return "" }
        let value = joinNodeValues(current, attr: contentSpec ?? "text", baseURL: baseURL)
        return applyRegex(to: value, parts: regexParts).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractValueListByJsoupDefault(html: String, baseURL: String, rule: String) -> [String] {
        let (mainRule, regexParts) = splitRuleAndRegex(rule)
        let segments = mainRule.components(separatedBy: "@")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !segments.isEmpty else { return [] }
        let doc = parseHTML(html)
        var current: [HTMLNode] = [doc]
        var contentSpec: String? = nil
        for seg in segments {
            if isJsoupContentSpec(seg) {
                contentSpec = seg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                break
            }
            current = applyJsoupSegment(nodes: current, segment: seg)
            if current.isEmpty { break }
        }
        let attr = contentSpec ?? "text"
        return current.compactMap { node in
            var value = extractAttr(from: node, attr: attr)
            if attr == "href" || attr == "src" || attr.hasPrefix("data-") {
                value = resolveURL(value, base: baseURL)
            }
            value = applyRegex(to: value, parts: regexParts)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? nil : trimmedValue
        }
    }

    static func extractValueListByXPath(html: String, xpath: String, baseURL: String) -> [String] {
        let (xpathClean, regexParts) = splitRuleAndRegex(xpath)
        let doc = parseHTML(html)
        let (pathPart, attrPart) = splitXPathAttr(xpathClean)
        let nodes = evaluateXPath(node: doc, xpath: pathPart)
        return nodes.compactMap { node in
            var value = extractAttr(from: node, attr: attrPart)
            let lower = attrPart.lowercased()
            if lower == "href" || lower == "src" || lower.hasPrefix("data-") {
                value = resolveURL(value, base: baseURL)
            }
            value = applyRegex(to: value, parts: regexParts)
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedValue.isEmpty ? nil : trimmedValue
        }
    }

    // MARK: - JSON Support

    /// Detect whether a string is a JSON response.
    static func isJSON(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") || t.hasPrefix("[")
    }

    /// Extract a list from a JSON response (rule is a JSONPath, e.g., $.data.list).
    static func extractJSONArray(jsonStr: String, rule: String) -> [Any] {
        guard let data = jsonStr.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return (root as? [Any]) ?? [root]
        }
        let (pathPart, _) = splitRuleAndRegex(trimmed)
        let path = normalizeJSONPath(pathPart)
        if path.isEmpty {
            return (root as? [Any]) ?? [root]
        }
        let value = jsonGet(root, path: path)
        let result = value == nil ? [] : ((value as? [Any]) ?? [value!])

        // --- Debug Hook: Parse Event ---
        Task { @MainActor in
            WebCrawlerDebugger.shared.logParse(rule: rule, matchCount: result.count, url: "")
        }

        return result
    }

    /// Extract a string value from a JSON item (item is a single element from an array, or the root).
    static func extractJSONValue(fromJSON item: Any, rule: String, baseURL: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return jsonToString(item) }

        let (pathPart, regexParts) = splitRuleAndRegex(trimmed)
        let isRecursive = pathPart.hasPrefix("$..") || pathPart.hasPrefix("..")
        let path = normalizeJSONPath(pathPart)

        let raw: Any?
        if isRecursive && !path.isEmpty {
            let leafKey = path.components(separatedBy: ".").last ?? path
            // Legado $.. semantics: collect all matching values, join with newlines
            let allMatches = jsonSearchAll(item, key: leafKey)
            if allMatches.count > 1 {
                // Multiple results: convert each to string and join
                raw = allMatches.map { jsonToString($0) }.filter { !$0.isEmpty }.joined(separator: "\n") as Any
            } else {
                raw = allMatches.first
            }
        } else {
            raw = path.isEmpty ? item : jsonGet(item, path: path)
        }
        var value = jsonToString(raw)

        // Auto-resolve URL fields to absolute paths
        let lower = pathPart.lowercased()
        if lower.hasSuffix("url") || lower.hasSuffix("href") || lower.hasSuffix("link")
            || lower.hasSuffix("cover") || lower.hasSuffix("img")
        {
            if !value.isEmpty { value = resolveURL(value, base: baseURL) }
        }

        value = applyRegex(to: value, parts: regexParts)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Extract a single value from a JSON string response (when the entire response is JSON).
    static func extractValueFromJSON(_ jsonStr: String, rule: String, baseURL: String) -> String {
        guard let data = jsonStr.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else { return "" }
        return extractJSONValue(fromJSON: root, rule: rule, baseURL: baseURL)
    }

    // MARK: - Private JSON Utilities

    private static func normalizeJSONPath(_ rule: String) -> String {
        var path = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "$" { return "" }
        if path.hasPrefix("$.") {
            path = String(path.dropFirst(2))
        } else if path.hasPrefix("$") {
            path = String(path.dropFirst())
        } else if path.hasPrefix("@.") {
            path = String(path.dropFirst(2))
        } else if path.hasPrefix("@") {
            path = String(path.dropFirst())
        } else if path.hasPrefix(".") {
            path = String(path.dropFirst())
        }
        return path
    }

    /// Simplified JSONPath evaluation (supports .key, [idx], [*] wildcard).
    private static func jsonGet(_ root: Any, path: String) -> Any? {
        if path.isEmpty { return root }
        var frontier: [Any] = [root]
        for component in splitJSONPath(path) {
            var next: [Any] = []
            for current in frontier {
                if component == "*" || component == "[*]" {
                    if let arr = current as? [Any] {
                        next.append(contentsOf: arr)
                    } else if let dict = current as? [String: Any] {
                        next.append(contentsOf: dict.values)
                    } else {
                        next.append(current)
                    }
                    continue
                }

                if component.hasPrefix("[") && component.hasSuffix("]") {
                    let inner = String(component.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    if inner == "*" {
                        if let arr = current as? [Any] {
                            next.append(contentsOf: arr)
                        } else if let dict = current as? [String: Any] {
                            next.append(contentsOf: dict.values)
                        }
                    } else if let idx = Int(inner), let arr = current as? [Any] {
                        let i = idx >= 0 ? idx : arr.count + idx
                        if i >= 0, i < arr.count {
                            next.append(arr[i])
                        }
                    } else {
                        let key = inner.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                        if let dict = current as? [String: Any], let val = dict[key] {
                            next.append(val)
                        }
                    }
                    continue
                }

                if let dict = current as? [String: Any], let val = dict[component] {
                    next.append(val)
                } else if let arr = current as? [Any], let idx = Int(component) {
                    let i = idx >= 0 ? idx : arr.count + idx
                    if i >= 0, i < arr.count {
                        next.append(arr[i])
                    }
                }
            }
            frontier = next
            if frontier.isEmpty { return nil }
        }
        return frontier.count == 1 ? frontier[0] : frontier
    }

    /// Recursively search a JSON tree for the first value matching a given key (supports $.. recursive JSONPath).
    private static func jsonSearch(_ node: Any, key: String) -> Any? {
        if let dict = node as? [String: Any] {
            if let val = dict[key] { return val }
            for (_, child) in dict {
                if let found = jsonSearch(child, key: key) { return found }
            }
        } else if let arr = node as? [Any] {
            for item in arr {
                if let found = jsonSearch(item, key: key) { return found }
            }
        }
        return nil
    }

    /// Recursively search a JSON tree for all values matching a given key (Legado $.. semantics: collect all).
    private static func jsonSearchAll(_ node: Any, key: String) -> [Any] {
        var results: [Any] = []
        if let dict = node as? [String: Any] {
            if let val = dict[key] { results.append(val) }
            for (_, child) in dict {
                results.append(contentsOf: jsonSearchAll(child, key: key))
            }
        } else if let arr = node as? [Any] {
            for item in arr {
                results.append(contentsOf: jsonSearchAll(item, key: key))
            }
        }
        return results
    }

    /// Split a JSONPath (handles a.b[0].c format).
    private static func splitJSONPath(_ path: String) -> [String] {
        var components: [String] = []
        var current = ""
        var i = path.startIndex
        while i < path.endIndex {
            let ch = path[i]
            if ch == "." {
                if !current.isEmpty {
                    components.append(current)
                    current = ""
                }
                i = path.index(after: i)
            } else if ch == "[" {
                if !current.isEmpty {
                    components.append(current)
                    current = ""
                }
                var bracket = "["
                i = path.index(after: i)
                while i < path.endIndex && path[i] != "]" {
                    bracket.append(path[i])
                    i = path.index(after: i)
                }
                bracket.append("]")
                components.append(bracket)
                if i < path.endIndex { i = path.index(after: i) }
            } else {
                current.append(ch)
                i = path.index(after: i)
            }
        }
        if !current.isEmpty { components.append(current) }
        return components
    }

    private static func jsonToString(_ value: Any?) -> String {
        guard let value = value else { return "" }
        if let s = value as? String { return s }
        if value is NSNull { return "" }
        if let n = value as? NSNumber { return n.stringValue }
        if let data = try? JSONSerialization.data(withJSONObject: value),
            let s = String(data: data, encoding: .utf8)
        {
            return s
        }
        return ""
    }
}

// MARK: - Search URL Template Rendering
