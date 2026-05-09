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
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "\"")
            .replacingOccurrences(of: "’", with: "\"")
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

    /// 渲染搜索 URL（對齊 Legado AnalyzeUrl）
    /// 支援：{{key}} {{page}} {{key,GB2312}} / URL,POST,body / URL,{JSON 選項}
    /// JSON 選項支援欄位：method, body, charset, headers, webView, webJs, retry
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
            // 處理剩餘的 {{...}} JavaScript 表達式
            result = BookSource.evaluateRemainingTemplates(result, source: self)
            return result
        }

        // Legado 格式：URL 後面跟逗號+JSON → URL,{"method":"POST","body":"...","webView":true,...}
        // 先嘗試用正則切分 URL 和 JSON 選項
        let trimmedSearch = searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let jsonStart = trimmedSearch.range(of: ",\\s*\\{", options: .regularExpression) {
            let urlPart = applyVars(String(trimmedSearch[trimmedSearch.startIndex..<jsonStart.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines))
            let jsonPart = String(trimmedSearch[jsonStart.lowerBound...]).dropFirst() // 去掉逗號
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = jsonPart.data(using: .utf8),
               let opt = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let method = (opt["method"] as? String)?.uppercased() == "POST" ? "POST" : "GET"
                let body = (opt["body"] as? String).map { applyVars($0) }
                return (urlPart, method, body)
            }
        }

        // 舊格式：URL,POST,bodyTemplate
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
            // 處理剩餘的 {{...}} JavaScript 表達式（如 {{cookie.removeCookie(source.key)}}）
            // 這些通常是 cookie 管理等副作用操作，在 Legado 中返回空字串
            // 使用 JSContext 嘗試求值，失敗則替換為空字串
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

    /// 解析 header 字串為 Dictionary
    var parsedHeaders: [String: String] {
        guard !header.isEmpty,
            let data = header.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return dict
    }

    /// 處理 URL 中剩餘的 `{{...}}` JavaScript 模板表達式
    /// Legado 書源 URL 中常含 `{{cookie.removeCookie(source.key)}}` 等 JS 片段，
    /// 這些通常是副作用操作（清 cookie 等），返回空字串。
    /// 此方法嘗試透過 JSContext 求值，失敗則替換為空字串。
    static func evaluateRemainingTemplates(_ input: String, source: BookSource) -> String {
        guard input.contains("{{") else { return input }
        guard let regex = try? NSRegularExpression(pattern: #"\{\{([\s\S]*?)\}\}"#) else { return input }
        let nsRange = NSRange(input.startIndex..., in: input)
        let matches = regex.matches(in: input, range: nsRange)
        guard !matches.isEmpty else { return input }

        var output = input
        // 反向替換避免偏移
        for match in matches.reversed() {
            guard let wholeRange = Range(match.range(at: 0), in: output),
                  let exprRange = Range(match.range(at: 1), in: output) else { continue }
            let expression = String(output[exprRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !expression.isEmpty else {
                output.replaceSubrange(wholeRange, with: "")
                continue
            }
            // 嘗試用 JSContext 求值
            let evaluated = evaluateTemplateExpression(expression, source: source)
            output.replaceSubrange(wholeRange, with: evaluated)
        }
        return output
    }

    /// 用 JSContext 求值單個模板表達式
    private static func evaluateTemplateExpression(_ expression: String, source: BookSource) -> String {
        let context = JSContext()
        context?.exceptionHandler = { _, _ in }

        // 提供 source 物件（Legado 相容）
        let sourceObj: [String: Any] = [
            "bookSourceUrl": source.bookSourceUrl,
            "bookSourceName": source.bookSourceName,
            "bookSourceGroup": source.bookSourceGroup,
            "loginUrl": source.loginUrl,
            "header": source.header,
        ]
        context?.setObject(sourceObj, forKeyedSubscript: "source" as NSString)

        // 提供 source.getKey() 方法
        let getKeyBlock: @convention(block) () -> String = { source.bookSourceUrl }
        context?.objectForKeyedSubscript("source")?.setObject(getKeyBlock, forKeyedSubscript: "getKey" as NSString)

        // 提供 cookie 橋接（cookie.removeCookie 等常見 Legado 操作）
        let cookieObj: [String: Any] = [:]
        context?.setObject(cookieObj, forKeyedSubscript: "cookie" as NSString)
        let removeCookieBlock: @convention(block) (String) -> String = { _ in "" }
        context?.objectForKeyedSubscript("cookie")?.setObject(removeCookieBlock, forKeyedSubscript: "removeCookie" as NSString)
        let getCookieBlock: @convention(block) (String) -> String = { _ in "" }
        context?.objectForKeyedSubscript("cookie")?.setObject(getCookieBlock, forKeyedSubscript: "getCookie" as NSString)

        // 提供 java 橋接（基本的鏈式呼叫，返回空字串）
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
        context?.setObject(javaConnectBlock, forKeyedSubscript: "java" as NSString)
        context?.objectForKeyedSubscript("java")?.setObject(javaConnectBlock, forKeyedSubscript: "connect" as NSString)

        // 嘗試求值
        let candidates = [
            expression,
            "(function(){ return (\(expression)); })()",
        ]
        for candidate in candidates {
            context?.exception = nil
            if let value = context?.evaluateScript(candidate), !value.isUndefined, !value.isNull {
                let result = value.toString() ?? ""
                if result != "undefined" && result != "null" {
                    return result
                }
            }
        }
        // 求值失敗，返回空字串（大多數 cookie/java 操作本身就是副作用，不影響 URL）
        return ""
    }
}

// MARK: - Legado Rule Analyzer（忠實移植 RuleAnalyzer.kt）
// 用於規則字串的括號感知分割，處理 &&、||、%% 運算子

