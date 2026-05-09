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

    // MARK: - 執行緒安全 Regex 快取
    //
    // NSRegularExpression 的初始化涉及 NFA 編譯，在大量章節解析時（每個捕獲組、每條替換規則
    // 各呼叫一次 applyRegex / extractRegexAllInOneMatches）會造成明顯的 CPU 峰值。
    // NSCache 是執行緒安全的，且在記憶體壓力時會自動驅逐條目。
    private static let regexCache = NSCache<NSString, NSRegularExpression>()

    /// 取得已編譯的 NSRegularExpression，優先從快取讀取。
    /// - Returns: 編譯後的實例，pattern 非法時回傳 nil。
    static func cachedRegex(pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        let cacheKey = "\(options.rawValue):\(pattern)" as NSString
        if let cached = regexCache.object(forKey: cacheKey) { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        regexCache.setObject(regex, forKey: cacheKey)
        return regex
    }

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
        if let hrefRegex = cachedRegex(pattern: #"href\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive) {
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
        if let srcRegex = cachedRegex(pattern: #"src\s*=\s*["']([^"']+)["']"#, options: .caseInsensitive) {
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
            if let regex = cachedRegex(pattern: pattern) {
                let range = NSRange(text.startIndex..., in: text)
                return regex.stringByReplacingMatches(
                    in: text, range: range, withTemplate: replacement)
            }
        } else {
            // Legado 相容：單 ##pattern 為移除模式（全部替換為空字串）
            if let regex = cachedRegex(pattern: pattern, options: .caseInsensitive) {
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
