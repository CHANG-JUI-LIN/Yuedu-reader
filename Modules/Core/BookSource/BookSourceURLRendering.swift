import Foundation
import JavaScriptCore

extension BookSource {
    private func stringifyRequestValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let string = value as? String { return string }
        if let data = try? JSONSerialization.data(withJSONObject: value),
            let string = String(data: data, encoding: .utf8)
        {
            return string
        }
        return String(describing: value)
    }

    private func stringifyRequestHeaders(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var output: [String: String] = [:]
        for (key, rawValue) in dict {
            guard let stringValue = stringifyRequestValue(rawValue) else { continue }
            output[key] = stringValue
        }
        return output
    }

    private func normalizeLegadoJSONObjectLike(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(",") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s
            .replacingOccurrences(of: "\u{201c}", with: "\"")
            .replacingOccurrences(of: "\u{201d}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "\"")
            .replacingOccurrences(of: "\u{2019}", with: "\"")
        if s.contains("'") {
            s = s.replacingOccurrences(
                of: #"(?<!\\)'([^']*)'"#,
                with: #""$1""#,
                options: .regularExpression
            )
        }
        s = s.replacingOccurrences(
            of: #"([{\[,]\s*)([A-Za-z_][A-Za-z0-9_\-]*)(\s*:)"#,
            with: #"$1"$2"$3"#,
            options: .regularExpression
        )
        return s
    }

    struct SearchRequestSpec {
        var url: String
        var method: String
        var body: String?
        var charset: String?
        var useWebView: Bool
        var headers: [String: String]
    }

    /// Render a search URL (aligns with Legado AnalyzeUrl).
    /// Supports: {{key}} {{page}} {{key,GB2312}} / URL,POST,body / URL,{JSON options}
    /// JSON options support fields: method, body, charset, headers, webView, webJs, retry
    func renderSearchURL(query: String, page: Int = 1) -> (
        url: String, method: String, body: String?
    ) {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let pageStr = String(page)

        let gbkEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbkEncoded: String
        if let data = query.data(using: gbkEncoding) {
            gbkEncoded = data.map { String(format: "%%%02X", $0) }.joined()
        } else {
            gbkEncoded = encoded
        }

        func applyVars(_ s: String) -> String {
            var result = s
                .replacingOccurrences(of: "{{key,GB2312}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,gb2312}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,GBK}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,gbk}}", with: gbkEncoded)
                .replacingOccurrences(of: "{key,GB2312}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key}}", with: encoded)
                .replacingOccurrences(of: "{key}", with: encoded)
                .replacingOccurrences(of: "{{page}}", with: pageStr)
                .replacingOccurrences(of: "{page}", with: pageStr)
            // Handle remaining {{...}} JavaScript expressions
            result = BookSource.evaluateRemainingTemplates(result, source: self)
            return result
        }

        // Legado format: URL followed by comma+JSON → URL,{"method":"POST","body":"...","webView":true,...}
        // First try using regex to split URL and JSON options
        let trimmedSearch = searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jsonStart = trimmedSearch.range(of: ",\\s*\\{", options: .regularExpression) {
            let urlPart = applyVars(String(trimmedSearch[trimmedSearch.startIndex..<jsonStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            let jsonPart = String(trimmedSearch[jsonStart.lowerBound...]).dropFirst() // remove comma
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonPart.data(using: .utf8),
               let opt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let method = (opt["method"] as? String)?.uppercased() == "POST" ? "POST" : "GET"
                let body = (opt["body"] as? String).map { applyVars($0) }
                return (urlPart, method, body)
            }
        }

        // Legacy format: URL,POST,bodyTemplate
        let parts = trimmedSearch.components(separatedBy: ",")
        if parts.count >= 2 && parts[1].trimmingCharacters(in: .whitespaces).uppercased() == "POST"
        {
            let urlStr = applyVars(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
            let bodyTemplate = parts.count >= 3 ? parts[2...].joined(separator: ",") : ""
            let body = applyVars(bodyTemplate)
            return (urlStr, "POST", body.isEmpty ? nil : body)
        } else {
            let finalURL = applyVars(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
            return (finalURL, "GET", nil)
        }
    }

    func renderSearchRequest(query: String, page: Int = 1) -> SearchRequestSpec {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let pageStr = String(page)

        let gbkEncoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let gbkEncoded: String
        if let data = query.data(using: gbkEncoding) {
            gbkEncoded = data.map { String(format: "%%%02X", $0) }.joined()
        } else {
            gbkEncoded = encoded
        }

        func applyVars(_ s: String) -> String {
            var result = s
                .replacingOccurrences(of: "{{key,GB2312}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,gb2312}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,GBK}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,gbk}}", with: gbkEncoded)
                .replacingOccurrences(of: "{key,GB2312}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key}}", with: encoded)
                .replacingOccurrences(of: "{key}", with: encoded)
                .replacingOccurrences(of: "{{page}}", with: pageStr)
                .replacingOccurrences(of: "{page}", with: pageStr)
            // Handle remaining {{...}} JavaScript expressions (e.g. {{cookie.removeCookie(source.key)}})
            // These are typically side-effect operations like cookie management; in Legado they return empty strings.
            // Attempt evaluation via JSContext; replace with empty string on failure.
            result = BookSource.evaluateRemainingTemplates(result, source: self)
            return result
        }

        func parseOptions(_ raw: String) -> [String: Any]? {
            let normalized = normalizeLegadoJSONObjectLike(raw)
            guard let data = normalized.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return obj
        }

        let trimmedSearch = searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jsonStart = trimmedSearch.range(of: ",\\s*\\{", options: .regularExpression) {
            let urlPart = applyVars(String(trimmedSearch[..<jsonStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            let jsonPart = String(trimmedSearch[jsonStart.lowerBound...])
            if let opt = parseOptions(jsonPart) {
                let method = ((opt["method"] as? String) ?? "GET").uppercased() == "POST" ? "POST" : "GET"
                let body = stringifyRequestValue(opt["body"]).map(applyVars)
                let charset = stringifyRequestValue(opt["charset"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                let useWebView = {
                    if let bool = opt["webView"] as? Bool { return bool }
                    let text = stringifyRequestValue(opt["webView"])?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return ["true", "1", "yes", "y"].contains(text ?? "")
                }()
                let headers = stringifyRequestHeaders(opt["headers"])
                return SearchRequestSpec(
                    url: urlPart,
                    method: method,
                    body: body,
                    charset: charset,
                    useWebView: useWebView,
                    headers: headers
                )
            }
        }

        let legacy = renderSearchURL(query: query, page: page)
        return SearchRequestSpec(
            url: legacy.url,
            method: legacy.method,
            body: legacy.body,
            charset: nil,
            useWebView: false,
            headers: [:]
        )
    }

    /// Parse header string into Dictionary
    var parsedHeaders: [String: String] {
        guard !header.isEmpty,
            let data = header.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dict
    }

    /// Process remaining `{{...}}` JavaScript template expressions in URLs.
    /// Legado book source URLs often contain `{{cookie.removeCookie(source.key)}}` and similar JS fragments.
    /// These are typically side-effect operations (cookie clearing, etc.), returning empty strings.
    /// This method attempts evaluation via JSContext; replaces with empty string on failure.
    static func evaluateRemainingTemplates(_ input: String, source: BookSource) -> String {
        guard input.contains("{{") else { return input }
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([\s\S]*?)\}\}"#) else { return input }
        let nsRange = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, range: nsRange)
        guard !matches.isEmpty else { return input }

        var output = input
        // Reverse order to avoid offset issues
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range(at: 0), in: output),
                  let exprRange = Range(match.range(at: 1), in: output) else { continue }
            let expression = String(output[exprRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expression.isEmpty else {
                output.replaceSubrange(wholeRange, with: "")
                continue
            }
            // Try evaluating with JSContext
            let evaluated = evaluateTemplateExpression(expression, source: source)
            output.replaceSubrange(wholeRange, with: evaluated)
        }
        return output
    }

    /// Evaluate a single template expression using a persistent, per-source JSContext
    /// that has the source's jsLib pre-evaluated so that `{{qt}}`, `{{ho}}` etc. resolve.
    private static var templateContextCache: [String: JSContext] = [:]
    private static let templateContextLock = NSLock()

    private static func evaluateTemplateExpression(_ expression: String, source: BookSource) -> String {
        let cacheKey = source.bookSourceUrl

        templateContextLock.lock()
        let context: JSContext
        if let cached = templateContextCache[cacheKey] {
            context = cached
        } else {
            context = JSContext()
            context.exceptionHandler = { _, _ in }
            templateContextCache[cacheKey] = context

            // Provide source object (Legado compatible)
            let sourceObj: [String: Any] = [
                "bookSourceUrl": source.bookSourceUrl,
                "bookSourceName": source.bookSourceName,
                "bookSourceGroup": source.bookSourceGroup,
                "loginUrl": source.loginUrl,
                "header": source.header,
            ]
            context.setObject(sourceObj, forKeyedSubscript: "source" as NSString)

            // Provide source.getKey() method
            let getKeyBlock: @convention(block) () -> String = { source.bookSourceUrl }
            context.objectForKeyedSubscript("source")?.setObject(getKeyBlock, forKeyedSubscript: "getKey" as NSString)

            // Provide real cookie bridge so jsLib functions like generateCsrfToken()
            // can read cookies (e.g. `this.cookie.getCookie(ho)`) during template resolution.
            let cookieBridge = LegadoCookieBridge()
            context.setObject(cookieBridge, forKeyedSubscript: "cookie" as NSString)

            // Provide java bridge (basic chainable calls, returns empty string)
            let javaConnectBlock: @convention(block) (String) -> JSValue? = { _ in
                guard let chainObj = JSValue(newObjectIn: context) else { return nil }
                let rawBlock: @convention(block) () -> JSValue? = { [weak chainObj] in chainObj }
                chainObj.setObject(rawBlock, forKeyedSubscript: "raw" as NSString)
                let requestBlock: @convention(block) () -> JSValue? = { [weak chainObj] in chainObj }
                chainObj.setObject(requestBlock, forKeyedSubscript: "request" as NSString)
                let urlBlock: @convention(block) () -> String = { source.bookSourceUrl }
                chainObj.setObject(urlBlock, forKeyedSubscript: "url" as NSString)
                return chainObj
            }
            context.setObject(javaConnectBlock, forKeyedSubscript: "java" as NSString)
            context.objectForKeyedSubscript("java")?.setObject(javaConnectBlock, forKeyedSubscript: "connect" as NSString)

            // Evaluate jsLib so {{qt}}, {{ho}} and jsLib functions are available
            if !source.jsLib.isEmpty {
                context.evaluateScript(source.jsLib)
            }
        }
        templateContextLock.unlock()

        // Attempt evaluation
        let candidates = [
            expression,
            "(function(){ return (\(expression)); })()",
        ]
        for candidate in candidates {
            context.exception = nil
            if let value = context.evaluateScript(candidate), !value.isUndefined, !value.isNull {
                let result = value.toString() ?? ""
                if result != "undefined" && result != "null" {
                    return result
                }
            }
        }
        // Evaluation failed, return empty string (most cookie/java operations are side effects that don't affect the URL)
        return ""
    }
}

// MARK: - Legado Rule Analyzer (faithful port of RuleAnalyzer.kt)
// Used for bracket-aware splitting of rule strings, handling &&, ||, %% operators
