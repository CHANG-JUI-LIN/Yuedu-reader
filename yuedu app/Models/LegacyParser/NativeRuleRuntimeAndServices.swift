import Foundation
import JavaScriptCore

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
