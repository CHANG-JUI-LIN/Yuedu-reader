import Foundation
import JavaScriptCore
import CryptoKit
import CommonCrypto
import UIKit

// MARK: - JSExport Protocol

/// Protocol for Legado's `java.*` bridge functions.
/// Conforms to JSExport so methods are callable from JavaScript.
@objc protocol LegadoJSBridgeExport: JSExport {
    // Networking
    func ajax(_ urlStr: String) -> String
    func axja(_ urlStr: String) -> String
    func ajaxAll(_ urlArray: [String]) -> [LegadoStrResponse]
    func connect(_ urlStr: String) -> String
    func post(_ urlStr: String, _ body: String, _ headers: JSValue) -> LegadoStrResponse
    func importScript(_ url: String) -> String

    // Headless WebView (Legado java.webView(html, url, js) — runs js after load, returns result)
    func webView(_ html: JSValue, _ url: JSValue, _ js: JSValue) -> String

    // Cookie helpers (used by sources like 光遇)
    func getCookie(_ url: String) -> String
    func getCookie(_ url: String, _ key: String) -> String
    func getCookieValue(_ url: String, _ key: String) -> String
    func removeCookie(_ url: String)
    func getWebViewUA() -> String

    // Variable storage
    func put(_ key: String, _ value: String)
    func get(_ key: String) -> String

    // Rule evaluation (placeholder — connected to ModernRuleEngine later)
    func getString(_ ruleStr: String) -> String
    func getStringList(_ ruleStr: String) -> [String]
    func setContent(_ content: JSValue, _ baseUrl: JSValue) -> String
    func getElements(_ ruleStr: String) -> [Any]

    // Browser WebView (Legado startBrowser / startBrowserAwait)
    func startBrowser(_ url: String, _ title: String)
    func startBrowserAwait(_ url: String, _ title: String) -> LegadoStrResponse
    func startBrowserAwait(_ url: String, _ title: String, _ refetchAfterSuccess: Bool) -> LegadoStrResponse

    // Toast notifications
    func toast(_ msg: String)
    func longToast(_ msg: String)

    // Logging
    func log(_ msg: String) -> String
    func logType(_ msg: String)

    // Response processing (TTS)
    func setResponseBase64(_ data: String, _ mimeType: String)

    // Time utilities
    func timeFormat(_ timestamp: JSValue) -> String
    func timeFormatUTC(_ time: Double, _ format: String, _ sh: Int) -> String

    // Encoding / Decoding
    func base64Decode(_ str: String) -> String
    func base64Encode(_ str: String) -> String
    func md5Encode(_ str: String) -> String
    func md5Encode16(_ str: String) -> String
    func hexDecodeToString(_ hex: String) -> String
    func hexEncodeToString(_ str: String) -> String
    // Symmetric crypto (low-level helpers used by the javax.crypto JS shim).
    // All args/returns are lowercase hex; empty string means failure.
    func aesDecryptHex(_ transformation: String, _ keyHex: String, _ ivHex: String, _ dataHex: String) -> String
    func aesEncryptHex(_ transformation: String, _ keyHex: String, _ ivHex: String, _ dataHex: String) -> String
    func encodeURI(_ str: String) -> String
    func encodeURIComponent(_ str: String) -> String
    func htmlFormat(_ str: String) -> String

    // Chinese character conversion
    func t2s(_ text: String) -> String
    func s2t(_ text: String) -> String

    // UI actions used by complex Legado sources. Most are safe no-ops in parser-only flows.
    func refreshExplore()
    func reLoginView()
    func refreshBookInfo()
    func refreshBookToc()
    func refreshContent()
    func showBrowser(_ url: String, _ title: String)
    func showReadingBrowser(_ url: String, _ title: String)
    func startBrowserDp(_ url: String, _ title: String)
    func copyText(_ text: String)
    func deviceID() -> String
    func androidId() -> String
    func openVideoPlayer(_ url: String, _ title: String)
    func upLoginData(_ data: JSValue)
    // `java.qread()` is a no-op stub ON PURPOSE: it makes 起点-family content JS set
    // `dev='android-轻阅读'`, so createSvg emits the 轻阅读 段评 SVG variant — the one the user wants
    // on iOS. (Removing it → `dev='ios'` → the ios variant, which the user rejected.) Don't remove it.
    func qread()
}

// MARK: - Cookie Bridge

/// Legado's `cookie` object — accessible from JS as `cookie.get(url)`, `cookie.set(url, val)`, `cookie.remove(url)`.
@objc protocol LegadoCookieBridgeExport: JSExport {
    func get(_ url: String) -> String
    func getCookie(_ url: String) -> String
    func getKey(_ url: String, _ key: String) -> String
    func set(_ url: String, _ cookie: String)
    func setCookie(_ url: String, _ cookie: String)
    func remove(_ url: String)
    func removeCookie(_ url: String)
}

@objc class LegadoCookieBridge: NSObject, LegadoCookieBridgeExport {

    func get(_ url: String) -> String {
        CookieStore.shared.get(url: url)
    }

    /// Legado `cookie.getKey(tag, key)` — value of a single cookie for a domain/URL.
    func getKey(_ url: String, _ key: String) -> String {
        CookieStore.shared.getKey(url: url, key: key)
    }

    func getCookie(_ url: String) -> String {
        CookieStore.shared.get(url: url)
    }

    func set(_ url: String, _ cookie: String) {
        CookieStore.shared.set(url: url, cookie: cookie)
    }

    func setCookie(_ url: String, _ cookie: String) {
        CookieStore.shared.set(url: url, cookie: cookie)
    }

    func remove(_ url: String) {
        CookieStore.shared.remove(url: url)
    }

    func removeCookie(_ url: String) {
        CookieStore.shared.remove(url: url)
    }
}

// MARK: - Bridge Implementation

/// Concrete implementation of the `java` bridge object injected into JSContext.
@objc class LegadoJSBridge: NSObject, LegadoJSBridgeExport {

    /// Delegate for variable storage (wired to RuleDataInterface).
    var getData: ((String) -> String?)?
    var putData: ((String, String) -> Void)?

    /// Delegate for network requests.
    var networkHandler: ((URLRequest) -> String?)?

    /// Called when JS invokes `java.startBrowser(url, title)` or `java.startBrowserAwait(url, title, ...)`.
    /// Receives (url, title, completion). Completion receives the page body (nil if no body captured).
    /// For `startBrowserAwait` the bridge blocks jsQueue via DispatchSemaphore until completion is called.
    var browserPresentHandler: ((String, String, @escaping (String?) -> Void) -> Void)?

    /// Called when JS invokes `java.toast(msg)` / `java.longToast(msg)`.
    var toastHandler: ((String) -> Void)?

    /// Called when JS invokes `java.reLoginView()` — the source asks the host to re-render its
    /// custom login menu (e.g. after `changeMenu(tag)` switches `menuTag`). Lets multi-page
    /// source menus (起点's 评论设置/气泡模版 submenus) navigate instead of staying on page 1.
    var reLoginViewHandler: (() -> Void)?

    /// Called when JS invokes `java.upLoginData(map)` — persist a map of setting key/values into
    /// the source's login data (read back via `source.getLoginInfoMap()`).
    var upLoginDataHandler: ((JSValue) -> Void)?

    /// Delegate for rule evaluation (connected later).
    var getStringHandler: ((String) -> String?)?
    var getStringListHandler: ((String) -> [String]?)?
    var setContentHandler: ((Any?, String?) -> Void)?
    var getElementsHandler: ((String) -> [Any]?)?
    var getStringWithContentHandler: ((String, Any?) -> String?)?

    /// Called when JS invokes `java.setResponseBase64(data, mimeType)` — stores decoded audio data.
    /// Used by TTS `loginCheckJs` to extract base64 audio from JSON API responses.
    var setResponseBase64Handler: ((Data, String) -> Void)?

    /// Called when JS issues a network request that hits a Cloudflare challenge.
    /// Calls `done()` after CF cookies are obtained; jsQueue blocks via DispatchSemaphore until then.
    var cloudflareChallengeHandler: ((URL, @escaping () -> Void) -> Void)?

    /// Book source headers (for JS network requests to use correct User-Agent etc.)
    var sourceHeaders: [String: String] = [:]

    /// Timeout for `java.ajax`/`java.connect` requests. Legado sources carry `respondTime`
    /// in milliseconds; JSCoreEngine clamps it before assigning here.
    var requestTimeoutSeconds: TimeInterval = 8

    /// AnalyzeUrl-based request handler. When set, `java.ajax()` routes URLs containing `,{json}`
    /// through AnalyzeUrl rather than treating the entire string as a simple URL.
    var analyzeUrlHandler: ((String) -> String?)?

    // MARK: - JS network attribution
    //
    // Wall-time the JS thread spent blocked on `java.*` network during the current parse.
    // 段評 sources fetch per-paragraph review counts from inside the content rule JS, so that
    // network lands inside `chapter.parse` and is invisible to `chapter.network`. Accumulate it
    // here (ajaxAll adds its BATCH wall time — it runs 6-wide, so summing items would over-count)
    // and let ModernParserBridge emit `⏱ chapter.jsNet` to split a slow parse into network vs CPU.
    private let networkMsLock = NSLock()
    private var accumulatedNetworkMs: Double = 0
    func resetNetworkMs() { networkMsLock.lock(); accumulatedNetworkMs = 0; networkMsLock.unlock() }
    func takeNetworkMs() -> Double { networkMsLock.lock(); defer { networkMsLock.unlock() }; return accumulatedNetworkMs }
    private func recordBlockingNetwork(_ ms: Double) {
        networkMsLock.lock(); accumulatedNetworkMs += ms; networkMsLock.unlock()
    }

    // MARK: - Dedicated java.* session
    //
    // iOS caps `URLSession.shared` at 6 connections per host. 段評 sources fan out ONE
    // review-count request PER PARAGRAPH (50–150) to a single host, so that cap — doubled by
    // the old `ajaxAll` throttle of 6 — serialized them into multi-second batches (measured
    // `⏱ chapter.jsNet` ≈ 1.7–6.2s, ≈ the whole chapter.parse). Legado runs these at its user
    // "线程数" (threadCount, default 16) over an OkHttp pool, which is why the SAME 段評 chapter
    // opens ~3× faster there. Match Legado's default 16 per host; the user confirmed Legado's 16
    // doesn't trip these 段評 servers, so 16 is a validated (not speculative) concurrency.
    //
    // NOT private: the online reader routes java.* network through ModernParserBridge's
    // `networkHandler` / `analyzeUrlHandler` (those are always set), so those two handlers must
    // use THIS pool too — otherwise they fall back to URLSession.shared's 6/host and the 16-wide
    // ajaxAll just queues behind 6 connections (the reason raising the throttle alone did nothing).
    static let requestSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    // MARK: Networking

    func ajax(_ urlStr: String) -> String {
        let started = Date()
        let body = performRequest(urlStr)
        recordBlockingNetwork(Date().timeIntervalSince(started) * 1000)
        // ⟐ ajax — reveal WHY 起点 content comes back empty: log the response of the
        // auth/content/review API calls (get_my_token / content.php / review.php …).
        if Self.shouldLogReviewNetwork(urlStr) {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            AppLogger.parse("⟐ ajax", context: [
                "kind": Self.reviewNetworkKind(urlStr),
                "path": Self.requestPathPreview(urlStr),
                "query": Self.redactedQueryPreview(urlStr),
                "ms": ms,
                "len": body.count,
                "json": Self.responseShape(body),
                "head": String(body.prefix(160))
            ])
        }
        return body
    }

    func axja(_ urlStr: String) -> String {
        let body = performRequest(urlStr)
        return Self.aaDecode(body)
    }

    /// Decode aaencode (源阅 obfuscation) — maps Unicode-encoded characters
    /// back to their ASCII equivalents. Mirrors Legado's `StringUtils.aaDecode`.
    static func aaDecode(_ str: String) -> String {
        guard !str.isEmpty else { return str }
        let pairs: [(UnicodeScalar, String)] = [
            ("\u{203F}", "_"), ("\u{2040}", " "),
            ("\u{00A1}", "!"), ("\u{00A6}", "|"),
            ("\u{15AD}", "("), ("\u{15AE}", ")"),
            ("\u{20A9}", "\\"), ("\u{4DC0}", "||"),
            ("\u{20B4}", "$"), ("\u{0C8C}", "="),
            ("\u{0C98}", ">"), ("\u{0C95}", "<"),
            ("\u{14A6}", "}"), ("\u{14A5}", "{"),
            ("\u{0E50}", "0"), ("\u{0E51}", "1"),
            ("\u{0E52}", "2"), ("\u{0E53}", "3"),
            ("\u{0E54}", "4"), ("\u{0E55}", "5"),
            ("\u{0E56}", "6"), ("\u{0E57}", "7"),
            ("\u{0E58}", "8"), ("\u{0E59}", "9"),
            ("\u{2010}", "-"), ("\u{2011}", "-"),
            ("\u{2012}", "-"), ("\u{2013}", "-"),
            ("\u{2014}", "--"), ("\u{2015}", "--"),
            ("\u{2215}", "/"), ("\u{FF0F}", "/"),
            ("\u{FF3A}", "Z"), ("\u{FF3A}", "z"),
            ("\u{FF21}", "A"), ("\u{FF41}", "a"),
            ("\u{FF22}", "B"), ("\u{FF42}", "b"),
            ("\u{FF23}", "C"), ("\u{FF43}", "c"),
            ("\u{FF24}", "D"), ("\u{FF44}", "d"),
            ("\u{FF25}", "E"), ("\u{FF45}", "e"),
            ("\u{FF26}", "F"), ("\u{FF46}", "f"),
            ("\u{FF27}", "G"), ("\u{FF47}", "g"),
            ("\u{FF28}", "H"), ("\u{FF48}", "h"),
            ("\u{FF29}", "I"), ("\u{FF49}", "i"),
            ("\u{FF2A}", "J"), ("\u{FF4A}", "j"),
            ("\u{FF2B}", "K"), ("\u{FF4B}", "k"),
            ("\u{FF2C}", "L"), ("\u{FF4C}", "l"),
            ("\u{FF2D}", "M"), ("\u{FF4D}", "m"),
            ("\u{FF2E}", "N"), ("\u{FF4E}", "n"),
            ("\u{FF2F}", "O"), ("\u{FF4F}", "o"),
            ("\u{FF30}", "P"), ("\u{FF50}", "p"),
            ("\u{FF31}", "Q"), ("\u{FF51}", "q"),
            ("\u{FF32}", "R"), ("\u{FF52}", "r"),
            ("\u{FF33}", "S"), ("\u{FF53}", "s"),
            ("\u{FF34}", "T"), ("\u{FF54}", "t"),
            ("\u{FF35}", "U"), ("\u{FF55}", "u"),
            ("\u{FF36}", "V"), ("\u{FF56}", "v"),
            ("\u{FF37}", "W"), ("\u{FF57}", "w"),
            ("\u{FF38}", "X"), ("\u{FF58}", "x"),
            ("\u{FF39}", "Y"), ("\u{FF59}", "y"),
            ("\u{FF10}", "0"), ("\u{FF11}", "1"),
            ("\u{FF12}", "2"), ("\u{FF13}", "3"),
            ("\u{FF14}", "4"), ("\u{FF15}", "5"),
            ("\u{FF16}", "6"), ("\u{FF17}", "7"),
            ("\u{FF18}", "8"), ("\u{FF19}", "9"),
            ("\u{02C8}", "'"),
        ]
        var result = str
        for (scalar, replacement) in pairs {
            result = result.replacingOccurrences(
                of: String(scalar),
                with: replacement
            )
        }
        return result
    }

    func ajaxAll(_ urlArray: [String]) -> [LegadoStrResponse] {
        guard !urlArray.isEmpty else { return [] }
        // Legado's `java.ajaxAll` returns `StrResponse[]`; sources ALWAYS call `.body()` on
        // each element (起点 段评: `cmtData[0].body()`; 番茄 bookshelf: `r.body()`). Returning
        // plain `[String]` made `.body()` throw → callers' try/catch swallowed it → e.g. 段评
        // bubbles silently never injected (review.php fetched fine, just unused). Wrap each
        // body in LegadoStrResponse so `.body()` works.
        let throttle = DispatchSemaphore(value: 16) // match Legado threadCount (16); paired with requestSession httpMaximumConnectionsPerHost=16
        var results = Array(repeating: "", count: urlArray.count)
        let resultsLock = NSLock()
        let group = DispatchGroup()

        // ⟐ ajaxAll — 段评 review.php is fetched here; log entry/exit + elapsed so a hang
        // (the suspected 段评-on infinite-loading) is visible on device.
        let _start = Date()
        let firstHost = URL(string: urlArray[0].components(separatedBy: ",").first ?? "")?.host ?? "?"
        AppLogger.parse("⟐ ajaxAll start", context: [
            "count": urlArray.count,
            "host": firstHost,
            "sample": urlArray.prefix(6).map { Self.requestPathPreview($0) }
        ])

        for (index, urlStr) in urlArray.enumerated() {
            throttle.wait() // block until a concurrency slot is free
            group.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let itemStart = Date()
                let body = self?.performRequest(urlStr) ?? ""
                let itemMs = Int(Date().timeIntervalSince(itemStart) * 1000)
                resultsLock.lock()
                results[index] = body
                resultsLock.unlock()
                if index < 16 || Self.shouldLogReviewNetwork(urlStr) {
                    AppLogger.parse("⟐ ajaxAll item", context: [
                        "i": index,
                        "kind": Self.reviewNetworkKind(urlStr),
                        "path": Self.requestPathPreview(urlStr),
                        "query": Self.redactedQueryPreview(urlStr),
                        "ms": itemMs,
                        "len": body.count,
                        "json": Self.responseShape(body),
                        "head": String(body.prefix(120))
                    ])
                }
                throttle.signal()
                group.leave()
            }
        }

        // Bounded wait: each performRequest is already capped at ~8s, so the whole batch
        // must finish well within 30s. Never block the JS thread forever.
        let waited = group.wait(timeout: .now() + 30)
        let _ms = Int(Date().timeIntervalSince(_start) * 1000)
        // Batch wall time = how long the JS thread was actually blocked (requests ran up to
        // 16-wide over requestSession's 16 connections/host — matches Legado threadCount).
        recordBlockingNetwork(Date().timeIntervalSince(_start) * 1000)
        AppLogger.parse("⟐ ajaxAll done", context: [
            "ms": _ms,
            "timedOut": waited == .timedOut,
            "empty": results.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count,
            "lens": results.map { $0.count }
        ])
        // Wrap into StrResponse objects so JS `.body()` works (Legado contract).
        return zip(urlArray, results).map { url, body in
            LegadoStrResponse(url: url.components(separatedBy: ",{").first ?? url, body: body)
        }
    }

    private static func shouldLogReviewNetwork(_ urlStr: String) -> Bool {
        let lower = urlStr.lowercased()
        return lower.contains("content.php")
            || lower.contains("api_user")
            || lower.contains("review.php")
            || lower.contains("chaxun")
            || lower.contains("/qdapi/")
            || lower.contains("list.php")
            || lower.contains("comment")
            || lower.contains("cmt")
    }

    private static func reviewNetworkKind(_ urlStr: String) -> String {
        let lower = urlStr.lowercased()
        if lower.contains("content.php") { return "content" }
        if lower.contains("api_user") { return "auth" }
        if lower.contains("review.php") || lower.contains("comment") || lower.contains("cmt") {
            return "review"
        }
        if lower.contains("list.php") { return "list" }
        return "other"
    }

    private static func requestPathPreview(_ urlStr: String) -> String {
        let rawURL = urlStr.components(separatedBy: ",{").first ?? urlStr
        guard let components = URLComponents(string: rawURL) else {
            return String(rawURL.prefix(96))
        }
        let host = components.host ?? ""
        let path = components.path.isEmpty ? "/" : components.path
        return String((host + path).suffix(96))
    }

    private static func redactedQueryPreview(_ urlStr: String) -> String {
        let rawURL = urlStr.components(separatedBy: ",{").first ?? urlStr
        guard let components = URLComponents(string: rawURL),
              let items = components.queryItems,
              !items.isEmpty else { return "" }
        let preview = items.prefix(8).map { item -> String in
            let lower = item.name.lowercased()
            if lower.contains("token") || lower.contains("cookie") || lower.contains("password") {
                return "\(item.name)=<redacted:\((item.value ?? "").isEmpty ? "empty" : "set")>"
            }
            return "\(item.name)=\(item.value ?? "")"
        }.joined(separator: "&")
        return String(preview.prefix(180))
    }

    private static func responseShape(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }
        let lower = trimmed.lowercased()
        var flags: [String] = []
        if trimmed.hasPrefix("{") { flags.append("jsonObject") }
        if trimmed.hasPrefix("[") { flags.append("jsonArray") }
        if lower.contains(#""success":false"#) { flags.append("success=false") }
        if lower.contains(#""success":true"#) { flags.append("success=true") }
        if lower.contains(#""message""#) { flags.append("message") }
        if lower.contains(#""content""#) { flags.append("content") }
        if lower.contains(#""count""#) { flags.append("count") }
        if lower.contains("token") { flags.append("token") }
        if lower.contains("请先登录") || lower.contains("\\u8bf7\\u5148\\u767b\\u5f55") {
            flags.append("login-required")
        }
        return flags.isEmpty ? "text" : flags.joined(separator: "|")
    }

    func connect(_ urlStr: String) -> String {
        let started = Date()
        let body = performRequest(urlStr)
        recordBlockingNetwork(Date().timeIntervalSince(started) * 1000)
        return body
    }

    /// Legado `java.post(url, body, headers)` — HTTP POST returning a `StrResponse` (`.body()`).
    /// `body` is sent verbatim; `headers` is a JS object. Defaults to
    /// `application/x-www-form-urlencoded` when no Content-Type is supplied.
    func post(_ urlStr: String, _ body: String, _ headers: JSValue) -> LegadoStrResponse {
        let started = Date()
        let response = performPost(urlStr, body: body, headers: Self.headerDict(from: headers))
        recordBlockingNetwork(Date().timeIntervalSince(started) * 1000)
        return response
    }

    /// Legado `java.importScript(url)` — fetch a remote JS library and return its text.
    /// Sources typically wrap this in `eval(...)` to load shared helpers at runtime.
    func importScript(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http") else { return trimmed }
        return performRequest(trimmed)
    }

    // MARK: Cookie Helpers

    func getCookie(_ url: String) -> String {
        return CookieStore.shared.get(url: url)
    }

    func getCookie(_ url: String, _ key: String) -> String {
        getCookieValue(url, key)
    }

    func getCookieValue(_ url: String, _ key: String) -> String {
        let cookie = CookieStore.shared.get(url: url)
        guard !key.isEmpty else { return cookie }
        return cookie
            .split(separator: ";")
            .compactMap { part -> String? in
                let pieces = part.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard pieces.count == 2, pieces[0] == key else { return nil }
                return pieces[1]
            }
            .first ?? ""
    }

    /// Legado `java.removeCookie(url)` — clears cookies for the host of `url`.
    /// (The `cookie.removeCookie` bridge has the same effect; some sources call it via `java`.)
    func removeCookie(_ url: String) {
        CookieStore.shared.remove(url: url)
    }

    func getWebViewUA() -> String {
        return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
    }

    // MARK: Variable Storage

    func put(_ key: String, _ value: String) {
        putData?(key, value)
    }

    func get(_ key: String) -> String {
        return getData?(key) ?? ""
    }

    // MARK: Rule Evaluation (placeholder)

    /// Content stored by `java.setContent(...)` for chained rule evaluation.
    private var storedContent: Any?
    private var storedBaseUrl: String?

    func getString(_ ruleStr: String) -> String {
        return _evaluateString(ruleStr)
    }

    func getStringList(_ ruleStr: String) -> [String] {
        return getStringListHandler?(ruleStr) ?? []
    }

    @discardableResult
    func setContent(_ content: JSValue, _ baseUrl: JSValue) -> String {
        if content.isString {
            storedContent = content.toString()
        } else if content.isObject {
            storedContent = content.toObject()
        } else {
            storedContent = content.toString() ?? ""
        }
        storedBaseUrl = baseUrl.isString ? baseUrl.toString() : ""
        // Update engine content and set result for subsequent JS code
        setContentHandler?(storedContent, storedBaseUrl)
        return "" // Legado returns "" after setContent
    }

    func getElements(_ ruleStr: String) -> [Any] {
        return getElementsHandler?(ruleStr) ?? []
    }

    private func _evaluateString(_ ruleStr: String) -> String {
        if let content = storedContent {
            return getStringWithContentHandler?(ruleStr, content) ?? ""
        }
        return getStringHandler?(ruleStr) ?? ""
    }

    // MARK: Browser & Toast (Legado java.startBrowser / startBrowserAwait / toast)

    /// Opens a browser WebView without blocking JS execution.
    func startBrowser(_ url: String, _ title: String) {
        browserPresentHandler?(url, title) { _ in /* fire and forget */ }
    }

    /// Opens a browser WebView and blocks the JS thread (jsQueue) until the user closes it.
    /// Returns a `LegadoStrResponse` with `.body()` and `.url` for JS consumption.
    /// Mirrors Legado's `java.startBrowserAwait(url, title): StrResponse`.
    func startBrowserAwait(_ url: String, _ title: String) -> LegadoStrResponse {
        return startBrowserAwait(url, title, false)
    }

    /// Opens a browser WebView and blocks the JS thread, with optional refetch-after-success.
    func startBrowserAwait(_ url: String, _ title: String, _ refetchAfterSuccess: Bool) -> LegadoStrResponse {
        guard let handler = browserPresentHandler else {
            return LegadoStrResponse(url: url, body: "")
        }
        let sem = DispatchSemaphore(value: 0)
        var capturedBody: String?
        handler(url, title) { body in
            capturedBody = body
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 60)
        return LegadoStrResponse(url: url, body: capturedBody ?? "")
    }

    /// Show a short toast. Delegates to `toastHandler` on MainThread.
    func toast(_ msg: String) {
        #if DEBUG
        print("[JSBridge toast] \(msg)")
        #endif
        DispatchQueue.main.async { [weak self] in self?.toastHandler?(msg) }
    }

    func longToast(_ msg: String) { toast(msg) }

    // MARK: Logging

    @discardableResult
    func log(_ msg: String) -> String {
        #if DEBUG
        print("[JSBridge] \(msg)")
        #endif
        return msg
    }

    func logType(_ msg: String) {
        #if DEBUG
        print("[JSBridge logType] \(type(of: msg)): \(msg)")
        #endif
    }

    func setResponseBase64(_ data: String, _ mimeType: String) {
        guard let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters) else {
            log("setResponseBase64: invalid base64 data (\(data.count) chars)")
            return
        }
        setResponseBase64Handler?(decoded, mimeType)
    }

    // MARK: Utilities

    func timeFormat(_ timestamp: JSValue) -> String {
        let ms: Double
        if timestamp.isNumber {
            ms = timestamp.toDouble()
        } else if let str = timestamp.toString(), let parsed = Double(str) {
            ms = parsed
        } else {
            return ""
        }
        let date = Date(timeIntervalSince1970: ms / 1000.0)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter.string(from: date)
    }

    func base64Decode(_ str: String) -> String {
        guard let data = Data(base64Encoded: str, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8) else {
            return ""
        }
        return decoded
    }

    func base64Encode(_ str: String) -> String {
        guard let data = str.data(using: .utf8) else { return "" }
        return data.base64EncodedString()
    }

    func md5Encode(_ str: String) -> String {
        guard let data = str.data(using: .utf8) else { return "" }
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    func md5Encode16(_ str: String) -> String {
        let full = md5Encode(str)
        guard full.count == 32 else { return full }
        let start = full.index(full.startIndex, offsetBy: 8)
        let end = full.index(start, offsetBy: 16)
        return String(full[start..<end])
    }

    // MARK: - Hex Encoding

    /// Decode a hex string to a UTF-8 string. Example: `"48656c6c6f"` → `"Hello"`.
    func hexDecodeToString(_ hex: String) -> String {
        let cleaned = hex.replacingOccurrences(of: " ", with: "")
        guard cleaned.count % 2 == 0 else { return "" }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let byte = UInt8(cleaned[idx..<next], radix: 16) else { return "" }
            bytes.append(byte)
            idx = next
        }
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// Encode a string to lowercase hex. Example: `"Hello"` → `"48656c6c6f"`.
    func hexEncodeToString(_ str: String) -> String {
        str.data(using: .utf8)?.map { String(format: "%02x", $0) }.joined() ?? ""
    }

    // MARK: - Symmetric Crypto

    /// AES decrypt. Inputs/output are lowercase hex; `""` on failure.
    /// `transformation` is a Java-style spec like `AES/CBC/PKCS5Padding`.
    /// Backs the `javax.crypto.Cipher` JS shim so Legado sources that decrypt
    /// chapter content via raw Java crypto (e.g. 七猫-明月) work under JavaScriptCore.
    func aesDecryptHex(_ transformation: String, _ keyHex: String, _ ivHex: String, _ dataHex: String) -> String {
        return Self.aesCrypt(encrypt: false, transformation: transformation, keyHex: keyHex, ivHex: ivHex, dataHex: dataHex)
    }

    /// AES encrypt. Inputs/output are lowercase hex; `""` on failure.
    func aesEncryptHex(_ transformation: String, _ keyHex: String, _ ivHex: String, _ dataHex: String) -> String {
        return Self.aesCrypt(encrypt: true, transformation: transformation, keyHex: keyHex, ivHex: ivHex, dataHex: dataHex)
    }

    /// Hex string → bytes (nil on malformed input).
    private static func bytesFromHex(_ hex: String) -> [UInt8]? {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            bytes.append(b); idx = next
        }
        return bytes
    }

    private static func aesCrypt(encrypt: Bool, transformation: String, keyHex: String, ivHex: String, dataHex: String) -> String {
        let parts = transformation.uppercased().split(separator: "/").map(String.init)
        guard parts.first == "AES" else { return "" }
        let mode = parts.count > 1 ? parts[1] : "ECB"
        let padding = parts.count > 2 ? parts[2] : "PKCS5PADDING"

        guard let key = bytesFromHex(keyHex), let data = bytesFromHex(dataHex), !data.isEmpty else { return "" }
        let iv = bytesFromHex(ivHex) ?? []

        var options: CCOptions = 0
        switch padding {
        case "PKCS5PADDING", "PKCS7PADDING": options |= CCOptions(kCCOptionPKCS7Padding)
        case "NOPADDING": break
        default: return "" // unsupported padding (e.g. ISO10126) — fail loudly rather than corrupt
        }
        if mode == "ECB" {
            options |= CCOptions(kCCOptionECBMode)
        } else if mode != "CBC" {
            return "" // only ECB/CBC supported via CommonCrypto here
        }
        // CBC requires a 16-byte IV; ECB ignores it.
        let ivBytes: [UInt8] = (mode == "CBC") ? (iv.count == kCCBlockSizeAES128 ? iv : [UInt8](repeating: 0, count: kCCBlockSizeAES128)) : []

        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
            CCAlgorithm(kCCAlgorithmAES),
            options,
            key, key.count,
            ivBytes.isEmpty ? nil : ivBytes,
            data, data.count,
            &out, out.count,
            &moved
        )
        guard status == kCCSuccess else { return "" }
        return out.prefix(moved).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - URL Encoding

    /// Mirrors Legado's `java.encodeURI(str)`. Encodes all characters except URI-safe ones.
    func encodeURI(_ str: String) -> String {
        str.addingPercentEncoding(
            withAllowedCharacters: .init(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'();/?:@&=+$,#")
        ) ?? str
    }

    /// Mirrors Legado's `java.encodeURIComponent(str)`. Encodes all characters except unreserved ones.
    func encodeURIComponent(_ str: String) -> String {
        str.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? str
    }

    // MARK: - HTML Formatting

    /// Decode common HTML entities to plain text.
    /// Mirrors Legado's `java.htmlFormat(str)`.
    func htmlFormat(_ str: String) -> String {
        var result = str
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", "\u{00A0}"), ("&ensp;", "\u{2002}"),
            ("&emsp;", "\u{2003}"), ("&hellip;", "…"),
            ("&mdash;", "—"), ("&ndash;", "–"),
        ]
        for (entity, replacement) in entities {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        // Decode numeric entities like &#1234; and &#x4e2d;
        if let regex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);|&#([0-9]+);") {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                if match.range(at: 1).location != NSNotFound {
                    let hexStr = ns.substring(with: match.range(at: 1))
                    if let scalar = UInt32(hexStr, radix: 16), let u = Unicode.Scalar(scalar) {
                        result.replaceSubrange(Range(match.range, in: result)!, with: String(u))
                    }
                } else if match.range(at: 2).location != NSNotFound {
                    let decStr = ns.substring(with: match.range(at: 2))
                    if let scalar = UInt32(decStr), let u = Unicode.Scalar(scalar) {
                        result.replaceSubrange(Range(match.range, in: result)!, with: String(u))
                    }
                }
            }
        }
        return result
    }

    // MARK: - Chinese Character Conversion

    /// Traditional Chinese → Simplified Chinese. Mirrors Legado's `java.t2s(text)`.
    func t2s(_ text: String) -> String {
        text.applyingTransform(.init("Traditional-Simplified"), reverse: false) ?? text
    }

    /// Simplified Chinese → Traditional Chinese. Mirrors Legado's `java.s2t(text)`.
    func s2t(_ text: String) -> String {
        text.applyingTransform(.init("Traditional-Simplified"), reverse: true) ?? text
    }

    // MARK: - Action Stubs (Legado UI actions)

    func refreshExplore() {
        #if DEBUG
        print("[JSBridge] refreshExplore() called")
        #endif
    }

    func reLoginView() {
        #if DEBUG
        print("[JSBridge] reLoginView() called")
        #endif
        reLoginViewHandler?()
    }

    func refreshBookInfo() {
        #if DEBUG
        print("[JSBridge] refreshBookInfo() called")
        #endif
    }

    func refreshBookToc() {
        #if DEBUG
        print("[JSBridge] refreshBookToc() called")
        #endif
    }

    func refreshContent() {
        #if DEBUG
        print("[JSBridge] refreshContent() called")
        #endif
    }

    /// Opens a URL in browser without returning body.
    func showBrowser(_ url: String, _ title: String) {
        browserPresentHandler?(url, title) { _ in }
    }

    func showReadingBrowser(_ url: String, _ title: String) {
        showBrowser(url, title)
    }

    func startBrowserDp(_ url: String, _ title: String) {
        startBrowser(url, title)
    }

    /// Copies text to clipboard (stub).
    func copyText(_ text: String) {
        #if DEBUG
        print("[JSBridge] copyText(\(text.prefix(50))) called")
        #endif
    }

    /// Returns a device identifier. Used by sources like 光遇 for `checkEnv()`.
    func deviceID() -> String {
        return UIDevice.current.identifierForVendor?.uuidString ?? "ios-device"
    }

    func androidId() -> String {
        deviceID()
    }

    /// Opens a video player (stub — falls back to browser).
    func openVideoPlayer(_ url: String, _ title: String) {
        startBrowser(url, title)
    }

    /// Legado `java.upLoginData(map)` — merge the given map into the source's stored login data
    /// (read back by source menus via `source.getLoginInfoMap()` / `getConfigValue`). Used by
    /// custom setting menus (起点/光遇 段评颜色·气泡模版) to persist their values.
    func upLoginData(_ data: JSValue) {
        #if DEBUG
        print("[JSBridge] upLoginData() called")
        #endif
        upLoginDataHandler?(data)
    }

    /// Legado `java.qread()` — no-op stub (kept on purpose; see note in LegadoJSBridgeExports).
    /// Lets 起点 content JS set `dev='android-轻阅读'` → createSvg uses the 轻阅读 段评 bubble variant.
    func qread() {
        #if DEBUG
        print("[JSBridge] qread() called")
        #endif
    }

    // MARK: Headless WebView (Legado java.webView)

    /// Legado `java.webView(html, url, js)` — load `url` (or raw `html`) in an offscreen
    /// WebView, run `js` after the page finishes loading, and return the string result.
    /// Cookies acquired during the load are copied into `HTTPCookieStorage` so later
    /// `java.ajax`/`cookie.getCookie` calls see them. Blocks the JS serial queue (not main).
    func webView(_ html: JSValue, _ url: JSValue, _ js: JSValue) -> String {
        let htmlArg = Self.optionalString(html)
        let urlArg = Self.optionalString(url)
        let jsArg = Self.optionalString(js) ?? "document.documentElement.outerHTML"
        let ua = sourceHeaders.first { $0.key.lowercased() == "user-agent" }?.value ?? getWebViewUA()

        let sem = DispatchSemaphore(value: 0)
        let box = WebViewResultBox()
        Task { @MainActor in
            box.value = await LegadoHeadlessWebView.run(
                html: htmlArg, url: urlArg, js: jsArg, userAgent: ua, timeout: 30
            )
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 35)
        return box.value
    }

    /// Extract a non-empty String from a JS argument, treating undefined/null/"null" as nil.
    private static func optionalString(_ value: JSValue) -> String? {
        guard !value.isUndefined, !value.isNull else { return nil }
        guard let s = value.toString(), s != "null", s != "undefined", !s.isEmpty else { return nil }
        return s
    }

    /// Convert a JS headers object into a `[String: String]` dictionary.
    private static func headerDict(from value: JSValue) -> [String: String] {
        guard !value.isUndefined, !value.isNull, value.isObject,
              let dict = value.toDictionary() as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, val) in dict {
            if let str = val as? String { result[key] = str }
            else if let num = val as? NSNumber { result[key] = num.stringValue }
            else { result[key] = "\(val)" }
        }
        return result
    }

    // MARK: - UTC Time Formatting

    /// Format a Unix millisecond timestamp in UTC with a timezone offset.
    /// Mirrors Legado's `java.timeFormatUTC(time, format, sh)`.
    /// - Parameters:
    ///   - time: Unix timestamp in milliseconds.
    ///   - format: Java-style date format string (e.g. `"yyyy-MM-dd HH:mm:ss"`).
    ///   - sh: Hour offset from UTC (e.g. `8` for UTC+8).
    func timeFormatUTC(_ time: Double, _ format: String, _ sh: Int) -> String {
        let date = Date(timeIntervalSince1970: time / 1000)
        let fmt = DateFormatter()
        // Convert Java format → DateFormatter format
        let fmtStr = format
            .replacingOccurrences(of: "yyyy", with: "yyyy")
            .replacingOccurrences(of: "MM",   with: "MM")
            .replacingOccurrences(of: "dd",   with: "dd")
            .replacingOccurrences(of: "HH",   with: "HH")
            .replacingOccurrences(of: "mm",   with: "mm")
            .replacingOccurrences(of: "ss",   with: "ss")
        fmt.dateFormat = fmtStr
        fmt.timeZone = TimeZone(secondsFromGMT: sh * 3600) ?? .current
        return fmt.string(from: date)
    }

    /// Synchronous HTTP POST used by `java.post`. Blocks the calling (JS serial queue) thread.
    private func performPost(_ urlStr: String, body: String, headers: [String: String]) -> LegadoStrResponse {
        guard let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return LegadoStrResponse(url: urlStr, body: "")
        }
        let timeoutSeconds = max(15, requestTimeoutSeconds)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        // Source headers first, then explicit per-call headers override.
        sourceHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if request.value(forHTTPHeaderField: "Content-Type") == nil {
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }

        var responseBody = ""
        let semaphore = DispatchSemaphore(value: 0)
        let task = Self.requestSession.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data = data else { return }
            responseBody = Self.decodeData(data, response: response)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeoutSeconds)
        return LegadoStrResponse(url: urlStr, body: responseBody)
    }

    private func performRequest(_ urlStr: String) -> String {
        // Route through AnalyzeUrl handler if available and URL looks like a Legado URL
        let trimmedUrl = urlStr.trimmingCharacters(in: .whitespacesAndNewlines)
        if let analyzeHandler = analyzeUrlHandler,
           trimmedUrl.hasPrefix("data:")
            || trimmedUrl.contains(",{")
            || trimmedUrl.contains("{\"method\"") {
            return analyzeHandler(urlStr) ?? ""
        }

        // Delegate to external handler if provided
        if let handler = networkHandler {
            guard let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return ""
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeoutSeconds)
            sourceHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            return handler(request) ?? ""
        }

        // Fallback: synchronous URLSession request with charset-aware decoding
        guard let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ""
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeoutSeconds)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        // Apply book source headers (may override User-Agent)
        sourceHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        var responseBody = ""
        // Use a long timeout: if a CF handler is registered, the user may need to solve CAPTCHA.
        let timeoutSeconds: Double = cloudflareChallengeHandler != nil ? 120 : requestTimeoutSeconds
        let semaphore = DispatchSemaphore(value: 0)

        let task = Self.requestSession.dataTask(with: request) { [weak self] data, response, _ in
            guard let data = data else { semaphore.signal(); return }
            let body = Self.decodeData(data, response: response)

            let isCF =
                Self.isCloudflareChallenged(body, response: response)
                || Self.isCloudflareChallengedBody(body)
            guard isCF, let self, let handler = self.cloudflareChallengeHandler, let reqURL = request.url else {
                if isCF {
                    #if DEBUG
                    print("[JSBridge] ⚠️ CF detected for \(urlStr) — no handler, returning empty")
                    #endif
                } else {
                    responseBody = body
                }
                semaphore.signal()
                return
            }

            // Present the CF challenge UI on the main thread; signal cfSem via done() callback.
            let cfSem = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                handler(reqURL) { cfSem.signal() }
            }
            cfSem.wait()  // cookies are now in HTTPCookieStorage.shared

            // Retry once without CF check (cookies are fresh).
            let retrySem = DispatchSemaphore(value: 0)
            Self.requestSession.dataTask(with: request) { retryData, retryResp, _ in
                defer { retrySem.signal() }
                guard let retryData else { return }
                responseBody = Self.decodeData(retryData, response: retryResp)
            }.resume()
            _ = retrySem.wait(timeout: .now() + 15)
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + timeoutSeconds)
        return responseBody
    }

    /// Charset-aware string decoding: honours HTTP Content-Type charset before falling back to UTF-8.
    static func decodeData(_ data: Data, response: URLResponse?) -> String {
        if let httpResponse = response as? HTTPURLResponse,
           let ianaName = httpResponse.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(ianaName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let text = String(data: data, encoding: String.Encoding(rawValue: nsEncoding)) {
                    return text
                }
            }
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }

    /// Returns true when the response body looks like a Cloudflare challenge page.
    /// Returning an empty string from performRequest prevents `JSON.parse` from crashing
    /// with `SyntaxError` on the raw HTML protection page.
    static func isCloudflareChallenged(_ body: String, response: URLResponse?) -> Bool {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        // CF typically returns 403 or 503 with recognisable markers
        if status != 403 && status != 503 && status != 429 { return false }
        let markers = [
            "cf-browser-verification",
            "cf_chl_prog",
            "Checking if the site connection is secure",
            "checking your browser",
            "_cf_chl_",
            "cf-challenge",
        ]
        let lower = body.lowercased()
        return markers.contains(where: { lower.contains($0.lowercased()) })
    }

    /// Returns true when the body alone (regardless of HTTP status) looks like a CF page.
    /// Used for HTTP 200 responses that smuggle a CF challenge in the body.
    static func isCloudflareChallengedBody(_ body: String) -> Bool {
        // Use only unambiguous, CF-specific fingerprints to minimise false positives.
        let specificMarkers = [
            "cf-browser-verification",
            "cf_chl_prog",
            "_cf_chl_",
            "cf-challenge-running",
        ]
        let lower = body.lowercased()
        return specificMarkers.contains(where: { lower.contains($0) })
    }
}

// MARK: - StrResponse (Legado startBrowserAwait return type)

/// JS-callable response object returned by `java.startBrowserAwait()`.
/// Mirrors Legado's `StrResponse(url, body)`.
@objc protocol LegadoStrResponseExport: JSExport {
    func body() -> String
    var url: String { get }
}

@objc class LegadoStrResponse: NSObject, LegadoStrResponseExport {
    @objc let url: String
    private let responseBody: String

    init(url: String, body: String) {
        self.url = url
        self.responseBody = body
        super.init()
    }

    func body() -> String {
        return responseBody
    }
}

// MARK: - WebView Result Box

/// Mutable, lock-free carrier for a `java.webView` result handed across the
/// MainActor → JS-queue boundary. Safe because access is serialized by the
/// DispatchSemaphore (write-before-signal, read-after-wait).
final class WebViewResultBox: @unchecked Sendable {
    var value: String = ""
}
