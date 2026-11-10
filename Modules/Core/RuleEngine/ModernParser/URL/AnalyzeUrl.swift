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

    /// JavaScript that transforms the decoded HTTP response body before rule parsing.
    /// Legado exposes the raw response string as `result` and uses the script's return
    /// value as the new response body.
    private(set) var bodyJs: String?

    /// Delay in milliseconds before extracting WebView content.
    private(set) var webViewDelayTime: Int = 0

    /// Content type hint from the rule ("text", "json", etc.).
    private(set) var type: String?

    /// Optional server identifier for multi-server setups.
    private(set) var serverID: String?

    /// The rule URL after template/JS resolution but **before** the `,{json}` options
    /// are split off — i.e. exactly the string the source's own rules produced.
    ///
    /// `url` is the option-stripped form, which is right for building a request and
    /// wrong as a `baseUrl` handed back to rule JS: sources stash state in those
    /// options and read it back out of `baseUrl`. 同人小说网's TOC does
    /// `JSON.parse(baseUrl.slice(baseUrl.indexOf('{'))).type` on a
    /// `data:;base64,<id>,{"type":"novel"}` tocUrl.
    private(set) var evaluatedRuleUrl: String = ""

    /// The rule URL as it was handed in, which `java.initUrl()` reads again from the start.
    private let rawRuleUrl: String

    /// Why a URL script or `{{…}}` template failed: its exception, or its timeout. Legado's
    /// `evalJS` throws there and no request is made, so `toURLRequest()` builds none; nil when
    /// every script ran.
    private(set) var scriptFailure: String?

    /// Legado's `ruleUrl` at each step: the raw rule while its `@js:` runs, then the rule its
    /// scripts and templates produced. `java.ruleUrl` reads it (`LegadoAnalyzeUrlScriptView`).
    private var scriptRuleUrl: String = ""

    /// `java` in this URL's own scripts and in `loginCheckJs` on its response: this AnalyzeUrl
    /// on top of the bridge, as Legado binds it. Its `execute` is installed by whoever sends
    /// the request.
    private(set) lazy var scriptView: LegadoAnalyzeUrlScriptView = LegadoAnalyzeUrlScriptView(
        state: { [weak self] in
            LegadoAnalyzeUrlScriptView.State(
                url: self?.url ?? "",
                ruleUrl: self?.scriptRuleUrl ?? "",
                urlNoQuery: self.map { $0.urlNoQuery.isEmpty ? $0.url : $0.urlNoQuery } ?? "",
                type: self?.type,
                baseUrl: self?.baseUrl ?? ""
            )
        },
        headers: LegadoHeaderMap(
            read: { [weak self] in self?.headers ?? [:] },
            write: { [weak self] in self?.headers = $0 }
        ),
        reinitialize: { [weak self] in
            guard let self else { return }
            self.initUrl(self.rawRuleUrl)
        }
    )

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

    /// The error the last `jsEvaluator` call threw, if it threw. `jsEvaluator` answers nil
    /// both for a script that threw and for one that yielded null/undefined; a `{{…}}`
    /// template tells the two apart with this (`replaceDoubleBraceTemplates`). Nil when the
    /// caller cannot tell — every nil result then reads as "yielded nothing".
    private let jsErrorProvider: (() -> String?)?

    /// Book source header JSON string. When non-nil, `{header}` in URL option
    /// blocks is replaced with this value before JSON parsing (源阅 syntax).
    private let sourceHeader: String?

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
         sourceHeader: String? = nil,
         baseUrl: String? = nil,
         source: RuleDataInterface? = nil,
         book: RuleDataInterface? = nil,
         chapter: RuleDataInterface? = nil,
         jsEvaluator: ((String, [String: Any]) -> String?)? = nil,
         jsErrorProvider: (() -> String?)? = nil) {

        self.key = key
        self.page = page
        self.speakText = speakText
        self.speakSpeed = speakSpeed
        self.sourceHeader = sourceHeader
        self.source = source
        self.ruleData = book
        self.chapter = chapter
        self.jsEvaluator = jsEvaluator
        self.jsErrorProvider = jsErrorProvider
        self.rawRuleUrl = ruleUrl

        // Strip any JSON options / `#…` tags appended to the base URL itself
        if let base = baseUrl {
            self.baseUrl = Self.cleanBaseURL(base)
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
        scriptRuleUrl = ruleUrl
        scriptFailure = nil

        // Step 1: Strip / placeholder JS blocks
        ruleUrl = stripJs(ruleUrl)
        scriptRuleUrl = ruleUrl
        // Legado's `initUrl` stops at the exception: the rest of the rule is never read.
        guard scriptFailure == nil else {
            evaluatedRuleUrl = ruleUrl
            return
        }

        // Step 2: Replace template variables and page rules
        ruleUrl = replaceKeyPageJs(ruleUrl)
        evaluatedRuleUrl = ruleUrl
        scriptRuleUrl = ruleUrl
        guard scriptFailure == nil else { return }

        // Step 3: Parse URL, options, and build request components
        analyzeUrl(ruleUrl)
    }

    // MARK: - Step 1: JavaScript Handling

    /// Legado's `AnalyzeUrl.analyzeJs`: every `<js>…</js>` / `@js:…` block runs in turn with
    /// `result` bound to the URL so far — the text before the first block, or the previous
    /// block's value — and its value replaces it; text between or after blocks becomes the
    /// URL with `@result` standing for it. 笔趣小说's search URL is `/search` followed by an
    /// `@js:` that fetches the page's token and returns `result + "," + options`.
    private func stripJs(_ input: String) -> String {
        let nsRange = NSRange(input.startIndex..., in: input)
        let matches = Self.jsPattern.matches(in: input, range: nsRange)
        guard !matches.isEmpty else { return input }

        var result = input
        var start = input.startIndex
        for match in matches {
            guard let range = Range(match.range, in: input) else { continue }
            if range.lowerBound > start {
                let text = input[start..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { result = text.replacingOccurrences(of: "@result", with: result) }
            }
            let block = String(input[range])
            let code = block.lowercased().hasPrefix("<js>")
                ? String(block.dropFirst(4).dropLast(5))
                : String(block.dropFirst(4))
            guard let value = evaluateURLScript(code, result: result) else { return result }
            result = value
            start = range.upperBound
        }
        if start < input.endIndex {
            let text = input[start...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result = text.replacingOccurrences(of: "@result", with: result) }
        }
        return result
    }

    /// One URL script's value; nil when it threw, recorded in `scriptFailure`. Legado's
    /// `evalJS` throws there and the request is not sent. Until 11-07 the URL so far went on
    /// in its place: 偶然中文 (YCK1330), whose script is the whole rule, sent the script's text
    /// to the site as a path.
    ///
    /// A script that gives no value did not fail: Rhino's `undefined` unwraps to null and
    /// `analyzeJs` takes its `toString()`, "null", as the URL so far, which the text after the
    /// block then replaces. 棉花小说 (YCK1331) opens its search URL with
    /// `<js>cookie.removeCookie(source.key);</js>` followed by the URL itself; until 11-08 that
    /// block failed the search.
    private func evaluateURLScript(_ code: String, result: String) -> String? {
        guard let evaluator = jsEvaluator else { return result }
        var bindings = buildJsBindings()
        bindings["result"] = result
        if let value = evaluator(code, bindings) {
            return value
        }
        if let value = evaluateBuildRequestArgument(from: code, evaluator: evaluator, bindings: bindings) {
            return value
        }
        guard let failure = jsErrorProvider?() else { return "null" }
        scriptFailure = failure
        AppLogger.parse("URL script failed", context: [
            "script": String(code.prefix(160)),
            "error": failure,
        ], level: .notice)
        return nil
    }

    private func evaluateBuildRequestArgument(
        from jsCode: String,
        evaluator: (String, [String: Any]) -> String?,
        bindings: [String: Any]
    ) -> String? {
        let pattern = #"(?s)^\s*buildRequest\s*\(\s*(`(?:\\.|[^`])*`|"(?:\\.|[^"])*"|'(?:\\.|[^'])*')\s*(?:,\s*[\s\S]*)?\)\s*;?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: jsCode,
                  range: NSRange(jsCode.startIndex..., in: jsCode)
              ),
              let range = Range(match.range(at: 1), in: jsCode)
        else {
            return nil
        }

        let argument = String(jsCode[range])
        if let evaluated = evaluator(argument, bindings),
           !evaluated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return evaluated
        }
        if argument.count >= 2,
           let first = argument.first,
           let last = argument.last,
           (first == "\"" || first == "'"),
           first == last {
            return String(argument.dropFirst().dropLast())
        }
        return nil
    }

    // MARK: - Step 2: Template & Page-Rule Replacement

    /// Replaces `{{key}}`, `{{page}}`, `{{pageIndex}}`, `${key}`,
    /// `@get:{key}`, and `<page1,page2,...>` page rules.
    private func replaceKeyPageJs(_ input: String) -> String {
        var result = input

        // `{{…}}` first, then the page rule — legado-E's order ("先替换内嵌规则再替换页数规则，
        // 避免内嵌规则中存在大于小于号时，规则被切错"). Page-first cut a `{{js}}` containing `<` or
        // `>` (a comparison, an HTML string) at that bracket, so its JS never compiled
        // (黄果短劇, YCK1330 report).
        // --- {{…}} templates via RuleAnalyzer.innerRule ---
        result = replaceDoubleBraceTemplates(result)

        // --- Page rules: <val1,val2,val3,...> ---
        result = replacePageRules(result)

        // --- ${…} alternative template syntax ---
        result = replaceDollarBraceTemplates(result)

        // --- @get:{key} variable references ---
        result = replaceGetVariables(result)

        return result
    }

    /// Replace `<p1,p2,p3,…>` page rules, as legado's `AnalyzeUrl.replaceKeyPageJs`: the
    /// comma-separated list is indexed by page — page n reads item n, and every page past the
    /// list reads the last item. `<,{{page}}>` is the common two-item form: empty on page 1,
    /// the page number after it. Each item is trimmed.
    private func replacePageRules(_ input: String) -> String {
        Self.applyPageRules(input, page: page)
    }

    /// `replacePageRules` for a caller without an AnalyzeUrl: the native search URL renderer
    /// (`BookSource.renderSearchURL`) reads `<,page/{{page}}/>` exactly as the runtime does.
    static func applyPageRules(_ input: String, page: Int?) -> String {
        // Only a paged request has page rules (Legado's `page?.let`). A detail, TOC or content
        // URL read as page 1 cut its `<…>` up: an XML POST body, a `webJs` with `a > b` in it.
        guard let page, input.contains("<") else { return input }
        let nsRange = NSRange(input.startIndex..., in: input)
        var result = input

        let matches = Self.pagePattern.matches(in: input, range: nsRange)
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let innerRange = Range(match.range(at: 1), in: result) else { continue }

            let pages = result[innerRange].components(separatedBy: ",")
            let pageNum = max(page, 1)
            let chosen = pageNum < pages.count ? pages[pageNum - 1] : pages[pages.count - 1]
            result.replaceSubrange(
                fullRange,
                with: chosen.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        return result
    }

    /// Replace `{{key}}`, `{{page}}`, `{{pageIndex}}`, and generic `{{varName}}`.
    ///
    /// A template runs from a `{{` to the next `}}`, unbalanced, as Legado's AnalyzeUrl reads
    /// one (`RuleAnalyzer.innerRule("{{", "}}")`); a `{{` with no `}}` after it is text. 连城读书
    /// (YCK1329) pages its 發現 with `pn={{page-1}*20}&rank=…`, which has none: Legado sends it
    /// as written and the site answers the first page. The balanced scan read `page-1}*2` as a
    /// script, and once a throwing script stopped the request (below) every list failed.
    ///
    /// As in Legado's AnalyzeUrl (`evalJS(it) ?: ""`), a template whose JS yields nothing
    /// renders as "": `{{cookie.removeCookie(source.key)}}` (no return value) and the first
    /// page's `{{page == 1 ? '' : …}}` used to stay in the URL verbatim and 404 (YCK1330,
    /// indices 13, 93, 241, 360). Without a JS evaluator an unknown expression has nothing to
    /// run and stays as written.
    ///
    /// A template whose JS threw is not "nothing": Legado's `evalJS` throws out of
    /// `replaceKeyPageJs` and no request is made. That is `scriptFailure` here, so
    /// `toURLRequest()` builds none. Until 11-08 the template stayed as written and the
    /// request went out with it as a path: 绿色小说 (YCK1331) posted to
    /// `/%7B%7Burl=source.getKey();…%7D%7D`.
    private func replaceDoubleBraceTemplates(_ input: String) -> String {
        let analyzer = RuleAnalyzer(data: input, code: true)
        let replaced = analyzer.innerRule(startStr: "{{", endStr: "}}") { [weak self] expression in
            // Legado stops at the exception: no later template runs.
            guard let self, scriptFailure == nil else { return nil }
            if let value = resolveTemplateExpression(expression) { return value }
            guard jsEvaluator != nil else { return "{{\(expression)}}" }
            if let error = jsErrorProvider?() {
                if scriptFailure == nil { scriptFailure = error }
                AppLogger.parse("URL template script failed", context: [
                    "template": String(expression.prefix(160)),
                    "error": error,
                ], level: .notice)
                return nil
            }
            return ""
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
        case "header":
            return sourceHeader ?? ""
        default:
            // Try JS evaluator for arbitrary expressions
            if let evaluator = jsEvaluator {
                let bindings = buildJsBindings()
                let result = evaluator(trimmed, bindings)
                if let result, result != trimmed {
                    NSLog("[企點診斷] AnalyzeUrl 模板 「%@」→「%@」", trimmed, result)
                }
                return result
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
        // Legado's `analyzeUrl()`: `NetworkUtils.getBaseUrl(url)?.let { baseUrl = it }`. From
        // here on `baseUrl` is the URL's scheme and host — in the `js` option, in `bodyJs` and
        // `loginCheckJs` on the response (`evalJS` binds it), and as the base an `initUrl()`
        // resolves the rule against again. The rule's own templates ran before, with the base
        // the rule was given.
        if let origin = Self.legadoBaseUrl(of: url) { baseUrl = origin }

        // --- Resolve {header} template in option block (源阅 syntax) ---
        let resolvedOptions = optionStr?.replacingOccurrences(
            of: "{header}",
            with: sourceHeader ?? ""
        )
        // --- Parse JSON options ---
        if let json = resolvedOptions {
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
            encodedForm = shouldEncodePostBodyAsForm(body) ? encodeParams(body, isQuery: false) : nil
        }
    }

    /// Parse JSON option block and populate request fields.
    private func parseOptions(_ json: String) {
        guard let dict = Self.parseOptionDictionary(json) else {
            return
        }

        // 源阅 also accepts a bare header map after the URL (for example
        // `href##$##,{Cookie:"..."}` or `href##$##,{header}`). This is a
        // distinct, deterministic option shape: none of the keys belong to
        // Legado's UrlOption model, so the whole object represents headers.
        // Keep this in the primary parser instead of retrying failed requests.
        let urlOptionKeys: Set<String> = [
            "method", "headers", "body", "type", "charset", "retry",
            "usewebview", "webview", "webjs", "bodyjs",
            "webviewdelaytime", "webviewdelay", "serverid", "js"
        ]
        let isBareHeaderMap = !dict.keys.contains {
            urlOptionKeys.contains($0.lowercased())
        }
        if isBareHeaderMap {
            for (key, value) in dict where !(value is NSNull) {
                headers[key] = "\(value)"
            }
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
        } else if let b = dict["body"], !(b is NSNull) {
            // Body could be a dict/array — serialize to JSON string
            // Source options also allow JSON scalars. Without fragmentsAllowed,
            // Foundation raises an Objective-C exception that Swift cannot catch.
            // `null` is no body at all, as in Legado (GSON leaves `UrlOption.body` null).
            if let bData = try? JSONSerialization.data(withJSONObject: b, options: [.fragmentsAllowed]),
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

        if let wv = dict["useWebView"] ?? dict["webView"] {
            useWebView = Self.legadoWebViewFlag(wv)
        }

        webJs = dict["webJs"] as? String

        if let script = (dict["bodyJs"] ?? dict["bodyJS"]) as? String {
            let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
            bodyJs = trimmed.isEmpty ? nil : script
        }

        if let delay = (dict["webViewDelayTime"] ?? dict["webViewDelay"]) as? Int {
            webViewDelayTime = delay
        } else if let delayStr = (dict["webViewDelayTime"] ?? dict["webViewDelay"]) as? String,
                  let d = Int(delayStr) {
            webViewDelayTime = d
        }

        serverID = dict["serverID"] as? String

        // Legado's `js` option: `evalJS(jsStr, url)?.toString()?.let { url = it }` — the script
        // gets the URL as `result` and what it returns is the URL from then on; one that returns
        // nothing (null, undefined) leaves it. The value was thrown away until 11-07, so
        // 刚够小说网's `…;java.url` with its 访问验证 cookie put in `java.headerMap` did nothing.
        if let js = dict["js"] as? String, let evaluator = jsEvaluator {
            var bindings = buildJsBindings()
            bindings["result"] = url
            if let replaced = evaluator(js, bindings) {
                url = replaced
            }
        }
    }

    // MARK: - URL Resolution

    /// Legado's `NetworkUtils.getBaseUrl`: an http(s) URL up to the first `/` from its tenth
    /// character on — its scheme and authority — or the whole URL when there is none; nil for
    /// any other URL.
    static func legadoBaseUrl(of url: String) -> String? {
        let lowered = url.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return nil }
        guard let from = url.index(url.startIndex, offsetBy: 9, limitedBy: url.endIndex),
              let slash = url[from...].firstIndex(of: "/")
        else { return url }
        return String(url[..<slash])
    }

    /// Resolve a potentially relative URL against baseUrl.
    private func resolveUrl(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Already absolute
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") ||
           trimmed.hasPrefix("data:") {
            return trimmed
        }

        // Resolve against base
        guard let base = baseUrl, !base.isEmpty,
              let resolved = Self.javaAbsoluteURL(trimmed, base: base) else {
            // Protocol-relative with no base to take a scheme from.
            if trimmed.hasPrefix("//") { return "https:" + trimmed }
            return trimmed
        }
        return resolved
    }

    /// Java's `new URL(context, spec).toString()`, which Legado's `NetworkUtils.getAbsoluteURL`
    /// joins with: the characters stay as written and only the path's `.` and `..` segments
    /// are resolved. Foundation's `URL(string:relativeTo:)` percent-encodes every non-ASCII
    /// character in UTF-8 (iOS 17 and later), so a query written
    /// `searchkey={{key}}&submit=搜索` reached `encodeParams` already in UTF-8, passed as
    /// encoded, and the source's `charset` never applied: 搜小说 and 人文书库 (YCK1330 indices 0
    /// and 65) searched a GBK site in UTF-8 and got no books.
    ///
    /// nil when `base` has no `scheme://` to resolve against (Java's `URL(base)` throws, and
    /// Legado then keeps the spec as it is).
    static func javaAbsoluteURL(_ spec: String, base: String) -> String? {
        let base = stripOptions(from: base).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = base.range(of: "://") else { return nil }
        let scheme = String(base[..<schemeEnd.lowerBound])
        guard !scheme.isEmpty,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) })
        else { return nil }
        let afterScheme = base[schemeEnd.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { "/?#".contains($0) }) ?? afterScheme.endIndex
        let origin = scheme + "://" + afterScheme[..<authorityEnd]
        let pathAndRest = afterScheme[authorityEnd...]
        let basePathEnd = pathAndRest.firstIndex(where: { "?#".contains($0) }) ?? pathAndRest.endIndex
        let basePath = String(pathAndRest[..<basePathEnd])
        let baseQuery: Substring? = {
            let rest = pathAndRest[basePathEnd...]
            guard rest.hasPrefix("?") else { return nil }
            return rest[..<(rest.firstIndex(of: "#") ?? rest.endIndex)]
        }()

        let trimmed = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = trimmed.firstIndex(of: ":"),
           let first = trimmed.first, first.isASCII, first.isLetter,
           trimmed[..<colon].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) {
            return trimmed // has its own scheme
        }
        if trimmed.hasPrefix("//") { return scheme + ":" + trimmed }

        let specPathEnd = trimmed.firstIndex(where: { "?#".contains($0) }) ?? trimmed.endIndex
        let specPath = String(trimmed[..<specPathEnd])
        let specRest = trimmed[specPathEnd...]
        if specPath.isEmpty {
            if specRest.hasPrefix("?") { return origin + basePath + specRest }
            return origin + basePath + (baseQuery ?? "") + specRest
        }
        let path: String
        if specPath.hasPrefix("/") {
            path = specPath
        } else if let slash = basePath.lastIndex(of: "/") {
            path = basePath[...slash] + specPath
        } else {
            path = "/" + specPath
        }
        return origin + removeDotSegments(path) + specRest
    }

    // MARK: - Request URL (OkHttp `HttpUrl`)

    /// The `URL` a request for `string` goes to, read as OkHttp's `HttpUrl` reads it for
    /// Legado: a character a URL cannot carry as written goes out percent-encoded in UTF-8, and
    /// a `%XX` already there goes out as it is. Foundation's `URL(string:)` re-encodes every
    /// `%` of a component that also holds a raw character, so `q=%E6%88%91&sa=搜尋` went out
    /// as `q=%25E6%2588%2591…&sa=%E6%90%9C%E5%B0%8B` and the site searched for the literal
    /// text `%E6%88%91` (漫画戏说, YCK1329). Every byte Foundation would still re-encode is
    /// encoded here first, so it never does. Every request URL a source hands over is made
    /// here: `safeURL`, `toURLRequest`, and the bridge's plain requests.
    static func requestURL(_ string: String) -> URL? {
        URL(string: canonicalRequestURLString(string))
    }

    /// `requestURL`'s string. As in `HttpUrl.Builder.parse`, surrounding whitespace is dropped
    /// and so is a tab, line feed, form feed or carriage return inside (a URL a script joined
    /// across lines); the scheme and authority stay as written; the first `#` opens the
    /// fragment and any later one is text. The fragment is encoded whole, its `%` too, so
    /// `legadoURLString` reads it back exactly as written; no server ever sees it.
    static func canonicalRequestURLString(_ string: String) -> String {
        let bytes = Array(string.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        if let separator = firstIndex(of: Array("://".utf8), in: bytes), separator > 0,
           bytes[0..<separator].allSatisfy({ byte in
               (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte | 0x20)
                   || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || "+-.".utf8.contains(byte)
           }) {
            var end = separator + 3
            while end < bytes.count, !"/?#".utf8.contains(bytes[end]) { end += 1 }
            out.append(contentsOf: bytes[0..<end])
            i = end
        }
        let hex = Array("0123456789ABCDEF".utf8)
        var inFragment = false
        while i < bytes.count {
            let byte = bytes[i]
            switch byte {
            case UInt8(ascii: "\t"), UInt8(ascii: "\n"), 0x0C, UInt8(ascii: "\r"):
                i += 1
                continue
            case UInt8(ascii: "%") where !inFragment:
                if i + 2 < bytes.count, isHexDigit(bytes[i + 1]), isHexDigit(bytes[i + 2]) {
                    out.append(contentsOf: bytes[i...(i + 2)])
                    i += 3
                    continue
                }
            case UInt8(ascii: "#") where !inFragment:
                inFragment = true
                out.append(byte)
                i += 1
                continue
            default:
                if requestURLLiteralBytes.contains(byte) {
                    out.append(byte)
                    i += 1
                    continue
                }
            }
            out.append(UInt8(ascii: "%"))
            out.append(hex[Int(byte >> 4)])
            out.append(hex[Int(byte & 0x0F)])
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// The URL a response came from as a source reads it — `baseUrl`, `StrResponse.url()` —
    /// which in Legado is okhttp's `HttpUrl.toString()` of the last request. okhttp keeps a
    /// fragment as written (`HttpUrl.Builder.parse`: `FRAGMENT_ENCODE_SET` is empty and the
    /// text counts as already encoded, so only a control character is encoded and a tab or
    /// line break dropped — okhttp 5.3.2), where Foundation cannot hold a second `#`
    /// or a raw `{`. A response to the URL the source asked for (`requested`, made by
    /// `requestURL`) reads back that URL's fragment as the source wrote it; one a redirect
    /// moved reads as Foundation has it. 吾爱耽美 (YCK1330) lists its 排行榜 at `/##` and tests
    /// `baseUrl.match(/##/)`, which `/#%23` never matched.
    static func legadoURLString(final: URL, requested: URL?) -> String {
        let text = final.absoluteString
        let resource = text.firstIndex(of: "#").map { text[..<$0] } ?? text[...]
        guard let requestedText = requested?.absoluteString,
              let requestedHash = requestedText.firstIndex(of: "#"),
              resource == requestedText[..<requestedHash]
        else { return text }
        // Every byte of a fragment `canonicalRequestURLString` made is an escape of the
        // UTF-8 the source wrote, so it decodes; one that does not was made elsewhere, and
        // reads as Foundation has it.
        let encoded = requestedText[requestedText.index(after: requestedHash)...]
        guard let fragment = encoded.removingPercentEncoding else { return text }
        var out = String(requestedText[...requestedHash])
        for scalar in fragment.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0C, 0x0D:
                continue
            case 0..<0x20, 0x7F:
                out += String(format: "%%%02X", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// What a path, query or fragment carries as written (RFC 3986 `pchar` plus `/` and `?`).
    /// `[`, `]`, `{`, `}`, `|`, `^`, `` ` ``, `"`, `<`, `>`, `\` and space are not: OkHttp
    /// sends some of them raw, but Foundation re-encodes a component holding any of them.
    private static let requestURLLiteralBytes: Set<UInt8> = unreservedBytes.union("!$&'()*+,;=:@/?".utf8)

    private static func firstIndex(of needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= needle.count else { return nil }
        for start in 0...(bytes.count - needle.count) where bytes[start..<(start + needle.count)].elementsEqual(needle) {
            return start
        }
        return nil
    }

    /// The dot-segment removal of Java's `URLStreamHandler.parseURL`.
    private static func removeDotSegments(_ input: String) -> String {
        var path = input
        while let range = path.range(of: "/./") {
            path.replaceSubrange(range, with: "/")
        }
        var searchFrom = path.startIndex
        while let range = path.range(of: "/../", range: searchFrom..<path.endIndex) {
            if range.lowerBound > path.startIndex,
               let limit = path[..<range.lowerBound].lastIndex(of: "/"),
               !path[limit...].hasPrefix("/../") {
                path.replaceSubrange(limit..<path.index(range.lowerBound, offsetBy: 3), with: "")
                searchFrom = path.startIndex
            } else {
                searchFrom = path.index(range.lowerBound, offsetBy: 3)
            }
        }
        while path.hasSuffix("/.."), let range = path.range(of: "/..") {
            guard range.lowerBound > path.startIndex,
                  let limit = path[..<range.lowerBound].lastIndex(of: "/") else { break }
            path = String(path[...limit])
        }
        if path.hasPrefix("./"), path.count > 2 { path.removeFirst(2) }
        if path.hasSuffix("/.") { path.removeLast() }
        return path
    }

    /// Whether `urlString` carries JSON options: `url,{…}`, with the spaces around the
    /// comma that Legado's `paramPattern` allows.
    static func hasOptions(_ urlString: String) -> Bool {
        paramPattern.firstMatch(in: urlString, range: NSRange(urlString.startIndex..., in: urlString)) != nil
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

    /// Normalize a book source's base URL for relative-path resolution.
    ///
    /// Sources routinely append Legado tags/comments to `bookSourceUrl` — both
    /// `,{json}` options and `#…` markers like `#♤Haxc`, `#Haxc1107`, `##@okou`.
    /// Left in place, `URL(string:)` returns nil (especially with the non-ASCII
    /// `♤` marker), so relative URLs can't resolve against the base at all.
    /// Strip the options suffix and any `#` fragment before using as a base.
    static func cleanBaseURL(_ urlString: String) -> String {
        var s = stripOptions(from: urlString)
        if let hashIdx = s.firstIndex(of: "#") {
            s = String(s[..<hashIdx])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse a Legado URL option block (the `{…}` after the `,`).
    ///
    /// Book sources frequently write the option block as GSON-lenient JSON —
    /// single-quoted strings, “smart” quotes, and unquoted object keys, e.g.
    /// `{Cookie:"xmanhua_lang=2"}` or `{'method':'POST','body':'…'}` — which
    /// `JSONSerialization` rejects outright. Try strict parsing first, then fall
    /// back to normalizing to strict JSON and retrying.
    static func parseOptionDictionary(_ json: String) -> [String: Any]? {
        if let data = json.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dict
        }
        let normalized = normalizeLegadoOptionJSON(json)
        guard let data = normalized.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// Gson's lenient `JsonReader` (Legado's `GSON.fromJson…`) rewritten as strict JSON, read
    /// token by token as Gson reads it: a string in single or double quotes — a `"` inside a
    /// single-quoted one is text, so it is escaped here —, a bare name or value (quoted, unless
    /// it is `true`, `false`, `null` or a number), `=` or `=>` for `:`, `;` for `,`, and `//`,
    /// `/* */` and `#` comments. A leading comma (the option block's own) is dropped.
    ///
    /// Until 11-07 regexes did this, and `'([^']*)'` → `"$1"` broke every single-quoted string
    /// holding a double quote: 趣悦小说 (YCK1331) posts `'body': '{"model":"MI PAD 4",…}'`, the
    /// block parsed as nothing and the search went out as a GET without its body.
    ///
    /// Curly quotes outside a string open one, as this function has read them since before
    /// 11-07 (Gson would take them as a bare literal); inside a string they are text.
    static func normalizeLegadoOptionJSON(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(",") { text.removeFirst() }
        let scalars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        let literalEnd: Set<Unicode.Scalar> = ["/", "\\", ";", "#", "=", "{", "}", "[", "]", ":", ",", " ", "\t", "\u{0C}", "\r", "\n"]

        func appendEscaped(_ scalar: Unicode.Scalar) {
            switch scalar {
            case "\"": out.append(contentsOf: #"\""#.unicodeScalars)
            case "\\": out.append(contentsOf: #"\\"#.unicodeScalars)
            case "\n": out.append(contentsOf: #"\n"#.unicodeScalars)
            case "\r": out.append(contentsOf: #"\r"#.unicodeScalars)
            case "\t": out.append(contentsOf: #"\t"#.unicodeScalars)
            default:
                if scalar.value < 0x20 {
                    out.append(contentsOf: String(format: "\\u%04x", scalar.value).unicodeScalars)
                } else {
                    out.append(scalar)
                }
            }
        }

        while i < scalars.count {
            let c = scalars[i]
            let next: Unicode.Scalar? = i + 1 < scalars.count ? scalars[i + 1] : nil
            switch c {
            case "\"", "'", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}":
                let closers: Set<Unicode.Scalar> = switch c {
                case "\"": ["\""]
                case "'": ["'"]
                case "\u{2018}", "\u{2019}": ["\u{2018}", "\u{2019}"]
                default: ["\u{201C}", "\u{201D}"]
                }
                i += 1
                out.append("\"")
                while i < scalars.count, !closers.contains(scalars[i]) {
                    let ch = scalars[i]
                    if ch == "\\", i + 1 < scalars.count {
                        let escaped = scalars[i + 1]
                        if escaped == "'" {
                            out.append("'") // Gson's `\'`; JSON has no such escape
                        } else {
                            out.append("\\")
                            out.append(escaped)
                        }
                        i += 2
                        continue
                    }
                    appendEscaped(ch)
                    i += 1
                }
                i += 1
                out.append("\"")
            case "/" where next == "/", "#":
                while i < scalars.count, scalars[i] != "\n", scalars[i] != "\r" { i += 1 }
            case "/" where next == "*":
                i += 2
                while i + 1 < scalars.count, !(scalars[i] == "*" && scalars[i + 1] == "/") { i += 1 }
                i += 2
            case "=":
                out.append(":")
                i += next == ">" ? 2 : 1
            case ";":
                out.append(",")
                i += 1
            case "{", "}", "[", "]", ":", ",", " ", "\t", "\u{0C}", "\r", "\n":
                out.append(c)
                i += 1
            default:
                var literal = String.UnicodeScalarView()
                while i < scalars.count, !literalEnd.contains(scalars[i]) {
                    literal.append(scalars[i])
                    i += 1
                }
                if literal.isEmpty {
                    // A lone `/` or `\` Gson would reject; kept, so the strict parse fails as before.
                    out.append(c)
                    i += 1
                    continue
                }
                let word = String(literal)
                if ["true", "false", "null"].contains(word)
                    || word.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil {
                    out.append(contentsOf: literal)
                } else {
                    out.append("\"")
                    for scalar in literal { appendEscaped(scalar) }
                    out.append("\"")
                }
            }
        }
        return String(out)
    }

    /// A raw control character (a line break, a tab) inside a JSON string, escaped. Gson reads
    /// one as itself — only its `STRICT` mode rejects it, and Legado's `GSON.fromJson` is
    /// lenient — while Foundation rejects it, and `JSONDecoder` only once that field is read:
    /// a per-field `try?` lost the value without a trace. 美女图站 (YCK1331) writes its POST
    /// kinds' option block over several lines inside the `url` string, and every one of those
    /// kinds lost its URL. Only double-quoted strings are scanned; text outside them is JSON
    /// whitespace already.
    static func escapingControlCharactersInJSONStrings(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return text }
        var out = String.UnicodeScalarView()
        var inString = false
        var escaped = false
        for scalar in text.unicodeScalars {
            guard inString else {
                if scalar == "\"" { inString = true }
                out.append(scalar)
                continue
            }
            if escaped {
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else if scalar == "\"" {
                inString = false
            } else if scalar.value < 0x20 {
                switch scalar {
                case "\n": out.append(contentsOf: #"\n"#.unicodeScalars)
                case "\r": out.append(contentsOf: #"\r"#.unicodeScalars)
                case "\t": out.append(contentsOf: #"\t"#.unicodeScalars)
                default: out.append(contentsOf: String(format: "\\u%04x", scalar.value).unicodeScalars)
                }
                continue
            }
            out.append(scalar)
        }
        return String(out)
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
    ///
    /// A source that names a `charset` (`{"charset":"gbk"}`, `"escape"`) gets Legado's
    /// `encodeParams(params, charset, isQuery)`: its keyword goes out in that charset's bytes —
    /// `我的` as `%CE%D2%B5%C4`, not UTF-8's `%E6%88%91%E7%9A%84`, which a GBK site parses as
    /// garbage and answers with zero books (YCK1330: 新御书屋3, 桔纸书屋, po18城, 笔趣阁 parsed 0 → 30).
    ///
    /// Without a charset it is the same function over UTF-8, as in Legado — which also keeps a
    /// form value that is already encoded. The app's own encoder before it kept `+`, `/` and `=`
    /// in a form value, so a base64 field reached the server with its `+` read as a space.
    private func encodeParams(_ params: String?, isQuery: Bool) -> String? {
        guard let params, !params.isEmpty else { return nil }
        return Self.encodeParams(params, charsetName: charset, isQuery: isQuery)
    }

    /// Legado's `analyzeFields` condition: a POST body is form fields unless it is JSON or
    /// XML, or the source set its own `Content-Type` (then the body goes out as written).
    /// Legado reads the header map by its exact key, so a lowercase `content-type` still
    /// leaves the body to be encoded.
    private func shouldEncodePostBodyAsForm(_ body: String?) -> Bool {
        guard let body else { return false }
        if Self.isJSONText(body) || Self.isXMLText(body) { return false }
        return headers["Content-Type"]?.isEmpty ?? true
    }

    /// Legado `String.isJson()`.
    private static func isJSONText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
    }

    /// Legado `String.isXml()`.
    private static func isXMLText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("<") && trimmed.hasSuffix(">")
    }

    // MARK: - Charset-Aware Encoding (Legado `encodeParams(params, charset, isQuery)`)

    /// RFC 3986 unreserved bytes.
    private static let unreservedBytes: Set<UInt8> = {
        var set = Set<UInt8>()
        set.formUnion(UInt8(ascii: "a")...UInt8(ascii: "z"))
        set.formUnion(UInt8(ascii: "A")...UInt8(ascii: "Z"))
        set.formUnion(UInt8(ascii: "0")...UInt8(ascii: "9"))
        set.formUnion("-._~".utf8)
        return set
    }()

    /// Legado's `queryEncoder`: unreserved plus `!$%&()*+,/:;=?@[\]^`{|}` pass through, so a
    /// query keeps its `&`/`=` structure and any `%XX` the source already wrote.
    private static let queryKeptBytes: Set<UInt8> = unreservedBytes.union("!$%&()*+,/:;=?@[\\]^`{|}".utf8)

    /// Legado's `NetworkUtils.notNeedEncodingQuery`: a query made only of these (and valid
    /// `%XX`) is already encoded and is sent as written.
    private static let encodedQueryBytes: Set<UInt8> = unreservedBytes.union("!$&()*+,-./:;=?@[\\]^_`{|}~".utf8)

    /// `java.net.URLEncoder`'s literal bytes; a space becomes `+`.
    private static let formKeptBytes: Set<UInt8> = {
        var set = unreservedBytes
        set.remove(UInt8(ascii: "~"))
        set.insert(UInt8(ascii: "*"))
        return set
    }()

    /// - Parameter charsetName: the request's `charset` option; nil or blank is UTF-8.
    static func encodeParams(_ params: String, charsetName: String?, isQuery: Bool) -> String {
        let charsetName = charsetName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Legado's `checkEncoded`: only without a charset is a form value that already looks
        // encoded sent as it is.
        let checkEncoded = charsetName.isEmpty
        let isEscape = charsetName.lowercased() == "escape"
        let encoding: String.Encoding
        if charsetName.isEmpty || isEscape {
            encoding = .utf8 // `escape` encodes UTF-16 code units itself
        } else if let resolved = HTMLResponseDecoder.encoding(forIANA: charsetName) {
            encoding = resolved
        } else {
            // Legado's `charset(name)` throws for an unknown name and the request fails. We
            // log and keep UTF-8 rather than drop the request; delete if a source relies on
            // the failure.
            AppLogger.parse("AnalyzeUrl: unknown request charset; encoding as UTF-8", context: [
                "charset": charsetName,
            ], level: .warning)
            encoding = .utf8
        }

        if isQuery && !isEscape {
            if isEncodedQuery(params) { return params }
            return percentEncode(params, encoding: encoding, kept: queryKeptBytes, spaceAsPlus: false)
        }

        // Form fields (and an `escape` query): each key/value encoded on its own.
        var parts: [String] = []
        for field in params.split(separator: "&", omittingEmptySubsequences: false) {
            let field = String(field)
            func encode(_ value: String) -> String {
                if checkEncoded && isEncodedForm(value) { return value }
                return isEscape
                    ? jsEscape(value)
                    : percentEncode(value, encoding: encoding, kept: formKeptBytes, spaceAsPlus: true)
            }
            if let eq = field.firstIndex(of: "=") {
                let key = String(field[..<eq])
                let value = String(field[field.index(after: eq)...])
                parts.append(encode(key) + "=" + encode(value))
            } else {
                parts.append(encode(field))
            }
        }
        return parts.joined(separator: "&")
    }

    /// Java's `URLEncoder.encode(value, charsetName)` (Legado's `java.encodeURI`); nil for a
    /// charset name Java would reject.
    static func javaURLEncode(_ value: String, charsetName: String) -> String? {
        guard let encoding = HTMLResponseDecoder.encoding(forIANA: charsetName) else { return nil }
        return percentEncode(value, encoding: encoding, kept: formKeptBytes, spaceAsPlus: true)
    }

    /// Legado `NetworkUtils.encodedQuery`.
    static func isEncodedQuery(_ value: String) -> Bool {
        isEncoded(value, literal: encodedQueryBytes)
    }

    /// Legado `NetworkUtils.encodedForm`: only `URLEncoder`'s literal bytes and valid `%XX` —
    /// a `+` or `/` means the value still needs encoding.
    static func isEncodedForm(_ value: String) -> Bool {
        isEncoded(value, literal: formKeptBytes)
    }

    private static func isEncoded(_ value: String, literal: Set<UInt8>) -> Bool {
        let bytes = Array(value.utf8)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            if literal.contains(byte) {
                i += 1
                continue
            }
            if byte == UInt8(ascii: "%"), i + 2 < bytes.count,
               isHexDigit(bytes[i + 1]), isHexDigit(bytes[i + 2]) {
                i += 3
                continue
            }
            return false
        }
        return true
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    /// Encode `value` character by character, as Java's encoders do: a `kept` ASCII character
    /// stays literal, any other is its bytes in `encoding`, each as `%XX`. Per character, not
    /// per byte — a GBK character's second byte can be an ASCII letter or `@`, and must not be
    /// left literal. A character the charset cannot represent becomes `?`, as Java substitutes.
    private static func percentEncode(
        _ value: String, encoding: String.Encoding, kept: Set<UInt8>, spaceAsPlus: Bool
    ) -> String {
        var out = ""
        out.reserveCapacity(value.utf8.count * 3)
        for scalar in value.unicodeScalars {
            if scalar.isASCII, kept.contains(UInt8(scalar.value)) {
                out.unicodeScalars.append(scalar)
            } else if spaceAsPlus && scalar == " " {
                out.append("+")
            } else {
                let bytes = String(scalar).data(using: encoding, allowLossyConversion: true)
                    ?? Data("?".utf8)
                for byte in bytes { out.append(String(format: "%%%02X", byte)) }
            }
        }
        return out
    }

    /// Legado `EncoderUtils.escape` (JavaScript `escape` over UTF-16 code units).
    static func jsEscape(_ value: String) -> String {
        var out = ""
        for unit in value.utf16 {
            switch unit {
            case 48...57, 65...90, 97...122:
                out.unicodeScalars.append(UnicodeScalar(UInt8(unit)))
            case ..<16:
                out.append("%0" + String(unit, radix: 16))
            case ..<256:
                out.append("%" + String(unit, radix: 16))
            default:
                out.append("%u" + String(unit, radix: 16))
            }
        }
        return out
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
        bindings["header"] = sourceHeader ?? ""
        // `java` is this AnalyzeUrl in its own scripts (`AnalyzeUrl.evalJS` binds `java = this`);
        // the engine lays it over the bridge for the evaluation.
        bindings["java"] = scriptView
        return bindings
    }

    // MARK: - URLRequest Construction

    /// Convert the parsed URL into an iOS `URLRequest`.
    ///
    /// Returns `nil` if the URL is invalid or is a data-URI.
    func toURLRequest() -> URLRequest? {
        guard scriptFailure == nil else { return nil }
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

        guard let requestUrl = Self.requestURL(finalUrlString) else { return nil }

        var request = URLRequest(url: requestUrl)
        request.httpMethod = method.uppercased()

        // Headers
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        // Body (POST), as Legado's `executeStrRequest`: the encoded form — also for a blank
        // body —, else the body as written under the source's own `Content-Type` (in that
        // header's charset), else the body as JSON.
        if method.uppercased() == "POST" {
            let bodyStr = body ?? ""
            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            if encodedForm?.isEmpty == false
                || bodyStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                request.httpBody = Data((encodedForm ?? "").utf8)
                if contentType.isEmpty {
                    request.setValue("application/x-www-form-urlencoded",
                                    forHTTPHeaderField: "Content-Type")
                }
            } else if !contentType.isEmpty {
                let encoding = HTMLResponseDecoder.encoding(
                    forIANA: HTMLResponseDecoder.charsetInHeader(contentType)
                ) ?? .utf8
                request.httpBody = bodyStr.data(using: encoding, allowLossyConversion: true)
            } else {
                request.httpBody = Data(bodyStr.utf8)
                request.setValue("application/json; charset=utf-8",
                                forHTTPHeaderField: "Content-Type")
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
        // Legado `AnalyzeUrl.getByteArrayIfDataUri`: `android.util.Base64.decode(…, DEFAULT)`.
        guard let data = LegadoBase64.androidDecode(b64) else {
            AppLogger.parse("data: URL is not base-64", context: ["head": String(b64.prefix(60))])
            return nil
        }
        return (data, mime)
    }

    // MARK: - Helpers

    /// Legado `UrlOption.useWebView()`: only null, "", false and "false" leave it off — any
    /// other value, `"1"` or `"yes"` too, turns the WebView on.
    private static func legadoWebViewFlag(_ value: Any) -> Bool {
        if value is NSNull { return false }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        if let text = value as? String { return !(text.isEmpty || text == "false") }
        return true
    }
}
