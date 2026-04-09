import Foundation
import JavaScriptCore
import SwiftUI  // withAnimation (SearchAggregator callers)

// MARK: - 規則引擎（對齊 Legado https://github.com/gedoor/legado 書源解析）
// 參考 app/model/analyzeRule/：AnalyzeRule, AnalyzeByJSoup, AnalyzeByXPath, AnalyzeByJSonPath, AnalyzeByRegex
//   "div.content"         → CSS 選擇器，取 innerText
//   "a.title@href"        → CSS 選擇器 + @href 屬性
//   "@text"               → 從當前節點取文字
//   "@href" / "@src"      → 取屬性
//   "@attr(name)"         → 取任意屬性
//   "@outerHtml"          → 取外層 HTML（保留標籤）
//   "##pattern"           → Regex 提取第一個捕獲組
//   "##pattern##replace"  → Regex 替換
//   "@xpath://div[@class='x']" → XPath 解析
//   "@css:div.content"    → 明確指定 CSS 選擇器
//   "@json:$.data.list"   → 明確指定 JSONPath

enum RuleEngine {

    // MARK: - 括號感知的規則分割（Legado RuleAnalyzer.splitRule 對應）

    /// 括號感知分割：在 `[...]` 和 `(...)` 內部不分割
    /// 對應 Legado 的 RuleAnalyzer.splitRule("&&", "||", "%%")
    /// - Returns: (type, parts)，type 是命中的分隔符（"||"/"&&"/"%%" 或 "" 表示無分隔），parts 是各段
    static func splitRuleByOperators(_ rule: String) -> (type: String, parts: [String]) {
        // 按優先級掃描：先找 ||，再找 &&，最後找 %%（與 Legado 一致）
        for op in ["||", "&&", "%%"] {
            let parts = bracketAwareSplit(rule, separator: op)
            if parts.count > 1 {
                return (op, parts)
            }
        }
        return ("", [rule])
    }

    /// 用指定分隔符做括號感知分割
    static func bracketAwareSplit(_ rule: String, separator: String) -> [String] {
        guard !separator.isEmpty else { return [rule] }
        var parts: [String] = []
        var depth = 0 // [] 和 () 的嵌套深度
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

    // MARK: - 解析器路由（自動偵測 CSS / XPath / JSONPath）

    /// 路由提取列表：根據規則前綴自動選擇解析策略
    static func routeExtractList(content: String, baseURL: String, rule: String) -> [HTMLNode] {
        var trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Legado：開頭 @@ 表示 Default，去掉 @@
        if trimmed.hasPrefix("@@") {
            trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        // 處理反轉語法：開頭 `-` 代表結果需要倒序（Legado 常見規範）
        var shouldReverse = false
        if trimmed.hasPrefix("-") {
            shouldReverse = true
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // 括號感知分割 ||、&&、%%（Legado RuleAnalyzer.splitRule 對應）
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

        // JSON 內容 → 外部直接呼叫 extractJSONArray
        if isJSON(content) { return [] }

        let nodes: [HTMLNode]

        // @xpath: 前綴 或 // 開頭 → XPath
        if trimmed.hasPrefix("@xpath:") || trimmed.hasPrefix("@XPath:") {
            nodes = extractListByXPath(html: content, xpath: String(trimmed.dropFirst(7)))
        } else if trimmed.hasPrefix("//") && !trimmed.hasPrefix("//@") {
            nodes = extractListByXPath(html: content, xpath: trimmed)
        } else if trimmed.hasPrefix("@css:") || trimmed.hasPrefix("@CSS:") {
            // @css: 前綴 → CSS
            nodes = extractList(html: content, baseURL: baseURL, rule: String(trimmed.dropFirst(5)))
        } else if isJsoupDefaultRule(trimmed) {
            // Legado JSOUP Default：class.xxx@tag.li 等
            nodes = extractListByJsoupDefault(html: content, baseURL: baseURL, rule: trimmed)
        } else {
            // 預設 → CSS
            nodes = extractList(html: content, baseURL: baseURL, rule: trimmed)
        }

        return shouldReverse ? nodes.reversed() : nodes
    }

    /// 路由提取值：根據規則前綴自動選擇解析策略
    static func routeExtractValue(content: String, baseURL: String, rule: String) -> String {
        var trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Legado：開頭 @@ 表示 Default，去掉 @@
        if trimmed.hasPrefix("@@") {
            trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        // 括號感知分割 ||、&&（Legado RuleAnalyzer 對應）
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

        // JSON 內容 → JSONPath
        if isJSON(content) {
            return extractValueFromJSON(content, rule: trimmed, baseURL: baseURL)
        }

        // @json: 前綴（不區分大小寫）
        if trimmed.lowercased().hasPrefix("@json:") {
            return extractValueFromJSON(
                content, rule: String(trimmed.dropFirst(6)), baseURL: baseURL)
        }

        // @xpath: 前綴 或 // 開頭 → XPath
        if trimmed.hasPrefix("@xpath:") || trimmed.hasPrefix("@XPath:") {
            return extractValueByXPath(
                html: content, xpath: String(trimmed.dropFirst(7)), baseURL: baseURL)
        }
        if trimmed.hasPrefix("//") && !trimmed.hasPrefix("//@") {
            return extractValueByXPath(html: content, xpath: trimmed, baseURL: baseURL)
        }

        // @css: 前綴
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

        // 預設 → CSS
        return extractValue(fromHTML: content, rule: trimmed, baseURL: baseURL)
    }

    /// 從節點路由提取（帶上下文節點）
    static func routeExtractValue(from node: HTMLNode, rule: String, baseURL: String) -> String {
        var trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return node.innerText }

        // Legado：開頭 @@ 去掉
        if trimmed.hasPrefix("@@") {
            trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        // 括號感知分割 ||、&&
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

        // @xpath: → XPath（從節點的 outerHTML 重新解析）
        if trimmed.hasPrefix("@xpath:") || trimmed.hasPrefix("@XPath:") {
            let html = buildOuterHTML(node)
            return extractValueByXPath(
                html: html, xpath: String(trimmed.dropFirst(7)), baseURL: baseURL)
        }

        // @css: 前綴
        if trimmed.hasPrefix("@css:") || trimmed.hasPrefix("@CSS:") {
            return extractValue(from: node, rule: String(trimmed.dropFirst(5)), baseURL: baseURL)
        }

        // Legado JSOUP Default（從當前節點往下）
        if isJsoupDefaultRule(trimmed) {
            return extractValueByJsoupDefault(from: node, rule: trimmed, baseURL: baseURL)
        }

        // 預設 → CSS
        return extractValue(from: node, rule: trimmed, baseURL: baseURL)
    }

    // MARK: - Legado JSOUP Default（type.name.index@type.name.index@content）

    /// 是否為 JSOUP Default 規則：至少一段為 type.name 或 type.name.index（type = class/id/tag），或純標籤名（如 dl@dt@a）
    static func isJsoupDefaultRule(_ rule: String) -> Bool {
        let segments = rule.components(separatedBy: "@")
        for seg in segments {
            let s = seg.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            // 純標籤名（無點號）如 dl, dt, a → 視為 JSOUP
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

    /// Legado 索引描述：支持 [0,2,-1] 選擇、[!0,2] 排除、[0:2] 範圍、tag.div.0 舊式索引
    private enum JsoupIndexSpec {
        case none                                     // 不篩選
        case select([Int])                            // [0,2,-1] 選擇指定索引
        case exclude([Int])                           // [!0,2] 排除指定索引
        case range(start: Int?, end: Int?, step: Int) // [0:2] 或 [0:10:2] 範圍
        case single(Int)                              // 舊式 class.name.0
    }

    /// 解析 JSOUP 段：class.xxx / tag.li / text.下一页
    /// 完整 Legado 索引語法：[0,2,-1]、[!0,2]、[0:2]、[0:10:2]、tag.div.0
    private static func parseJsoupSegment(_ segment: String) -> (css: String?, indexSpec: JsoupIndexSpec, text: String?, directChildren: Bool)? {
        var s = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 先提取尾部 [...] 索引
        var indexSpec: JsoupIndexSpec = .none
        if s.hasSuffix("]"), let bracketStart = s.lastIndex(of: "[") {
            let inside = String(s[s.index(after: bracketStart)..<s.index(before: s.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            s = String(s[s.startIndex..<bracketStart]).trimmingCharacters(in: .whitespaces)
            indexSpec = parseIndexExpression(inside)
        }

        // Legado 舊式排除語法：p!0、p!-1、p!0:-1（tag 名後直接跟 ! 和索引）
        if case .none = indexSpec, let bangIdx = s.firstIndex(of: "!"), !s.hasPrefix("!") {
            let tagPart = String(s[s.startIndex..<bangIdx]).trimmingCharacters(in: .whitespaces)
            let idxPart = String(s[s.index(after: bangIdx)...]).trimmingCharacters(in: .whitespaces)
            if !tagPart.isEmpty, !idxPart.isEmpty {
                // 解析排除索引
                if idxPart.contains(":") {
                    // 範圍排除 p!0:-1
                    let colonParts = idxPart.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                    let start = colonParts.count > 0 && !colonParts[0].isEmpty ? Int(colonParts[0]) : nil
                    let end = colonParts.count > 1 && !colonParts[1].isEmpty ? Int(colonParts[1]) : nil
                    indexSpec = .range(start: start, end: end, step: 1)
                    // 注意：Legado 中 p!0:-1 是「排除索引 0 到 -1」，用 exclude 更準確
                    // 但實際使用中 p!0 更常見，range 在此只做兼容
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
        // 無點號的單詞（dl, dt, a）→ tag 選擇器
        // 也支持 CSS 格式：#id、.class（無點號分隔但有前綴）
        if parts.count == 1 {
            let tag = s.lowercased()
            if tag.allSatisfy({ $0.isLetter || $0.isNumber }) {
                return (tag, indexSpec, nil, false)
            }
            // #id 格式 → CSS 選擇器
            if s.hasPrefix("#") {
                return (s, indexSpec, nil, false)
            }
            return nil
        }

        let type = parts[0].lowercased()
        let name = parts[1]

        // 舊式 Legado 索引：class.name.0 或 class.name.0:2（如果沒有 [] 索引）
        if case .none = indexSpec, parts.count >= 3 {
            let tail = parts[2...].joined(separator: ".")
            indexSpec = parseLegacyIndex(tail)
        }

        var css: String
        switch type {
        case "class":
            // Legado 格式 class.name1 name2 表示同時具有多個 class（如 class.lb_mulu chapterList）
            // 需轉為 CSS .name1.name2 而非 .name1 name2（後代選擇器）
            let classNames = name.components(separatedBy: " ").filter { !$0.isEmpty }
            css = classNames.map { "." + $0 }.joined()
        case "id":    css = "#" + name
        case "tag":   css = name.lowercased()
        case "text":  return (nil, indexSpec, name, false)
        case "children": return (nil, indexSpec, nil, true)
        case "":
            // .className 格式（split by "." 後 parts[0] 為空）→ CSS class 選擇器
            css = "." + name
        default:
            // 不認識的 type → 嘗試用原始段作為 CSS 選擇器
            css = s
        }
        return (css, indexSpec, nil, false)
    }

    /// 解析 [...] 內的索引表達式
    private static func parseIndexExpression(_ expr: String) -> JsoupIndexSpec {
        let trimmed = expr.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .none }

        // [!...] 排除模式
        if trimmed.hasPrefix("!") {
            let inner = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            let indices = inner.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return indices.isEmpty ? .none : .exclude(indices)
        }

        // 包含 : → 範圍模式 [start:end] 或 [start:end:step]
        if trimmed.contains(":") {
            let colonParts = trimmed.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            let start = colonParts.count > 0 && !colonParts[0].isEmpty ? Int(colonParts[0]) : nil
            let end = colonParts.count > 1 && !colonParts[1].isEmpty ? Int(colonParts[1]) : nil
            let step = colonParts.count > 2 && !colonParts[2].isEmpty ? (Int(colonParts[2]) ?? 1) : 1
            return .range(start: start, end: end, step: max(step, 1))
        }

        // 包含 , → 多索引選擇 [0,2,-1]
        if trimmed.contains(",") {
            let indices = trimmed.components(separatedBy: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            return indices.isEmpty ? .none : .select(indices)
        }

        // 單數字
        if let idx = Int(trimmed) {
            return .single(idx)
        }

        return .none
    }

    /// 解析舊式 Legado 索引：.0 或 .0:2（點號後的數字部分）
    private static func parseLegacyIndex(_ tail: String) -> JsoupIndexSpec {
        // 範圍 0:2 或 0:10:2
        if tail.contains(":") {
            let colonParts = tail.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            let start = colonParts.count > 0 && !colonParts[0].isEmpty ? Int(colonParts[0]) : nil
            let end = colonParts.count > 1 && !colonParts[1].isEmpty ? Int(colonParts[1]) : nil
            let step = colonParts.count > 2 && !colonParts[2].isEmpty ? (Int(colonParts[2]) ?? 1) : 1
            return .range(start: start, end: end, step: max(step, 1))
        }
        // 排除 !0
        if tail.hasPrefix("!"), let idx = Int(String(tail.dropFirst())) {
            return .exclude([idx])
        }
        // 單索引
        if let idx = Int(tail) {
            return .single(idx)
        }
        return .none
    }

    /// 根據索引規則從候選列表中篩選元素
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
                // 反向範圍
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

    /// 是否為「取內容」段：text, href, src, html, all, ownText, textNodes
    private static func isJsoupContentSpec(_ segment: String) -> Bool {
        let s = segment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s == "text" || s == "href" || s == "src" || s == "html" || s == "all"
            || s == "owntext" || s == "textnodes"
    }

    /// 從節點列表依 JSOUP 段取下一層節點（含完整索引篩選）
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

    /// Legado JSOUP Default 列表：class.update_con@tag.li → 先 .update_con 再每個取 li
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

    /// Legado JSOUP Default 單值（從 HTML）
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
        // Legado 行為：如果沒有指定 contentSpec 且目標節點是 <a>，預設取 href
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

    /// Legado JSOUP Default 單值（從節點）
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
        // Legado 行為：如果沒有指定 contentSpec 且目標節點是 <a>，預設取 href
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

    // MARK: - 從 HTML 提取節點列表（用於 bookList、chapterList）
    static func extractList(html: String, baseURL: String, rule: String) -> [HTMLNode] {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // 拆出 CSS 部分（list 規則通常不帶 regex 後處理）
        let (cssRule, _) = splitRuleAndRegex(trimmed)

        // 支援 Legado @@ 多步選擇器："A@@B" 先選 A，再從每個結果中選 B
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

    // MARK: - 從節點提取字串值
    static func extractValue(from node: HTMLNode, rule: String, baseURL: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return node.innerText }

        // 分離 CSS 選擇器 + 屬性提取 + regex 後處理
        let (cssAndAttr, regexParts) = splitRuleAndRegex(trimmed)
        let (selector, attrName) = splitSelectorAndAttr(cssAndAttr)

        // 1. 用 CSS 選擇器找節點（若 selector 為空則用當前節點）
        let targetNode: HTMLNode
        if selector.isEmpty {
            targetNode = node
        } else {
            guard let found = node.selectFirst(selector) else { return "" }
            targetNode = found
        }

        // 2. 提取屬性或文字
        var value = extractAttr(from: targetNode, attr: attrName)

        // 3. URL 拼接（href/src 類）
        if attrName == "href" || attrName == "src" || attrName.hasPrefix("data-") {
            if !value.isEmpty {
                value = resolveURL(value, base: baseURL)
            }
        }

        // 4. Regex 後處理
        value = applyRegex(to: value, parts: regexParts)

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 從 HTML 字串提取單個值（自動解析 HTML）
    static func extractValue(fromHTML html: String, rule: String, baseURL: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Legado JSOUP Default 規則（如 class.read-content@text）不是合法 CSS，需路由到專用解析器
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
                // 只有帶 ##regex 規則才回退到原始 html 處理，否則直接回傳空字串
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

        // 對含 @css: / @xpath: / @json: / || / && 前綴的規則，走 routeExtractValue（統一路由）
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

    // MARK: - 從節點提取屬性
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

    // MARK: - URL 拼接
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
        // 相對路徑
        if let resolved = URL(string: urlPart, relativeTo: baseURL)?.absoluteString {
            return resolved + optionSuffix
        }
        return trimmed
    }

    /// 清理提取到的 URL：若包含 HTML 標籤（如 `<a href="...">第1章</a>`），嘗試提取 href 屬性
    /// 同時處理 percent-encoded HTML（如 `%3Ca%20href=%22...%22%3E`）
    static func sanitizeExtractedURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 先嘗試 percent-decode 後再檢查
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

        // 嘗試從 href="..." 或 href='...' 提取
        if let hrefRegex = try? NSRegularExpression(pattern: #"href\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive) {
            let nsRange = NSRange(workingStr.startIndex..., in: workingStr)
            if let match = hrefRegex.firstMatch(in: workingStr, range: nsRange),
               let urlRange = Range(match.range(at: 1), in: workingStr) {
                let extracted = String(workingStr[urlRange])
                // 若原始 URL 有 base（如 https://domain.com/path/<a>），需要保留 base
                if needsDecode, let hrefStart = decoded.range(of: "<") {
                    let basePart = String(decoded[..<hrefStart.lowerBound])
                    if !basePart.isEmpty && extracted.hasPrefix("/") {
                        // href 是相對路徑，直接返回 href（resolveURL 會處理）
                        return extracted
                    }
                    if !basePart.isEmpty && !extracted.hasPrefix("http") {
                        return extracted
                    }
                }
                return extracted
            }
        }
        // 嘗試從 src="..." 提取
        if let srcRegex = try? NSRegularExpression(pattern: #"src\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive) {
            let nsRange = NSRange(workingStr.startIndex..., in: workingStr)
            if let match = srcRegex.firstMatch(in: workingStr, range: nsRange),
               let urlRange = Range(match.range(at: 1), in: workingStr) {
                return String(workingStr[urlRange])
            }
        }
        // 去掉所有 HTML 標籤作為最後手段
        let stripped = workingStr.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? trimmed : stripped
    }

    /// Legado 正則 AllInOne：用正則從全文匹配，返回每筆 [完整匹配, 捕獲組1, 捕獲組2, ...]
    static func extractRegexAllInOneMatches(html: String, pattern: String) -> [[String]] {
        let p = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, let regex = try? NSRegularExpression(pattern: p) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        let matches = regex.matches(in: html, range: range)
        return matches.map { match in
            (0..<match.numberOfRanges).compactMap { i -> String? in
                guard let r = Range(match.range(at: i), in: html) else { return nil }
                return String(html[r])
            }
        }
    }

    /// 將模板中的 $1, $2, ... 替換為 groups[1], groups[2], ...（Legado 目錄正則用）
    static func substituteGroupRefs(template: String, groups: [String]) -> String {
        var s = template
        for i in 1..<groups.count {
            s = s.replacingOccurrences(of: "$\(i)", with: groups[i])
        }
        return s
    }

    // MARK: - XPath 解析

    /// 從 HTML 用 XPath 提取節點列表
    static func extractListByXPath(html: String, xpath: String) -> [HTMLNode] {
        let (xpathClean, _) = splitRuleAndRegex(xpath)
        let doc = parseHTML(html)
        return evaluateXPath(node: doc, xpath: xpathClean)
    }

    /// 從 HTML 用 XPath 提取單個值
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

    /// 簡易 XPath 求值引擎
    /// 支援：/html/body/div, //div, //div[@class='x'], //div[@id='y'], /text(), /@attr, [n]
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

    // MARK: - 私有 XPath 工具

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

    /// 解析 XPath 字串為步驟列表
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

    /// 解析單一 XPath 段
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

    /// 應用單一 XPath 步驟到節點
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

    /// 分離 XPath 末尾的屬性提取（/text() 或 /@href）
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

    // MARK: - 私有工具

    // 分離規則中的 "cssSelector@attr" 部分和 "##regex##replace" 部分
    private static func splitRuleAndRegex(_ rule: String) -> (String, [String]) {
        let parts = rule.components(separatedBy: "##")
        let cssAndAttr = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let regexParts = Array(parts.dropFirst())
        return (cssAndAttr, regexParts)
    }

    // 分離 "div.title@href" → ("div.title", "href")
    private static func splitSelectorAndAttr(_ s: String) -> (String, String) {
        // 從最後一個 @ 分割
        if let atRange = s.range(of: "@", options: .backwards) {
            let selector = String(s[s.startIndex..<atRange.lowerBound])
            let attr = String(s[atRange.upperBound...])
            return (selector.trimmingCharacters(in: .whitespacesAndNewlines), attr.lowercased())
        }
        return (s, "text")
    }

    // 應用 regex：["pattern"] 或 ["pattern", "replacement"]
    private static func applyRegex(to text: String, parts: [String]) -> String {
        guard !parts.isEmpty else { return text }
        let pattern = parts[0]
        guard !pattern.isEmpty else { return text }

        if parts.count >= 2 {
            // 替換模式
            let replacement = parts[1]
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(text.startIndex..., in: text)
                return regex.stringByReplacingMatches(
                    in: text, range: range, withTemplate: replacement)
            }
        } else {
            // Legado 相容：單 ##pattern 為移除模式（全部替換為空字串）
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(text.startIndex..., in: text)
                return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
            }
        }
        return text
    }

    // 清理文字：去除行首行尾 ASCII 空白，但保留全形空格（　U+3000）縮進
    private static func cleanText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { line -> String in
                var s = line
                // 只去除行首 ASCII 空白（空格/Tab），不動全形空格
                while let f = s.first, f == " " || f == "\t" || f == "\r" { s.removeFirst() }
                while let l = s.last, l == " " || l == "\t" || l == "\r" { s.removeLast() }
                return s
            }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: "\n")
    }

    // 重建外層 HTML（簡化版）
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
        for (i, seg) in segments.enumerated() {
            if isJsoupContentSpec(seg) {
                contentSpec = seg.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                break
            }
            let prev = current
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

    // MARK: - JSON 支援

    /// 偵測字串是否為 JSON 回應
    static func isJSON(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("{") || t.hasPrefix("[")
    }

    /// 從 JSON 回應提取列表（rule 為 JSONPath，如 $.data.list）
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

    /// 從 JSON item（Any）提取字串值（item 為 Array 中的單個元素或 root）
    static func extractJSONValue(fromJSON item: Any, rule: String, baseURL: String) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return jsonToString(item) }

        let (pathPart, regexParts) = splitRuleAndRegex(trimmed)
        let isRecursive = pathPart.hasPrefix("$..") || pathPart.hasPrefix("..")
        let path = normalizeJSONPath(pathPart)

        let raw: Any?
        if isRecursive && !path.isEmpty {
            let leafKey = path.components(separatedBy: ".").last ?? path
            // Legado $.. 語義：收集所有匹配的值，用換行連接
            let allMatches = jsonSearchAll(item, key: leafKey)
            if allMatches.count > 1 {
                // 多結果：逐個轉字串後合併
                raw = allMatches.map { jsonToString($0) }.filter { !$0.isEmpty }.joined(separator: "\n") as Any
            } else {
                raw = allMatches.first
            }
        } else {
            raw = path.isEmpty ? item : jsonGet(item, path: path)
        }
        var value = jsonToString(raw)

        // URL 欄位自動拼接絕對路徑
        let lower = pathPart.lowercased()
        if lower.hasSuffix("url") || lower.hasSuffix("href") || lower.hasSuffix("link")
            || lower.hasSuffix("cover") || lower.hasSuffix("img")
        {
            if !value.isEmpty { value = resolveURL(value, base: baseURL) }
        }

        value = applyRegex(to: value, parts: regexParts)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 從 JSON 字串回應中提取單個值（整個回應為 JSON 時使用）
    static func extractValueFromJSON(_ jsonStr: String, rule: String, baseURL: String) -> String {
        guard let data = jsonStr.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else { return "" }
        return extractJSONValue(fromJSON: root, rule: rule, baseURL: baseURL)
    }

    // MARK: - 私有 JSON 工具

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

    /// 簡化 JSONPath 求值（支援 .key、[idx]、[*] 萬用字元）
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

    /// 遞歸搜索 JSON 樹中第一個匹配指定 key 的值（支援 $.. 遞歸 JSONPath）
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

    /// 遞歸搜索 JSON 樹中所有匹配指定 key 的值（Legado $.. 語義：收集全部匹配）
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

    /// 分割 JSONPath（處理 a.b[0].c 格式）
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

// MARK: - 搜尋 URL 模板渲染

extension BookSource {
    private func stringifyRequestValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let string = value as? String { return string }
        if let data = try? JSONSerialization.data(withJSONObject: value),
            let string = String(data: data, encoding: .utf8)
        {
            return string
        }
        return String(describing: value)
    }

    private func stringifyRequestHeaders(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var output: [String: String] = [:]
        for (key, rawValue) in dict {
            guard let stringValue = stringifyRequestValue(rawValue) else { continue }
            output[key] = stringValue
        }
        return output
    }

    private func normalizeLegadoJSONObjectLike(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(",") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "\"")
            .replacingOccurrences(of: "’", with: "\"")
        if s.contains("'") {
            s = s.replacingOccurrences(
                of: #"(?<!\\)'([^']*)'"#,
                with: #""$1""#,
                options: .regularExpression
            )
        }
        s = s.replacingOccurrences(
            of: #"([{\[,]\s*)([A-Za-z_][A-Za-z0-9_\-]*)(\s*:)"#,
            with: #"$1"$2"$3"#,
            options: .regularExpression
        )
        return s
    }

    struct SearchRequestSpec {
        var url: String
        var method: String
        var body: String?
        var charset: String?
        var useWebView: Bool
        var headers: [String: String]
    }

    /// 渲染搜索 URL（對齊 Legado AnalyzeUrl）
    /// 支援：{{key}} {{page}} {{key,GB2312}} / URL,POST,body / URL,{JSON 選項}
    /// JSON 選項支援欄位：method, body, charset, headers, webView, webJs, retry
    func renderSearchURL(query: String, page: Int = 1) -> (
        url: String, method: String, body: String?
    ) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let pageStr = String(page)

        let gbkEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbkEncoded: String
        if let data = query.data(using: gbkEncoding) {
            gbkEncoded = data.map { String(format: "%%%02X", $0) }.joined()
        } else {
            gbkEncoded = encoded
        }

        func applyVars(_ s: String) -> String {
            var result = s
                .replacingOccurrences(of: "{{key,GB2312}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,gb2312}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,GBK}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,gbk}}", with: gbkEncoded)
                .replacingOccurrences(of: "{key,GB2312}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key}}", with: encoded)
                .replacingOccurrences(of: "{key}", with: encoded)
                .replacingOccurrences(of: "{{page}}", with: pageStr)
                .replacingOccurrences(of: "{page}", with: pageStr)
            // 處理剩餘的 {{...}} JavaScript 表達式
            result = BookSource.evaluateRemainingTemplates(result, source: self)
            return result
        }

        // Legado 格式：URL 後面跟逗號+JSON → URL,{"method":"POST","body":"...","webView":true,...}
        // 先嘗試用正則切分 URL 和 JSON 選項
        let trimmedSearch = searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jsonStart = trimmedSearch.range(of: ",\\s*\\{", options: .regularExpression) {
            let urlPart = applyVars(String(trimmedSearch[trimmedSearch.startIndex..<jsonStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            let jsonPart = String(trimmedSearch[jsonStart.lowerBound...]).dropFirst() // 去掉逗號
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonPart.data(using: .utf8),
               let opt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let method = (opt["method"] as? String)?.uppercased() == "POST" ? "POST" : "GET"
                let body = (opt["body"] as? String).map { applyVars($0) }
                return (urlPart, method, body)
            }
        }

        // 舊格式：URL,POST,bodyTemplate
        let parts = trimmedSearch.components(separatedBy: ",")
        if parts.count >= 2 && parts[1].trimmingCharacters(in: .whitespaces).uppercased() == "POST"
        {
            let urlStr = applyVars(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
            let bodyTemplate = parts.count >= 3 ? parts[2...].joined(separator: ",") : ""
            let body = applyVars(bodyTemplate)
            return (urlStr, "POST", body.isEmpty ? nil : body)
        } else {
            let finalURL = applyVars(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
            return (finalURL, "GET", nil)
        }
    }

    func renderSearchRequest(query: String, page: Int = 1) -> SearchRequestSpec {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let pageStr = String(page)

        let gbkEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbkEncoded: String
        if let data = query.data(using: gbkEncoding) {
            gbkEncoded = data.map { String(format: "%%%02X", $0) }.joined()
        } else {
            gbkEncoded = encoded
        }

        func applyVars(_ s: String) -> String {
            var result = s
                .replacingOccurrences(of: "{{key,GB2312}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,gb2312}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,GBK}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,gbk}}", with: gbkEncoded)
                .replacingOccurrences(of: "{key,GB2312}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key}}", with: encoded)
                .replacingOccurrences(of: "{key}", with: encoded)
                .replacingOccurrences(of: "{{page}}", with: pageStr)
                .replacingOccurrences(of: "{page}", with: pageStr)
            // 處理剩餘的 {{...}} JavaScript 表達式（如 {{cookie.removeCookie(source.key)}}）
            // 這些通常是 cookie 管理等副作用操作，在 Legado 中返回空字串
            // 使用 JSContext 嘗試求值，失敗則替換為空字串
            result = BookSource.evaluateRemainingTemplates(result, source: self)
            return result
        }

        func parseOptions(_ raw: String) -> [String: Any]? {
            let normalized = normalizeLegadoJSONObjectLike(raw)
            guard let data = normalized.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return obj
        }

        let trimmedSearch = searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jsonStart = trimmedSearch.range(of: ",\\s*\\{", options: .regularExpression) {
            let urlPart = applyVars(String(trimmedSearch[..<jsonStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            let jsonPart = String(trimmedSearch[jsonStart.lowerBound...])
            if let opt = parseOptions(jsonPart) {
                let method = ((opt["method"] as? String) ?? "GET").uppercased() == "POST" ? "POST" : "GET"
                let body = stringifyRequestValue(opt["body"]).map(applyVars)
                let charset = stringifyRequestValue(opt["charset"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                let useWebView = {
                    if let bool = opt["webView"] as? Bool { return bool }
                    let text = stringifyRequestValue(opt["webView"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return ["true", "1", "yes", "y"].contains(text ?? "")
                }()
                let headers = stringifyRequestHeaders(opt["headers"])
                return SearchRequestSpec(
                    url: urlPart,
                    method: method,
                    body: body,
                    charset: charset,
                    useWebView: useWebView,
                    headers: headers
                )
            }
        }

        let legacy = renderSearchURL(query: query, page: page)
        return SearchRequestSpec(
            url: legacy.url,
            method: legacy.method,
            body: legacy.body,
            charset: nil,
            useWebView: false,
            headers: [:]
        )
    }

    /// 解析 header 字串為 Dictionary
    var parsedHeaders: [String: String] {
        guard !header.isEmpty,
            let data = header.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dict
    }

    /// 處理 URL 中剩餘的 `{{...}}` JavaScript 模板表達式
    /// Legado 書源 URL 中常含 `{{cookie.removeCookie(source.key)}}` 等 JS 片段，
    /// 這些通常是副作用操作（清 cookie 等），返回空字串。
    /// 此方法嘗試透過 JSContext 求值，失敗則替換為空字串。
    static func evaluateRemainingTemplates(_ input: String, source: BookSource) -> String {
        guard input.contains("{{") else { return input }
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([\s\S]*?)\}\}"#) else { return input }
        let nsRange = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, range: nsRange)
        guard !matches.isEmpty else { return input }

        var output = input
        // 反向替換避免偏移
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range(at: 0), in: output),
                  let exprRange = Range(match.range(at: 1), in: output) else { continue }
            let expression = String(output[exprRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expression.isEmpty else {
                output.replaceSubrange(wholeRange, with: "")
                continue
            }
            // 嘗試用 JSContext 求值
            let evaluated = evaluateTemplateExpression(expression, source: source)
            output.replaceSubrange(wholeRange, with: evaluated)
        }
        return output
    }

    /// 用 JSContext 求值單個模板表達式
    private static func evaluateTemplateExpression(_ expression: String, source: BookSource) -> String {
        let context = JSContext()
        context?.exceptionHandler = { _, _ in }

        // 提供 source 物件（Legado 相容）
        let sourceObj: [String: Any] = [
            "bookSourceUrl": source.bookSourceUrl,
            "bookSourceName": source.bookSourceName,
            "bookSourceGroup": source.bookSourceGroup,
            "loginUrl": source.loginUrl,
            "header": source.header,
        ]
        context?.setObject(sourceObj, forKeyedSubscript: "source" as NSString)

        // 提供 source.getKey() 方法
        let getKeyBlock: @convention(block) () -> String = { source.bookSourceUrl }
        context?.objectForKeyedSubscript("source")?.setObject(getKeyBlock, forKeyedSubscript: "getKey" as NSString)

        // 提供 cookie 橋接（cookie.removeCookie 等常見 Legado 操作）
        let cookieObj: [String: Any] = [:]
        context?.setObject(cookieObj, forKeyedSubscript: "cookie" as NSString)
        let removeCookieBlock: @convention(block) (String) -> String = { _ in "" }
        context?.objectForKeyedSubscript("cookie")?.setObject(removeCookieBlock, forKeyedSubscript: "removeCookie" as NSString)
        let getCookieBlock: @convention(block) (String) -> String = { _ in "" }
        context?.objectForKeyedSubscript("cookie")?.setObject(getCookieBlock, forKeyedSubscript: "getCookie" as NSString)

        // 提供 java 橋接（基本的鏈式呼叫，返回空字串）
        let javaConnectBlock: @convention(block) (String) -> JSValue? = { _ in
            guard let chainObj = JSValue(newObjectIn: context) else { return nil }
            let rawBlock: @convention(block) () -> JSValue? = { [weak chainObj] in chainObj }
            chainObj.setObject(rawBlock, forKeyedSubscript: "raw" as NSString)
            let requestBlock: @convention(block) () -> JSValue? = { [weak chainObj] in chainObj }
            chainObj.setObject(requestBlock, forKeyedSubscript: "request" as NSString)
            let urlBlock: @convention(block) () -> String = { source.bookSourceUrl }
            chainObj.setObject(urlBlock, forKeyedSubscript: "url" as NSString)
            return chainObj
        }
        context?.setObject(javaConnectBlock, forKeyedSubscript: "java" as NSString)
        context?.objectForKeyedSubscript("java")?.setObject(javaConnectBlock, forKeyedSubscript: "connect" as NSString)

        // 嘗試求值
        let candidates = [
            expression,
            "(function(){ return (\(expression)); })()",
        ]
        for candidate in candidates {
            context?.exception = nil
            if let value = context?.evaluateScript(candidate), !value.isUndefined, !value.isNull {
                let result = value.toString() ?? ""
                if result != "undefined" && result != "null" {
                    return result
                }
            }
        }
        // 求值失敗，返回空字串（大多數 cookie/java 操作本身就是副作用，不影響 URL）
        return ""
    }
}

// MARK: - Legado Rule Analyzer（忠實移植 RuleAnalyzer.kt）
// 用於規則字串的括號感知分割，處理 &&、||、%% 運算子

private final class LegadoRuleAnalyzer {
    private let queue: [Character]
    private var pos: Int = 0
    private var start: Int = 0
    private var startX: Int = 0
    private var rule: [String] = []
    private var step: Int = 0
    var elementsType: String = ""
    private let isCode: Bool

    init(_ data: String, code: Bool = false) {
        self.queue = Array(data)
        self.isCode = code
    }

    private func chompBalanced(_ open: Character, _ close: Character) -> Bool {
        if isCode {
            return chompCodeBalanced(open, close)
        } else {
            return chompRuleBalanced(open, close)
        }
    }

    func trim() {
        guard pos < queue.count else { return }
        if queue[pos] == "@" || queue[pos].asciiValue.map({ $0 < 33 }) == true {
            pos += 1
            while pos < queue.count && (queue[pos] == "@" || queue[pos].asciiValue.map({ $0 < 33 }) == true) {
                pos += 1
            }
            start = pos
            startX = pos
        }
    }

    func reSetPos() {
        pos = 0
        startX = 0
    }

    private func consumeTo(_ seq: String) -> Bool {
        start = pos
        let seqChars = Array(seq)
        guard !seqChars.isEmpty else { return false }
        let maxStart = queue.count - seqChars.count
        guard maxStart >= pos else { return false }
        outer: for i in pos...maxStart {
            for j in 0..<seqChars.count {
                if queue[i + j] != seqChars[j] { continue outer }
            }
            pos = i
            return true
        }
        return false
    }

    private func consumeToAny(_ seqs: [String]) -> Bool {
        var p = pos
        while p < queue.count {
            for s in seqs {
                let sChars = Array(s)
                if p + sChars.count <= queue.count {
                    var match = true
                    for j in 0..<sChars.count {
                        if queue[p + j] != sChars[j] { match = false; break }
                    }
                    if match {
                        step = sChars.count
                        pos = p
                        return true
                    }
                }
            }
            p += 1
        }
        return false
    }

    private func findToAny(_ chars: [Character]) -> Int {
        var p = pos
        while p < queue.count {
            for c in chars {
                if queue[p] == c { return p }
            }
            p += 1
        }
        return -1
    }

    private func chompCodeBalanced(_ open: Character, _ close: Character) -> Bool {
        var p = pos
        var depth = 0
        var otherDepth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        repeat {
            if p >= queue.count { break }
            let c = queue[p]; p += 1
            if c != "\\" {
                if c == "'" && !inDoubleQuote { inSingleQuote = !inSingleQuote }
                else if c == "\"" && !inSingleQuote { inDoubleQuote = !inDoubleQuote }
                if inSingleQuote || inDoubleQuote { continue }
                if c == "[" { depth += 1 }
                else if c == "]" { depth -= 1 }
                else if depth == 0 {
                    if c == open { otherDepth += 1 }
                    else if c == close { otherDepth -= 1 }
                }
            } else { p += 1 }
        } while depth > 0 || otherDepth > 0
        guard depth <= 0 && otherDepth <= 0 else { return false }
        pos = p
        return true
    }

    private func chompRuleBalanced(_ open: Character, _ close: Character) -> Bool {
        var p = pos
        var depth = 0
        var inSingleQuote = false
        var inDoubleQuote = false
        repeat {
            if p >= queue.count { break }
            let c = queue[p]; p += 1
            if c == "'" && !inDoubleQuote { inSingleQuote = !inSingleQuote }
            else if c == "\"" && !inSingleQuote { inDoubleQuote = !inDoubleQuote }
            if inSingleQuote || inDoubleQuote { continue }
            if c == "\\" { p += 1; continue }
            if c == open { depth += 1 }
            else if c == close { depth -= 1 }
        } while depth > 0
        guard depth <= 0 else { return false }
        pos = p
        return true
    }

    private func substring(_ from: Int, _ to: Int) -> String {
        guard from >= 0 && to <= queue.count && from <= to else { return "" }
        return String(queue[from..<to])
    }

    private func substringFrom(_ from: Int) -> String {
        guard from >= 0 && from < queue.count else { return "" }
        return String(queue[from...])
    }

    /// 分割規則（對應 Legado RuleAnalyzer.splitRule）
    func splitRule(_ splits: String...) -> [String] {
        return splitRuleImpl(splits)
    }

    func splitRuleImpl(_ splits: [String]) -> [String] {
        rule = []
        if splits.count == 1 {
            elementsType = splits[0]
            if !consumeTo(elementsType) {
                rule.append(substringFrom(startX))
                return rule
            }
            step = elementsType.count
            return splitRuleNext()
        }
        if !consumeToAny(splits) {
            rule.append(substringFrom(startX))
            return rule
        }
        let end = pos
        pos = start
        // 查找筛选器
        while true {
            let st = findToAny(["[", "("])
            if st == -1 {
                rule = [substring(startX, end)]
                elementsType = substring(end, end + step)
                pos = end + step
                while consumeTo(elementsType) {
                    rule.append(substring(start, pos))
                    pos += step
                }
                rule.append(substringFrom(pos))
                return rule
            }
            if st > end {
                rule = [substring(startX, end)]
                elementsType = substring(end, end + step)
                pos = end + step
                while consumeTo(elementsType) && pos < st {
                    rule.append(substring(start, pos))
                    pos += step
                }
                if pos > st {
                    startX = start
                    return splitRuleNext()
                }
                rule.append(substringFrom(pos))
                return rule
            }
            pos = st
            let next: Character = queue[pos] == "[" ? "]" : ")"
            if !chompBalanced(queue[pos], next) { break }
            if end <= pos { break }
        }
        start = pos
        return splitRuleImpl(splits)
    }

    private func splitRuleNext() -> [String] {
        let end = pos
        pos = start
        while true {
            let st = findToAny(["[", "("])
            if st == -1 {
                rule.append(substring(startX, end))
                pos = end + step
                while consumeTo(elementsType) {
                    rule.append(substring(start, pos))
                    pos += step
                }
                rule.append(substringFrom(pos))
                return rule
            }
            if st > end {
                rule.append(substring(startX, end))
                pos = end + step
                while consumeTo(elementsType) && pos < st {
                    rule.append(substring(start, pos))
                    pos += step
                }
                if pos > st {
                    startX = start
                    return splitRuleNext()
                }
                rule.append(substringFrom(pos))
                return rule
            }
            pos = st
            let next: Character = queue[pos] == "[" ? "]" : ")"
            if !chompBalanced(queue[pos], next) { break }
            if end <= pos { break }
        }
        start = pos
        if !consumeTo(elementsType) {
            rule.append(substringFrom(startX))
            return rule
        }
        return splitRuleNext()
    }

    /// 替換內嵌規則 {$.field}（對應 Legado RuleAnalyzer.innerRule）
    func innerRule(_ inner: String, startStep: Int = 1, endStep: Int = 1,
                   fr: (String) -> String?) -> String {
        var st = ""
        while consumeTo(inner) {
            let posPre = pos
            if chompCodeBalanced("{", "}") {
                let innerStr = substring(posPre + startStep, pos - endStep)
                if let frv = fr(innerStr), !frv.isEmpty {
                    st += substring(startX, posPre) + frv
                    startX = pos
                    continue
                }
            }
            pos += inner.count
        }
        if startX == 0 { return "" }
        st += substringFrom(startX)
        return st
    }

    /// 替換內嵌規則（帶起止字串）
    func innerRule(startStr: String, endStr: String, fr: (String) -> String?) -> String {
        var st = ""
        while consumeTo(startStr) {
            pos += startStr.count
            let posPre = pos
            if consumeTo(endStr) {
                let frv = fr(substring(posPre, pos)) ?? ""
                st += substring(startX, posPre - startStr.count) + frv
                pos += endStr.count
                startX = pos
            }
        }
        if startX == 0 { return String(queue) }
        st += substringFrom(startX)
        return st
    }
}

// MARK: - Legado AnalyzeByJSonPath（忠實移植 AnalyzeByJSonPath.kt）

private final class LegadoAnalyzeByJSonPath {
    private let ctx: Any // JSON root object

    init(_ json: Any) {
        if let str = json as? String,
           let data = str.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            self.ctx = obj
        } else {
            self.ctx = json
        }
    }

    func getString(_ rule: String) -> String? {
        if rule.isEmpty { return nil }
        let ruleAnalyzer = LegadoRuleAnalyzer(rule, code: true)
        let rules = ruleAnalyzer.splitRule("&&", "||")

        if rules.count == 1 {
            ruleAnalyzer.reSetPos()
            let result = ruleAnalyzer.innerRule("{$.") { getString($0) }
            if !result.isEmpty { return result }
            // 無成功替換的內嵌規則，直接用 JSONPath 求值
            return evaluateJSONPath(rule, on: ctx)
        }
        var textList: [String] = []
        for rl in rules {
            if let temp = getString(rl), !temp.isEmpty {
                textList.append(temp)
                if ruleAnalyzer.elementsType == "||" { break }
            }
        }
        return textList.joined(separator: "\n")
    }

    func getStringList(_ rule: String) -> [String] {
        if rule.isEmpty { return [] }
        let ruleAnalyzer = LegadoRuleAnalyzer(rule, code: true)
        let rules = ruleAnalyzer.splitRule("&&", "||", "%%")

        if rules.count == 1 {
            ruleAnalyzer.reSetPos()
            let st = ruleAnalyzer.innerRule("{$.") { getString($0) }
            if !st.isEmpty { return [st] }
            return evaluateJSONPathList(rule, on: ctx)
        }
        var results: [[String]] = []
        for rl in rules {
            let temp = getStringList(rl)
            if !temp.isEmpty {
                results.append(temp)
                if ruleAnalyzer.elementsType == "||" { break }
            }
        }
        if results.isEmpty { return [] }
        if ruleAnalyzer.elementsType == "%%" {
            var result: [String] = []
            let maxLen = results.map(\.count).max() ?? 0
            for i in 0..<maxLen {
                for temp in results {
                    if i < temp.count { result.append(temp[i]) }
                }
            }
            return result
        }
        return results.flatMap { $0 }
    }

    func getList(_ rule: String) -> [Any] {
        if rule.isEmpty { return [] }
        let ruleAnalyzer = LegadoRuleAnalyzer(rule, code: true)
        let rules = ruleAnalyzer.splitRule("&&", "||", "%%")

        if rules.count == 1 {
            return evaluateJSONPathArray(rules[0], on: ctx)
        }
        var results: [[Any]] = []
        for rl in rules {
            let temp = getList(rl)
            if !temp.isEmpty {
                results.append(temp)
                if ruleAnalyzer.elementsType == "||" { break }
            }
        }
        if results.isEmpty { return [] }
        if ruleAnalyzer.elementsType == "%%" {
            var result: [Any] = []
            let maxLen = results.map(\.count).max() ?? 0
            for i in 0..<maxLen {
                for temp in results {
                    if i < temp.count { result.append(temp[i]) }
                }
            }
            return result
        }
        return results.flatMap { $0 }
    }

    // MARK: JSONPath 求值

    private func evaluateJSONPath(_ path: String, on obj: Any) -> String? {
        let value = resolveJSONPath(path, on: obj)
        if value == nil { return nil }
        if let arr = value as? [Any] {
            return arr.map { RuleEngine.jsonValueToString($0) }.joined(separator: "\n")
        }
        return RuleEngine.jsonValueToString(value!)
    }

    private func evaluateJSONPathList(_ path: String, on obj: Any) -> [String] {
        let value = resolveJSONPath(path, on: obj)
        if value == nil { return [] }
        if let arr = value as? [Any] {
            return arr.map { RuleEngine.jsonValueToString($0) }
        }
        let s = RuleEngine.jsonValueToString(value!)
        return s.isEmpty ? [] : [s]
    }

    private func evaluateJSONPathArray(_ path: String, on obj: Any) -> [Any] {
        let value = resolveJSONPath(path, on: obj)
        if value == nil { return [] }
        if let arr = value as? [Any] { return arr }
        return [value!]
    }

    /// 解析 JSONPath：支援 $., $.., $[*], 簡單路徑
    private func resolveJSONPath(_ path: String, on obj: Any) -> Any? {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉 @json: 前綴（不區分大小寫）
        if p.lowercased().hasPrefix("@json:") { p = String(p.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if p.isEmpty || p == "$" { return obj }
        // 去掉 $ 前綴
        if p.hasPrefix("$.") { p = String(p.dropFirst(2)) }
        else if p.hasPrefix("$[") { p = String(p.dropFirst(1)) }
        else if p.hasPrefix("$") { p = String(p.dropFirst(1)) }

        // 處理 .. 遞歸搜索
        if p.hasPrefix(".") {
            let recursivePath = p.hasPrefix("..") ? String(p.dropFirst(2)) : String(p.dropFirst())
            let (key, remaining) = splitFirstPathSegment(recursivePath)
            guard !key.isEmpty else { return nil }
            let allMatches = RuleEngine.jsonSearchAllValues(obj, key: key)
            if remaining.isEmpty {
                return allMatches.count == 1 ? allMatches.first : allMatches
            }
            // 繼續解析剩餘路徑
            var results: [Any] = []
            for match in allMatches {
                if let sub = navigatePath(remaining, on: match) {
                    if let arr = sub as? [Any] { results.append(contentsOf: arr) }
                    else { results.append(sub) }
                }
            }
            return results.isEmpty ? nil : (results.count == 1 ? results.first : results)
        }

        return navigatePath(p, on: obj)
    }

    private func splitFirstPathSegment(_ path: String) -> (key: String, remaining: String) {
        guard !path.isEmpty else { return ("", "") }
        var key = ""
        var i = path.startIndex
        while i < path.endIndex {
            let ch = path[i]
            if ch == "." || ch == "[" { break }
            key.append(ch)
            i = path.index(after: i)
        }

        guard i < path.endIndex else { return (key, "") }
        if path[i] == "." {
            return (key, String(path[path.index(after: i)...]))
        }
        return (key, String(path[i...]))
    }

    private func navigatePath(_ path: String, on obj: Any) -> Any? {
        let components = splitPath(path)
        var frontier: [Any] = [obj]
        for comp in components {
            var next: [Any] = []
            for current in frontier {
                if comp == "*" || comp == "[*]" {
                    if let arr = current as? [Any] {
                        next.append(contentsOf: arr)
                    } else if let dict = current as? [String: Any] {
                        next.append(contentsOf: dict.values)
                    } else {
                        next.append(current)
                    }
                    continue
                }

                if comp.hasPrefix("[") && comp.hasSuffix("]") {
                    let inner = String(comp.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
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

                if let dict = current as? [String: Any], let val = dict[comp] {
                    next.append(val)
                } else if let arr = current as? [Any], let idx = Int(comp) {
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

    private func splitPath(_ path: String) -> [String] {
        var components: [String] = []
        var current = ""
        var i = path.startIndex
        while i < path.endIndex {
            let ch = path[i]
            if ch == "." {
                if !current.isEmpty { components.append(current); current = "" }
                i = path.index(after: i)
            } else if ch == "[" {
                if !current.isEmpty { components.append(current); current = "" }
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
}

// MARK: - Legado AnalyzeRule 核心（忠實移植 AnalyzeRule.kt）

private final class NativeRuleRuntime {
    private(set) var variables: [String: String]

    init(_ initial: [String: String]?) {
        self.variables = initial ?? [:]
    }

    func put(_ key: String, _ value: String) -> String {
        variables[key] = value
        return value
    }

    func get(_ key: String) -> String {
        variables[key] ?? ""
    }

    func snapshot() -> [String: String]? {
        variables.isEmpty ? nil : variables
    }
}

private enum RuleMode {
    case defaultMode  // JSoup CSS
    case xpath
    case json
    case js
    case regex
}

/// 對應 Legado AnalyzeRule.SourceRule
private struct SourceRule {
    var rule: String
    var mode: RuleMode
    var replaceRegex: String = ""
    var replacement: String = ""
    var replaceFirst: Bool = false
    var putMap: [String: String] = [:]
    // 用於 makeUpRule 的模板片段
    var ruleParams: [(type: Int, param: String)] = []
    // type: -2 = @get, -1 = {{js}}, 0 = literal, >0 = regex group $N
    var hasTemplates: Bool = false
}

@objc private protocol NativeRuleJavaExports: JSExport {
    func put(_ key: String, _ value: String) -> String
    func get(_ key: String) -> String
    func getString(_ rule: String) -> String
    func getStringList(_ rule: String) -> [String]
    func ajax(_ url: String) -> String
}

private final class NativeRuleJavaBridge: NSObject, NativeRuleJavaExports {
    weak var analyzer: NativeRuleAnalyzer?
    var currentResult: Any?

    init(analyzer: NativeRuleAnalyzer, currentResult: Any?) {
        self.analyzer = analyzer
        self.currentResult = currentResult
    }

    func put(_ key: String, _ value: String) -> String {
        analyzer?.runtime.put(key, value) ?? value
    }

    func get(_ key: String) -> String {
        analyzer?.runtime.get(key) ?? ""
    }

    func getString(_ rule: String) -> String {
        guard let a = analyzer else { return "" }
        return a.getString(rule, content: currentResult ?? a.rootContent)
    }

    func getStringList(_ rule: String) -> [String] {
        guard let a = analyzer else { return [] }
        return a.getStringList(rule, content: currentResult ?? a.rootContent) ?? []
    }

    func ajax(_ url: String) -> String { "" }
}


private final class NativeRuleAnalyzer {
    let source: BookSource
    let runtime: NativeRuleRuntime
    let rootContent: Any
    let baseURL: String
    private var isJSON: Bool
    private var content: Any
    private var analyzeByJSonPath: LegadoAnalyzeByJSonPath?

    // JS_PATTERN: 匹配 @js:... 和 <js>...</js>
    private static let jsPattern = try! NSRegularExpression(
        pattern: #"<js>([\s\S]*?)</js>|@js:([\s\S]*?)$"#,
        options: [.caseInsensitive]
    )

    // evalPattern: 匹配 @get:{key} 和 {{expression}}
    private static let evalPattern = try! NSRegularExpression(
        pattern: #"@get:\{[^}]+?\}|\{\{[\s\S]*?\}\}"#,
        options: [.caseInsensitive]
    )

    // putPattern: 匹配 @put:{json}
    private static let putPattern = try! NSRegularExpression(
        pattern: #"@put:(\{[^}]+?\})"#,
        options: [.caseInsensitive]
    )

    // regexPattern: 匹配 $1, $2 等組引用
    private static let regexPattern = try! NSRegularExpression(
        pattern: #"\$\d{1,2}"#
    )

    init(source: BookSource, content: Any, baseURL: String, runtimeVariables: [String: String]?) {
        self.source = source
        self.rootContent = content
        self.content = content
        self.baseURL = baseURL
        self.runtime = NativeRuleRuntime(runtimeVariables)
        // 偵測是否 JSON
        if let str = content as? String {
            self.isJSON = RuleEngine.isJSON(str)
        } else if content is [String: Any] || content is [Any] {
            self.isJSON = true
        } else {
            self.isJSON = false
        }
    }

    func runtimeSnapshot() -> [String: String]? { runtime.snapshot() }

    // MARK: - 設定內容（對應 Legado setContent）

    private func setContent(_ newContent: Any) {
        content = newContent
        analyzeByJSonPath = nil
        if let str = newContent as? String {
            isJSON = RuleEngine.isJSON(str)
        } else if newContent is [String: Any] || newContent is [Any] {
            isJSON = true
        } else {
            isJSON = false
        }
    }

    // MARK: - 取得 JSON 分析器（延遲初始化）

    private func getAnalyzeByJSonPath(_ obj: Any) -> LegadoAnalyzeByJSonPath {
        if obj as AnyObject === content as AnyObject {
            if analyzeByJSonPath == nil {
                analyzeByJSonPath = LegadoAnalyzeByJSonPath(content)
            }
            return analyzeByJSonPath!
        }
        return LegadoAnalyzeByJSonPath(obj)
    }

    // MARK: - splitSourceRule（對應 Legado AnalyzeRule.splitSourceRule）
    // 按 @js: 和 <js>...</js> 切分規則，返回 SourceRule 列表

    func splitSourceRule(_ ruleStr: String?, allInOne: Bool = false) -> [SourceRule] {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else { return [] }
        var ruleList: [SourceRule] = []
        var defaultMode: RuleMode = .defaultMode
        var start = 0
        let nsStr = ruleStr as NSString
        let fullRange = NSRange(location: 0, length: nsStr.length)

        if allInOne && ruleStr.hasPrefix(":") {
            defaultMode = .regex
            start = 1
        }

        let matches = Self.jsPattern.matches(in: ruleStr, range: fullRange)
        for match in matches {
            if match.range.location > start {
                let tmp = nsStr.substring(with: NSRange(location: start, length: match.range.location - start))
                    .trimmingCharacters(in: .whitespaces)
                if !tmp.isEmpty {
                    ruleList.append(parseSourceRule(tmp, defaultMode: defaultMode))
                }
            }
            // group(2) 是 @js: 的內容，group(1) 是 <js> 的內容
            let jsContent: String
            if match.range(at: 2).location != NSNotFound {
                jsContent = nsStr.substring(with: match.range(at: 2))
            } else if match.range(at: 1).location != NSNotFound {
                jsContent = nsStr.substring(with: match.range(at: 1))
            } else {
                jsContent = ""
            }
            let jsRule = SourceRule(rule: jsContent, mode: .js)
            ruleList.append(jsRule)
            start = match.range.location + match.range.length
        }

        if ruleStr.count > start {
            let tmp = nsStr.substring(from: start).trimmingCharacters(in: .whitespaces)
            if !tmp.isEmpty {
                ruleList.append(parseSourceRule(tmp, defaultMode: defaultMode))
            }
        }
        return ruleList
    }

    // MARK: - SourceRule 解析（對應 Legado SourceRule.init）

    private func parseSourceRule(_ ruleStr: String, defaultMode: RuleMode) -> SourceRule {
        var mode = defaultMode
        var ruleBody: String

        if mode == .js || mode == .regex {
            ruleBody = ruleStr
        } else if ruleStr.hasPrefix("@CSS:") || ruleStr.lowercased().hasPrefix("@css:") {
            mode = .defaultMode
            ruleBody = ruleStr // @CSS: 保留完整前綴，在求值時處理
        } else if ruleStr.hasPrefix("@@") {
            mode = .defaultMode
            ruleBody = String(ruleStr.dropFirst(2))
        } else if ruleStr.lowercased().hasPrefix("@xpath:") {
            mode = .xpath
            ruleBody = String(ruleStr.dropFirst(7))
        } else if ruleStr.lowercased().hasPrefix("@json:") {
            mode = .json
            ruleBody = String(ruleStr.dropFirst(6))
        } else if isJSON || ruleStr.hasPrefix("$.") || ruleStr.hasPrefix("$[") {
            mode = .json
                ruleBody = ruleStr
            } else if ruleStr.hasPrefix("/") {
                mode = .xpath
                ruleBody = ruleStr
            } else {
                ruleBody = ruleStr
            }

        // 分離 @put 規則
        var putMap: [String: String] = [:]
        ruleBody = splitPutRule(ruleBody, putMap: &putMap)

        // 解析 @get:{} 和 {{}} 模板
        var ruleParams: [(type: Int, param: String)] = []
        var hasTemplates = false
        let nsRule = ruleBody as NSString
        let ruleRange = NSRange(location: 0, length: nsRule.length)
        let evalMatches = Self.evalPattern.matches(in: ruleBody, range: ruleRange)

        if let firstMatch = evalMatches.first {
            // 有模板表達式
            let beforeFirst = nsRule.substring(to: firstMatch.range.location)
            if mode != .js && mode != .regex {
                if firstMatch.range.location == 0 || !beforeFirst.contains("##") {
                    mode = .regex
                }
            }
            var startIdx = 0
            for match in evalMatches {
                if match.range.location > startIdx {
                    let tmp = nsRule.substring(with: NSRange(location: startIdx, length: match.range.location - startIdx))
                    splitRegexParams(tmp, into: &ruleParams, mode: &mode)
                }
                let tmp = nsRule.substring(with: match.range)
                if tmp.lowercased().hasPrefix("@get:") {
                    // @get:{key}
                    let key = String(tmp.dropFirst(6).dropLast())
                    ruleParams.append((type: -2, param: key))
                } else if tmp.hasPrefix("{{") {
                    // {{expression}}
                    let expr = String(tmp.dropFirst(2).dropLast(2))
                    ruleParams.append((type: -1, param: expr))
                } else {
                    splitRegexParams(tmp, into: &ruleParams, mode: &mode)
                }
                startIdx = match.range.location + match.range.length
            }
            if ruleBody.count > startIdx {
                let tmp = nsRule.substring(from: startIdx)
                splitRegexParams(tmp, into: &ruleParams, mode: &mode)
            }
            hasTemplates = true
        } else if ruleBody.count > 0 {
            // 無模板，但仍需處理 $1 $2 和 ##
            splitRegexParams(ruleBody, into: &ruleParams, mode: &mode)
            // 檢查是否有 $N 引用
            let regexMatches = Self.regexPattern.matches(in: ruleBody, range: NSRange(location: 0, length: (ruleBody as NSString).length))
            if !regexMatches.isEmpty { hasTemplates = true }
        }

        return SourceRule(
            rule: ruleBody,
            mode: mode,
            putMap: putMap,
            ruleParams: ruleParams,
            hasTemplates: hasTemplates
        )
    }

    private func splitRegexParams(_ ruleStr: String, into params: inout [(type: Int, param: String)], mode: inout RuleMode) {
        let nsStr = ruleStr as NSString
        // 只在 ## 之前的部分查找 $N
        let ruleStrArray = ruleStr.components(separatedBy: "##")
        let mainPart = ruleStrArray[0]
        let nsMain = mainPart as NSString
        let mainRange = NSRange(location: 0, length: nsMain.length)
        let regexMatches = Self.regexPattern.matches(in: mainPart, range: mainRange)

        if !regexMatches.isEmpty {
            if mode != .js && mode != .regex { mode = .regex }
            var start = 0
            for match in regexMatches {
                if match.range.location > start {
                    let tmp = nsStr.substring(with: NSRange(location: start, length: match.range.location - start))
                    params.append((type: 0, param: tmp))
                }
                let groupStr = nsMain.substring(with: match.range)
                let groupNum = Int(String(groupStr.dropFirst())) ?? 0
                params.append((type: groupNum, param: groupStr))
                start = match.range.location + match.range.length
            }
            if ruleStr.count > start {
                params.append((type: 0, param: nsStr.substring(from: start)))
            }
        } else {
            params.append((type: 0, param: ruleStr))
        }
    }

    // MARK: - splitPutRule（對應 Legado AnalyzeRule.splitPutRule）

    private func splitPutRule(_ ruleStr: String, putMap: inout [String: String]) -> String {
        var result = ruleStr
        let nsStr = ruleStr as NSString
        let range = NSRange(location: 0, length: nsStr.length)
        let matches = Self.putPattern.matches(in: ruleStr, range: range)
        for match in matches.reversed() {
            let wholeRange = match.range
            result = (result as NSString).replacingCharacters(in: wholeRange, with: "")
            if match.range(at: 1).location != NSNotFound {
                let jsonStr = nsStr.substring(with: match.range(at: 1))
                if let data = jsonStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                    for (k, v) in dict { putMap[k] = v }
                }
            }
        }
        return result
    }

    // MARK: - makeUpRule（對應 Legado SourceRule.makeUpRule）
    // 展開 @get, {{}}, $N 模板，並分離 ## 正則

    private func makeUpRule(_ sourceRule: inout SourceRule, result: Any?) {
        if sourceRule.hasTemplates && !sourceRule.ruleParams.isEmpty {
            var infoVal = ""
            for (type, param) in sourceRule.ruleParams {
                switch type {
                case let n where n > 0:
                    // $N: regex group reference
                    if let list = result as? [String], list.count > n {
                        infoVal += list[n]
                    } else {
                        infoVal += param
                    }
                case -1:
                    // {{expression}}: JS 或規則
                    if isRuleExpression(param) {
                        let ruleList = splitSourceRule(param)
                        infoVal += getString(ruleList, content: content)
                    } else {
                        if let jsResult = evalJS(param, result: result) {
                            infoVal += stringifyResult(jsResult)
                        }
                    }
                case -2:
                    // @get:{key}
                    infoVal += runtime.get(param)
                default:
                    infoVal += param
                }
            }
            sourceRule.rule = infoVal
        }

        // 分離 ##
        let parts = sourceRule.rule.components(separatedBy: "##")
        sourceRule.rule = parts[0].trimmingCharacters(in: .whitespaces)
        sourceRule.replaceRegex = parts.count > 1 ? parts[1] : ""
        sourceRule.replacement = parts.count > 2 ? parts[2] : ""
        sourceRule.replaceFirst = parts.count > 3
    }

    private func isRuleExpression(_ s: String) -> Bool {
        s.hasPrefix("@") || s.hasPrefix("$.") || s.hasPrefix("$[") || s.hasPrefix("//")
    }

    // MARK: - putRule（對應 Legado AnalyzeRule.putRule）

    private func putRule(_ map: [String: String]) {
        for (key, value) in map {
            _ = runtime.put(key, getString(value, content: content))
        }
    }

    // MARK: - replaceRegex（對應 Legado AnalyzeRule.replaceRegex）

    private func replaceRegex(_ result: String, _ sourceRule: SourceRule) -> String {
        guard !sourceRule.replaceRegex.isEmpty else { return result }
        if sourceRule.replaceFirst {
            if let regex = try? NSRegularExpression(pattern: sourceRule.replaceRegex) {
                let nsResult = result as NSString
                let range = NSRange(location: 0, length: nsResult.length)
                if let match = regex.firstMatch(in: result, range: range),
                   let matchRange = Range(match.range, in: result) {
                    let matched = String(result[matchRange])
                    return matched.replacingOccurrences(
                        of: sourceRule.replaceRegex,
                        with: sourceRule.replacement,
                        options: .regularExpression
                    )
                }
                return ""
            }
            return sourceRule.replacement
        } else {
            if let _ = try? NSRegularExpression(pattern: sourceRule.replaceRegex) {
                return result.replacingOccurrences(
                    of: sourceRule.replaceRegex,
                    with: sourceRule.replacement,
                    options: .regularExpression
                )
            }
            return result.replacingOccurrences(of: sourceRule.replaceRegex, with: sourceRule.replacement)
        }
    }

    // MARK: - getString（對應 Legado AnalyzeRule.getString）
    // 這是核心方法：鏈式求值 SourceRule 列表

    func getString(_ ruleStr: String?, content mContent: Any? = nil, isUrl: Bool = false) -> String {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else { return "" }
        let ruleList = splitSourceRule(ruleStr)
        return getString(ruleList, content: mContent, isUrl: isUrl)
    }

    func getString(_ ruleList: [SourceRule], content mContent: Any? = nil, isUrl: Bool = false, unescape: Bool = true) -> String {
        var result: Any? = nil
        let workContent = mContent ?? content
        guard !ruleList.isEmpty else { return "" }

        result = workContent
        for var sourceRule in ruleList {
            putRule(sourceRule.putMap)
            let hadTemplates = sourceRule.hasTemplates
            makeUpRule(&sourceRule, result: result)
            guard result != nil else { continue }
            let rule = sourceRule.rule
            // 當模板展開後 rule 為空（如 {{java.timeFormat(...)}} 失敗），
            // 結果應為空字串，不應把原始 content 原封不動當結果傳遞。
            // 非模板規則的空 rule 則保持原行為（透傳 content）。
            if rule.isEmpty && hadTemplates && sourceRule.replaceRegex.isEmpty {
                result = "" as Any
            } else {
                if !rule.isEmpty {
                    result = evaluateSourceRule(sourceRule, on: result!, isUrl: isUrl)
                }
                if result != nil && !sourceRule.replaceRegex.isEmpty {
                    result = replaceRegex(stringifyResult(result!), sourceRule)
                }
            }
        }

        if result == nil { result = "" }
        var str = stringifyResult(result!)
        if unescape && str.contains("&") {
            str = str.htmlUnescaped
        }
        if isUrl {
            return str.isBlank ? (baseURL) : RuleEngine.resolveURL(str, base: baseURL)
        }
        return str
    }

    // MARK: - getStringList（對應 Legado AnalyzeRule.getStringList）

    func getStringList(_ ruleStr: String?, content mContent: Any? = nil, isUrl: Bool = false) -> [String]? {
        guard let ruleStr = ruleStr, !ruleStr.isEmpty else { return nil }
        let ruleList = splitSourceRule(ruleStr)
        return getStringList(ruleList, content: mContent, isUrl: isUrl)
    }

    func getStringList(_ ruleList: [SourceRule], content mContent: Any? = nil, isUrl: Bool = false) -> [String]? {
        var result: Any? = nil
        let workContent = mContent ?? content

        guard !ruleList.isEmpty else { return nil }
        result = workContent
        for var sourceRule in ruleList {
            putRule(sourceRule.putMap)
            makeUpRule(&sourceRule, result: result)
            guard result != nil else { continue }
            let rule = sourceRule.rule
            if !rule.isEmpty {
                result = evaluateSourceRuleForList(sourceRule, on: result!)
            }
            if !sourceRule.replaceRegex.isEmpty {
                if let list = result as? [Any] {
                    result = list.map { replaceRegex(stringifyResult($0), sourceRule) }
                } else if result != nil {
                    result = replaceRegex(stringifyResult(result!), sourceRule)
                }
            }
        }

        guard let result = result else { return nil }
        var resultList: [String]
        if let str = result as? String {
            resultList = str.components(separatedBy: "\n")
        } else if let list = result as? [Any] {
            resultList = list.map { stringifyResult($0) }
        } else {
            resultList = [stringifyResult(result)]
        }

        if isUrl {
            var urlList: [String] = []
            for url in resultList {
                let absolute = RuleEngine.resolveURL(url.trimmingCharacters(in: .whitespacesAndNewlines), base: baseURL)
                if !absolute.isEmpty && !urlList.contains(absolute) {
                    urlList.append(absolute)
                }
            }
            return urlList
        }
        return resultList
    }

    // MARK: - getElements（對應 Legado AnalyzeRule.getElements）

    func getElements(_ ruleStr: String) -> [Any] {
        guard !ruleStr.isEmpty else { return [] }
        let ruleList = splitSourceRule(ruleStr, allInOne: true)
        var result: Any? = content

        for var sourceRule in ruleList {
            putRule(sourceRule.putMap)
            makeUpRule(&sourceRule, result: result)
            guard result != nil else { continue }
            result = evaluateSourceRuleForElements(sourceRule, on: result!)
        }

        if let list = result as? [Any] { return list }
        return []
    }

    // MARK: - 求值 SourceRule（按 mode 分發）

    private func evaluateSourceRule(_ rule: SourceRule, on obj: Any, isUrl: Bool = false) -> Any? {
        let ruleStr = rule.rule
        if ruleStr.isEmpty { return obj }
        switch rule.mode {
        case .js:
            return evalJS(ruleStr, result: obj)
        case .json:
            return getAnalyzeByJSonPath(obj).getString(ruleStr) as Any?
        case .xpath:
            let html = objToHTML(obj)
            return RuleEngine.extractValueByXPath(html: html, xpath: ruleStr, baseURL: baseURL) as Any?
        case .defaultMode:
            let node = objToNode(obj)
            if isUrl {
                return extractByJSoup0(node: node, rule: ruleStr)
            }
            return extractByJSoup(node: node, rule: ruleStr)
        case .regex:
            return ruleStr
        }
    }

    private func evaluateSourceRuleForList(_ rule: SourceRule, on obj: Any) -> Any? {
        let ruleStr = rule.rule
        if ruleStr.isEmpty { return obj }
        switch rule.mode {
        case .js:
            return evalJS(ruleStr, result: obj)
        case .json:
            return getAnalyzeByJSonPath(obj).getStringList(ruleStr) as Any
        case .xpath:
            let html = objToHTML(obj)
            return extractListByXPath(html: html, rule: ruleStr)
        case .defaultMode:
            let node = objToNode(obj)
            return extractListByJSoup(node: node, rule: ruleStr)
        case .regex:
            return ruleStr
        }
    }

    private func evaluateSourceRuleForElements(_ rule: SourceRule, on obj: Any) -> Any? {
        let ruleStr = rule.rule
        if ruleStr.isEmpty { return obj }
        switch rule.mode {
        case .js:
            return evalJS(ruleStr, result: obj)
        case .json:
            return getAnalyzeByJSonPath(obj).getList(ruleStr) as Any
        case .xpath:
            let html = objToHTML(obj)
            let nodes = RuleEngine.extractListByXPath(html: html, xpath: ruleStr)
            return nodes as Any
        case .defaultMode:
            let node = objToNode(obj)
            return extractElementsByJSoup(node: node, rule: ruleStr) as Any
        case .regex:
            return obj
        }
    }

    // MARK: - JSoup CSS 求值（對應 Legado AnalyzeByJSoup）

    private func extractByJSoup(node: HTMLNode, rule: String) -> String? {
        if rule.isEmpty { return nil }
        let list = extractListByJSoup(node: node, rule: rule)
        if list.isEmpty { return nil }
        return list.joined(separator: "\n")
    }

    private func extractByJSoup0(node: HTMLNode, rule: String) -> String {
        let list = extractListByJSoup(node: node, rule: rule)
        return list.first ?? ""
    }

    /// 對應 Legado AnalyzeByJSoup.getStringList
    private func extractListByJSoup(node: HTMLNode, rule: String) -> [String] {
        if rule.isEmpty { return [] }

        // 檢查 @CSS: 前綴
        var isCss = false
        var elementsRule = rule
        if rule.lowercased().hasPrefix("@css:") {
            isCss = true
            elementsRule = String(rule.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }

        if elementsRule.isEmpty { return [] }

        // 用 RuleAnalyzer 分割 &&/||/%%
        let ruleAnalyzer = LegadoRuleAnalyzer(elementsRule)
        let rules = ruleAnalyzer.splitRule("&&", "||", "%%")

        var results: [[String]] = []
        for ruleStr in rules {
            let temp: [String]
            if isCss {
                // @CSS: 格式：css_selector@attr
                if let lastAt = ruleStr.lastIndex(of: "@") {
                    let cssSelector = String(ruleStr[..<lastAt])
                    let lastRule = String(ruleStr[ruleStr.index(after: lastAt)...])
                    let elements = node.select(cssSelector)
                    temp = getResultLast(elements, lastRule: lastRule)
                } else {
                    let elements = node.select(ruleStr)
                    temp = elements.map { $0.innerText }
                }
            } else {
                temp = getResultListJSoup(node: node, rule: ruleStr)
            }
            if !temp.isEmpty {
                results.append(temp)
                if ruleAnalyzer.elementsType == "||" { break }
            }
        }

        if results.isEmpty { return [] }
        if ruleAnalyzer.elementsType == "%%" {
            var textS: [String] = []
            let maxLen = results.map(\.count).max() ?? 0
            for i in 0..<maxLen {
                for temp in results {
                    if i < temp.count { textS.append(temp[i]) }
                }
            }
            return textS
        }
        return results.flatMap { $0 }
    }

    /// 對應 Legado AnalyzeByJSoup.getResultList
    private func getResultListJSoup(node: HTMLNode, rule: String) -> [String] {
        if rule.isEmpty { return [] }

        let ruleAnalyzer = LegadoRuleAnalyzer(rule)
        ruleAnalyzer.trim()
        let rules = ruleAnalyzer.splitRule("@")

        if rules.isEmpty { return [] }
        let last = rules.count - 1

        // 前段選擇元素
        var elements: [HTMLNode] = [node]
        for i in 0..<last {
            var nextElements: [HTMLNode] = []
            for elt in elements {
                nextElements.append(contentsOf: selectElementsSingle(elt, rule: rules[i]))
            }
            elements = nextElements
        }

        if elements.isEmpty { return [] }
        return getResultLast(elements, lastRule: rules[last])
    }

    /// 對應 Legado AnalyzeByJSoup.getElements
    private func extractElementsByJSoup(node: HTMLNode, rule: String) -> [Any] {
        if rule.isEmpty { return [] }

        var isCss = false
        var elementsRule = rule
        if rule.lowercased().hasPrefix("@css:") {
            isCss = true
            elementsRule = String(rule.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        }

        let ruleAnalyzer = LegadoRuleAnalyzer(elementsRule)
        let rules = ruleAnalyzer.splitRule("&&", "||", "%%")

        var elementsList: [[Any]] = []
        if isCss {
            for ruleStr in rules {
                let nodes = node.select(ruleStr)
                if !nodes.isEmpty {
                    elementsList.append(nodes)
                    if ruleAnalyzer.elementsType == "||" { break }
                }
            }
        } else {
            for ruleStr in rules {
                let rsRule = LegadoRuleAnalyzer(ruleStr)
                rsRule.trim()
                let rs = rsRule.splitRule("@")

                var el: [HTMLNode]
                if rs.count > 1 {
                    el = [node]
                    for rl in rs {
                        var es: [HTMLNode] = []
                        for et in el {
                            es.append(contentsOf: selectElementsSingle(et, rule: rl))
                        }
                        el = es
                    }
                } else {
                    el = selectElementsSingle(node, rule: ruleStr)
                }

                if !el.isEmpty {
                    elementsList.append(el)
                    if ruleAnalyzer.elementsType == "||" { break }
                }
            }
        }

        if elementsList.isEmpty { return [] }
        if ruleAnalyzer.elementsType == "%%" {
            var result: [Any] = []
            let maxLen = elementsList.map(\.count).max() ?? 0
            for i in 0..<maxLen {
                for es in elementsList {
                    if i < es.count { result.append(es[i]) }
                }
            }
            return result
        }
        return elementsList.flatMap { $0 }
    }

    /// 對應 Legado ElementsSingle.getElementsSingle（簡化版）
    private func selectElementsSingle(_ element: HTMLNode, rule: String) -> [HTMLNode] {
        // Legado 支持 class.xxx、tag.div、id.xxx、text.xxx、children 和 CSS
        // 也支持 [] 索引語法
        let r = rule.trimmingCharacters(in: .whitespaces)
        if r.isEmpty { return element.elements }

        // 嘗試 Legado JSOUP Default 路由
        if RuleEngine.isJsoupDefaultRule(r) {
            return RuleEngine.applyJsoupSegment(nodes: [element], segment: r)
        }

        // 否則嘗試 CSS 選擇器
        return element.select(r)
    }

    /// 對應 Legado AnalyzeByJSoup.getResultLast
    private func getResultLast(_ elements: [HTMLNode], lastRule: String) -> [String] {
        var textS: [String] = []
        switch lastRule.lowercased() {
        case "text":
            for el in elements {
                let text = el.innerText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { textS.append(text) }
            }
        case "textnodes":
            for el in elements {
                let text = el.textNodesContent
                if !text.isEmpty { textS.append(text) }
            }
        case "owntext":
            for el in elements {
                let text = el.directText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { textS.append(text) }
            }
        case "html":
            for el in elements {
                let html = RuleEngine.buildInnerHTML(el)
                if !html.isEmpty { textS.append(html) }
            }
        case "all":
            for el in elements {
                let html = RuleEngine.buildOuterHTML(el)
                if !html.isEmpty { textS.append(html) }
            }
        default:
            // 取屬性
            for el in elements {
                let url = el.attr(lastRule)
                if !url.isEmpty && !textS.contains(url) {
                    textS.append(url)
                }
            }
        }
        return textS
    }

    // MARK: - XPath 求值

    private func extractListByXPath(html: String, rule: String) -> [String] {
        RuleEngine.extractValueListByXPath(html: html, xpath: rule, baseURL: baseURL)
    }

    // MARK: - JavaScript 求值（對應 Legado evalJS）

    private func evalJS(_ jsStr: String, result: Any?) -> Any? {
        let context = JSContext()
        context?.exceptionHandler = { _, _ in }

        // 設定 bindings（對應 Legado）
        let bridge = NativeRuleJavaBridge(analyzer: self, currentResult: result)
        context?.setObject(bridge, forKeyedSubscript: "java" as NSString)

        // result
        if let strResult = result as? String {
            context?.setObject(strResult, forKeyedSubscript: "result" as NSString)
        } else if let dictResult = result as? [String: Any] {
            context?.setObject(dictResult, forKeyedSubscript: "result" as NSString)
        } else if let arrResult = result as? [Any] {
            context?.setObject(arrResult, forKeyedSubscript: "result" as NSString)
        } else {
            context?.setObject(stringifyResult(result ?? ""), forKeyedSubscript: "result" as NSString)
        }

        // baseUrl
        context?.setObject(baseURL, forKeyedSubscript: "baseUrl" as NSString)

        // source
        let sourceObj: [String: Any] = [
            "bookSourceUrl": source.bookSourceUrl,
            "bookSourceName": source.bookSourceName,
            "bookSourceGroup": source.bookSourceGroup,
            "loginUrl": source.loginUrl,
            "header": source.header,
        ]
        context?.setObject(sourceObj, forKeyedSubscript: "source" as NSString)

        // cookie（簡化）
        let cookieObj: [String: Any] = [:]
        context?.setObject(cookieObj, forKeyedSubscript: "cookie" as NSString)

        // src（原始內容）
        if let str = rootContent as? String {
            context?.setObject(str, forKeyedSubscript: "src" as NSString)
        }

        context?.exception = nil
        let value = context?.evaluateScript(jsStr)
        if let exception = context?.exception {
            return nil
        }
        guard let value = value, !value.isUndefined, !value.isNull else { return nil }

        // 轉換 JSValue 為 Swift 類型
        if value.isString { return value.toString() }
        if value.isNumber {
            let d = value.toDouble()
            if d == d.rounded() && abs(d) < 1e15 {
                return String(format: "%.0f", d)
            }
            return value.toNumber()?.stringValue
        }
        if value.isArray { return value.toArray() }
        if value.isObject { return value.toDictionary() }
        return value.toString()
    }

    // MARK: - 輔助方法

    private func objToHTML(_ obj: Any) -> String {
        if let str = obj as? String { return str }
        if let node = obj as? HTMLNode { return RuleEngine.buildOuterHTML(node) }
        if let dict = obj as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dict),
           let str = String(data: data, encoding: .utf8) { return str }
        if let arr = obj as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: arr),
           let str = String(data: data, encoding: .utf8) { return str }
        return "\(obj)"
    }

    /// 將任意物件轉為 HTMLNode，保留已有的 HTMLNode 避免不必要的序列化/反序列化。
    /// Legado 的 JSoup 分析器直接在 Element 上操作，不會多包 document wrapper。
    private func objToNode(_ obj: Any) -> HTMLNode {
        if let node = obj as? HTMLNode { return node }
        return parseHTML(objToHTML(obj))
    }

    func stringifyResult(_ obj: Any) -> String {
        if let s = obj as? String { return s }
        if obj is NSNull { return "" }
        if let n = obj as? NSNumber { return n.stringValue }
        if let node = obj as? HTMLNode { return node.innerText }
        if let data = try? JSONSerialization.data(withJSONObject: obj),
           let s = String(data: data, encoding: .utf8) { return s }
        return "\(obj)"
    }

    // MARK: - 高層 API（parseSearchResults / parseBookInfo / parseTOC / parseChapterPayload）

    func parseSearchResults() -> [OnlineBook] {
        let ruleStr = source.ruleSearch.bookList
        let items = getElements(ruleStr)
        return items.compactMap { item in
            let itemAnalyzer = NativeRuleAnalyzer(
                source: source, content: item, baseURL: baseURL,
                runtimeVariables: runtime.snapshot()
            )
            let name = itemAnalyzer.getString(source.ruleSearch.name, content: item).plainText
            let author = itemAnalyzer.getString(source.ruleSearch.author, content: item).plainText
            let bookUrl = itemAnalyzer.getString(source.ruleSearch.bookUrl, content: item, isUrl: true)

            // bookUrl 為空，或與搜索頁 URL 相同（規則匹配失敗回退到 baseURL），則丟棄
            guard !bookUrl.isEmpty, bookUrl != baseURL else { return nil }

            let intro = itemAnalyzer.getString(source.ruleSearch.intro, content: item).plainText
            let coverUrl = itemAnalyzer.getString(source.ruleSearch.coverUrl, content: item, isUrl: true)
            let lastChapter = itemAnalyzer.getString(source.ruleSearch.lastChapter, content: item).plainText
            let kind = itemAnalyzer.getString(source.ruleSearch.kind, content: item).plainText
            let wordCount = itemAnalyzer.getString(source.ruleSearch.wordCount, content: item).plainText

            return OnlineBook(
                name: name,
                author: author,
                intro: intro,
                coverUrl: coverUrl,
                bookUrl: bookUrl,
                tocUrl: bookUrl,
                wordCount: wordCount,
                lastChapter: lastChapter,
                kind: kind,
                sourceId: source.id,
                sourceName: source.bookSourceName,
                runtimeVariables: itemAnalyzer.runtimeSnapshot()
            )
        }
    }

    func parseBookInfo(bookUrl: String) -> OnlineBook {
        let preparedContent = preprocessBookInfoContent(bookUrl: bookUrl)
        let infoAnalyzer = NativeRuleAnalyzer(
            source: source, content: preparedContent, baseURL: baseURL,
            runtimeVariables: runtime.snapshot()
        )
        let tocUrl = infoAnalyzer.getString(source.ruleBookInfo.tocUrl, isUrl: true)
        return OnlineBook(
            name: infoAnalyzer.getString(source.ruleBookInfo.name).plainText,
            author: infoAnalyzer.getString(source.ruleBookInfo.author).plainText,
            intro: infoAnalyzer.getString(source.ruleBookInfo.intro).plainText,
            coverUrl: infoAnalyzer.getString(source.ruleBookInfo.coverUrl, isUrl: true),
            bookUrl: bookUrl,
            tocUrl: tocUrl.isEmpty ? bookUrl : tocUrl,
            wordCount: infoAnalyzer.getString(source.ruleBookInfo.wordCount).plainText,
            lastChapter: infoAnalyzer.getString(source.ruleBookInfo.lastChapter).plainText,
            kind: infoAnalyzer.getString(source.ruleBookInfo.kind).plainText,
            sourceId: source.id,
            sourceName: source.bookSourceName,
            runtimeVariables: infoAnalyzer.runtimeSnapshot()
        )
    }

    func parseTOC() -> [OnlineChapterRef] {
        let items = getElements(source.ruleToc.chapterList)
        let nameRuleList = splitSourceRule(source.ruleToc.chapterName)
        let urlRuleList = splitSourceRule(source.ruleToc.chapterUrl)

        return items.enumerated().map { index, item in
            let itemAnalyzer = NativeRuleAnalyzer(
                source: source, content: item, baseURL: baseURL,
                runtimeVariables: runtime.snapshot()
            )
            var url = itemAnalyzer.getString(urlRuleList, content: item, isUrl: true)

            // Legado 兜底：chapterUrl 為空時從 <a> 取 href
            if url.isEmpty, let node = item as? HTMLNode {
                let href = node.attr("href")
                if !href.isEmpty {
                    url = RuleEngine.resolveURL(href, base: baseURL)
                } else if let firstA = node.selectFirst("a") {
                    let childHref = firstA.attr("href")
                    if !childHref.isEmpty {
                        url = RuleEngine.resolveURL(childHref, base: baseURL)
                    }
                }
            }

            let title = itemAnalyzer.getString(nameRuleList, content: item)
            let isVolume = itemAnalyzer.getString(source.ruleToc.isVolume, content: item)
            let isVip = itemAnalyzer.getString(source.ruleToc.isVip, content: item)
            let isPay = itemAnalyzer.getString(source.ruleToc.isPay, content: item)

            if !url.isEmpty {
                url = RuleEngine.sanitizeExtractedURL(url)
                url = RuleEngine.resolveURL(url, base: baseURL)
            }

            let chapter = OnlineChapterRef(
                index: index,
                title: title.isEmpty ? "第\(index + 1)章" : title,
                url: url,
                isVolume: isVolume.lowercased() == "true" || isVolume == "1",
                isVip: isVip.lowercased() == "true" || isVip == "1",
                isPay: isPay.lowercased() == "true" || isPay == "1",
                runtimeVariables: itemAnalyzer.runtimeSnapshot()
            )
            return chapter
        }
    }

    func parseChapterPayload() -> ChapterParsePayload {
        let contentRule = source.ruleContent.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentStr: String
        if contentRule.isEmpty {
            contentStr = ""
        } else {
            contentStr = getString(contentRule)
        }

        // 取標題
        let titleRule = source.ruleContent.title
        let title: String
        if !titleRule.isEmpty {
            title = getString(titleRule)
        } else {
            title = ""
        }

        return ChapterParsePayload(
            content: contentStr.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title,
            sourceMatched: !contentStr.isEmpty,
            isPay: false,
            runtimeVariables: runtimeSnapshot()
        )
    }

    func extractSingleValue(_ rule: String) -> String {
        getString(rule)
    }

    // MARK: - preprocessBookInfoContent

    private func preprocessBookInfoContent(bookUrl: String) -> Any {
        let initRule = source.ruleBookInfo.initScript
        if !initRule.isEmpty {
            // Legado: analyzeRule.setContent(analyzeRule.getElement(it))
            let elements = getElements(initRule)
            if let firstElement = elements.first {
                return firstElement
            }
        }
        return rootContent
    }
}

// MARK: - RuleEngine JSON 輔助（對外接口）

extension RuleEngine {
    /// 將 JSON 值轉字串（公開版本，供 LegadoAnalyzeByJSonPath 使用）
    static func jsonValueToString(_ value: Any) -> String {
        if let s = value as? String { return s }
        if value is NSNull { return "" }
        if let n = value as? NSNumber { return n.stringValue }
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let s = String(data: data, encoding: .utf8) { return s }
        return ""
    }

    /// 遞歸搜索 JSON 樹中所有匹配指定 key 的值
    static func jsonSearchAllValues(_ node: Any, key: String) -> [Any] {
        var results: [Any] = []
        if let dict = node as? [String: Any] {
            if let val = dict[key] { results.append(val) }
            for (_, child) in dict {
                results.append(contentsOf: jsonSearchAllValues(child, key: key))
            }
        } else if let arr = node as? [Any] {
            for item in arr {
                results.append(contentsOf: jsonSearchAllValues(item, key: key))
            }
        }
        return results
    }

    /// 構建 innerHTML
    static func buildInnerHTML(_ node: HTMLNode) -> String {
        node.children.map { buildOuterHTML($0) }.joined()
    }

}

// MARK: - String 輔助

private extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 輕量 HTML → 純文字：<br> 轉換行，移除其他標籤，解碼 HTML entities
    var plainText: String {
        guard contains("<") else { return self }
        var s = self
        // <br> → \n
        if let br = try? NSRegularExpression(pattern: "<br\\s*/?>", options: .caseInsensitive) {
            s = br.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n")
        }
        // 塊級閉標籤 → \n
        if let block = try? NSRegularExpression(pattern: "</(?:p|div|li|blockquote|section|h[1-6])>", options: .caseInsensitive) {
            s = block.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n")
        }
        // 移除剩餘標籤
        if let tags = try? NSRegularExpression(pattern: "<[^>]+>") {
            s = tags.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.htmlUnescaped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var htmlUnescaped: String {
        guard contains("&") else { return self }
        var s = self
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&#x27;", "'"), ("&#x2F;", "/"),
        ]
        for (entity, char) in entities {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        // 處理 &#NNN; 和 &#xHHH;
        if let regex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            let nsStr = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: nsStr.length))
            for match in matches.reversed() {
                let numRange = match.range(at: 1)
                let num = nsStr.substring(with: numRange)
                if let code = UInt32(num), let scalar = Unicode.Scalar(code) {
                    s = (s as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
        }
        if let regex = try? NSRegularExpression(pattern: #"&#x([0-9a-fA-F]+);"#) {
            let nsStr = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: nsStr.length))
            for match in matches.reversed() {
                let hexRange = match.range(at: 1)
                let hex = nsStr.substring(with: hexRange)
                if let code = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(code) {
                    s = (s as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
                }
            }
        }
        return s
    }
}

final class NativeRuleEngineRunner {
    static let shared = NativeRuleEngineRunner()

    private init() {}

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> [OnlineBook] {
        NativeRuleAnalyzer(
            source: source,
            content: html,
            baseURL: baseURL,
            runtimeVariables: runtimeVariables
        ).parseSearchResults()
    }

    func parseBookInfo(
        html: String,
        bookUrl: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> OnlineBook {
        NativeRuleAnalyzer(
            source: source,
            content: html,
            baseURL: baseURL,
            runtimeVariables: runtimeVariables
        ).parseBookInfo(bookUrl: bookUrl)
    }

    func parseTOC(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> [OnlineChapterRef] {
        NativeRuleAnalyzer(
            source: source,
            content: html,
            baseURL: baseURL,
            runtimeVariables: runtimeVariables
        ).parseTOC()
    }

    func parseChapterPayload(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> ChapterParsePayload {
        NativeRuleAnalyzer(
            source: source,
            content: html,
            baseURL: baseURL,
            runtimeVariables: runtimeVariables
        ).parseChapterPayload()
    }

    func extractSingleValue(
        html: String,
        baseURL: String,
        rule: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> String {
        NativeRuleAnalyzer(
            source: source,
            content: html,
            baseURL: baseURL,
            runtimeVariables: runtimeVariables
        ).extractSingleValue(rule)
    }

    func extractStringList(
        html: String,
        baseURL: String,
        rule: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        isURL: Bool = false
    ) throws -> [String] {
        NativeRuleAnalyzer(
            source: source,
            content: html,
            baseURL: baseURL,
            runtimeVariables: runtimeVariables
        ).getStringList(rule, isUrl: isURL) ?? []
    }
}

protocol WebNovelParserService: AnyObject {
    func resolveURL(_ raw: String, base: String) -> String
    func sanitizeExtractedURL(_ raw: String) -> String
    func applyReplaceRegex(_ text: String, rules: String) -> String
    func extractValue(fromHTML html: String, rule: String, baseURL: String) -> String

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) throws -> [OnlineBook]

    func parseBookInfo(
        html: String,
        bookUrl: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) throws -> OnlineBook

    func parseTOC(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) throws -> [OnlineChapterRef]

    func parseChapterPayload(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) throws -> ChapterParsePayload

    func extractSingleValue(
        html: String,
        baseURL: String,
        rule: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) throws -> String

    func extractStringList(
        html: String,
        baseURL: String,
        rule: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        isURL: Bool
    ) throws -> [String]
}

enum ParserExtractionMode {
    case native
    case modern
}

final class DefaultWebNovelParserService: WebNovelParserService {
    static let shared = DefaultWebNovelParserService()
    static var extractionMode: ParserExtractionMode = .native

    private let nativeRunner: NativeRuleEngineRunner
    private let modernRuleEngine: ModernRuleEngine

    init(
        nativeRunner: NativeRuleEngineRunner = .shared,
        modernRuleEngine: ModernRuleEngine = ModernRuleEngine()
    ) {
        self.nativeRunner = nativeRunner
        self.modernRuleEngine = modernRuleEngine
    }

    func resolveURL(_ raw: String, base: String) -> String {
        RuleEngine.resolveURL(raw, base: base)
    }

    func sanitizeExtractedURL(_ raw: String) -> String {
        RuleEngine.sanitizeExtractedURL(raw)
    }

    func applyReplaceRegex(_ text: String, rules: String) -> String {
        RuleEngine.applyReplaceRegex(text, rules: rules)
    }

    func extractValue(fromHTML html: String, rule: String, baseURL: String) -> String {
        switch Self.extractionMode {
        case .native:
            return RuleEngine.extractValue(fromHTML: html, rule: rule, baseURL: baseURL)
        case .modern:
            if let value = try? modernRuleEngine.extractValue(from: html, rule: rule, baseURL: baseURL) {
                return value
            }
            return RuleEngine.extractValue(fromHTML: html, rule: rule, baseURL: baseURL)
        }
    }

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) throws -> [OnlineBook] {
        try nativeRunner.parseSearchResults(
            html: html,
            baseURL: baseURL,
            source: source,
            runtimeVariables: runtimeVariables
        )
    }

    func parseBookInfo(
        html: String,
        bookUrl: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) throws -> OnlineBook {
        try nativeRunner.parseBookInfo(
            html: html,
            bookUrl: bookUrl,
            baseURL: baseURL,
            source: source,
            runtimeVariables: runtimeVariables
        )
    }

    func parseTOC(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) throws -> [OnlineChapterRef] {
        try nativeRunner.parseTOC(
            html: html,
            baseURL: baseURL,
            source: source,
            runtimeVariables: runtimeVariables
        )
    }

    func parseChapterPayload(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) throws -> ChapterParsePayload {
        try nativeRunner.parseChapterPayload(
            html: html,
            baseURL: baseURL,
            source: source,
            runtimeVariables: runtimeVariables
        )
    }

    func extractSingleValue(
        html: String,
        baseURL: String,
        rule: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) throws -> String {
        switch Self.extractionMode {
        case .native:
            return try nativeRunner.extractSingleValue(
                html: html,
                baseURL: baseURL,
                rule: rule,
                source: source,
                runtimeVariables: runtimeVariables
            )
        case .modern:
            if let value = try? modernRuleEngine.extractValue(from: html, rule: rule, baseURL: baseURL), !value.isEmpty {
                return value
            }
            return try nativeRunner.extractSingleValue(
                html: html,
                baseURL: baseURL,
                rule: rule,
                source: source,
                runtimeVariables: runtimeVariables
            )
        }
    }

    func extractStringList(
        html: String,
        baseURL: String,
        rule: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        isURL: Bool
    ) throws -> [String] {
        switch Self.extractionMode {
        case .native:
            return try nativeRunner.extractStringList(
                html: html,
                baseURL: baseURL,
                rule: rule,
                source: source,
                runtimeVariables: runtimeVariables,
                isURL: isURL
            )
        case .modern:
            if let values = try? modernRuleEngine.extractList(from: html, rule: rule, baseURL: baseURL), !values.isEmpty {
                if isURL {
                    return values.map { RuleEngine.resolveURL($0, base: baseURL) }
                }
                return values
            }
            return try nativeRunner.extractStringList(
                html: html,
                baseURL: baseURL,
                rule: rule,
                source: source,
                runtimeVariables: runtimeVariables,
                isURL: isURL
            )
        }
    }
}
