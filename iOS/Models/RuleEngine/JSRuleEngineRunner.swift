import Foundation
import WebKit

// #region agent log
private func _dbgLog(location: String, message: String, data: [String: Any], hypothesisId: String) {
    _ = location
    _ = message
    _ = data
    _ = hypothesisId
}
// #endregion

// MARK: - JS Security Validator
// Blacklists dangerous patterns in JavaScript from book sources (untrusted user-imported sources).
// This is defense-in-depth, not a guarantee; the primary goal is blocking obvious malicious operations.

private enum JSSecurityValidator {
    struct ValidationError: Error {
        let reason: String
        var localizedDescription: String { reason }
    }

    /// High-risk patterns: rejected immediately
    private static let blockedPatterns: [String] = [
        "document\\.cookie",          // Read cookies
        "localStorage",               // Access local storage
        "sessionStorage",             // Access session storage
        "indexedDB",                  // Access IndexedDB
        "XMLHttpRequest",             // Initiate XHR (should be managed by WebFetcher)
        "fetch\\s*\\(",               // Fetch API
        "window\\.location\\s*=",     // Redirect the page
        "document\\.write\\s*\\(",    // Dynamic document writing
        "eval\\s*\\(",                // Dynamic execution (ruleEngine.js already has sandbox)
        "Function\\s*\\(",            // Dynamic function construction
        "webkit\\.messageHandlers",   // Direct call to iOS bridge
    ]

    /// Validate whether a JS string passes security checks
    /// - Returns: `.success(js)` if passed, `.failure(reason)` if rejected
    static func validate(_ js: String) -> Result<String, ValidationError> {
        for pattern in blockedPatterns {
            if js.range(of: pattern, options: .regularExpression) != nil {
                AppLogger.security(
                    "Book source JS contains a high-risk pattern; execution blocked",
                    context: ["pattern": pattern, "jsPreview": String(js.prefix(120))]
                )
                return .failure(ValidationError(reason: "Book source JavaScript contains a disallowed operation: \(pattern)"))
            }
        }
        return .success(js)
    }
}

// MARK: - JS Book Source Engine Bridge (Optional)
// Book source parsing is handled by Assets/bookSourceEngine/ruleEngine.js,
// shared between Web and iOS. Activate by switching BookSourceFetcher to call
// JSRuleEngineRunner.shared.parseSearchResults(...) etc.

@MainActor
final class JSRuleEngineRunner: NSObject, WKScriptMessageHandler {
    static let shared = JSRuleEngineRunner()

    struct ChapterPayload: Decodable {
        let content: String
        let title: String
        let sourceMatched: Bool
        let isPay: Bool
        let runtimeVariables: [String: String]?
    }

    private var webView: WKWebView?
    private var scriptLoaded = false
    private var loadContinuation: CheckedContinuation<Void, Error>?
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []
    private var isLoading = false
    /// Cached ruleEngine.js content, used in didFinish to inject via evaluateJavaScript
    /// (workaround for iOS bug where WKUserScript does not execute on about:blank)
    private var cachedScriptContent: String?

    private override init() {
        super.init()
    }

    private func ensureScriptLoaded() async throws {
        if scriptLoaded { return }
        if isLoading {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                loadWaiters.append(cont)
            }
            return
        }
        isLoading = true
        defer { isLoading = false }
        // Try the bundle root first (ruleEngine.js is at root after Xcode build),
        // then try the bookSourceEngine subdirectory
        let url = Bundle.main.url(forResource: "ruleEngine", withExtension: "js", subdirectory: nil)
            ?? Bundle.main.url(forResource: "ruleEngine", withExtension: "js", subdirectory: "bookSourceEngine")
        guard let url = url,
              let scriptContent = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw NSError(domain: "JSRuleEngineRunner", code: -1, userInfo: [NSLocalizedDescriptionKey: "ruleEngine.js not found"])
        }
        cachedScriptContent = scriptContent
        // Do not inject ruleEngine via WKUserScript: iOS has a known bug where
        // WKUserScript does not execute on the initial about:blank load.
        // Instead, inject via evaluateJavaScript in didFinish.
        let html = """
        <!DOCTYPE html><html><head><meta charset="UTF-8"></head><body></body></html>
        """
        let config = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        config.userContentController = userContentController
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        webView = wv
        _ = wv.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loadContinuation = cont
        }
        scriptLoaded = true
        for w in loadWaiters { w.resume() }
        loadWaiters.removeAll()
    }

    private func ruleSearchToDict(_ r: SearchRule) -> [String: String] {
        [
            "bookList": r.bookList, "name": r.name, "author": r.author,
            "coverUrl": r.coverUrl, "intro": r.intro, "bookUrl": r.bookUrl,
            "wordCount": r.wordCount, "lastChapter": r.lastChapter, "kind": r.kind
        ]
    }

    private func ruleBookInfoToDict(_ r: BookInfoRule) -> [String: String] {
        [
            "init": r.initScript,
            "name": r.name, "author": r.author, "coverUrl": r.coverUrl,
            "intro": r.intro, "kind": r.kind, "wordCount": r.wordCount,
            "lastChapter": r.lastChapter, "updateTime": r.updateTime,
            "tocUrl": r.tocUrl, "canReName": r.canReName
        ]
    }

    private func ruleTocToDict(_ r: TOCRule) -> [String: String] {
        [
            "preUpdateJs": r.preUpdateJs,
            "chapterList": r.chapterList, "chapterName": r.chapterName,
            "chapterUrl": r.chapterUrl, "formatJs": r.formatJs,
            "isVolume": r.isVolume, "isVip": r.isVip, "isPay": r.isPay,
            "updateTime": r.updateTime, "nextTocUrl": r.nextTocUrl
        ]
    }

    private func ruleContentToDict(_ r: ContentRule) -> [String: String] {
        [
            "content": r.content,
            "title": r.title,
            "nextContentUrl": r.nextContentUrl,
            "webJs": r.webJs,
            "sourceRegex": r.sourceRegex,
            "replaceRegex": r.replaceRegex,
            "imageStyle": r.imageStyle,
            "payAction": r.payAction
        ]
    }

    /// Encode a string as a JSON string literal (with surrounding quotes),
    /// avoiding ambiguity between Data?.flatMap and Data.flatMap.
    private func jsonEncodeString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let str = String(data: data, encoding: .utf8) else { return "\"\"" }
        return str
    }

    private func evaluateJSONString(on webView: WKWebView, js: String, timeout: TimeInterval = AppConfig.jsRuleEngineExecutionTimeout) async throws -> String {
        switch JSSecurityValidator.validate(js) {
        case .failure(let err):
            throw NSError(domain: "JSRuleEngineRunner", code: -10, userInfo: [NSLocalizedDescriptionKey: err.reason])
        case .success: break
        }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { res in
                        switch res {
                        case .failure(let err):
                            cont.resume(throwing: err)
                        case .success(let val):
                            guard let data = try? JSONSerialization.data(withJSONObject: val),
                                  let str = String(data: data, encoding: .utf8)
                            else {
                                cont.resume(throwing: NSError(domain: "JSRuleEngineRunner", code: -4, userInfo: [NSLocalizedDescriptionKey: "Result serialization failed"]))
                                return
                            }
                            cont.resume(returning: str)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "JSRuleEngineRunner", code: -9, userInfo: [NSLocalizedDescriptionKey: "JS execution timed out"])
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    private func evaluateString(on webView: WKWebView, js: String, timeout: TimeInterval = 5) async throws -> String {
        switch JSSecurityValidator.validate(js) {
        case .failure(let err):
            throw NSError(domain: "JSRuleEngineRunner", code: -10, userInfo: [NSLocalizedDescriptionKey: err.reason])
        case .success: break
        }
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    webView.evaluateJavaScript(js, in: nil, in: .defaultClient) { res in
                        switch res {
                        case .failure(let err):
                            cont.resume(throwing: err)
                        case .success(let val):
                            cont.resume(returning: (val as? String) ?? "")
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "JSRuleEngineRunner", code: -9, userInfo: [NSLocalizedDescriptionKey: "JS execution timed out"])
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    func parseSearchResults(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> [OnlineBook] {
        try await ensureScriptLoaded()
        guard let wv = webView else { throw NSError(domain: "JSRuleEngineRunner", code: -2, userInfo: [NSLocalizedDescriptionKey: "WebView not ready"]) }
        let ruleDict = ruleSearchToDict(source.ruleSearch)
        let htmlEnc = jsonEncodeString(html)
        let baseEnc = jsonEncodeString(baseURL)
        let runtimeEnc: String
        if let runtimeVariables,
           let runtimeData = try? JSONSerialization.data(withJSONObject: runtimeVariables),
           let encoded = String(data: runtimeData, encoding: .utf8) {
            runtimeEnc = encoded
        } else {
            runtimeEnc = "{}"
        }
        guard let ruleData = try? JSONSerialization.data(withJSONObject: ruleDict),
              let ruleEnc = String(data: ruleData, encoding: .utf8)
        else { throw NSError(domain: "JSRuleEngineRunner", code: -3, userInfo: [NSLocalizedDescriptionKey: "Rule serialization failed"]) }
        let js = "window.BookSourceEngine.parseSearchResults(\(htmlEnc), \(baseEnc), \(ruleEnc), \(runtimeEnc))"
        // #region agent log
        _dbgLog(location: "JSRuleEngineRunner.swift:parseSearchResults", message: "about to evaluate JS", data: ["source": source.bookSourceName, "htmlLen": String(html.count)], hypothesisId: "H5")
        // #endregion
        let result = try await evaluateJSONString(on: wv, js: js, timeout: 10)
        struct SearchBookPayload: Decodable {
            let name: String?
            let author: String?
            let intro: String?
            let coverUrl: String?
            let bookUrl: String?
            let tocUrl: String?
            let wordCount: String?
            let lastChapter: String?
            let kind: String?
            let runtimeVariables: [String: String]?
        }
        guard let arr = try? JSONDecoder().decode([SearchBookPayload].self, from: Data(result.utf8)) else {
            return []
        }
        return arr.compactMap { dict -> OnlineBook? in
            guard let bookUrl = dict.bookUrl, !bookUrl.isEmpty else { return nil }
            return OnlineBook(
                name: dict.name ?? "",
                author: dict.author ?? "",
                intro: dict.intro ?? "",
                coverUrl: dict.coverUrl ?? "",
                bookUrl: bookUrl,
                tocUrl: dict.tocUrl ?? bookUrl,
                wordCount: dict.wordCount ?? "",
                lastChapter: dict.lastChapter ?? "",
                kind: dict.kind ?? "",
                sourceId: source.id,
                sourceName: source.bookSourceName,
                runtimeVariables: dict.runtimeVariables
            )
        }
    }

    func parseBookInfo(
        html: String,
        bookUrl: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> OnlineBook {
        try await ensureScriptLoaded()
        guard let wv = webView else { throw NSError(domain: "JSRuleEngineRunner", code: -2, userInfo: nil) }
        let ruleDict = ruleBookInfoToDict(source.ruleBookInfo)
        let htmlEnc = jsonEncodeString(html)
        let baseEnc = jsonEncodeString(baseURL)
        let bookUrlEnc = jsonEncodeString(bookUrl)
        let runtimeEnc: String
        if let runtimeVariables,
           let runtimeData = try? JSONSerialization.data(withJSONObject: runtimeVariables),
           let encoded = String(data: runtimeData, encoding: .utf8) {
            runtimeEnc = encoded
        } else {
            runtimeEnc = "{}"
        }
        guard let ruleData = try? JSONSerialization.data(withJSONObject: ruleDict),
              let ruleEnc = String(data: ruleData, encoding: .utf8)
        else { throw NSError(domain: "JSRuleEngineRunner", code: -3, userInfo: nil) }
        let js = "window.BookSourceEngine.parseBookInfo(\(htmlEnc), \(bookUrlEnc), \(baseEnc), \(ruleEnc), \(runtimeEnc))"
        let result = try await evaluateJSONString(on: wv, js: js, timeout: 8)
        struct BookInfoPayload: Decodable {
            let name: String?
            let author: String?
            let intro: String?
            let coverUrl: String?
            let tocUrl: String?
            let wordCount: String?
            let lastChapter: String?
            let kind: String?
            let runtimeVariables: [String: String]?
        }
        guard let dict = try? JSONDecoder().decode(BookInfoPayload.self, from: Data(result.utf8)) else {
            return OnlineBook(name: "", author: "", intro: "", coverUrl: "", bookUrl: bookUrl, tocUrl: bookUrl, wordCount: "", lastChapter: "", kind: "", sourceId: source.id, sourceName: source.bookSourceName, runtimeVariables: runtimeVariables)
        }
        return OnlineBook(
            name: dict.name ?? "",
            author: dict.author ?? "",
            intro: dict.intro ?? "",
            coverUrl: dict.coverUrl ?? "",
            bookUrl: bookUrl,
            tocUrl: dict.tocUrl ?? bookUrl,
            wordCount: dict.wordCount ?? "",
            lastChapter: dict.lastChapter ?? "",
            kind: dict.kind ?? "",
            sourceId: source.id,
            sourceName: source.bookSourceName,
            runtimeVariables: dict.runtimeVariables
        )
    }

    func parseTOC(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> [OnlineChapterRef] {
        try await ensureScriptLoaded()
        guard let wv = webView else { throw NSError(domain: "JSRuleEngineRunner", code: -2, userInfo: nil) }
        let ruleDict = ruleTocToDict(source.ruleToc)
        // #region agent log
        _dbgLog(location: "JSRuleEngineRunner.swift:parseTOC", message: "rule passed to JS", data: [
            "source": source.bookSourceName,
            "htmlLen": String(html.count),
            "chapterList": String((ruleDict["chapterList"] ?? "").prefix(120)),
            "chapterName": String((ruleDict["chapterName"] ?? "").prefix(80)),
            "chapterUrl": String((ruleDict["chapterUrl"] ?? "").prefix(80))
        ], hypothesisId: "H1")
        // #endregion
        let htmlEnc = jsonEncodeString(html)
        let baseEnc = jsonEncodeString(baseURL)
        let runtimeEnc: String
        if let runtimeVariables,
           let runtimeData = try? JSONSerialization.data(withJSONObject: runtimeVariables),
           let encoded = String(data: runtimeData, encoding: .utf8) {
            runtimeEnc = encoded
        } else {
            runtimeEnc = "{}"
        }
        guard let ruleData = try? JSONSerialization.data(withJSONObject: ruleDict),
              let ruleEnc = String(data: ruleData, encoding: .utf8)
        else { throw NSError(domain: "JSRuleEngineRunner", code: -3, userInfo: nil) }
        let js = "window.BookSourceEngine.parseTOC(\(htmlEnc), \(baseEnc), \(ruleEnc), \(runtimeEnc))"
        let result = try await evaluateJSONString(on: wv, js: js, timeout: 8)
        struct Chap: Decodable {
            let index: Int
            let title: String
            let url: String
            let isVolume: Bool?
            let isVip: Bool?
            let isPay: Bool?
            let runtimeVariables: [String: String]?
        }
        guard let arr = try? JSONDecoder().decode([Chap].self, from: Data(result.utf8)) else {
            _dbgLog(location: "JSRuleEngineRunner.swift:parseTOC", message: "decode failed or empty", data: ["resultPreview": String(result.prefix(200)), "source": source.bookSourceName], hypothesisId: "T1")
            return []
        }
        if arr.isEmpty {
            _dbgLog(location: "JSRuleEngineRunner.swift:parseTOC", message: "JS returned empty array", data: ["source": source.bookSourceName], hypothesisId: "T1")
        }
        return arr.enumerated().map { i, c in
            OnlineChapterRef(
                index: i,
                title: ReaderHTMLUtilities.displayText(fromHTMLFragment: c.title),
                url: c.url,
                isVolume: c.isVolume ?? false,
                isVip: c.isVip ?? false,
                isPay: c.isPay ?? false,
                runtimeVariables: c.runtimeVariables
            )
        }
    }

    func parseChapterContent(html: String, baseURL: String, source: BookSource) async throws -> String {
        try await parseChapterPayload(html: html, baseURL: baseURL, source: source).content
    }

    func parseChapterPayload(
        html: String,
        baseURL: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> ChapterPayload {
        try await ensureScriptLoaded()
        guard let wv = webView else { throw NSError(domain: "JSRuleEngineRunner", code: -2, userInfo: nil) }
        let ruleDict = ruleContentToDict(source.ruleContent)
        let htmlEnc = jsonEncodeString(html)
        let baseEnc = jsonEncodeString(baseURL)
        let runtimeEnc: String
        if let runtimeVariables,
           let runtimeData = try? JSONSerialization.data(withJSONObject: runtimeVariables),
           let encoded = String(data: runtimeData, encoding: .utf8) {
            runtimeEnc = encoded
        } else {
            runtimeEnc = "{}"
        }
        guard let ruleData = try? JSONSerialization.data(withJSONObject: ruleDict),
              let ruleEnc = String(data: ruleData, encoding: .utf8)
        else { throw NSError(domain: "JSRuleEngineRunner", code: -3, userInfo: nil) }
        let js = "window.BookSourceEngine.parseChapterPayload(\(htmlEnc), \(baseEnc), \(ruleEnc), \(runtimeEnc))"
        let result = try await evaluateJSONString(on: wv, js: js, timeout: 8)
        guard let payload = try? JSONDecoder().decode(ChapterPayload.self, from: Data(result.utf8)) else {
            return ChapterPayload(content: "", title: "", sourceMatched: true, isPay: false, runtimeVariables: runtimeVariables)
        }
        return payload
    }

    /// Use ruleEngine.js routeExtractValue to extract a single field (for nextTocUrl / nextContentUrl)
    func extractSingleValue(
        html: String,
        baseURL: String,
        rule: String,
        runtimeVariables: [String: String]? = nil
    ) async throws -> String {
        guard !rule.isEmpty else { return "" }
        try await ensureScriptLoaded()
        guard let wv = webView else { throw NSError(domain: "JSRuleEngineRunner", code: -2, userInfo: nil) }
        let htmlEnc = jsonEncodeString(html)
        let baseEnc = jsonEncodeString(baseURL)
        let ruleEnc = jsonEncodeString(rule)
        let runtimeEnc: String
        if let runtimeVariables,
           let runtimeData = try? JSONSerialization.data(withJSONObject: runtimeVariables),
           let encoded = String(data: runtimeData, encoding: .utf8) {
            runtimeEnc = encoded
        } else {
            runtimeEnc = "{}"
        }
        let js = "window.BookSourceEngine.routeExtractValue(\(htmlEnc), \(baseEnc), \(ruleEnc), null, null, \(runtimeEnc))"
        return try await evaluateString(on: wv, js: js, timeout: 5)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "logging", let body = message.body as? String else { return }
        if let data = body.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let loc = json["location"] as? String ?? "JS_Console"
            let msg = json["message"] as? String ?? body
            let d = json["data"] as? [String: Any] ?? [:]
            let hid = json["hypothesisId"] as? String ?? "JS"
            _dbgLog(location: loc, message: msg, data: d, hypothesisId: hid)
        } else {
            _dbgLog(location: "JS_Console", message: body, data: [:], hypothesisId: "JS_Console")
        }
    }
}

extension JSRuleEngineRunner: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // #region agent log
        _dbgLog(location: "JSRuleEngineRunner.swift:didFinish", message: "didFinish fired", data: [:], hypothesisId: "H3")
        let scriptToInject = cachedScriptContent ?? ""
        guard !scriptToInject.isEmpty else {
            _dbgLog(location: "JSRuleEngineRunner.swift:didFinish", message: "no script to inject", data: [:], hypothesisId: "H8")
            loadContinuation?.resume(throwing: NSError(domain: "JSRuleEngineRunner", code: -10, userInfo: [NSLocalizedDescriptionKey: "BookSourceEngine not ready: no cached script"]))
            loadContinuation = nil
            return
        }
        // Inject ruleEngine via evaluateJavaScript using defaultClient to avoid
        // the .page content world restriction on about:blank.
        // WKUserScript does not execute on the initial about:blank load (known iOS bug),
        // so injection happens sequentially in didFinish: first lock down dangerous APIs,
        // then inject ruleEngine.js.
        let world = WKContentWorld.defaultClient

        // Step 1: Inject API lockdown script to prevent book source scripts from
        // accessing network or local storage. eval/Function are not blocked
        // (ruleEngine.js may use them internally), but all data exfiltration
        // channels are closed.
        let apiLockdownScript = """
        (function() {
            'use strict';
            const deny = { get: () => null, set: () => {}, configurable: false };
            // Block network APIs: book source scripts must not initiate network requests
            try { Object.defineProperty(window, 'fetch', deny); } catch(_) {}
            try { Object.defineProperty(window, 'XMLHttpRequest', deny); } catch(_) {}
            try { Object.defineProperty(window, 'WebSocket', deny); } catch(_) {}
            try { Object.defineProperty(window, 'EventSource', deny); } catch(_) {}
            // Block persistent storage
            try { Object.defineProperty(window, 'localStorage', deny); } catch(_) {}
            try { Object.defineProperty(window, 'sessionStorage', deny); } catch(_) {}
            try { Object.defineProperty(window, 'indexedDB', deny); } catch(_) {}
            try { Object.defineProperty(window, 'caches', deny); } catch(_) {}
            // Block Beacon and geolocation
            try { Object.defineProperty(navigator, 'sendBeacon', deny); } catch(_) {}
            try { Object.defineProperty(navigator, 'geolocation', deny); } catch(_) {}
            // Clear cookies (read always returns empty, write is a no-op)
            try {
                Object.defineProperty(document, 'cookie', {
                    get: () => '',
                    set: () => {},
                    configurable: false
                });
            } catch(_) {}
        })();
        """
        webView.evaluateJavaScript(apiLockdownScript, in: nil, in: world) { [weak self] lockRes in
            guard let self else { return }
            if case .failure(let e) = lockRes {
                // Lock failure is logged but does not abort engine loading
                // (some environments may restrict Object.defineProperty)
                AppLogger.security("API lockdown script injection failed", context: ["error": e.localizedDescription])
            }
            // Step 2: After lockdown, inject ruleEngine.js
            webView.evaluateJavaScript(scriptToInject, in: nil, in: world) { [weak self] injectRes in
                switch injectRes {
                case .failure(let e):
                    let nsErr = e as NSError
                    var errData: [String: Any] = ["err": e.localizedDescription]
                    if let msg = nsErr.userInfo["WKJavaScriptExceptionMessage"] as? String { errData["jsMsg"] = msg }
                    if let line = nsErr.userInfo["WKJavaScriptExceptionLineNumber"] as? Int { errData["line"] = line }
                    if let col = nsErr.userInfo["WKJavaScriptExceptionColumnNumber"] as? Int { errData["col"] = col }
                    errData["domain"] = nsErr.domain
                    errData["code"] = nsErr.code
                    _dbgLog(location: "JSRuleEngineRunner.swift:didFinish:inject", message: "script inject failed", data: errData, hypothesisId: "H8")
                    self?.loadContinuation?.resume(throwing: NSError(domain: "JSRuleEngineRunner", code: -10, userInfo: [NSLocalizedDescriptionKey: "BookSourceEngine injection failed: \(e.localizedDescription)"]))
                    self?.loadContinuation = nil
                    return
                case .success:
                    break
                }
                // Step 3: Verify BookSourceEngine readiness
                webView.evaluateJavaScript("typeof window.BookSourceEngine", in: nil, in: world) { [weak self] res in
                    let typeStr: String
                    let errStr: String
                    switch res {
                    case .success(let v): typeStr = (v as? String) ?? "nil"; errStr = ""
                    case .failure(let e): typeStr = "nil"; errStr = e.localizedDescription
                    }
                    _dbgLog(location: "JSRuleEngineRunner.swift:didFinish:verify", message: "BookSourceEngine check", data: ["typeof": typeStr, "err": errStr], hypothesisId: "H2")
                    let ok = (typeStr == "object" || typeStr == "function")
                    _dbgLog(location: "JSRuleEngineRunner.swift:didFinish:resume", message: "resume decision", data: ["ok": ok, "typeof": typeStr], hypothesisId: "H4")
                    if ok {
                        self?.loadContinuation?.resume()
                    } else {
                        self?.loadContinuation?.resume(throwing: NSError(domain: "JSRuleEngineRunner", code: -10, userInfo: [NSLocalizedDescriptionKey: "BookSourceEngine not ready typeof=\(typeStr) err=\(errStr)"]))
                    }
                    self?.loadContinuation = nil
                }
            }
        }
        // #endregion
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadContinuation?.resume(throwing: error)
        loadContinuation = nil
        for w in loadWaiters { w.resume(throwing: error) }
        loadWaiters.removeAll()
    }
}
