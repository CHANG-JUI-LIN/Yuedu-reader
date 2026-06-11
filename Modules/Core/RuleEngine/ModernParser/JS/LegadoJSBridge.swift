import Foundation
import JavaScriptCore
import CryptoKit
import UIKit

// MARK: - JSExport Protocol

/// Protocol for Legado's `java.*` bridge functions.
/// Conforms to JSExport so methods are callable from JavaScript.
@objc protocol LegadoJSBridgeExport: JSExport {
    // Networking
    func ajax(_ urlStr: String) -> String
    func ajaxAll(_ urlArray: [String]) -> [String]
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

    /// Delegate for rule evaluation (connected later).
    var getStringHandler: ((String) -> String?)?
    var getStringListHandler: ((String) -> [String]?)?
    var setContentHandler: ((Any?, String?) -> Void)?
    var getElementsHandler: ((String) -> [Any]?)?
    var getStringWithContentHandler: ((String, Any?) -> String?)?

    /// Called when JS issues a network request that hits a Cloudflare challenge.
    /// Calls `done()` after CF cookies are obtained; jsQueue blocks via DispatchSemaphore until then.
    var cloudflareChallengeHandler: ((URL, @escaping () -> Void) -> Void)?

    /// Book source headers (for JS network requests to use correct User-Agent etc.)
    var sourceHeaders: [String: String] = [:]

    /// AnalyzeUrl-based request handler. When set, `java.ajax()` routes URLs containing `,{json}`
    /// through AnalyzeUrl rather than treating the entire string as a simple URL.
    var analyzeUrlHandler: ((String) -> String?)?

    // MARK: Networking

    func ajax(_ urlStr: String) -> String {
        return performRequest(urlStr)
    }

    func ajaxAll(_ urlArray: [String]) -> [String] {
        guard !urlArray.isEmpty else { return [] }
        // Throttle to at most 6 concurrent requests to avoid GCD thread-pool exhaustion.
        // ajaxAll is called from the JS serial queue thread, which blocks here intentionally.
        let throttle = DispatchSemaphore(value: 6)
        var results = Array(repeating: "", count: urlArray.count)
        let resultsLock = NSLock()
        let group = DispatchGroup()

        for (index, urlStr) in urlArray.enumerated() {
            throttle.wait() // block until a concurrency slot is free
            group.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let body = self?.performRequest(urlStr) ?? ""
                resultsLock.lock()
                results[index] = body
                resultsLock.unlock()
                throttle.signal()
                group.leave()
            }
        }

        group.wait()
        return results
    }

    func connect(_ urlStr: String) -> String {
        return performRequest(urlStr)
    }

    /// Legado `java.post(url, body, headers)` — HTTP POST returning a `StrResponse` (`.body()`).
    /// `body` is sent verbatim; `headers` is a JS object. Defaults to
    /// `application/x-www-form-urlencoded` when no Content-Type is supplied.
    func post(_ urlStr: String, _ body: String, _ headers: JSValue) -> LegadoStrResponse {
        return performPost(urlStr, body: body, headers: Self.headerDict(from: headers))
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

    func log(_ msg: String) -> String {
        #if DEBUG
        print("[JSBridge] \(msg)")
        #endif
        return msg
    }

    func logType(_ msg: String) {
        #if DEBUG
        print("[JSBridge type] \(type(of: msg)): \(msg)")
        #endif
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

    /// Legado `java.upLoginData(map)` — refresh stored login data. No-op in parser-only flows
    /// (login state is managed by LoginManager via `source.putLoginInfo`).
    func upLoginData(_ data: JSValue) {
        #if DEBUG
        print("[JSBridge] upLoginData() called")
        #endif
    }

    /// Legado `java.qread()` — switch into "quick read" mode. No-op stub.
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
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
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
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data = data else { return }
            responseBody = Self.decodeData(data, response: response)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 15)
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
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
            sourceHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            return handler(request) ?? ""
        }

        // Fallback: synchronous URLSession request with charset-aware decoding
        guard let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ""
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
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
        let timeoutSeconds: Double = cloudflareChallengeHandler != nil ? 120 : 8
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
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
            URLSession.shared.dataTask(with: request) { retryData, retryResp, _ in
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
