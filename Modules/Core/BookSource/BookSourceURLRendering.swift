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
        // Source JS runs on the source-script thread (a script there may block on the
        // engine's queue), exactly like the runtime's own URL rendering (`prepareFetch`).
        let source = self
        let (url, body) = await SourceScriptThread.run {
            let bridge = BookSourceSession.session(for: source).bridgeForAsyncOperations
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

    /// Parse header string into Dictionary.
    ///
    /// Legado's `getHeaderMap()` also accepts a `@js:` / `<js>` rule that *builds*
    /// the map; returning `[:]` for those dropped the constant token 书山聚合
    /// requires on every endpoint, so its search/catalog answered
    /// `{"error":"访问被拒绝"}`. JS rules are evaluated through the source's shared
    /// session bridge and cached per source version (see `jsHeaderCache`).
    var parsedHeaders: [String: String] {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [:] }
        if let data = trimmed.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            return dict
        }
        guard JSCoreEngine.headerJSScript(trimmed) != nil else { return [:] }
        return Self.evaluatedJSHeaders(for: self)
    }

    /// Resolved `@js:` header maps keyed by source URL + `lastUpdateTime`, so an
    /// edited/re-imported source re-evaluates while normal use pays the JS cost once.
    ///
    /// The engine caches this too; the second layer exists because `parsedHeaders`
    /// is read from SwiftUI bodies (cover cells) on the main thread, and reaching
    /// the engine means a `sync` onto its serial JS queue — which may be mid-parse.
    /// Only the first read per source version pays that, and never while a script on
    /// that queue waits for the reader (`JSCoreEngine.currentSourceHeaders`).
    private nonisolated(unsafe) static var jsHeaderCache: [String: [String: String]] = [:]
    private static let jsHeaderCacheLock = NSLock()

    private static func evaluatedJSHeaders(for source: BookSource) -> [String: String] {
        let key = "\(source.bookSourceUrl)#\(source.lastUpdateTime)"
        jsHeaderCacheLock.lock()
        let cached = jsHeaderCache[key]
        jsHeaderCacheLock.unlock()
        if let cached { return cached }

        // One bridge per source (BookSourceSession) — never build a throwaway
        // JSContext here, and don't take the session's parse lock: the header
        // script only needs the engine's own serial queue.
        let bridge = BookSourceSession.session(for: source).bridgeForAsyncOperations
        // nil: the engine's queue is held by a script waiting for the reader, and this read
        // is on the main thread. Use what the engine last resolved, uncached, so the next
        // read after the page closes gets the current rule result.
        guard let headers = bridge.currentSourceHeaders() else {
            return bridge.lastResolvedSourceHeaders()
        }

        jsHeaderCacheLock.lock()
        if jsHeaderCache.count >= 32 { jsHeaderCache.removeAll(keepingCapacity: true) }
        jsHeaderCache[key] = headers
        jsHeaderCacheLock.unlock()
        AppLogger.parse("⟐ header.js resolved", context: [
            "source": source.bookSourceName,
            "keys": headers.keys.sorted().joined(separator: ",")
        ])
        return headers
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
