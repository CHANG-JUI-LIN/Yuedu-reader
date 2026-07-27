import Foundation
import CryptoKit

// MARK: - Error

enum ModernParserBridgeError: LocalizedError {
    case invalidURL(String)
    case parseError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .parseError(let msg): return "Parse error: \(msg)"
        case .timeout: return "Request timed out"
        }
    }
}

// MARK: - Bridge

/// Adapts ModernRuleEngine's API to the interface expected by
/// BookSourceParsingPipeline (parse-only) and BookSourceFetcher (fetch+parse).
///
/// Each instance is bound to a single BookSource.  Create a new bridge
/// when switching sources.
class ModernParserBridge {

    private let jsEngine: JSCoreEngine
    private let loginManager: LoginManager
    private let runtimeStateStore: BookSourceRuntimeStateStore
    let sourceRuleData: BookSourceRuleData

    /// When set, every `ModernRuleEngine` created by `makeEngine()` will have this
    /// observer attached, emitting pipeline events for diff-driven debugging against
    /// Legado's Android logs.  Set by `BookSourceDebugEngine`.
    var debugObserver: ((RuleDebugEvent) -> Void)?

    // MARK: - Init

    init(source: BookSource) {
        self.sourceRuleData = BookSourceRuleData(source: source)
        self.jsEngine = JSCoreEngine()
        self.loginManager = LoginManager.shared
        self.runtimeStateStore = BookSourceRuntimeStateStore.shared

        wireJSEngine()
    }

    // MARK: - Last JS network exchange (diagnostics)

    /// What the rule's own JS last fetched. Recorded on every `java.ajax`, dumped
    /// only when a chapter comes back empty — that is the one moment where knowing
    /// the server's actual answer decides between "we sent a bad request",
    /// "the source needs login/quota" and "our parsing dropped it".
    struct JSNetworkExchange {
        let url: String
        let status: String
        let length: Int
        let bodyHead: String
    }
    private var lastJSNetworkExchange: JSNetworkExchange?

    private func recordJSNetwork(
        url: String?, statusCode: Int?, timedOut: Bool, body: String?
    ) {
        lastJSNetworkExchange = JSNetworkExchange(
            url: String((url ?? "-").prefix(200)),
            status: timedOut ? "timeout" : (statusCode.map(String.init) ?? "error"),
            length: body?.count ?? -1,
            bodyHead: String((body ?? "nil").prefix(200)).replacingOccurrences(of: "\n", with: " ")
        )
        // Same exchange, second reader: the log line above is for us, this one is for
        // the user. A rule that swallows its API's error (`requestApiUrl` returning
        // null on `{"error":…}`) otherwise leaves an empty screen with no explanation.
        SourceAPIErrorLog.shared.record(
            sourceUrl: sourceRuleData.source.bookSourceUrl,
            requestUrl: url,
            statusCode: statusCode,
            body: body,
            timedOut: timedOut
        )
    }

    // MARK: - Source Headers

    /// The source's `header` rule resolved to request headers — plain JSON, or a
    /// `@js:` / `<js>` rule evaluated on this bridge's engine (Legado
    /// `getHeaderMap()`). Every request built here must carry these: sources like
    /// 书山聚合 put a required constant API token in a JS header rule.
    func resolvedSourceHeaders() -> [String: String] {
        jsEngine.resolvedSourceHeaders()
    }

    // MARK: - Engine Factory

    /// Creates a fresh, fully-wired ModernRuleEngine for a single parse operation.
    /// A new instance per call prevents state bleed when async operations overlap.
    private func makeEngine() -> ModernRuleEngine {
        let e = ModernRuleEngine()
        e.source = sourceRuleData
        e.debugObserver = debugObserver

        // Capture `e` weakly so the closure doesn't extend its lifetime past the parse call.
        e.jsEvaluator = { [weak self, weak e] jsCode, prevResult in
            guard let self, let engine = e else { return nil }
            // Point JS back-references at THIS engine instance before evaluating.
            // Safe because jsEngine serialises all evaluations on its dedicated queue.
            self.jsEngine.getStringHandler = { ruleStr in engine.getString(ruleStr: ruleStr) }
            self.jsEngine.getStringListHandler = { ruleStr in engine.getStringList(ruleStr: ruleStr) }
            // `java.getString(rule, obj)` — evaluate against the caller-supplied document.
            // `mContent` is a per-call input in ModernRuleEngine, so this does not disturb
            // the content the surrounding rule chain is parsing.
            self.jsEngine.getStringWithContentHandler = { ruleStr, content in
                engine.getString(ruleStr: ruleStr, mContent: content)
            }
            var bindings: [String: Any] = [
                "baseUrl": engine.baseUrl,
                "baseURL": engine.baseUrl
            ]
            if let content = engine.content {
                // Legado exposes the response currently being parsed as the global `src`.
                // Some sources intentionally read `src` after an earlier rule segment has
                // transformed `result`, so the two values must remain independent.
                bindings["src"] = content
            }
            return self.jsEngine.evaluateIsolated(
                jsCode,
                result: prevResult,
                bindings: bindings
            )
        }
        return e
    }

    // MARK: - Wire JS-only state (source headers, variable storage, network)

    private func wireJSEngine() {
        jsEngine.bookSource = sourceRuleData.source
        let sourceName = sourceRuleData.source.bookSourceName

        jsEngine.errorHandler = { [weak self] msg, script in
            self?.debugObserver?(.jsExecuted(
                segmentIndex: -1, script: String(script.prefix(200)),
                inputPreview: "", result: "ERROR: \(msg)"
            ))
            // NOT #if DEBUG: a rule's JS blowing up is the most common cause of an
            // empty chapter/TOC, and on a device os_log is the only way to see it.
            AppLogger.parse("⟐ rule JS error", context: [
                "source": sourceName,
                "error": msg,
                "script": String(script.prefix(160)).replacingOccurrences(of: "\n", with: " ")
            ])
        }

        // `java.toast(...)` is how a source reports its own failures — 书山聚合's
        // chapter rule toasts 「❌ 未登录，请先登录」/「⚠️请求失败3次: …」/「请尝试切换
        // 服务器」 from inside its retry loop. Nothing displays toasts during a
        // background parse, so log them; otherwise the source's own diagnosis is lost.
        jsEngine.toastHandler = { msg in
            AppLogger.parse("⟐ source toast", context: [
                "source": sourceName,
                "msg": msg.replacingOccurrences(of: "\n", with: " ")
            ])
        }

        jsEngine.getData = { [weak self] key in
            self?.sourceRuleData.getVariable(key: key)
        }
        jsEngine.putData = { [weak self] key, value in
            self?.sourceRuleData.putVariable(key: key, value: value)
        }

        // ── Source Bridge Wiring ──

        let sourceUrl = sourceRuleData.source.bookSourceUrl

        jsEngine.sourceBridge.getVariableHandler = { [weak self] in
            guard let self else { return "" }
            return self.runtimeStateStore.sourceVariableJSON(for: sourceUrl) ?? ""
        }
        jsEngine.sourceBridge.setVariableHandler = { [weak self] jsonString in
            self?.runtimeStateStore.setSourceVariableJSON(jsonString, for: sourceUrl)
        }
        jsEngine.sourceBridge.getKeyValueHandler = { [weak self] key in
            self?.runtimeStateStore.sourceValue(for: sourceUrl, key: key)
        }
        jsEngine.sourceBridge.putKeyValueHandler = { [weak self] key, value in
            self?.runtimeStateStore.setSourceValue(value, for: sourceUrl, key: key)
        }

        jsEngine.sourceBridge.getLoginInfoHandler = {
            LoginManager.shared.getLoginInfo(sourceUrl: sourceUrl).flatMap { info in
                if let data = try? JSONSerialization.data(withJSONObject: info),
                   let json = String(data: data, encoding: .utf8) {
                    return json
                }
                return nil
            }
        }
        jsEngine.sourceBridge.putLoginInfoHandler = { info in
            guard let data = info.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
            LoginManager.shared.storeLoginInfo(sourceUrl: sourceUrl, info: dict)
        }
        jsEngine.sourceBridge.getLoginInfoMapHandler = {
            LoginManager.shared.getLoginInfo(sourceUrl: sourceUrl) ?? [:]
        }
        jsEngine.sourceBridge.removeLoginInfoHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceUrl)
        }
        // Legado stores whatever `putLoginHeader` was given verbatim and only sends
        // it as headers when it parses as a JSON object; a bare token (书山聚合's
        // api_key) is read back by the source's own JS. Do NOT invent a header name
        // for it — guessing `X-Novel-Token` overwrote the constant token the source's
        // `header` rule sends and the server answered `{"error":"访问被拒绝"}`.
        jsEngine.sourceBridge.putLoginHeaderHandler = { header in
            LoginManager.shared.storeLoginHeader(sourceUrl: sourceUrl, raw: header)
        }
        jsEngine.sourceBridge.getLoginHeaderHandler = {
            LoginManager.shared.getLoginHeader(sourceUrl: sourceUrl)
        }
        jsEngine.sourceBridge.removeLoginHeaderHandler = {
            LoginManager.shared.clearLogin(sourceUrl: sourceUrl)
        }
        jsEngine.sourceBridge.getHeaderMapHandler = { [weak self] in
            var merged = self?.resolvedSourceHeaders() ?? [:]
            if let loginHeaders = LoginManager.shared.getLoginHeaderMap(sourceUrl: sourceUrl) {
                merged.merge(loginHeaders) { _, new in new }
            }
            return merged
        }
        jsEngine.sourceBridge.evalJSHandler = { [weak self] js in
            self?.jsEngine.evaluate(js) ?? ""
        }

        // ── AnalyzeUrl handler for java.ajax() ──
        jsEngine.analyzeUrlHandler = { [weak self] urlStr in
            guard let self else { return nil }
            let analyzeUrl = AnalyzeUrl(
                ruleUrl: urlStr,
                sourceHeader: self.sourceRuleData.source.header,
                baseUrl: self.sourceRuleData.source.bookSourceUrl,
                source: self.sourceRuleData,
                jsEvaluator: { [weak self] jsCode, bindings in
                    self?.jsEngine.evaluateIsolated(jsCode, bindings: bindings)
                }
            )
            if analyzeUrl.isDataUri {
                return Self.bodyForDataURI(analyzeUrl)
            }
            guard var request = analyzeUrl.toURLRequest() else { return nil }
            for (key, value) in self.resolvedSourceHeaders() {
                if request.value(forHTTPHeaderField: key) == nil {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            LoginManager.shared.applyLoginHeaders(to: &request, sourceUrl: sourceUrl)
            if request.value(forHTTPHeaderField: "Cookie") == nil,
               let reqUrl = request.url?.absoluteString {
                let jar = CookieStore.shared.get(url: reqUrl)
                if !jar.isEmpty {
                    request.setValue(jar, forHTTPHeaderField: "Cookie")
                }
            }
            let sem = DispatchSemaphore(value: 0)
            var result: String?
            var responseStatusCode: Int?
            var responseError: Error?
            let task = LegadoJSBridge.requestSession.dataTask(with: request) { data, response, error in
                if let httpResponse = response as? HTTPURLResponse {
                    responseStatusCode = httpResponse.statusCode
                }
                responseError = error
                if let data {
                    let encoding = Self.encodingFromCharset(analyzeUrl.charset)
                    result = String(data: data, encoding: encoding)
                        ?? String(data: data, encoding: .utf8)
                }
                sem.signal()
            }
            task.resume()
            let waitResult = sem.wait(timeout: .now() + 30)
            self.recordJSNetwork(
                url: request.url?.absoluteString,
                statusCode: responseStatusCode,
                timedOut: waitResult == .timedOut,
                body: result
            )
            if waitResult == .timedOut {
                AppLogger.parse("⟐ ajax IN timeout", context: [
                    "url": request.url?.absoluteString ?? analyzeUrl.url,
                    "method": analyzeUrl.method
                ])
                task.cancel()
                return nil
            }
            // Log failures only — this handler is the 段評 `ajaxAll` path too, and a
            // body head per call floods the device console. "Failure" includes a 2xx
            // with a tiny body: these aggregator APIs answer `{"error":"访问被拒绝"}` /
            // `{"code":1,"message":…}` with HTTP 200, so status alone would miss them,
            // while real chapter/search payloads are far larger than 300 chars.
            let bodyLooksLikeErrorEnvelope = (result?.count ?? 0) < 300
            if responseStatusCode.map({ !(200..<300).contains($0) }) ?? true
                || bodyLooksLikeErrorEnvelope {
                AppLogger.parse("⟐ ajax IN failed", context: [
                    "url": request.url?.absoluteString ?? analyzeUrl.url,
                    "method": analyzeUrl.method,
                    "status": responseStatusCode.map(String.init) ?? "error",
                    "error": responseError?.localizedDescription ?? "-",
                    "headerKeys": request.allHTTPHeaderFields?.keys.sorted().joined(separator: ",") ?? "-",
                    "bodyHead": (result ?? "nil").prefix(200).description
                ])
            }
            return result
        }

        // Evaluate jsLib if present, cache the hash to avoid re-evaluation
        evaluateJsLibIfNeeded()

        // setContent handler: JS calls java.setContent(html) → create engine, set content, wire back-refs
        jsEngine.setContentHandler = { [weak self] content, baseUrl in
            guard let self else { return }
            let engine = ModernRuleEngine()
            engine.source = self.sourceRuleData
            engine.jsEvaluator = { [weak engine] jsCode, prevResult in
                guard engine != nil else { return nil }
                return self.jsEngine.evaluate(
                    jsCode,
                    result: prevResult,
                    bindings: [
                        "baseUrl": baseUrl ?? "",
                        "baseURL": baseUrl ?? ""
                    ]
                )
            }
            engine.setContent(content, baseUrl: baseUrl ?? "")
            self.jsEngine.getStringHandler = { ruleStr in engine.getString(ruleStr: ruleStr) }
            self.jsEngine.getStringListHandler = { ruleStr in engine.getStringList(ruleStr: ruleStr) }
            self.jsEngine.getElementsHandler = { ruleStr in engine.getElements(ruleStr: ruleStr) }
            self.jsEngine.getStringWithContentHandler = { ruleStr, content in
                engine.setContent(content, baseUrl: baseUrl ?? "")
                return engine.getString(ruleStr: ruleStr)
            }
        }

        // networkHandler runs on the jsEngine serial queue thread — blocking via
        // semaphore here is intentional and safe (dedicated thread, not the global pool).
        jsEngine.networkHandler = { [weak self] request in
            let semaphore = DispatchSemaphore(value: 0)
            var result: String?
            var statusCode: Int?
            var transportError: Error?
            // Pool at 16/host: this handler is ALWAYS set for the online reader, so plain 段評
            // ajaxAll requests land here — URLSession.shared would re-cap them at 6/host (why the
            // ajaxAll throttle raise alone left `⏱ chapter.jsNet` unchanged).
            let task = LegadoJSBridge.requestSession.dataTask(with: request) { data, response, error in
                statusCode = (response as? HTTPURLResponse)?.statusCode
                transportError = error
                if let data {
                    result = LegadoJSBridge.decodeData(data, response: response)
                }
                semaphore.signal()
            }
            task.resume()
            let timedOut = semaphore.wait(timeout: .now() + 30) == .timedOut
            self?.recordJSNetwork(
                url: request.url?.absoluteString,
                statusCode: statusCode,
                timedOut: timedOut,
                body: result
            )
            // This is the path a plain `java.ajax(url)` takes — 书山聚合 fetches chapter
            // *content* here — and the transport error used to be discarded outright, so
            // a failed chapter left no trace at all. Same failure rule as the AnalyzeUrl
            // branch: non-2xx, or a 2xx whose body is too short to be real content.
            if timedOut || transportError != nil
                || statusCode.map({ !(200..<300).contains($0) }) ?? true
                || (result?.count ?? 0) < 300 {
                AppLogger.parse("⟐ js net failed", context: [
                    "source": sourceName,
                    "url": request.url?.absoluteString.prefix(160).description ?? "-",
                    "status": timedOut ? "timeout" : (statusCode.map(String.init) ?? "error"),
                    "error": transportError?.localizedDescription ?? "-",
                    "bodyHead": (result ?? "nil").prefix(200).description
                ])
            }
            if timedOut { task.cancel() }
            return result
        }
    }

    // MARK: - Parsing API (matches BookSourceParsingPipeline signatures)

    /// Legado `ImageUtils.decode`: runs `coverDecodeJs` / `ruleContent.imageDecode`
    /// over downloaded image bytes. The script sees `result` (byte array) and
    /// `src`, and returns the decoded bytes. nil = decode failed (keep original).
    func decodeImageBytes(_ data: Data, src: String, ruleJs: String) -> Data? {
        var script = ruleJs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty, !data.isEmpty else { return nil }
        if script.hasPrefix("@js:") {
            script = String(script.dropFirst(4))
        } else if script.lowercased().hasPrefix("<js>"),
                  let closeRange = script.range(of: "</js>", options: [.caseInsensitive, .backwards]) {
            script = String(script[script.index(script.startIndex, offsetBy: 4)..<closeRange.lowerBound])
        }
        return jsEngine.evaluateBytes(script, data: data, bindings: ["src": src])
    }

    /// Runs `ruleContent.imageDecode` purely for its side effects, with no image bytes to hand.
    ///
    /// Legado calls the rule after an image is decoded, and sources hang per-image bookkeeping off
    /// it — 同人小说网 clears the memory flag that makes `createSvg()` draw the 段評 bubble, so the
    /// next call (the user's tap) opens the review page instead. Images whose bytes we never
    /// downloaded because the source's own JS produced them (`LegadoImageSourceResolver`) still owe
    /// the source that call. `result` is bound to an empty byte array: the rules that use this hook
    /// return `result` untouched, and the return value is irrelevant here.
    func runImageDecodeHook(src: String, ruleJs: String) {
        var script = ruleJs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return }
        if script.hasPrefix("@js:") {
            script = String(script.dropFirst(4))
        } else if script.lowercased().hasPrefix("<js>"),
                  let closeRange = script.range(of: "</js>", options: [.caseInsensitive, .backwards]) {
            script = String(script[script.index(script.startIndex, offsetBy: 4)..<closeRange.lowerBound])
        }
        _ = jsEngine.evaluate(script, result: [Int](), bindings: ["src": src])
    }

    /// Evaluates a bare source-JS expression with `jsLib` in scope and returns its string result.
    ///
    /// This is Legado's `AnalyzeUrl` `UrlOption.js` / image click-config contract: the source ships
    /// a function call, we run it in the source's own runtime, and what it returns is the answer.
    /// jsLib is hash-guarded, so the ensure call is a no-op once loaded.
    func evaluateSourceScript(_ script: String, bindings: [String: Any] = [:]) -> String? {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        evaluateJsLibIfNeeded()
        return jsEngine.evaluate(trimmed, bindings: bindings)
    }

    /// Presents URLs that source JS opens via `java.showBrowser` / `java.startBrowser`.
    /// Reading a 段評 bubble's click action means running the source's JS and seeing where it
    /// wants to send the user, so this has to be reachable from outside the parsing pipeline.
    var browserPresentHandler: ((String, String, @escaping (String?) -> Void) -> Void)? {
        get { jsEngine.browserPresentHandler }
        set { jsEngine.browserPresentHandler = newValue }
    }

    /// Legado-fork `hasMoreRule`: a JS expression run against the fetched page
    /// body (`result`) that answers whether a next result page exists.
    /// Returns nil when evaluation fails so callers fall back to heuristics.
    func evaluateHasMoreRule(_ rule: String, html: String) -> Bool? {
        var script = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty else { return nil }
        if script.hasPrefix("@js:") {
            script = String(script.dropFirst(4))
        } else if script.lowercased().hasPrefix("<js>"),
                  let closeRange = script.range(of: "</js>", options: [.caseInsensitive, .backwards]) {
            script = String(script[script.index(script.startIndex, offsetBy: 4)..<closeRange.lowerBound])
        }
        guard let raw = jsEngine.evaluateIsolated(script, result: html, bindings: [:]) else {
            return nil
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || normalized == "false" || normalized == "0"
            || normalized == "null" || normalized == "undefined" {
            return false
        }
        return true
    }

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)? = nil
    ) throws -> [OnlineBook] {
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        let listRule = source.ruleSearch.bookList
        guard !listRule.isEmpty else { return [] }

        let elements = engine.getElements(ruleStr: listRule)
        guard !elements.isEmpty else { return [] }

        var books: [OnlineBook] = []
        for element in elements {
            engine.setContent(element, baseUrl: baseURL)

            let name = engine.getString(ruleStr: source.ruleSearch.name)
            guard !name.isEmpty else { continue }

            let author = engine.getString(ruleStr: source.ruleSearch.author)

            // Early filter (Legado BookList idea): a rejected item skips the
            // remaining six rule evaluations below — for strict matchers like
            // 換源 that's most of the per-page parsing work.
            if let earlyFilter, !earlyFilter(name, author) { continue }

            let bookUrl = engine.getString(ruleStr: source.ruleSearch.bookUrl, isUrl: true)
            let coverUrl = engine.getString(ruleStr: source.ruleSearch.coverUrl, isUrl: true)
            let intro = engine.getString(ruleStr: source.ruleSearch.intro)
            let wordCount = engine.getString(ruleStr: source.ruleSearch.wordCount)
            let lastChapter = engine.getString(ruleStr: source.ruleSearch.lastChapter)
            let kind = engine.getString(ruleStr: source.ruleSearch.kind)

            books.append(OnlineBook(
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
                sourceName: source.bookSourceName
            ))
        }

        engine.setContent(html, baseUrl: baseURL)
        return books
    }

    func parseBookInfo(
        html: String,
        bookUrl: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> OnlineBook {
        loadRuntimeVariables(runtimeVariables)
        setBookContext(runtimeVariables: runtimeVariables)
        if !bookUrl.isEmpty {
            jsEngine.bookBridge.bookUrl = bookUrl
        }
        jsEngine.setChapterBridge(LegadoChapterBridge())
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        // Execute init script if present (Legado ruleBookInfo.init)
        let initScript = source.ruleBookInfo.initScript
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !initScript.isEmpty {
            if initScript.hasPrefix(":") {
                // AllInOne Regex: matches groups become the effective content for subsequent rules
                let pattern = String(initScript.dropFirst())
                if !pattern.isEmpty,
                   let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
                   let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                    let nsHTML = html as NSString
                    var groups: [String] = []
                    for i in 0..<match.numberOfRanges {
                        let r = match.range(at: i)
                        groups.append(r.location != NSNotFound ? nsHTML.substring(with: r) : "")
                    }
                    engine.setContent(groups, baseUrl: baseURL)
                }
            } else {
                // Legado init can itself be a full rule chain, e.g.
                // `<js>...</js>$.data`; run it through ModernRuleEngine.
                let initResult = engine.getString(ruleStr: initScript)
                if let jsonData = initResult.data(using: .utf8),
                   let jsonObj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    engine.setContent(jsonObj, baseUrl: baseURL)
                } else if !initResult.isEmpty {
                    engine.setContent(initResult, baseUrl: baseURL)
                } else if let jsonText = jsEngine.evaluate(initScript, result: html),
                   let jsonData = jsonText.data(using: .utf8),
                   let jsonObj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                    engine.setContent(jsonObj, baseUrl: baseURL)
                } else {
                    _ = jsEngine.evaluate(initScript, result: html)
                }
            }
        }

        let name = engine.getString(ruleStr: source.ruleBookInfo.name)
        let author = engine.getString(ruleStr: source.ruleBookInfo.author)
        // An empty cover rule must NOT fall back to baseUrl (getString's isUrl path does that),
        // otherwise sources with an empty ruleBookInfo (七猫/书旗) get the site URL as a "cover"
        // and clobber the real search-result cover. Empty rule → empty cover → UI keeps search cover.
        let coverRule = source.ruleBookInfo.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let coverUrl = coverRule.isEmpty ? "" : engine.getString(ruleStr: coverRule, isUrl: true)
        let intro = engine.getString(ruleStr: source.ruleBookInfo.intro)
        let kind = engine.getString(ruleStr: source.ruleBookInfo.kind)
        let wordCount = engine.getString(ruleStr: source.ruleBookInfo.wordCount)
        let lastChapter = engine.getString(ruleStr: source.ruleBookInfo.lastChapter)
        // Same guard for tocUrl: an empty rule would otherwise resolve to baseUrl (site root) and
        // we'd scrape the homepage as a TOC. Empty rule → fall back to the book's own URL.
        let tocRule = source.ruleBookInfo.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let tocUrlRaw = tocRule.isEmpty ? "" : engine.getString(ruleStr: tocRule, isUrl: true)
        let tocUrl = tocUrlRaw.isEmpty ? bookUrl : tocUrlRaw

        return OnlineBook(
            // Leave empty when the source has no/empty ruleBookInfo (e.g. 七猫/书旗 ship `{}`)
            // or the name rule yields nothing — the detail UI then falls back to the search
            // result's title instead of clobbering it with a placeholder.
            name: name,
            author: author,
            intro: intro,
            coverUrl: coverUrl,
            bookUrl: bookUrl,
            tocUrl: tocUrl,
            wordCount: wordCount,
            lastChapter: lastChapter,
            kind: kind,
            sourceId: source.id,
            sourceName: source.bookSourceName,
            runtimeVariables: dumpRuntimeVariables()
        )
    }

    func parseTOC(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> [OnlineChapterRef] {
        loadRuntimeVariables(runtimeVariables)
        setBookContext(runtimeVariables: runtimeVariables)
        jsEngine.setChapterBridge(LegadoChapterBridge())
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        let listRule = source.ruleToc.chapterList
        guard !listRule.isEmpty else { return [] }

        let elements = engine.getElements(ruleStr: listRule)
        guard !elements.isEmpty else {
            // Device-visible diagnostic: an empty chapter list almost always means the
            // chapterList rule's JS threw (e.g. a TDZ on `let result`, a failed java.ajax,
            // or a missing jsLib symbol). Surface the source + last JS error to Console so
            // "目录为空" is diagnosable without the in-app debug engine.
            AppLogger.parse("TOC chapterList produced 0 chapters", context: [
                "source": source.bookSourceName,
                "jsError": jsEngine.lastError ?? "none",
                "tocUrl": String(baseURL.prefix(120)),
                "bodyLen": "\(html.count)",
                "bodyHead": String(html.prefix(120)),
                "rule": String(listRule.prefix(60))
            ])
            return []
        }

        let formatJs = source.ruleToc.formatJs.trimmingCharacters(in: .whitespacesAndNewlines)

        var chapters: [OnlineChapterRef] = []
        chapters.reserveCapacity(elements.count)
        // Drain autorelease pool every 200 elements to prevent OOM from SwiftSoup DOM accumulation
        let batchSize = 200
        for batchStart in stride(from: 0, to: elements.count, by: batchSize) {
            let batchEnd = min(batchStart + batchSize, elements.count)
            autoreleasepool {
                for index in batchStart..<batchEnd {
                    let element = elements[index]
                    engine.setContent(element, baseUrl: baseURL)

                    var title = ReaderHTMLUtilities.displayText(
                        fromHTMLFragment: engine.getString(ruleStr: source.ruleToc.chapterName)
                    )
                    let url = engine.getString(ruleStr: source.ruleToc.chapterUrl, isUrl: true)
                    guard !title.isEmpty || !url.isEmpty else { continue }

                    let isVolumeStr = engine.getString(ruleStr: source.ruleToc.isVolume)
                    let isVipStr = engine.getString(ruleStr: source.ruleToc.isVip)
                    let isPayStr = engine.getString(ruleStr: source.ruleToc.isPay)
                    let isVolume = Self.parseBool(isVolumeStr)
                    let isVip = Self.parseBool(isVipStr)
                    let isPay = Self.parseBool(isPayStr)

                    if !formatJs.isEmpty {
                        let chapterDict: [String: Any] = [
                            "index": index,
                            "title": title,
                            "url": url,
                            "isVolume": isVolume,
                            "isVip": isVip,
                            "isPay": isPay
                        ]
                        if let formatted = jsEngine.evaluate(
                            formatJs,
                            bindings: ["index": index, "title": title, "chapter": chapterDict]
                        ), !formatted.isEmpty {
                            title = ReaderHTMLUtilities.displayText(fromHTMLFragment: formatted)
                        }
                    }

                    let ref = OnlineChapterRef(
                        index: index,
                        title: title,
                        url: url,
                        isVolume: isVolume,
                        isVip: isVip,
                        isPay: isPay,
                        runtimeVariables: dumpRuntimeVariables()
                    )
                    if ref.isVolume || ref.hasVolumeSeparatorTitle || index < 12 {
                        AppLogger.parse("⟐ tocItem", context: [
                            "index": index,
                            "title": title,
                            "isVolumeRaw": isVolumeStr,
                            "isVolume": ref.isVolume,
                            "volumeTitle": ref.hasVolumeSeparatorTitle,
                            "shouldSkip": ref.shouldRenderAsVolumeSeparator,
                            "isVip": ref.isVip,
                            "isPay": ref.isPay,
                            "urlLen": ref.sanitizedContentURL.count,
                            "urlHead": String(ref.sanitizedContentURL.prefix(120))
                        ])
                    }
                    chapters.append(ref)
                }
            }
        }

        return chapters
    }

    func extractNextTocURL(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) -> String {
        let rule = source.ruleToc.nextTocUrl
        guard !rule.isEmpty else { return "" }
        loadRuntimeVariables(runtimeVariables)
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)
        return engine.getString(ruleStr: rule, isUrl: true)
    }

    /// One TOC page in a single call: chapters plus the next-page URL. The
    /// second rule reuses the page DOM through `JsoupDocumentCache`, so a page
    /// is parsed once instead of once per rule set.
    func parseTOCPage(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) throws -> (chapters: [OnlineChapterRef], nextTocURL: String) {
        let chapters = try parseTOC(
            html: html, baseURL: baseURL,
            source: source, runtimeVariables: runtimeVariables
        )
        let nextTocURL = extractNextTocURL(
            html: html, baseURL: baseURL,
            source: source, runtimeVariables: runtimeVariables
        )
        return (chapters, nextTocURL)
    }

    func parseChapterResult(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        chapterRef: OnlineChapterRef? = nil
    ) throws -> ChapterParsePayload {
        loadRuntimeVariables(runtimeVariables)
        setBookContext(runtimeVariables: runtimeVariables)
        if let chapterRef {
            jsEngine.setChapterBridge(
                LegadoChapterBridge(
                    index: chapterRef.index,
                    title: chapterRef.title,
                    order: chapterRef.index,
                    url: chapterRef.url,
                    // Carry the chapter's VIP flag (from ruleToc.isVip) into `chapter.isVip()`.
                    // 起点's content JS does `try { isVip = chapter.isVip() } catch { isVip = result.v }`
                    // to choose `/chapter/vip` vs `/chapter/free`. Building the bridge WITHOUT this
                    // (the build23 regression) left `chapter.isVip()` always false → VIP chapters
                    // were fetched from `/chapter/free` → proxy returned「网络开小差了」. result.v is
                    // never reached because isVip() returns a value (doesn't throw).
                    isVip: chapterRef.isVip
                )
            )
        } else {
            jsEngine.setChapterBridge(LegadoChapterBridge())
        }
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        // ⟐ contentJS — diagnose 段评-on infinite-loading: if "done" never logs the
        // ruleContent JS (getComments→ajaxAll) hung; if it logs empty the JS returned
        // nothing; if it logs content+0 bubbles the comment injection silently failed.
        let paraState = BookSourceRuntimeStateStore.shared.sourceVariableJSON(for: source.bookSourceUrl) ?? ""
        AppLogger.parse("⟐ contentJS start", context: [
            "title": chapterRef?.title ?? "",
            "vars": String(paraState.prefix(160))
        ])
        // 段评样式: content JS 的段评注入函数在 iOS 上（deviceType=='苹果'）会走「iOS 变体」，
        // 产出 <comment count onPress> → app 原生 .commentBadge，完全忽略书源「段评样式」SVG
        // 设置（起点对话框等）。为忠实还原书源样式，在 content 规则执行前把「iOS 变体」别名成
        // 「Android 变体」，让 iOS 也按书源段评样式产出 SVG <img>，再由 CommentBubbleSVGRecognizer
        // 原生重绘、跟随阅读字体。仅同时定义两者的源会被改写；只定义 iOS 变体的源维持原状。
        // 覆盖两套常见命名: paraForiOS/paraForAndroid 与 getCommentsios/getComments。
        // 注意: createSvg 用 java.get('dev') 选气泡变体，dev='ios'(见 qread 移除)→ios 变体(方形/紧凑)，
        // dev='android-轻阅读'→轻阅读变体(偏宽)。
        let aliasedParaForiOS = jsEngine.evaluate(
            """
            (function () {
                var done = [];
                if (typeof paraForAndroid === 'function' && typeof paraForiOS === 'function') {
                    paraForiOS = paraForAndroid; done.push('para');
                }
                if (typeof getComments === 'function' && typeof getCommentsios === 'function') {
                    getCommentsios = getComments; done.push('getComments');
                }
                return done.length ? done.join('+') : 'false';
            })()
            """
        ) ?? "false"

        jsEngine.resetJSNetworkMs()
        lastJSNetworkExchange = nil
        let _contentStart = Date()
        var content = engine.getString(ruleStr: source.ruleContent.content)
        // Snapshot the error HERE: every later `jsEngine.evaluate` (the replaceRegex
        // pass below runs one) starts by clearing `lastError`, so reading it at log
        // time reported `jsError=none` for a content rule that had actually thrown.
        let contentRuleError = jsEngine.lastError
        // 全文替换 — Legado `BookContent.analyzeContent`: line-trim, then run the source's own
        // `replaceRegex` **through the rule engine**, which is what expands `{{chapter.title}}`
        // templates and splits `##pattern##replacement`. Handing the raw string to a regex API
        // instead just fails to compile (`{{…}}` is not valid regex syntax) and silently replaced
        // nothing — that is why 番茄酱 showed its chapter title twice (the reader's own header plus
        // the `<h1>` the source embeds in the content, which this rule exists to delete).
        //
        // Legado re-adds a literal `　　` indent per line right after this; we deliberately do not.
        // The legado-lyc branch already gates that on `book.isOnLineTxt` (it is wrong for HTML /
        // comic / audio content), and this reader indents through `firstLineHeadIndent` on purpose:
        // a leading U+3000 makes CoreText resolve the whole paragraph run from a glyph that user
        // fonts like WeReadType may lack, dropping the entire line to PingFang. See
        // `NodeAttributedStringBuilder.convert`, which also trims U+3000 back off.
        if !source.ruleContent.replaceRegex.isEmpty {
            content = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: "\n")
            content = engine.getString(ruleStr: source.ruleContent.replaceRegex, mContent: content)
        }
        let _contentMs = Int(Date().timeIntervalSince(_contentStart) * 1000)
        // Split a slow chapter.parse: 段評 sources fetch per-paragraph review counts from
        // inside this content rule (java.ajaxAll), so that network hides here, not in
        // chapter.network. `chapter.parse − chapter.jsNet ≈ JS CPU (SVG generation etc.)`.
        let _jsNetMs = jsEngine.takeJSNetworkMs()
        if _jsNetMs >= 1 {
            AppLogger.parse("⏱ chapter.jsNet \(Int(_jsNetMs))ms \(source.bookSourceName)")
        }

        let lowerContent = content.lowercased()
        let lowerInput = html.lowercased()
        let bubbleCount = content.components(separatedBy: "data:image/svg").count - 1
        AppLogger.parse("⟐ contentJS done", context: [
            "ms": _contentMs,
            "len": content.count,
            "bubbles": bubbleCount,
            "commentTags": lowerContent.components(separatedBy: "<comment").count - 1,
            "ydreview": lowerContent.components(separatedBy: "ydreview://").count - 1,
            "showCmt": lowerContent.components(separatedBy: "showcmt").count - 1,
            "androidShowCmt": lowerContent.components(separatedBy: "androidshowcmt").count - 1,
            "aliasParaForiOS": aliasedParaForiOS,
            "inputLen": html.count,
            "baseURL": String(baseURL.prefix(120)),
            "inputHex": Self.hexPreview(html, byteLimit: 32),
            "inputHasContent": lowerInput.contains(#""content""#),
            "inputHasReview": lowerInput.contains("review") || lowerInput.contains("comment"),
            "empty": content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "jsError": contentRuleError ?? "none",
            "head": String(content.trimmingCharacters(in: .whitespacesAndNewlines).prefix(180))
        ])
        // An empty chapter is almost always the source's own HTTP call coming back
        // with something its JS couldn't use. The exchange is recorded (not logged)
        // per request, and only dumped here — otherwise every 段評 `ajaxAll` call
        // would print a body head.
        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let net = lastJSNetworkExchange
            AppLogger.parse("⟐ contentJS empty · lastJSNet", context: [
                "source": source.bookSourceName,
                "url": net?.url ?? "(the rule made no HTTP call)",
                "status": net?.status ?? "-",
                "len": net?.length ?? -1,
                "bodyHead": net?.bodyHead ?? "-"
            ])
        }
        let title = engine.getString(ruleStr: source.ruleContent.title)

        let sourceRegex = source.ruleContent.sourceRegex
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceMatched = sourceRegex.isEmpty || html.range(of: sourceRegex, options: .regularExpression) != nil

        return ChapterParsePayload(
            content: content,
            title: title,
            sourceMatched: sourceMatched,
            isPay: false,
            runtimeVariables: dumpRuntimeVariables()
        )
    }

    func extractNextContentURLs(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) -> [String] {
        let rule = source.ruleContent.nextContentUrl
        guard !rule.isEmpty else { return [] }
        loadRuntimeVariables(runtimeVariables)
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)
        let list = engine.getStringList(ruleStr: rule, isUrl: true)
        return list.filter { !$0.isEmpty }
    }

    // MARK: - Full pipeline methods (fetch + parse)

    func searchBooks(keyword: String, page: Int = 1) async throws -> [OnlineBook] {
        let source = sourceRuleData.source
        guard !source.searchUrl.isEmpty else { return [] }

        let (body, finalUrl) = try await fetch(
            ruleUrl: source.searchUrl, key: keyword, page: page
        )
        // #region agent log
        if source.bookSourceName.contains("企点") {
            NSLog("[企點診斷] searchBooks fetch URL → %@", finalUrl)
            NSLog("[企點診斷] searchBooks response(前200字) → %@", String(body.prefix(200)))
        }
        _dbgLog("聚合/JS 搜尋", data: [
            "source": source.bookSourceName,
            "变量": String(
                (BookSourceRuntimeStateStore.shared
                    .sourceVariableJSON(for: source.bookSourceUrl) ?? "(空)").prefix(300)),
            "搜索参数": Self.searchParamsPreview(from: finalUrl),
        ], hyp: "S1")
        // #endregion
        return try parseSearchResults(html: body, baseURL: finalUrl, source: source)
    }

    func searchBooksStreaming(
        keyword: String,
        page: Int = 1,
        onBatch: @escaping @Sendable ([OnlineBook]) async -> Void
    ) async throws -> (books: [OnlineBook], streamed: Bool) {
        let source = sourceRuleData.source
        guard !source.searchUrl.isEmpty else { return ([], false) }

        let (body, finalUrl) = try await fetch(
            ruleUrl: source.searchUrl, key: keyword, page: page
        )
        // #region agent log
        _dbgLog("聚合/JS 搜尋", data: [
            "source": source.bookSourceName,
            "变量": String(
                (BookSourceRuntimeStateStore.shared
                    .sourceVariableJSON(for: source.bookSourceUrl) ?? "(空)").prefix(300)),
            "搜索参数": Self.searchParamsPreview(from: finalUrl),
        ], hyp: "S1")
        // #endregion

        if let plan = aggregateSearchPlan(fromHexBody: body) {
            let books = await searchAggregateSubsources(
                plan: plan,
                baseURL: finalUrl,
                source: source,
                onBatch: onBatch
            )
            return (books, true)
        }

        return (try parseSearchResults(html: body, baseURL: finalUrl, source: source), false)
    }

    private struct AggregateSearchPlan {
        var params: [String: Any]
        var sourceKeys: [String]
    }

    private func aggregateSearchPlan(fromHexBody body: String) -> AggregateSearchPlan? {
        guard var params = Self.jsonDictionaryFromHexBody(body),
              var key = params["key"] as? String,
              var tab = params["tab"] as? String,
              var selectedSource = params["sourcesKey"] as? String
        else {
            return nil
        }

        let prefix = key.prefix(2).lowercased()
        let mediaByPrefix = ["x:": "小说", "t:": "听书", "m:": "漫画", "d:": "短剧",
                             "x：": "小说", "t：": "听书", "m：": "漫画", "d：": "短剧"]
        var isQualified = false
        if let media = mediaByPrefix[prefix] {
            isQualified = true
            tab = media
            key.removeFirst(min(2, key.count))
        }
        if let at = key.firstIndex(of: "@") {
            isQualified = true
            let source = String(key[key.index(after: at)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            key = String(key[..<at]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !source.isEmpty { selectedSource = source }
        }
        params["key"] = key
        params["tab"] = tab
        params["sourcesKey"] = selectedSource

        if selectedSource != "全部" {
            return isQualified ? AggregateSearchPlan(params: params, sourceKeys: [selectedSource]) : nil
        }
        guard !tab.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let sourceKeys = configuredAggregateSourceKeys(for: tab)
        guard sourceKeys.count > 1 else { return nil }
        params["sourcesKey"] = selectedSource
        return AggregateSearchPlan(params: params, sourceKeys: sourceKeys)
    }

    private func configuredAggregateSourceKeys(for tab: String) -> [String] {
        guard let variableJSON = runtimeStateStore.sourceVariableJSON(
            for: sourceRuleData.source.bookSourceUrl),
              let data = variableJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return []
        }

        let config = (root["云端配置"] as? [String: Any]) ?? root
        guard let rawList = config[tab] as? [Any] else { return [] }

        var seen = Set<String>()
        var keys: [String] = []
        for item in rawList {
            guard let key = Self.aggregateSourceKey(from: item) else { continue }
            guard key != "全部", seen.insert(key).inserted else { continue }
            keys.append(key)
        }
        return keys
    }

    private func searchAggregateSubsources(
        plan: AggregateSearchPlan,
        baseURL: String,
        source: BookSource,
        onBatch: @escaping @Sendable ([OnlineBook]) async -> Void
    ) async -> [OnlineBook] {
        let maxConcurrentSubsources = min(4, plan.sourceKeys.count)
        let observer = debugObserver
        var allBooks: [OnlineBook] = []

        await withTaskGroup(of: [OnlineBook].self) { group in
            var nextIndex = 0

            func enqueueNext() {
                guard nextIndex < plan.sourceKeys.count else { return }
                let sourceKey = plan.sourceKeys[nextIndex]
                nextIndex += 1

                var params = plan.params
                params["sourcesKey"] = sourceKey
                guard let body = Self.hexBody(forJSONObject: params) else { return }

                group.addTask {
                    guard !Task.isCancelled else { return [] }
                    let bridge = ModernParserBridge(source: source)
                    bridge.debugObserver = observer
                    return (try? bridge.parseSearchResults(
                        html: body,
                        baseURL: baseURL,
                        source: source
                    )) ?? []
                }
            }

            for _ in 0..<maxConcurrentSubsources {
                enqueueNext()
            }

            while let books = await group.next() {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if !books.isEmpty {
                    allBooks.append(contentsOf: books)
                    await onBatch(books)
                }
                enqueueNext()
            }
        }

        return allBooks
    }

    private static func aggregateSourceKey(from item: Any) -> String? {
        if let string = item as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = item as? [String: Any] {
            for field in ["name", "title", "source", "sourceName", "key"] {
                if let string = dict[field] as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return nil
    }

    private static func jsonDictionaryFromHexBody(_ body: String) -> [String: Any]? {
        var bytes: [UInt8] = []
        var index = body.startIndex
        while index < body.endIndex {
            let next = body.index(index, offsetBy: 2, limitedBy: body.endIndex) ?? body.endIndex
            guard next <= body.endIndex else { return nil }
            let hex = body[index..<next]
            guard hex.count == 2, let byte = UInt8(hex, radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        guard !bytes.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
    }

    private static func hexBody(forJSONObject object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else {
            return nil
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// For logging: if `url` is the aggregate sources' `data:;base64,…` pseudo-URL,
    /// decode it so the resolved search params (e.g. `sourcesKey`/`server`) are
    /// visible on-device. Returns a short prefix of the URL otherwise.
    private static func searchParamsPreview(from url: String) -> String {
        guard url.hasPrefix("data:"),
              let range = url.range(of: ";base64,") else {
            return String(url.prefix(120))
        }
        let payload = String(url[range.upperBound...])
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = String(data: data, encoding: .utf8) else {
            return String(url.prefix(120))
        }
        return String(json.prefix(200))
    }

    func getBookInfo(url: String) async throws -> OnlineBook {
        let source = sourceRuleData.source
        let (body, finalUrl) = try await fetch(ruleUrl: url)
        return try parseBookInfo(
            html: body, bookUrl: url, baseURL: finalUrl, source: source
        )
    }

    func getChapterList(url: String) async throws -> [OnlineChapterRef] {
        let source = sourceRuleData.source
        let (body, finalUrl) = try await fetch(ruleUrl: url)
        return try parseTOC(html: body, baseURL: finalUrl, source: source)
    }

    func getContent(url: String) async throws -> String {
        let source = sourceRuleData.source
        let (body, finalUrl) = try await fetch(ruleUrl: url)
        let payload = try parseChapterResult(
            html: body, baseURL: finalUrl, source: source
        )
        return payload.content
    }

    // MARK: - Explore / Discover

    /// Discover item returned from exploreUrl JS evaluation.
    ///
    /// Decoding is intentionally lenient: aggregator sources (e.g. 光遇聚合) emit
    /// `style` values as numbers/bools (`layout_flexBasisPercent: 0.45`), which a
    /// strict `[String: String]` decode would reject — failing the *entire* array.
    ///
    /// Also `Encodable` (auto-synthesized; `style` is already normalized to strings
    /// after decode) so `DiscoverKindsCache` can persist parsed discover categories.
    struct DiscoverItem: Codable {
        var title: String?
        var url: String?
        var style: [String: String]?
        var type: String?
        var action: String?
        var chars: [String]?
        var `default`: String?
        var viewName: String?

        enum CodingKeys: String, CodingKey {
            case title, url, style, type, action, chars, `default`, viewName
        }

        init(
            title: String? = nil,
            url: String? = nil,
            style: [String: String]? = nil,
            type: String? = nil,
            action: String? = nil,
            chars: [String]? = nil,
            default defaultValue: String? = nil,
            viewName: String? = nil
        ) {
            self.title = title
            self.url = url
            self.style = style
            self.type = type
            self.action = action
            self.chars = chars
            self.default = defaultValue
            self.viewName = viewName
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            url = try? c.decodeIfPresent(String.self, forKey: .url)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            action = try? c.decodeIfPresent(String.self, forKey: .action)
            `default` = try? c.decodeIfPresent(String.self, forKey: .default)
            viewName = try? c.decodeIfPresent(String.self, forKey: .viewName)
            chars = try? c.decodeIfPresent([String].self, forKey: .chars)
            if let raw = try? c.decodeIfPresent([String: LenientScalar].self, forKey: .style) {
                style = raw.mapValues(\.stringValue)
            } else {
                style = nil
            }
        }

        /// Decodes a JSON scalar (string / number / bool) into a string.
        private struct LenientScalar: Decodable {
            let stringValue: String
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { stringValue = s }
                else if let i = try? c.decode(Int.self) { stringValue = String(i) }
                else if let d = try? c.decode(Double.self) { stringValue = String(d) }
                else if let b = try? c.decode(Bool.self) { stringValue = String(b) }
                else { stringValue = "" }
            }
        }
    }

    /// Evaluate exploreUrl for a book source and return discover items.
    /// Mirrors Legado's exploreKinds(): JS may produce a rule string, JSON is
    /// decoded directly, and plain text is split into title::url kinds.
    func getExploreItems(page: Int = 1) async -> [DiscoverItem] {
        ensureCloudSettingsIfNeeded()
        let source = sourceRuleData.source
        let rawExploreUrl = source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawExploreUrl.isEmpty else { return [] }

        var ruleStr = rawExploreUrl
        let isJS = Self.isJSExploreRule(rawExploreUrl)
        var exploreJSError: String?
        if isJS {
            let jsCode = Self.jsCode(fromExploreRule: rawExploreUrl)
            let bindings: [String: Any] = [
                "page": page,
                "baseUrl": source.bookSourceUrl,
            ]
            ruleStr = jsEngine.evaluateIsolated(jsCode, bindings: bindings)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // Snapshot now: any later `jsEngine.evaluate` clears `lastError`, so
            // reading it at log time would report "none" for a rule that threw.
            exploreJSError = jsEngine.lastError
        }

        let result: [DiscoverItem]
        if ruleStr.isEmpty {
            result = []
        } else if Self.isJsonArrayOrObject(ruleStr) {
            let items = parseDiscoverJSON(ruleStr)
            // When the exploreUrl JS returns book data JSON directly (not a list
            // of discover categories), every decoded DiscoverItem has an empty
            // title.  If that happens AND the source has ruleExplore.bookList
            // (meaning it can parse book data), wrap the JSON as a data URI so
            // the normal discover pipeline feeds it through ruleExplore.
            if items.allSatisfy({ ($0.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
               !source.ruleExplore.bookList.isEmpty {
                let b64 = Data(ruleStr.utf8).base64EncodedString()
                let dataUrl = "data:application/json;base64,\(b64)"
                result = [DiscoverItem(title: source.bookSourceName, url: dataUrl)]
            } else {
                result = items
            }
        } else if Self.looksLikeMarkupOrError(ruleStr) {
            // A dynamic (<js>/@js:) exploreUrl whose backing endpoint has died returns an error
            // *document* — e.g. an nginx "404 Not Found" HTML page — not JSON and not a `分类::URL`
            // list. Shredding that markup line-by-line produced garbage category chips ("<html>",
            // "<head>…404…", …). Treat an unusable payload as "no explore content" instead.
            result = []
        } else {
            result = parseExploreKindText(ruleStr)
        }

        // An empty 發現頁 has four different causes that look identical on screen: the
        // rule JS threw, its API answered but with nothing usable, the payload decoded
        // to items with no `url` (dropped later as non-navigable), or it was never JSON
        // in the shape we decode. Only the payload itself tells them apart, and this is
        // the one place it exists. Logged for every explore load — it is one line per
        // page open, not per row.
        AppLogger.parse("⟐ explore", context: [
            "source": source.bookSourceName,
            "isJS": isJS,
            "jsError": exploreJSError ?? "none",
            "payloadLen": ruleStr.count,
            "items": result.count,
            "titled": result.filter { !($0.title ?? "").isEmpty }.count,
            "navigable": result.filter { !($0.url ?? "").isEmpty }.count,
            "selects": result.filter { ($0.type ?? "") == "select" }.count,
            "head": String(ruleStr.prefix(240)).replacingOccurrences(of: "\n", with: " ")
        ])

        return result
    }

    /// True when an explore payload is an HTML/error document rather than a JSON or
    /// `分类::URL` list — so a dead endpoint's 404 page isn't rendered as fake categories.
    static func looksLikeMarkupOrError(_ value: String) -> Bool {
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return true }
        if s.hasPrefix("<") { return true }
        let lower = s.lowercased()
        return lower.contains("<html")
            || lower.contains("<!doctype")
            || lower.contains("<body")
            || lower.contains("404 not found")
    }

    /// Parse a JSON array string into DiscoverItem list.
    private func parseDiscoverJSON(_ json: String) -> [DiscoverItem] {
        guard let data = json.data(using: .utf8) else { return [] }
        if let items = try? JSONDecoder().decode([DiscoverItem].self, from: data) {
            return items
        }
        if let single = try? JSONDecoder().decode(DiscoverItem.self, from: data) {
            return [single]
        }
        return []
    }

    private func parseExploreKindText(_ text: String) -> [DiscoverItem] {
        let normalized = text.replacingOccurrences(
            of: #"(&&|\r?\n)+"#,
            with: "\n",
            options: .regularExpression
        )
        return normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { rawEntry in
                let entry = rawEntry.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !entry.isEmpty else { return nil }
                // Drop stray markup lines (HTML fragments from a dead endpoint) — a real category
                // name never contains an `<…>` tag.
                if entry.range(of: #"<[^>]+>"#, options: .regularExpression) != nil { return nil }

                guard let separator = entry.range(of: "::") else {
                    return DiscoverItem(title: entry, url: nil)
                }

                let title = entry[..<separator.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let url = entry[separator.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return nil }
                return DiscoverItem(title: title, url: url.isEmpty ? nil : url)
            }
    }

    private static func isJSExploreRule(_ value: String) -> Bool {
        value.hasPrefix("<js>") || value.hasPrefix("@js:")
    }

    private static func jsCode(fromExploreRule value: String) -> String {
        if value.hasPrefix("@js:") {
            return String(value.dropFirst(4))
        }
        if value.hasPrefix("<js>"), value.hasSuffix("</js>") {
            return String(value.dropFirst(4).dropLast(5))
        }
        return value
    }

    private static func isJsonArrayOrObject(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("[") || trimmed.hasPrefix("{")
    }

    /// Parse explore results using ruleExplore rules (for non-JS exploreUrl).
    func parseExploreResults(html: String, baseURL: String, source: BookSource) -> [OnlineBook] {
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        // Legado convention: a source that ships no explore-specific rules (empty
        // ruleExplore.bookList) reuses its SEARCH rules for discover — the explore
        // endpoints return the same shape as search results. Most comic sources
        // rely on this (their `ruleExplore` is `{}`, only `ruleSearch` is defined),
        // so fall back to ruleSearch instead of giving up on the discover list.
        let explore = source.ruleExplore
        let search = source.ruleSearch
        let useSearch = explore.bookList.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let listRule = useSearch ? search.bookList : explore.bookList

        guard !listRule.isEmpty else {
            // Neither explore nor search defines a book list — last-ditch: treat the
            // payload as a JSON list of {title,url} discover items.
            return discoverItemsAsBooks(html: html, source: source)
        }

        let nameRule = useSearch ? search.name : explore.name
        let authorRule = useSearch ? search.author : explore.author
        let bookUrlRule = useSearch ? search.bookUrl : explore.bookUrl
        let coverRule = useSearch ? search.coverUrl : explore.coverUrl
        let introRule = useSearch ? search.intro : explore.intro
        let wordCountRule = useSearch ? search.wordCount : explore.wordCount
        let lastChapterRule = useSearch ? search.lastChapter : explore.lastChapter
        let kindRule = useSearch ? search.kind : explore.kind

        // Parse books for one bookList variant. Resets engine content to the full
        // page first, because the per-element loop reassigns it.
        func parseBooks(listVariant: String) -> (books: [OnlineBook], elements: Int, emptyNames: Int) {
            engine.setContent(html, baseUrl: baseURL)
            let elements = engine.getElements(ruleStr: listVariant)
            var result: [OnlineBook] = []
            var emptyNames = 0
            for (idx, element) in elements.enumerated() {
                engine.setContent(element, baseUrl: baseURL)
                let name = engine.getString(ruleStr: nameRule)
                if idx == 0 {
                    let elHTML = String(describing: element).prefix(180)
                        .replacingOccurrences(of: "\n", with: " ")
                    NSLog("❖DISC❖ %@", "\(source.bookSourceName) EL0 list='\(listVariant.prefix(24))' nameRule='\(nameRule.prefix(24))' name='\(name.prefix(30))' el=\(elHTML)")
                }
                guard !name.isEmpty else { emptyNames += 1; continue }
                let bookUrl = engine.getString(ruleStr: bookUrlRule, isUrl: true)
                // `isUrl:true` falls back to baseURL when the rule matches nothing —
                // a cover that is merely the page URL is junk (e.g. a bookList narrowed
                // past the <img>, like zymk's `class.item@h3`), so treat it as missing.
                // This also lets the cover-broaden retry below detect the gap.
                var coverUrl = engine.getString(ruleStr: coverRule, isUrl: true)
                if coverUrl == baseURL { coverUrl = "" }
                result.append(OnlineBook(
                    name: name,
                    author: engine.getString(ruleStr: authorRule),
                    intro: engine.getString(ruleStr: introRule),
                    coverUrl: coverUrl,
                    bookUrl: bookUrl,
                    tocUrl: bookUrl,
                    wordCount: engine.getString(ruleStr: wordCountRule),
                    lastChapter: engine.getString(ruleStr: lastChapterRule),
                    kind: engine.getString(ruleStr: kindRule),
                    sourceId: source.id, sourceName: source.bookSourceName
                ))
            }
            return (result, elements.count, emptyNames)
        }

        let primary = parseBooks(listVariant: listRule)
        var books = primary.books
        NSLog("❖DISC❖ %@", "\(source.bookSourceName) parseExplore useSearch=\(useSearch) listRule='\(listRule.prefix(40))' elements=\(primary.elements) books=\(books.count) emptyNames=\(primary.emptyNames)")

        // Compatibility beyond Legado: a `||` bookList returns the FIRST non-empty
        // element set, but that set can be the wrong one — e.g. a discover page that
        // reuses the search grid's class (`.manga-list`) for its category nav, so the
        // first branch matches nav links and every "book" has an empty name. When the
        // chosen branch yields zero valid books, retry the remaining `||` branches.
        if books.isEmpty {
            let (op, parts) = RuleSyntaxParser.splitRuleByOperators(listRule)
            if op == "||", parts.count > 1 {
                for branch in parts.dropFirst() {
                    let trimmed = branch.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    let alt = parseBooks(listVariant: trimmed)
                    NSLog("❖DISC❖ %@", "\(source.bookSourceName) parseExplore || retry '\(trimmed.prefix(30))' elements=\(alt.elements) books=\(alt.books.count)")
                    if !alt.books.isEmpty { books = alt.books; break }
                }
            }
        }

        // Cover compatibility: some sources narrow the bookList past the cover —
        // e.g. `class.item@h3` selects the title node while the <img> lives in a
        // sibling `.thumbnail`, so `img@data-src` resolves empty for every book.
        // When all books came back cover-less, retry with the bookList's parent
        // scope (drop the trailing `@leaf`), but only ADOPT it when it returns the
        // same number of books AND actually recovers covers — so a correctly-scoped
        // bookList, or a source that genuinely has no covers, is left untouched.
        if !books.isEmpty,
           books.allSatisfy({ $0.coverUrl.isEmpty }),
           let lastAt = listRule.range(of: "@", options: .backwards) {
            let broaderList = String(listRule[..<lastAt.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !broaderList.isEmpty {
                let broader = parseBooks(listVariant: broaderList)
                if broader.books.count == books.count,
                   broader.books.contains(where: { !$0.coverUrl.isEmpty }) {
                    NSLog("❖DISC❖ %@", "\(source.bookSourceName) parseExplore cover-broaden '\(broaderList.prefix(30))' recovered covers (\(broader.books.count) books)")
                    books = broader.books
                }
            }
        }

        // The ruleSearch fallback can legitimately match nothing when the discover
        // payload is instead a plain {title,url} JSON list. Preserve that legacy
        // path so no source that worked before this fallback regresses.
        if books.isEmpty, useSearch {
            let fallback = discoverItemsAsBooks(html: html, source: source)
            NSLog("❖DISC❖ %@", "\(source.bookSourceName) parseExplore search-fallback empty → discoverJSON books=\(fallback.count)")
            return fallback
        }
        return books
    }

    /// Last-resort discover parse: decode the payload as a JSON list of `{title,url}`
    /// items (Legado's "exploreUrl returns book data directly" shape). Returns an
    /// empty list for any other payload, so it is safe as a fallback.
    private func discoverItemsAsBooks(html: String, source: BookSource) -> [OnlineBook] {
        parseDiscoverJSON(html).compactMap { item in
            guard let title = item.title, !title.isEmpty else { return nil }
            return OnlineBook(
                name: title, author: "", intro: "",
                coverUrl: "", bookUrl: item.url ?? "",
                tocUrl: item.url ?? "", wordCount: "",
                lastChapter: "", kind: "",
                sourceId: source.id, sourceName: source.bookSourceName
            )
        }
    }

    // MARK: - Network fetch using AnalyzeUrl

    func checkLoginRequired(
        html: String,
        baseURL: String
    ) -> Bool {
        let engine = makeEngine()
        engine.setContent(html, baseUrl: baseURL)

        let js = sourceRuleData.source.loginCheckJs
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !js.isEmpty else { return false }

        let result = engine.getString(ruleStr: js)
        let lower = result.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower == "true" || lower == "1" || lower == "yes"
    }

    /// Prime a site cookie that a source's discover endpoints read inline but never set themselves.
    /// 起点's 榜單/分類 build URLs with `…&_csrfToken={{cookie.getKey("https://qidian.com","_csrfToken")}}`
    /// AND 起点 requires the SAME token be SENT as a cookie (double-submit) — verified: param-only →
    /// `{"code":1,"msg":"失败"}` 0 books; param+cookie → 20 books. That token is only issued by browsing
    /// a 起点 book/search page (NOT the homepage, NOT the qt 密鑰). So on iOS the discover is empty
    /// unless we obtain it. We **always re-fetch a fresh token** (not just when absent): a STALE
    /// `_csrfToken` left over from old browsing is session-rejected by 起点, and a skip-if-present
    /// guard would keep using it → still 0 books. Fetching the source's own search page reissues a
    /// current token (stored in HTTPCookieStorage, auto-sent by URLSession on the ranking request).
    func primeDiscoverCookiesIfNeeded() async {
        let source = sourceRuleData.source
        guard source.exploreUrl.contains("_csrfToken") else { return }
        let searchUrl = source.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchUrl.isEmpty else { return }
        _ = try? await fetch(ruleUrl: searchUrl, key: "1", page: 1)
    }

    func fetch(
        ruleUrl: String, key: String? = nil, page: Int? = nil
    ) async throws -> (String, String) {
        // The rule URL itself can be `@js:` calling into jsLib — a 發現頁 item's url is
        // literally `@js:getApiUrl('/novel/novels', {…})`. jsLib is evaluated when the
        // bridge is built, but a JS timeout resets the engine and only the paths that ask
        // get it back; this one never did, so the call evaluated to nothing and surfaced
        // as "Invalid URL: @js:getApiUrl(…)". Hash-guarded, so it is a no-op once loaded.
        evaluateJsLibIfNeeded()
        ensureCloudSettingsIfNeeded()
        let analyzeUrl = AnalyzeUrl(
            ruleUrl: ruleUrl,
            key: key,
            page: page,
            sourceHeader: sourceRuleData.source.header,
            baseUrl: sourceRuleData.source.bookSourceUrl,
            source: sourceRuleData,
            jsEvaluator: { [weak self] jsCode, bindings in
                self?.jsEngine.evaluateIsolated(jsCode, bindings: bindings)
            }
        )

        if analyzeUrl.isDataUri {
            // Hand back the FULL rule URL, options included. A `data:` URI has no
            // redirect chain, so there is no "final URL" to report — and its `,{json}`
            // options are the only place the source can stash state to read back from
            // `baseUrl`. Returning `analyzeUrl.url` (options stripped) meant
            // 同人小说网's TOC rule ran `JSON.parse(baseUrl.slice(baseUrl.indexOf('{')))`
            // on a string with no `{`: `indexOf` → -1, `slice(-1)` → the last base64
            // character, which parses as a bare JSON number, so `type` came out
            // `undefined`, the rule fetched `/undefined/catalog`, and every branch of
            // its `if (type === 'novel')` chain missed → 目录为空, with nothing thrown.
            // Same rule shape drives its ruleContent, so chapters were next.
            return (Self.bodyForDataURI(analyzeUrl), analyzeUrl.evaluatedRuleUrl)
        }

        guard var request = analyzeUrl.toURLRequest() else {
            throw ModernParserBridgeError.invalidURL(ruleUrl)
        }

        if sourceRuleData.source.bookSourceName.contains("企点") {
            NSLog("[企點診斷] fetch 請求 URL → %@", request.url?.absoluteString ?? "nil")
            NSLog("[企點診斷] fetch 請求 method → %@ body → %@",
                  request.httpMethod ?? "GET",
                  request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "nil")
        }

        // Apply source-level headers (don't overwrite per-request ones)
        for (key, value) in resolvedSourceHeaders() {
            if request.value(forHTTPHeaderField: key) == nil {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        // Apply login headers
        loginManager.applyLoginHeaders(
            to: &request, sourceUrl: sourceRuleData.source.bookSourceUrl
        )

        // Explicitly attach the cookie jar for this URL when no Cookie header is set.
        // Some endpoints require a cookie to be SENT alongside a matching URL param
        // (double-submit CSRF) — 起点 榜單/分類 reject the request unless the `_csrfToken`
        // cookie == the `_csrfToken` query param (verified: param-only → 0 books;
        // param+cookie → 20). URLSession.shared *should* auto-send it from HTTPCookieStorage,
        // but being explicit (mirroring WebFetcher) guarantees it isn't dropped.
        if request.value(forHTTPHeaderField: "Cookie") == nil,
           let reqUrl = request.url?.absoluteString {
            let jar = CookieStore.shared.get(url: reqUrl)
            if !jar.isEmpty {
                request.setValue(jar, forHTTPHeaderField: "Cookie")
            }
        }

        // Use a cooperative timeout so a hanging server never blocks the search/reader
        // indefinitely. The per-source search already has its own timeout in the
        // aggregator, but individual TOC/book-info fetches do not.
        request.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do {
            // Honor the source's `concurrentRate` budget (per-source anti-ban
            // throttle) around the actual network round-trip only.
            (data, response) = try await SourceRateLimit.run(source: sourceRuleData.source) {
                try await withThrowingTaskGroup(
                    of: (Data, URLResponse).self
                ) { group in
                    group.addTask {
                        try await URLSession.shared.data(for: request)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 30_000_000_000)
                        throw ModernParserBridgeError.timeout
                    }
                    guard let result = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return result
                }
            }
        } catch is ModernParserBridgeError {
            SourceAPIErrorLog.shared.record(
                sourceUrl: sourceRuleData.source.bookSourceUrl,
                requestUrl: request.url?.absoluteString,
                statusCode: nil, body: nil, timedOut: true
            )
            throw ModernParserBridgeError.timeout
        }

        let encoding = Self.encodingFromCharset(analyzeUrl.charset)
        let body = String(data: data, encoding: encoding)
            ?? String(data: data, encoding: .utf8) ?? ""
        let finalUrl = (response as? HTTPURLResponse)?.url?.absoluteString
            ?? analyzeUrl.url

        // The status is otherwise dropped here: a 403 error envelope reaches the rule
        // engine as an ordinary body, matches no rule, and search/TOC just come back
        // empty. Keep the body flowing (Legado parity — some sources DO parse error
        // pages) and record the failure alongside it.
        SourceAPIErrorLog.shared.record(
            sourceUrl: sourceRuleData.source.bookSourceUrl,
            requestUrl: request.url?.absoluteString,
            statusCode: (response as? HTTPURLResponse)?.statusCode,
            body: body
        )

        return (body, finalUrl)
    }

    // MARK: - Private: Runtime Variable Helpers

    private func loadRuntimeVariables(_ vars: [String: String]?) {
        guard let vars, !vars.isEmpty else { return }
        for (key, value) in vars {
            sourceRuleData.putVariable(key: key, value: value)
        }
    }

    private func dumpRuntimeVariables() -> [String: String]? {
        var map = sourceRuleData.variableMap
        map.merge(jsEngine.bookBridge.runtimeStateVariables()) { _, new in new }
        for (key, value) in jsEngine.bookBridge.runtimeVariables() where !value.isEmpty {
            map["book.variable.\(key)"] = value
        }
        return map.isEmpty ? nil : map
    }

    private func ensureCloudSettingsIfNeeded() {
        guard sourceMayUseCloudSettings else { return }
        evaluateJsLibIfNeeded()
        guard !sourceVariableHasCloudConfig() else { return }

        _ = jsEngine.evaluate(
            """
            cache.delete('gyksconfig');
            if (typeof getCloudSettings === 'function') {
                getCloudSettings(true);
            }
            """,
            bindings: [
                "baseUrl": sourceRuleData.source.bookSourceUrl,
                "baseURL": sourceRuleData.source.bookSourceUrl
            ]
        )
    }

    private var sourceMayUseCloudSettings: Bool {
        [
            sourceRuleData.source.jsLib,
            sourceRuleData.source.exploreUrl,
            sourceRuleData.source.searchUrl
        ].contains { script in
            script.contains("云端配置")
                || script.contains("getCloudSettings")
                || script.contains("gyksconfig")
        }
    }

    private func sourceVariableHasCloudConfig() -> Bool {
        guard let json = runtimeStateStore.sourceVariableJSON(for: sourceRuleData.source.bookSourceUrl),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cloudConfig = object["云端配置"]
        else { return false }

        switch cloudConfig {
        case let dict as [String: Any]:
            return !dict.isEmpty
        case let array as [Any]:
            return !array.isEmpty
        case let string as String:
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case is NSNull:
            return false
        default:
            return true
        }
    }

    private func setBookContext(runtimeVariables: [String: String]?) {
        var bookVariables: [String: String] = [:]
        runtimeVariables?.forEach { key, value in
            if key.hasPrefix("book.variable.") {
                let rawKey = String(key.dropFirst("book.variable.".count))
                bookVariables[rawKey] = value
            }
        }
        let bridge = LegadoBookBridge(
            durChapterIndex: Int(runtimeVariables?["book.durChapterIndex"] ?? "") ?? 0,
            durChapterTitle: runtimeVariables?["book.durChapterTitle"] ?? "",
            order: Int(runtimeVariables?["book.order"] ?? "") ?? 0,
            type: Int(runtimeVariables?["book.type"] ?? "") ?? 0,
            imageStyle: runtimeVariables?["book.imageStyle"] ?? "",
            name: runtimeVariables?["book.name"] ?? "",
            author: runtimeVariables?["book.author"] ?? "",
            coverUrl: runtimeVariables?["book.coverUrl"] ?? "",
            bookUrl: runtimeVariables?["book.bookUrl"] ?? "",
            abstract: runtimeVariables?["book.abstract"] ?? "",
            variables: bookVariables
        )
        jsEngine.setBookBridge(bridge)
    }

    // MARK: - Private: Helpers

    private static func parseBool(_ str: String) -> Bool {
        let lower = str.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return lower == "true" || lower == "1" || lower == "yes"
    }

    private static func hexPreview(_ text: String, byteLimit: Int) -> String {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return "" }
        return data.prefix(byteLimit).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func encodingFromCharset(_ charset: String?) -> String.Encoding {
        guard let charset = charset?.lowercased() else { return .utf8 }
        switch charset {
        case "gbk", "gb2312", "gb18030":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        default:
            return .utf8
        }
    }

    private static func bodyForDataURI(_ analyzeUrl: AnalyzeUrl) -> String {
        guard let decoded = analyzeUrl.decodeDataUri() else { return "" }
        // A `type` key in the data-URI options means "return the payload hex-encoded"
        // (binary-safe), which the source then decodes with `java.hexDecodeToString`.
        // Matches Legado's AnalyzeUrl.getStrResponseAwait():
        //   if (type != null) return StrResponse(url, HexUtil.encodeHexStr(getByteArrayAwait()))
        // The VALUE is just a marker — 起点 uses `{"type":"X-QD"}` for tocUrl but
        // `{"type":""}` (empty!) for chapter content, and BOTH content/toc JS call
        // hexDecodeToString. Keying off `type?.isEmpty == false` wrongly sent the
        // empty-type content payload back as UTF-8, so hexDecodeToString failed and the
        // chapter stuck on "加载中". Hex whenever `type` is present (even empty); only a
        // fully absent `type` returns the decoded string.
        if analyzeUrl.type != nil {
            return decoded.data.map { String(format: "%02x", $0) }.joined()
        }
        return String(data: decoded.data, encoding: .utf8)
            ?? String(decoding: decoded.data, as: UTF8.self)
    }

    // MARK: - jsLib Caching

    /// Hashed `jsLib` content that was last evaluated.  `nil` means jsLib has never been evaluated.
    private var evaluatedJsLibHash: String?
    /// Engine generation at the time `evaluatedJsLibHash` was set.  Invalidated
    /// when `jsEngine.generation` changes (engine was reset after a JS timeout).
    private var evaluatedJsLibEngineGen: UInt64 = 0

    /// Evaluate jsLib once per source, caching the hash so we don't re-evaluate
    /// on every request.  jsLib functions (e.g. `BaseUrl()`, `getVariable()`,
    /// `request()`) stay in the shared JSContext scope.
    private func evaluateJsLibIfNeeded() {
        let jsLib = sourceRuleData.source.jsLib
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !jsLib.isEmpty else { return }

        // If the JS engine was reset (timeout recovery), the new context has no
        // jsLib code — force re-evaluation.
        if jsEngine.generation != evaluatedJsLibEngineGen {
            evaluatedJsLibHash = nil
            evaluatedJsLibEngineGen = jsEngine.generation
        }

        let newHash = jsLib.md5Hash
        guard newHash != evaluatedJsLibHash else { return }

        _ = jsEngine.evaluate(jsLib)
        evaluatedJsLibHash = newHash
    }

    /// Re-evaluate jsLib on next use (e.g. after source variable reset).
    func invalidateJsLibCache() {
        evaluatedJsLibHash = nil
    }
}

private extension String {
    var md5Hash: String {
        guard let data = data(using: .utf8) else { return "" }
        let hash = CryptoKit.Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
