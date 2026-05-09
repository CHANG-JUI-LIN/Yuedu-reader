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

// MARK: - JS 安全驗證器
// 在執行來自書源（用戶導入的不可信來源）的 JavaScript 之前，進行黑名單過濾。
// 注意：這是縱深防禦，不是萬無一失的沙盒；主要防止明顯的惡意操作。

private enum JSSecurityValidator {
    struct ValidationError: Error {
        let reason: String
        var localizedDescription: String { reason }
    }

    /// 高危模式：出現即拒絕執行
    private static let blockedPatterns: [String] = [
        "document\\.cookie",          // 讀取 cookie
        "localStorage",               // 存取本地存儲
        "sessionStorage",             // 存取 session 存儲
        "indexedDB",                  // 存取 IndexedDB
        "XMLHttpRequest",             // 發起 XHR（應由 WebFetcher 管控）
        "fetch\\s*\\(",               // Fetch API
        "window\\.location\\s*=",     // 重定向頁面
        "document\\.write\\s*\\(",    // 動態寫入文檔
        "eval\\s*\\(",                // 動態執行（ruleEngine.js 內部已有沙盒）
        "Function\\s*\\(",            // 動態函數構造
        "webkit\\.messageHandlers",   // 直接呼叫 iOS bridge
    ]

    /// 驗證 JS 字串是否符合安全標準
    /// - Returns: `.success(js)` 通過，`.failure(reason)` 拒絕並附原因
    static func validate(_ js: String) -> Result<String, ValidationError> {
        for pattern in blockedPatterns {
            if js.range(of: pattern, options: .regularExpression) != nil {
                AppLogger.security(
                    "書源 JS 包含高危模式，已阻止執行",
                    context: ["pattern": pattern, "jsPreview": String(js.prefix(120))]
                )
                return .failure(ValidationError(reason: "書源 JavaScript 包含不允許的操作：\(pattern)"))
            }
        }
        return .success(js)
    }
}

// MARK: - JS 書源引擎橋接（可選）
// 書源解析改由 Assets/bookSourceEngine/ruleEngine.js 執行，Web 與 iOS 共用同一套邏輯。
// 啟用方式：在 BookSourceFetcher 中改為呼叫 JSRuleEngineRunner.shared.parseSearchResults(...) 等。

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
    /// 快取 ruleEngine.js 內容，用於 didFinish 時以 evaluateJavaScript 注入（繞過 about:blank 時 WKUserScript 不執行的 iOS bug）
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
        // 先試 bundle 根目錄（Xcode 編譯後 ruleEngine.js 在根目錄），再試 bookSourceEngine 子目錄
        let url = Bundle.main.url(forResource: "ruleEngine", withExtension: "js", subdirectory: nil)
            ?? Bundle.main.url(forResource: "ruleEngine", withExtension: "js", subdirectory: "bookSourceEngine")
        guard let url = url,
              let scriptContent = try? String(contentsOf: url, encoding: .utf8)
        else {
            throw NSError(domain: "JSRuleEngineRunner", code: -1, userInfo: [NSLocalizedDescriptionKey: "找不到 ruleEngine.js"])
        }
        cachedScriptContent = scriptContent
        // 不在 WKUserScript 注入 ruleEngine：iOS 對 about:blank 首次載入時 WKUserScript 不執行（已知 bug）
        // 改在 didFinish 中以 evaluateJavaScript 直接注入
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

    /// 將字串轉成可嵌入 JS 的 JSON 字串（含外層引號），避免 Data?.flatMap 與 Data.flatMap 歧義
    private func jsonEncodeString(_ s: String) -> String {
        guard let data = try? JSONEncoder().encode(s),
              let str = String(data: data, encoding: .utf8) else { return "\"\"" }
        return str
    }

    private func evaluateJSONString(on webView: WKWebView, js: String, timeout: TimeInterval = AppConfig.jsRuleEngineExecutionTimeout) async throws -> String {
        // 安全驗證：拒絕來自書源的高危 JS 模式
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
                                cont.resume(throwing: NSError(domain: "JSRuleEngineRunner", code: -4, userInfo: [NSLocalizedDescriptionKey: "結果序列化失敗"]))
                                return
                            }
                            cont.resume(returning: str)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw NSError(domain: "JSRuleEngineRunner", code: -9, userInfo: [NSLocalizedDescriptionKey: "JS 執行超時"])
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    private func evaluateString(on webView: WKWebView, js: String, timeout: TimeInterval = 5) async throws -> String {
        // 安全驗證：拒絕來自書源的高危 JS 模式
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
                throw NSError(domain: "JSRuleEngineRunner", code: -9, userInfo: [NSLocalizedDescriptionKey: "JS 執行超時"])
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
        guard let wv = webView else { throw NSError(domain: "JSRuleEngineRunner", code: -2, userInfo: [NSLocalizedDescriptionKey: "WebView 未就緒"]) }
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
        else { throw NSError(domain: "JSRuleEngineRunner", code: -3, userInfo: [NSLocalizedDescriptionKey: "規則序列化失敗"]) }
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
                title: c.title,
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

    /// 使用 ruleEngine.js 的 routeExtractValue 提取單一欄位（用於 nextTocUrl / nextContentUrl）
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
            loadContinuation?.resume(throwing: NSError(domain: "JSRuleEngineRunner", code: -10, userInfo: [NSLocalizedDescriptionKey: "BookSourceEngine 未就緒：無快取腳本"]))
            loadContinuation = nil
            return
        }
        // 以 evaluateJavaScript 注入 ruleEngine（使用 defaultClient 避免 .page 對 about:blank 的限制）
        // 注意：WKUserScript 在 about:blank 首次載入時不執行（已知 iOS bug），
        // 因此改在 didFinish 中序列執行：先鎖定危險 API，再注入 ruleEngine.js。
        let world = WKContentWorld.defaultClient

        // Step 1：注入 API 安全鎖定腳本，防止書源腳本存取網路或本地存儲
        // 不阻止 eval/Function（ruleEngine.js 可能自身使用），但封閉所有資料滲漏管道
        let apiLockdownScript = """
        (function() {
            'use strict';
            const deny = { get: () => null, set: () => {}, configurable: false };
            // 封鎖網路 API：書源腳本不應自行發起任何網路請求
            try { Object.defineProperty(window, 'fetch', deny); } catch(_) {}
            try { Object.defineProperty(window, 'XMLHttpRequest', deny); } catch(_) {}
            try { Object.defineProperty(window, 'WebSocket', deny); } catch(_) {}
            try { Object.defineProperty(window, 'EventSource', deny); } catch(_) {}
            // 封鎖持久存儲
            try { Object.defineProperty(window, 'localStorage', deny); } catch(_) {}
            try { Object.defineProperty(window, 'sessionStorage', deny); } catch(_) {}
            try { Object.defineProperty(window, 'indexedDB', deny); } catch(_) {}
            try { Object.defineProperty(window, 'caches', deny); } catch(_) {}
            // 封鎖 Beacon 與定位
            try { Object.defineProperty(navigator, 'sendBeacon', deny); } catch(_) {}
            try { Object.defineProperty(navigator, 'geolocation', deny); } catch(_) {}
            // Cookie 清空（讀取恆為空、寫入無效）
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
                // 鎖定失敗記錄警告，但不中止引擎載入（部分環境可能已限制 Object.defineProperty）
                AppLogger.security("API 鎖定腳本注入失敗", context: ["error": e.localizedDescription])
            }
            // Step 2：鎖定完成後再注入 ruleEngine.js
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
                    self?.loadContinuation?.resume(throwing: NSError(domain: "JSRuleEngineRunner", code: -10, userInfo: [NSLocalizedDescriptionKey: "BookSourceEngine 注入失敗: \(e.localizedDescription)"]))
                    self?.loadContinuation = nil
                    return
                case .success:
                    break
                }
                // Step 3：驗證 BookSourceEngine 是否就緒
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
                        self?.loadContinuation?.resume(throwing: NSError(domain: "JSRuleEngineRunner", code: -10, userInfo: [NSLocalizedDescriptionKey: "BookSourceEngine 未就緒 typeof=\(typeStr) err=\(errStr)"]))
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
