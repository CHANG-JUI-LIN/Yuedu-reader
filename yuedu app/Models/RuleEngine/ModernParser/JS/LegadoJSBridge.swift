import Foundation
import JavaScriptCore
import CommonCrypto

// MARK: - JSExport Protocol

/// Protocol for Legado's `java.*` bridge functions.
/// Conforms to JSExport so methods are callable from JavaScript.
@objc protocol LegadoJSBridgeExport: JSExport {
    // Networking
    func ajax(_ urlStr: String) -> String
    func ajaxAll(_ urlArray: [String]) -> [String]
    func connect(_ urlStr: String) -> String

    // Variable storage
    func put(_ key: String, _ value: String)
    func get(_ key: String) -> String

    // Rule evaluation (placeholder — connected to ModernRuleEngine later)
    func getString(_ ruleStr: String) -> String
    func getStringList(_ ruleStr: String) -> [String]

    // Browser WebView (Legado startBrowser / startBrowserAwait)
    func startBrowser(_ url: String, _ title: String)
    func startBrowserAwait(_ url: String, _ title: String)

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
}

// MARK: - Cookie Bridge

/// Legado's `cookie` object — accessible from JS as `cookie.get(url)`, `cookie.set(url, val)`, `cookie.remove(url)`.
@objc protocol LegadoCookieBridgeExport: JSExport {
    func get(_ url: String) -> String
    func set(_ url: String, _ cookie: String)
    func remove(_ url: String)
}

@objc class LegadoCookieBridge: NSObject, LegadoCookieBridgeExport {

    func get(_ url: String) -> String {
        CookieStore.shared.get(url: url)
    }

    func set(_ url: String, _ cookie: String) {
        CookieStore.shared.set(url: url, cookie: cookie)
    }

    func remove(_ url: String) {
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

    /// Called when JS invokes `java.startBrowser(url, title)` or `java.startBrowserAwait(url, title)`.
    /// Receives (url, title, onDismiss). For `startBrowserAwait` the bridge blocks jsQueue via
    /// DispatchSemaphore until `onDismiss()` is called; for `startBrowser` it is called immediately.
    var browserPresentHandler: ((String, String, @escaping () -> Void) -> Void)?

    /// Called when JS invokes `java.toast(msg)` / `java.longToast(msg)`.
    var toastHandler: ((String) -> Void)?

    /// Delegate for rule evaluation (connected later).
    var getStringHandler: ((String) -> String?)?
    var getStringListHandler: ((String) -> [String]?)?

    /// Book source headers (for JS network requests to use correct User-Agent etc.)
    var sourceHeaders: [String: String] = [:]

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

    // MARK: Variable Storage

    func put(_ key: String, _ value: String) {
        putData?(key, value)
    }

    func get(_ key: String) -> String {
        return getData?(key) ?? ""
    }

    // MARK: Rule Evaluation (placeholder)

    func getString(_ ruleStr: String) -> String {
        return getStringHandler?(ruleStr) ?? ""
    }

    func getStringList(_ ruleStr: String) -> [String] {
        return getStringListHandler?(ruleStr) ?? []
    }

    // MARK: Browser & Toast (Legado java.startBrowser / startBrowserAwait / toast)

    /// Opens a browser WebView without blocking JS execution.
    func startBrowser(_ url: String, _ title: String) {
        browserPresentHandler?(url, title) { /* fire and forget */ }
    }

    /// Opens a browser WebView and blocks the JS thread (jsQueue) until the user closes it.
    /// Uses DispatchSemaphore — safe because jsQueue is a background serial queue, not MainThread.
    func startBrowserAwait(_ url: String, _ title: String) {
        guard let handler = browserPresentHandler else { return }
        let sem = DispatchSemaphore(value: 0)
        handler(url, title) { sem.signal() }
        sem.wait()
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
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
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
        var fmtStr = format
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

    private func performRequest(_ urlStr: String) -> String {
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
        let semaphore = DispatchSemaphore(value: 0)

        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data = data else { return }
            let body = Self.decodeData(data, response: response)
            if Self.isCloudflareChallenged(body, response: response) {
                #if DEBUG
                print("[JSBridge] ⚠️ Cloudflare challenge detected for \(urlStr) — returning empty to prevent JSON.parse crash")
                #endif
                return  // responseBody stays ""
            }
            responseBody = body
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 8)
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
}
