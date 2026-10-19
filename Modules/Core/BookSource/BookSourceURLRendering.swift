import Foundation

extension BookSource {
    /// Render a search URL that has no JSON options: `{{key}}` `{{page}}` `{{key,GB2312}}`
    /// and the legacy `URL,POST,body`. A URL with options (`URL,{…}`) is the runtime's
    /// (`shouldUseLegadoRuntimeFetch`), which reads them as Legado's AnalyzeUrl does.
    ///
    /// Any other `{{…}}` left after those substitutions is source JS, evaluated in the
    /// source's own session runtime (`evaluateRemainingTemplates`).
    func renderSearchURL(query: String, page: Int = 1) async -> (
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
            s
                .replacingOccurrences(of: "{{key,GB2312}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,gb2312}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,GBK}}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key,gbk}}", with: gbkEncoded)
                .replacingOccurrences(of: "{key,GB2312}", with: gbkEncoded)
                .replacingOccurrences(of: "{{key}}", with: encoded)
                .replacingOccurrences(of: "{key}", with: encoded)
                .replacingOccurrences(of: "{{page}}", with: pageStr)
                .replacingOccurrences(of: "{page}", with: pageStr)
        }

        let trimmedSearch = searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        // Legacy format: URL,POST,bodyTemplate
        let parts = trimmedSearch.components(separatedBy: ",")
        let urlTemplate = applyVars(parts[0].trimmingCharacters(in: .whitespacesAndNewlines))
        let method: String
        let bodyTemplate: String?
        if parts.count >= 2 && parts[1].trimmingCharacters(in: .whitespaces).uppercased() == "POST" {
            method = "POST"
            bodyTemplate = applyVars(parts.count >= 3 ? parts[2...].joined(separator: ",") : "")
        } else {
            method = "GET"
            bodyTemplate = nil
        }

        guard urlTemplate.contains("{{") || bodyTemplate?.contains("{{") == true else {
            return (urlTemplate, method, bodyTemplate.flatMap { $0.isEmpty ? nil : $0 })
        }
        // Source JS runs on the source's host, exactly like the runtime's own URL rendering
        // (`prepareFetch`).
        let source = self
        let (url, body) = await BookSourceSession.session(for: source).host.run { bridge in
            // AnalyzeUrl's template bindings (`buildJsBindings`), so a template reads the
            // same names here as on the runtime path. `key` is the raw query, as in Legado.
            let bindings: [String: Any] = [
                "baseUrl": source.bookSourceUrl,
                "page": page,
                "key": query,
                "speakText": "",
                "speakSpeed": 0,
                "header": source.header,
            ]
            let url = Self.evaluateRemainingTemplates(
                urlTemplate, source: source, bridge: bridge, bindings: bindings)
            let body = bodyTemplate.map {
                Self.evaluateRemainingTemplates($0, source: source, bridge: bridge, bindings: bindings)
            }
            return (url, body)
        }
        return (url, method, body.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// The header rule as a dictionary, for a caller that cannot wait (a SwiftUI body, a
    /// cover cell). A request about to be sent uses `resolvedHeaders()` instead.
    ///
    /// Legado's `getHeaderMap()` also accepts a `@js:` / `<js>` rule that *builds*
    /// the map; returning `[:]` for those dropped the constant token 书山聚合
    /// requires on every endpoint, so its search/catalog answered
    /// `{"error":"访问被拒绝"}`. A JS rule is evaluated on the source's session host;
    /// here it reads as what that last resolved — `[:]` until the first resolution, which
    /// this starts (`BookSourceSession.headerSnapshotStartingResolution`).
    var parsedHeaders: [String: String] {
        switch headerRule {
        case .none: return [:]
        case .dictionary(let headers): return headers
        case .script: return BookSourceSession.session(for: self).headerSnapshotStartingResolution()
        }
    }

    /// The header rule as a dictionary for a request about to be sent: a `@js:` rule that
    /// has not resolved yet resolves now, on the source's host, instead of the request going
    /// out without it.
    func resolvedHeaders() async -> [String: String] {
        switch headerRule {
        case .none: return [:]
        case .dictionary(let headers): return headers
        case .script: return await BookSourceSession.session(for: self).resolvedHeaders()
        }
    }

    private enum HeaderRule {
        case none
        case dictionary([String: String])
        case script
    }

    private var headerRule: HeaderRule {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        if let data = trimmed.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return .dictionary(dict)
        }
        return JSCoreEngine.headerJSScript(trimmed) != nil ? .script : .none
    }

    /// Process remaining `{{...}}` JavaScript template expressions in URLs.
    /// Legado book source URLs often contain `{{cookie.removeCookie(source.key)}}` and similar JS
    /// fragments: side effects whose value is empty. Each expression runs in the source's session
    /// runtime — the one bridge per source, with `jsLib`, `source`, `cookie` and `java` in scope —
    /// and an expression that yields nothing (undefined, null, or an error) renders as "".
    private static func evaluateRemainingTemplates(
        _ input: String,
        source: BookSource,
        bridge: ModernParserBridge,
        bindings: [String: Any]
    ) -> String {
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
            let evaluated = bridge.evaluateSourceScript(expression, bindings: bindings)
            if evaluated == nil, let error = bridge.lastSourceScriptError {
                AppLogger.parse("search URL template failed; rendered empty", context: [
                    "source": source.bookSourceName,
                    "error": error,
                ], level: .warning)
            }
            output.replaceSubrange(wholeRange, with: evaluated ?? "")
        }
        return output
    }
}

// MARK: - Legado Rule Analyzer (faithful port of RuleAnalyzer.kt)
// Used for bracket-aware splitting of rule strings, handling &&, ||, %% operators
