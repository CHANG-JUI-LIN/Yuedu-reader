// Port of io.legado.app.model.analyzeRule.AnalyzeUrl
// Converts Legado's custom URL format into iOS URLRequest objects.

import Foundation

class AnalyzeUrl {

    // MARK: - Parsed Components

    /// Final resolved URL (no query string for GET; full URL for POST).
    private(set) var url: String = ""

    /// HTTP method — "GET" or "POST".
    private(set) var method: String = "GET"

    /// Request body string (POST only).
    private(set) var body: String?

    /// Merged header map (source defaults + per-rule overrides).
    private(set) var headers: [String: String] = [:]

    /// Response charset override (e.g. "gbk"). nil means UTF-8.
    private(set) var charset: String?

    /// Number of automatic retries.
    private(set) var retry: Int = 0

    /// Whether the rule requires a WebView-based fetch.
    private(set) var useWebView: Bool = false

    /// JavaScript to execute inside WebView after page load.
    private(set) var webJs: String?

    /// Delay in milliseconds before extracting WebView content.
    private(set) var webViewDelayTime: Int = 0

    /// Content type hint from the rule ("text", "json", etc.).
    private(set) var type: String?

    /// Optional server identifier for multi-server setups.
    private(set) var serverID: String?

    // MARK: - Internal State

    /// URL portion without query string (used for GET requests).
    private var urlNoQuery: String = ""

    /// Encoded query string for GET requests.
    private var encodedQuery: String?

    /// Encoded form body for POST requests.
    private var encodedForm: String?

    /// Base URL for resolving relative paths.
    private var baseUrl: String?

    /// The page number (1-based) for template replacement.
    private let page: Int?

    /// Search keyword for template replacement.
    private let key: String?

    /// Speak text for TTS rules.
    private let speakText: String?

    /// Speak speed for TTS rules.
    private let speakSpeed: Int?

    /// Optional JS evaluator closure used by `<js>` / `@js:` URL rules and
    /// `{{...}}` expressions. This must be available before `initUrl(_:)` runs.
    /// Signature: (jsCode, bindings) -> result string
    var jsEvaluator: ((String, [String: Any]) -> String?)?

    /// RuleData sources for `@get:{}` variable resolution.
    private weak var source: RuleDataInterface?
    private weak var ruleData: RuleDataInterface?
    private weak var chapter: RuleDataInterface?

    // MARK: - Regex Patterns (matching Legado companion object)

    /// Matches `, {` boundary between URL and JSON options.
    static let paramPattern = try! NSRegularExpression(pattern: "\\s*,\\s*(?=\\{)")

    /// Matches `<page1,page2,...>` page-rule blocks.
    static let pagePattern = try! NSRegularExpression(pattern: "<(.*?)>")

    /// Matches `@js:` or `<js>...</js>` blocks (for future JS support).
    static let jsPattern = try! NSRegularExpression(
        pattern: "@js:[\\s\\S]*$|<js>[\\s\\S]*?</js>",
        options: [.caseInsensitive]
    )

    /// Matches data-URIs: `data:...;base64,...`
    static let dataUriPattern = try! NSRegularExpression(
        pattern: "^data:(.*?);base64,(.*)",
        options: [.dotMatchesLineSeparators]
    )

    // MARK: - Initialization

    /// Build an AnalyzeUrl from a raw Legado rule URL string.
    ///
    /// - Parameters:
    ///   - ruleUrl:    The raw URL/rule string, possibly with `,{json}` options.
    ///   - key:        Search keyword (replaces `{{key}}`).
    ///   - page:       Current page number (1-based, replaces `{{page}}`).
    ///   - speakText:  TTS text.
    ///   - speakSpeed: TTS speed.
    ///   - baseUrl:    Base URL for relative path resolution.
    ///   - source:     Book source providing default headers / variables.
    ///   - book:       Book-level RuleData for `@get:{}` lookups.
    ///   - chapter:    Chapter-level RuleData for `@get:{}` lookups.
    init(ruleUrl: String,
         key: String? = nil,
         page: Int? = nil,
         speakText: String? = nil,
         speakSpeed: Int? = nil,
         baseUrl: String? = nil,
         source: RuleDataInterface? = nil,
         book: RuleDataInterface? = nil,
         chapter: RuleDataInterface? = nil,
         jsEvaluator: ((String, [String: Any]) -> String?)? = nil) {

        self.key = key
        self.page = page
        self.speakText = speakText
        self.speakSpeed = speakSpeed
        self.source = source
        self.ruleData = book
        self.chapter = chapter
        self.jsEvaluator = jsEvaluator

        // Strip any JSON options appended to the base URL itself
        if let base = baseUrl {
            self.baseUrl = Self.stripOptions(from: base)
        }

        // Run the full init pipeline
        initUrl(ruleUrl)
    }

    // MARK: - Init Pipeline

    /// Main pipeline matching Legado's `initUrl()`:
    /// 1. Strip JS blocks (placeholder).
    /// 2. Replace template variables & page rules.
    /// 3. Parse URL vs JSON options, build request.
    private func initUrl(_ rawUrl: String) {
        var ruleUrl = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 1: Strip / placeholder JS blocks
        ruleUrl = stripJs(ruleUrl)

        // Step 2: Replace template variables and page rules
        ruleUrl = replaceKeyPageJs(ruleUrl)

        // Step 3: Parse URL, options, and build request components
        analyzeUrl(ruleUrl)
    }

    // MARK: - Step 1: JavaScript Handling (placeholder)

    /// Strips `@js:...` and `<js>...</js>` blocks from the URL.
    /// When `jsEvaluator` is wired up, these will be executed instead.
    private func stripJs(_ input: String) -> String {
        let nsRange = NSRange(input.startIndex..., in: input)
        guard let match = Self.jsPattern.firstMatch(in: input, range: nsRange),
              let swiftRange = Range(match.range, in: input) else {
            return input
        }

        let jsCode = String(input[swiftRange])
        let textBefore = String(input[input.startIndex..<swiftRange.lowerBound])

        // If a JS evaluator is provided, execute the code
        if let evaluator = jsEvaluator {
            let bindings = buildJsBindings()
            let cleanJs = jsCode
                .replacingOccurrences(of: "@js:", with: "")
                .replacingOccurrences(of: "<js>", with: "")
                .replacingOccurrences(of: "</js>", with: "")
            if let result = evaluator(cleanJs, bindings) {
                return textBefore + result
            }
        }

        return textBefore
    }

    // MARK: - Step 2: Template & Page-Rule Replacement

    /// Replaces `{{key}}`, `{{page}}`, `{{pageIndex}}`, `${key}`,
    /// `@get:{key}`, and `<page1,page2,...>` page rules.
    private func replaceKeyPageJs(_ input: String) -> String {
        var result = input

        // --- Page rules: <val1,val2,val3,...> ---
        result = replacePageRules(result)

        // --- {{…}} templates via RuleAnalyzer.innerRule ---
        result = replaceDoubleBraceTemplates(result)

        // --- ${…} alternative template syntax ---
        result = replaceDollarBraceTemplates(result)

        // --- @get:{key} variable references ---
        result = replaceGetVariables(result)

        return result
    }

    /// Replace `<key,value>` page-conditional rules.
    ///
    /// Legado format: `<,{{page}}>` — the content before the **first** comma is the key
    /// (used when page == 1), and the rest is the value (used when page > 1).
    /// Both key and value may contain `{{…}}` templates that are resolved in a later step.
    ///
    /// Example: `<,{{page}}>` evaluates to `""` on page 1, `"{{page}}"` on page 2+.
    private func replacePageRules(_ input: String) -> String {
        let nsRange = NSRange(input.startIndex..., in: input)
        var result = input

        let matches = Self.pagePattern.matches(in: input, range: nsRange)
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let innerRange = Range(match.range(at: 1), in: result) else { continue }

            let inner = String(result[innerRange])
            guard let commaIndex = inner.firstIndex(of: ",") else { continue }

            let keyPart = String(inner[inner.startIndex..<commaIndex])
            let valuePart = String(inner[inner.index(after: commaIndex)...])

            let pageNum = page ?? 1
            let replacement = pageNum == 1 ? keyPart : valuePart
            result.replaceSubrange(fullRange, with: replacement)
        }

        return result
    }

    /// Replace `{{key}}`, `{{page}}`, `{{pageIndex}}`, and generic `{{varName}}`
    /// using RuleAnalyzer's innerRule for balanced-brace extraction.
    private func replaceDoubleBraceTemplates(_ input: String) -> String {
        let analyzer = RuleAnalyzer(data: input, code: true)
        let replaced = analyzer.innerRule(inner: "{{", startStep: 2, endStep: 2) { [weak self] expression in
            return self?.resolveTemplateExpression(expression)
        }
        return replaced.isEmpty ? input : replaced
    }

    /// Replace `${key}`, `${page}`, etc. — simpler regex-based replacement.
    private func replaceDollarBraceTemplates(_ input: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "\\$\\{(\\w+)\\}")
        let nsRange = NSRange(input.startIndex..., in: input)
        var result = input

        let matches = pattern.matches(in: input, range: nsRange)
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let keyRange = Range(match.range(at: 1), in: result) else { continue }
            let varName = String(result[keyRange])
            if let value = resolveTemplateExpression(varName) {
                result.replaceSubrange(fullRange, with: value)
            }
        }
        return result
    }

    /// Replace `@get:{key}` references with values from RuleData.
    private func replaceGetVariables(_ input: String) -> String {
        let pattern = try! NSRegularExpression(pattern: "@get:\\{(.*?)\\}")
        let nsRange = NSRange(input.startIndex..., in: input)
        var result = input

        let matches = pattern.matches(in: input, range: nsRange)
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let keyRange = Range(match.range(at: 1), in: result) else { continue }
            let varKey = String(result[keyRange])
            let value = getVariable(varKey)
            result.replaceSubrange(fullRange, with: value)
        }
        return result
    }

    /// Resolve a single template variable name to its value.
    private func resolveTemplateExpression(_ expression: String) -> String? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        switch trimmed {
        case "key", "searchKey":
            return key ?? ""
        case "page":
            return String(page ?? 1)
        case "pageIndex":
            return String((page ?? 1) - 1)
        case "speakText":
            return speakText ?? ""
        case "speakSpeed":
            return speakSpeed.map { String($0) } ?? ""
        default:
            // Try JS evaluator for arbitrary expressions
            if let evaluator = jsEvaluator {
                let bindings = buildJsBindings()
                return evaluator(trimmed, bindings)
            }
            // Fallback: try RuleData variable
            let v = getVariable(trimmed)
            return v.isEmpty ? nil : v
        }
    }

    // MARK: - Step 3: URL + Options Parsing

    /// Split URL from JSON options, resolve relative paths, parse options, encode params.
    private func analyzeUrl(_ ruleUrl: String) {
        // --- Split URL from options at `,{` boundary ---
        let nsRange = NSRange(ruleUrl.startIndex..., in: ruleUrl)
        let urlNoOption: String
        let optionStr: String?

        if let match = Self.paramPattern.firstMatch(in: ruleUrl, range: nsRange),
           let swiftRange = Range(match.range, in: ruleUrl) {
            urlNoOption = String(ruleUrl[ruleUrl.startIndex..<swiftRange.lowerBound])
            optionStr = String(ruleUrl[swiftRange.upperBound...])
        } else {
            urlNoOption = ruleUrl
            optionStr = nil
        }

        // --- Resolve relative URL ---
        url = resolveUrl(urlNoOption)

        // --- Parse JSON options ---
        if let json = optionStr {
            parseOptions(json)
        }

        // --- Apply template replacement to body ---
        if var bodyStr = body {
            bodyStr = replaceKeyPageJs(bodyStr)
            body = bodyStr
        }

        // --- Encode query / form parameters ---
        if method.uppercased() == "GET" {
            splitQueryFromUrl()
        } else {
            encodedForm = encodeParams(body, isQuery: false)
        }
    }

    /// Parse JSON option block and populate request fields.
    private func parseOptions(_ json: String) {
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        if let m = dict["method"] as? String {
            method = m.uppercased()
        }

        if let h = dict["headers"] as? [String: Any] {
            for (k, v) in h {
                headers[k] = "\(v)"
            }
        }

        if let b = dict["body"] as? String {
            body = b
        } else if let b = dict["body"] {
            // Body could be a dict/array — serialize to JSON string
            if let bData = try? JSONSerialization.data(withJSONObject: b),
               let bStr = String(data: bData, encoding: .utf8) {
                body = bStr
            }
        }

        if let t = dict["type"] as? String {
            type = t
        }

        charset = dict["charset"] as? String

        if let r = dict["retry"] as? Int {
            retry = r
        } else if let r = dict["retry"] as? String, let ri = Int(r) {
            retry = ri
        }

        if let wv = dict["useWebView"] {
            useWebView = parseBool(wv)
        }

        webJs = dict["webJs"] as? String

        if let delay = dict["webViewDelayTime"] as? Int {
            webViewDelayTime = delay
        } else if let delay = dict["webViewDelayTime"] as? String, let d = Int(delay) {
            webViewDelayTime = d
        }

        serverID = dict["serverID"] as? String

        // Execute post-parse JS if present
        if let js = dict["js"] as? String, let evaluator = jsEvaluator {
            let bindings = buildJsBindings()
            _ = evaluator(js, bindings)
        }
    }

    // MARK: - URL Resolution

    /// Resolve a potentially relative URL against baseUrl.
    private func resolveUrl(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Already absolute
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ||
           trimmed.hasPrefix("data:") {
            return trimmed
        }

        // Protocol-relative
        if trimmed.hasPrefix("//") {
            return "https:" + trimmed
        }

        // Resolve against base
        guard let base = baseUrl, !base.isEmpty,
              let baseURL = URL(string: base) else {
            return trimmed
        }

        if let resolved = URL(string: trimmed, relativeTo: baseURL) {
            return resolved.absoluteString
        }

        return trimmed
    }

    /// Remove JSON options suffix from a base URL string.
    static func stripOptions(from urlString: String) -> String {
        let nsRange = NSRange(urlString.startIndex..., in: urlString)
        if let match = paramPattern.firstMatch(in: urlString, range: nsRange),
           let swiftRange = Range(match.range, in: urlString) {
            return String(urlString[urlString.startIndex..<swiftRange.lowerBound])
        }
        return urlString
    }

    // MARK: - Query & Parameter Encoding

    /// For GET requests: split query string out of `url`, store in `encodedQuery`.
    private func splitQueryFromUrl() {
        guard let idx = url.firstIndex(of: "?") else {
            urlNoQuery = url
            encodedQuery = nil
            return
        }
        urlNoQuery = String(url[url.startIndex..<idx])
        let queryRaw = String(url[url.index(after: idx)...])
        encodedQuery = encodeParams(queryRaw, isQuery: true)
    }

    /// Percent-encode query or form parameters.
    /// Handles `key=value&key2=value2` pairs as well as raw strings.
    private func encodeParams(_ params: String?, isQuery: Bool) -> String? {
        guard let params, !params.isEmpty else { return nil }

        let pairs = params.components(separatedBy: "&")
        var encoded: [String] = []

        for pair in pairs {
            if let eqIndex = pair.firstIndex(of: "=") {
                let k = String(pair[pair.startIndex..<eqIndex])
                let v = String(pair[pair.index(after: eqIndex)...])
                let ek = encodeComponent(k)
                let ev = encodeComponent(v)
                encoded.append("\(ek)=\(ev)")
            } else {
                encoded.append(encodeComponent(pair))
            }
        }

        return encoded.joined(separator: "&")
    }

    /// Percent-encode a single component, skipping if it appears already encoded.
    private func encodeComponent(_ value: String) -> String {
        // If value already contains %-encoded sequences, don't double-encode
        if value.contains("%") && value.range(of: "%[0-9A-Fa-f]{2}",
                                                options: .regularExpression) != nil {
            return value
        }
        return value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
    }

    // MARK: - Variable Access

    /// Retrieve a variable from the RuleData chain (chapter → book → source).
    func getVariable(_ key: String) -> String {
        if let val = chapter?.getVariable(key: key), !val.isEmpty { return val }
        if let val = ruleData?.getVariable(key: key), !val.isEmpty { return val }
        if let val = source?.getVariable(key: key), !val.isEmpty { return val }
        return ""
    }

    /// Store a variable into chapter data (if available) or book data.
    func putVariable(_ key: String, value: String?) {
        if let ch = chapter {
            ch.putVariable(key: key, value: value)
        } else {
            ruleData?.putVariable(key: key, value: value)
        }
    }

    // MARK: - JS Bindings

    /// Build a dictionary of bindings for JavaScript evaluation.
    private func buildJsBindings() -> [String: Any] {
        var bindings: [String: Any] = [:]
        bindings["baseUrl"] = baseUrl ?? ""
        bindings["page"] = page ?? 1
        bindings["key"] = key ?? ""
        bindings["speakText"] = speakText ?? ""
        bindings["speakSpeed"] = speakSpeed ?? 0
        return bindings
    }

    // MARK: - URLRequest Construction

    /// Convert the parsed URL into an iOS `URLRequest`.
    ///
    /// Returns `nil` if the URL is invalid or is a data-URI.
    func toURLRequest() -> URLRequest? {
        // Reconstruct final URL for GET (with query)
        let finalUrlString: String
        if method.uppercased() == "GET" {
            if let q = encodedQuery, !q.isEmpty {
                finalUrlString = urlNoQuery + "?" + q
            } else if !urlNoQuery.isEmpty {
                finalUrlString = urlNoQuery
            } else {
                finalUrlString = url
            }
        } else {
            finalUrlString = url
        }

        guard let requestUrl = URL(string: finalUrlString) else { return nil }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = method.uppercased()

        // Headers
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Body (POST)
        if method.uppercased() == "POST" {
            if let form = encodedForm {
                request.httpBody = form.data(using: .utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    request.setValue("application/x-www-form-urlencoded",
                                    forHTTPHeaderField: "Content-Type")
                }
            } else if let bodyStr = body {
                request.httpBody = bodyStr.data(using: .utf8)
                if request.value(forHTTPHeaderField: "Content-Type") == nil {
                    // Guess JSON if body looks like JSON
                    if bodyStr.hasPrefix("{") || bodyStr.hasPrefix("[") {
                        request.setValue("application/json",
                                        forHTTPHeaderField: "Content-Type")
                    } else {
                        request.setValue("application/x-www-form-urlencoded",
                                        forHTTPHeaderField: "Content-Type")
                    }
                }
            }
        }

        return request
    }

    // MARK: - Data URI Support

    /// Check whether this URL is a `data:` URI.
    var isDataUri: Bool {
        return url.hasPrefix("data:")
    }

    /// Decode a `data:` URI, returning the raw data and MIME type.
    func decodeDataUri() -> (data: Data, mimeType: String)? {
        let nsRange = NSRange(url.startIndex..., in: url)
        guard let match = Self.dataUriPattern.firstMatch(in: url, range: nsRange),
              let mimeRange = Range(match.range(at: 1), in: url),
              let b64Range = Range(match.range(at: 2), in: url) else {
            return nil
        }
        let mime = String(url[mimeRange])
        let b64 = String(url[b64Range])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return (data, mime)
    }

    // MARK: - Helpers

    /// Flexible boolean parsing matching Legado's `useWebView()` logic.
    private func parseBool(_ value: Any) -> Bool {
        if let b = value as? Bool { return b }
        if let s = value as? String {
            return s.lowercased() == "true" || s == "1"
        }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }
}
