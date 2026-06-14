import Foundation

// MARK: - JSONPathEvaluator

/// Pure-Swift JSONPath engine supporting jayway-compatible syntax.
///
/// Supported features:
///   - Dot notation: `$.store.book`
///   - Bracket notation: `$['store']['book']`
///   - Array indexing (incl. negative): `$[0]`, `$[-1]`
///   - Wildcards: `$[*]`, `$.store.*`
///   - Deep scan: `$..author`
///   - Array slicing: `$[0:3]`, `$[1:5:2]`, `$[-2:]`
///   - Filter expressions: `$[?(@.price < 10)]`
///   - Multi-index / multi-key: `$[0,1]`, `$['a','b']`
///   - Length function: `$.store.book.length()`
final class JSONPathEvaluator {

    // MARK: - Segment

    private enum Segment {
        case root
        case child(String)
        case deepChild(String)          // ..key
        case deepWild                    // ..* or ..[
        case index(Int)
        case slice(Int?, Int?, Int?)     // start:end:step
        case wild                        // [*] or .*
        case filter(String)             // [?(...)]
        case length                      // .length()
        case indices([Int])             // [0,1,2]
        case keys([String])             // ['a','b']
    }

    // MARK: - Public API

    /// Evaluate a JSONPath expression and return all matching values.
    static func query(_ path: String, on data: Any) -> [Any] {
        let segments = tokenize(path)
        guard !segments.isEmpty else { return [] }
        var nodes: [Any] = [data]
        for segment in segments {
            nodes = apply(segment, to: nodes)
            if nodes.isEmpty { break }
        }
        return nodes
    }

    // MARK: - Tokenizer

    private static func tokenize(_ path: String) -> [Segment] {
        var segments: [Segment] = []
        let chars = Array(path)
        var i = 0

        guard i < chars.count, chars[i] == "$" else { return [] }
        segments.append(.root)
        i += 1

        while i < chars.count {
            if chars[i] == "." {
                i += 1
                guard i < chars.count else { break }

                if chars[i] == "." {
                    // Recursive descent (..)
                    i += 1
                    if i >= chars.count {
                        break
                    } else if chars[i] == "*" {
                        segments.append(.deepWild)
                        i += 1
                    } else if chars[i] == "[" {
                        segments.append(.deepWild)
                        // Don't advance — let bracket be parsed next iteration
                    } else {
                        let key = readDotKey(chars, &i)
                        if !key.isEmpty {
                            segments.append(.deepChild(key))
                        }
                    }
                } else if chars[i] == "*" {
                    segments.append(.wild)
                    i += 1
                } else {
                    let key = readDotKey(chars, &i)
                    if key == "length()" {
                        segments.append(.length)
                    } else if !key.isEmpty {
                        segments.append(.child(key))
                    }
                }
            } else if chars[i] == "[" {
                i += 1
                let content = readBracketContent(chars, &i)
                segments.append(parseBracket(content))
            } else {
                i += 1
            }
        }

        return segments
    }

    // MARK: - Tokenizer Helpers

    private static func readDotKey(_ chars: [Character], _ i: inout Int) -> String {
        var key = ""
        while i < chars.count && chars[i] != "." && chars[i] != "[" {
            key.append(chars[i])
            i += 1
        }
        return key
    }

    private static func readBracketContent(_ chars: [Character], _ i: inout Int) -> String {
        var content = ""
        var depth = 1
        var inSQ = false, inDQ = false

        while i < chars.count && depth > 0 {
            let c = chars[i]
            if c == "'" && !inDQ { inSQ.toggle() }
            else if c == "\"" && !inSQ { inDQ.toggle() }

            if !inSQ && !inDQ {
                if c == "[" { depth += 1 }
                else if c == "]" {
                    depth -= 1
                    if depth == 0 { i += 1; break }
                }
            }
            content.append(c)
            i += 1
        }
        return content
    }

    private static func parseBracket(_ content: String) -> Segment {
        let t = content.trimmingCharacters(in: .whitespaces)

        if t == "*" { return .wild }

        // Filter: [?(...)]
        if t.hasPrefix("?(") && t.hasSuffix(")") {
            return .filter(String(t.dropFirst(2).dropLast()))
        }

        // Quoted key(s)
        if t.hasPrefix("'") || t.hasPrefix("\"") {
            let keys = parseQuotedKeys(t)
            return keys.count == 1 ? .child(keys[0]) : .keys(keys)
        }

        // Slice (contains ':')
        if t.contains(":") {
            let parts = t.split(separator: ":", maxSplits: 2,
                                omittingEmptySubsequences: false)
            let s = parts.count > 0 ? Int(parts[0].trimmingCharacters(in: .whitespaces)) : nil
            let e = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
            let st = parts.count > 2 ? Int(parts[2].trimmingCharacters(in: .whitespaces)) : nil
            return .slice(s, e, st)
        }

        // Comma-separated
        if t.contains(",") {
            let raw = t.split(separator: ",")
            let ints = raw.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if ints.count == raw.count { return .indices(ints) }
            let strs = raw.map {
                $0.trimmingCharacters(in: .whitespaces)
                  .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            }
            return .keys(strs)
        }

        // Single integer index
        if let idx = Int(t) { return .index(idx) }

        // Fallback: child key
        return .child(t)
    }

    private static func parseQuotedKeys(_ content: String) -> [String] {
        var keys: [String] = []
        let chars = Array(content)
        var i = 0
        while i < chars.count {
            if chars[i] == "'" || chars[i] == "\"" {
                let q = chars[i]; i += 1
                var key = ""
                while i < chars.count && chars[i] != q {
                    if chars[i] == "\\" && i + 1 < chars.count { i += 1 }
                    key.append(chars[i]); i += 1
                }
                keys.append(key)
                if i < chars.count { i += 1 }
            } else {
                i += 1
            }
        }
        return keys
    }

    // MARK: - Segment Evaluation

    private static func apply(_ segment: Segment, to nodes: [Any]) -> [Any] {
        var result: [Any] = []

        for node in nodes {
            switch segment {
            case .root:
                result.append(node)

            case .child(let key):
                if let dict = node as? [String: Any], let val = dict[key] {
                    result.append(val)
                }

            case .deepChild(let key):
                result.append(contentsOf: deepScan(key: key, in: node))

            case .deepWild:
                result.append(contentsOf: allDescendants(of: node))

            case .index(let idx):
                if let arr = node as? [Any] {
                    let r = idx < 0 ? arr.count + idx : idx
                    if r >= 0 && r < arr.count { result.append(arr[r]) }
                }

            case .slice(let s, let e, let st):
                if let arr = node as? [Any] {
                    result.append(contentsOf: applySlice(arr, start: s, end: e, step: st))
                }

            case .wild:
                if let arr = node as? [Any] {
                    result.append(contentsOf: arr)
                } else if let dict = node as? [String: Any] {
                    result.append(contentsOf: dict.values)
                }

            case .filter(let expr):
                if let arr = node as? [Any] {
                    result.append(contentsOf: arr.filter { evaluateFilter(expr, on: $0) })
                }

            case .length:
                if let arr = node as? [Any] { result.append(arr.count) }
                else if let dict = node as? [String: Any] { result.append(dict.count) }
                else if let str = node as? String { result.append(str.count) }

            case .indices(let idxs):
                if let arr = node as? [Any] {
                    for idx in idxs {
                        let r = idx < 0 ? arr.count + idx : idx
                        if r >= 0 && r < arr.count { result.append(arr[r]) }
                    }
                }

            case .keys(let ks):
                if let dict = node as? [String: Any] {
                    for k in ks { if let v = dict[k] { result.append(v) } }
                }
            }
        }
        return result
    }

    // MARK: - Deep Scan

    private static func deepScan(key: String, in node: Any) -> [Any] {
        var results: [Any] = []
        if let dict = node as? [String: Any] {
            if let val = dict[key] { results.append(val) }
            for (_, v) in dict { results.append(contentsOf: deepScan(key: key, in: v)) }
        } else if let arr = node as? [Any] {
            for elem in arr { results.append(contentsOf: deepScan(key: key, in: elem)) }
        }
        return results
    }

    /// Collect every descendant value (children, grandchildren, …) excluding the node itself.
    private static func allDescendants(of node: Any) -> [Any] {
        var results: [Any] = []
        if let dict = node as? [String: Any] {
            for (_, v) in dict {
                results.append(v)
                results.append(contentsOf: allDescendants(of: v))
            }
        } else if let arr = node as? [Any] {
            for elem in arr {
                results.append(elem)
                results.append(contentsOf: allDescendants(of: elem))
            }
        }
        return results
    }

    // MARK: - Slicing

    private static func applySlice(_ arr: [Any], start: Int?, end: Int?, step: Int?) -> [Any] {
        let count = arr.count
        let st = step ?? 1
        guard st != 0 else { return [] }

        var result: [Any] = []
        if st > 0 {
            let s = resolve(start ?? 0, count: count)
            let e = resolve(end ?? count, count: count)
            var i = max(s, 0)
            while i < min(e, count) { result.append(arr[i]); i += st }
        } else {
            let s = resolve(start ?? (count - 1), count: count)
            let e = resolve(end ?? -(count + 1), count: count)
            var i = min(s, count - 1)
            while i > max(e, -1) {
                if i >= 0 && i < count { result.append(arr[i]) }
                i += st
            }
        }
        return result
    }

    private static func resolve(_ idx: Int, count: Int) -> Int {
        idx < 0 ? count + idx : idx
    }

    // MARK: - Filter Evaluation

    static func evaluateFilter(_ expr: String, on element: Any) -> Bool {
        let t = expr.trimmingCharacters(in: .whitespaces)

        // OR
        let orParts = splitFilter(t, by: "||")
        if orParts.count > 1 { return orParts.contains { evaluateFilter($0, on: element) } }

        // AND
        let andParts = splitFilter(t, by: "&&")
        if andParts.count > 1 { return andParts.allSatisfy { evaluateFilter($0, on: element) } }

        // Negation
        if t.hasPrefix("!") {
            return !evaluateFilter(String(t.dropFirst()).trimmingCharacters(in: .whitespaces),
                                   on: element)
        }

        // Parenthesized
        if t.hasPrefix("(") && t.hasSuffix(")") && isOuterParens(t) {
            return evaluateFilter(String(t.dropFirst().dropLast()), on: element)
        }

        // Comparison
        if let (left, op, right) = findComparison(t) {
            let lVal = resolveFilterValue(left, in: element)
            let rVal = resolveFilterValue(right, in: element)
            return compare(lVal, op, rVal)
        }

        // Existence check
        if let val = resolveFilterPath(t, in: element) { return !isNullish(val) }

        return false
    }

    /// Split a filter expression by a logical operator, respecting quotes and parens.
    private static func splitFilter(_ expr: String, by op: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inSQ = false, inDQ = false
        let chars = Array(expr)
        let opChars = Array(op)
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDQ { inSQ.toggle(); current.append(c); i += 1; continue }
            if c == "\"" && !inSQ { inDQ.toggle(); current.append(c); i += 1; continue }
            if inSQ || inDQ { current.append(c); i += 1; continue }

            if c == "(" || c == "[" { depth += 1 }
            if c == ")" || c == "]" { depth -= 1 }

            if depth == 0 && i + opChars.count <= chars.count
                && Array(chars[i..<i+opChars.count]) == opChars {
                parts.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                i += opChars.count
                continue
            }
            current.append(c)
            i += 1
        }
        parts.append(current.trimmingCharacters(in: .whitespaces))
        return parts
    }

    /// Check whether the first `(` and last `)` are a matching pair that wraps the entire string.
    private static func isOuterParens(_ s: String) -> Bool {
        var depth = 0
        for (i, c) in s.enumerated() {
            if c == "(" { depth += 1 }
            if c == ")" { depth -= 1 }
            if depth == 0 && i < s.count - 1 { return false }
        }
        return depth == 0
    }

    /// Scan for the first comparison operator outside quotes.
    private static func findComparison(_ expr: String) -> (String, String, String)? {
        let ops = ["!=", "<=", ">=", "==", "=~", "<", ">"]
        let chars = Array(expr)
        var inSQ = false, inDQ = false
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c == "'" && !inDQ { inSQ.toggle(); i += 1; continue }
            if c == "\"" && !inSQ { inDQ.toggle(); i += 1; continue }
            if inSQ || inDQ { i += 1; continue }

            for op in ops {
                let opArr = Array(op)
                guard i + opArr.count <= chars.count else { continue }
                if Array(chars[i..<i+opArr.count]) == opArr {
                    let left  = String(chars[0..<i]).trimmingCharacters(in: .whitespaces)
                    let right = String(chars[(i+opArr.count)...]).trimmingCharacters(in: .whitespaces)
                    if !left.isEmpty && !right.isEmpty { return (left, op, right) }
                }
            }
            i += 1
        }
        return nil
    }

    // MARK: - Filter Value Resolution

    /// Resolve `@.field.sub` paths against the current element.
    private static func resolveFilterPath(_ path: String, in element: Any) -> Any? {
        let t = path.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("@") else { return nil }
        let rest = String(t.dropFirst())
        if rest.isEmpty { return element }

        var current: Any = element
        let chars = Array(rest)
        var i = 0

        while i < chars.count {
            if chars[i] == "." {
                i += 1
                var key = ""
                while i < chars.count && chars[i] != "." && chars[i] != "[" {
                    key.append(chars[i]); i += 1
                }
                guard let dict = current as? [String: Any], let val = dict[key] else { return nil }
                current = val
            } else if chars[i] == "[" {
                i += 1
                if i < chars.count && (chars[i] == "'" || chars[i] == "\"") {
                    let q = chars[i]; i += 1
                    var key = ""
                    while i < chars.count && chars[i] != q { key.append(chars[i]); i += 1 }
                    if i < chars.count { i += 1 } // closing quote
                    if i < chars.count && chars[i] == "]" { i += 1 }
                    guard let dict = current as? [String: Any], let val = dict[key] else { return nil }
                    current = val
                } else {
                    var numStr = ""
                    while i < chars.count && chars[i] != "]" { numStr.append(chars[i]); i += 1 }
                    if i < chars.count { i += 1 }
                    guard let idx = Int(numStr), let arr = current as? [Any] else { return nil }
                    let r = idx < 0 ? arr.count + idx : idx
                    guard r >= 0 && r < arr.count else { return nil }
                    current = arr[r]
                }
            } else {
                i += 1
            }
        }
        return current
    }

    /// Resolve a filter token to a concrete value.
    private static func resolveFilterValue(_ token: String, in element: Any) -> Any? {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("@") { return resolveFilterPath(t, in: element) }
        if (t.hasPrefix("'") && t.hasSuffix("'"))
            || (t.hasPrefix("\"") && t.hasSuffix("\"")) {
            return String(t.dropFirst().dropLast())
        }
        if t == "true" { return true }
        if t == "false" { return false }
        if t == "null" { return NSNull() }
        if let d = Double(t) { return d }
        return t
    }

    // MARK: - Comparison Helpers

    private static func compare(_ left: Any?, _ op: String, _ right: Any?) -> Bool {
        switch op {
        case "==": return isEqual(left, right)
        case "!=": return !isEqual(left, right)
        case "<":
            return numCmp(left, right) == .orderedAscending
        case ">":
            return numCmp(left, right) == .orderedDescending
        case "<=":
            let r = numCmp(left, right); return r == .orderedAscending || r == .orderedSame
        case ">=":
            let r = numCmp(left, right); return r == .orderedDescending || r == .orderedSame
        case "=~":
            let str = stringify(left)
            var pat = stringify(right)
            if pat.hasPrefix("/") && pat.hasSuffix("/") && pat.count > 1 {
                pat = String(pat.dropFirst().dropLast())
            }
            guard let regex = try? NSRegularExpression(pattern: pat) else { return false }
            return regex.firstMatch(in: str, range: NSRange(str.startIndex..., in: str)) != nil
        default: return false
        }
    }

    private static func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        if isNullish(a) && isNullish(b) { return true }
        if isNullish(a) || isNullish(b) { return false }
        guard let a = a, let b = b else { return false }
        if let na = toDouble(a), let nb = toDouble(b) { return na == nb }
        return stringify(a) == stringify(b)
    }

    private static func numCmp(_ a: Any?, _ b: Any?) -> ComparisonResult {
        guard let a = a, let b = b else { return .orderedSame }
        if let na = toDouble(a), let nb = toDouble(b) {
            if na < nb { return .orderedAscending }
            if na > nb { return .orderedDescending }
            return .orderedSame
        }
        return stringify(a).compare(stringify(b))
    }

    private static func toDouble(_ v: Any) -> Double? {
        if let d = v as? Double { return d }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    private static func isNullish(_ v: Any?) -> Bool {
        guard let v = v else { return true }
        return v is NSNull
    }

    // MARK: - Stringify

    static func stringify(_ value: Any?) -> String {
        guard let value = value else { return "" }
        if let s = value as? String { return s }
        if value is NSNull { return "" }

        if let n = value as? NSNumber {
            // Distinguish JSON boolean from number via ObjC type encoding
            if n.objCType.pointee == 0x63 /* 'c' = BOOL */ {
                return n.boolValue ? "true" : "false"
            }
            let d = n.doubleValue
            if d.truncatingRemainder(dividingBy: 1) == 0 && !d.isInfinite && !d.isNaN
                && abs(d) < 1e15 {
                return "\(Int64(d))"
            }
            return n.stringValue
        }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: []),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "\(value)"
    }
}

// MARK: - JsonExtractor

struct JsonExtractor: RuleExtractor {

    func canHandle(rule: String) -> Bool {
        let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        return lowered.hasPrefix("@json:") || trimmed.hasPrefix("$.") || trimmed.hasPrefix("$[")
    }

    func extractList(from content: String, rule: String, baseURL: String) throws -> [String] {
        guard let json = parseJSON(content) else { return [] }
        let path = cleanRule(rule)
        let expanded = expandInnerRules(path, json: json)
        let effectivePath = expanded.isEmpty ? path : expanded

        let results = JSONPathEvaluator.query(effectivePath, on: json)

        // Flatten one level: if a result is an array, expand its elements.
        // This matches Legado's getList which returns a flat ArrayList<Any>.
        var strings: [String] = []
        for r in results {
            if let arr = r as? [Any] {
                for elem in arr { strings.append(JSONPathEvaluator.stringify(elem)) }
            } else {
                strings.append(JSONPathEvaluator.stringify(r))
            }
        }
        return strings.filter { !$0.isEmpty }
    }

    func extractValue(from content: String, rule: String, baseURL: String) throws -> String {
        guard let json = parseJSON(content) else { return "" }
        let path = cleanRule(rule)
        let expanded = expandInnerRules(path, json: json)
        let effectivePath = expanded.isEmpty ? path : expanded

        // If expansion replaced the entire rule with a concrete value, return it.
        if !effectivePath.hasPrefix("$") { return effectivePath }

        let results = JSONPathEvaluator.query(effectivePath, on: json)
        if results.isEmpty { return "" }

        // Single result → stringify directly
        if results.count == 1 { return JSONPathEvaluator.stringify(results[0]) }

        // Multiple results → join with newline (matching Legado)
        return results
            .map { JSONPathEvaluator.stringify($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

        /// Extract raw JSON objects (for `getElements` pipeline).
    /// Unlike `extractList` (which stringifies everything), this returns
    /// raw `[String: Any]` / `[Any]` objects so that a subsequent `<js>` filter
    /// can access properties like `item.BookName` directly.
    func extractRawElements(from content: String, rule: String) -> [Any] {
        guard let json = parseJSON(content) else { return [] }
        let path = cleanRule(rule)
        let results = JSONPathEvaluator.query(path, on: json)
        var objects: [Any] = []
        for r in results {
            if let arr = r as? [Any] {
                objects.append(contentsOf: arr)
            } else {
                objects.append(r)
            }
        }
        return objects
    }

    // MARK: - Private Helpers

    private func parseJSON(_ content: String) -> Any? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private func cleanRule(_ rule: String) -> String {
        var r = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.lowercased().hasPrefix("@json:") {
            r = String(r.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if r.hasPrefix(".") {
            r = "$" + r
        } else if !r.isEmpty, !r.hasPrefix("$") {
            r = "$." + r
        }
        return r
    }

    /// Expand `{$.inner.path}` references within a rule string.
    private func expandInnerRules(_ rule: String, json: Any) -> String {
        let analyzer = RuleAnalyzer(data: rule, code: true)
        return analyzer.innerRule(inner: "{$.") { innerPath in
            let values = JSONPathEvaluator.query(innerPath, on: json)
            if values.isEmpty { return nil }
            if values.count == 1 { return JSONPathEvaluator.stringify(values[0]) }
            return values.map { JSONPathEvaluator.stringify($0) }.joined(separator: "\n")
        }
    }
}
