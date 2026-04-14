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

    // Logging
    func log(_ msg: String) -> String
    func logType(_ msg: String)

    // Utilities
    func timeFormat(_ timestamp: JSValue) -> String
    func base64Decode(_ str: String) -> String
    func base64Encode(_ str: String) -> String
    func md5Encode(_ str: String) -> String
    func md5Encode16(_ str: String) -> String
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
        // Execute requests concurrently using DispatchGroup
        var results = Array(repeating: "", count: urlArray.count)
        let group = DispatchGroup()
        let resultsLock = NSLock()

        for (index, urlStr) in urlArray.enumerated() {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                defer { group.leave() }
                let body = self?.performRequest(urlStr) ?? ""
                resultsLock.lock()
                results[index] = body
                resultsLock.unlock()
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

    // MARK: - Private Helpers

    private func performRequest(_ urlStr: String) -> String {
        // Delegate to external handler if provided
        if let handler = networkHandler {
            guard let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return ""
            }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            sourceHeaders.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            return handler(request) ?? ""
        }

        // Fallback: synchronous URLSession request with charset-aware decoding
        guard let url = URL(string: urlStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return ""
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
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
            responseBody = Self.decodeData(data, response: response)
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 15)
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
}
