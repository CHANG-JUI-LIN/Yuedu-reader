import Foundation

extension BookSource {
    /// Render a search URL that has no JSON options: `{{key}}` `{{page}}` `{{key,GB2312}}`
    /// and the legacy `URL,POST,body`. A URL with options (`URL,{…}`) or a JS template is the
    /// runtime's (`shouldUseLegadoRuntimeFetch`), which reads them as Legado's AnalyzeUrl does.
    ///
    /// Any other `{{…}}` left after those substitutions — source JS in the legacy POST form, or
    /// `{{ key }}` spaced or cased in a way they do not match — is evaluated in the source's own
    /// session runtime (`evaluateRemainingTemplates`). What that JS puts is the page's
    /// (`pageVariables`), for its list to start from.
    func renderSearchURL(query: String, page: Int = 1) async -> (
        url: String, method: String, body: String?, pageVariables: [String: String]?
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
        let parts = Self.legacySearchURLParts(trimmedSearch)
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
            let body = bodyTemplate.map { AnalyzeUrl.applyPageRules($0, page: page) }
            return (
                AnalyzeUrl.applyPageRules(urlTemplate, page: page), method,
                body.flatMap { $0.isEmpty ? nil : $0 }, nil
            )
        }
        // Source JS runs on the source's host, exactly like the runtime's own URL rendering
        // (`prepareFetch`), and its puts go to the page's scope as they do there.
        let source = self
        let (url, body, pageVariables) = await BookSourceSession.session(for: source).host.run { bridge in
            let pageScope = RuleData()
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
            let (url, body) = bridge.withPutScope(pageScope) {
                let url = Self.evaluateRemainingTemplates(
                    urlTemplate, source: source, bridge: bridge, bindings: bindings)
                let body = bodyTemplate.map {
                    Self.evaluateRemainingTemplates($0, source: source, bridge: bridge, bindings: bindings)
                }
                return (url, body)
            }
            return (url, body, pageScope.variableMap.isEmpty ? nil : pageScope.variableMap)
        }
        // Page rules after templates, Legado's order (`replaceKeyPageJs`).
        let pagedBody = body.map { AnalyzeUrl.applyPageRules($0, page: page) }
        return (
            AnalyzeUrl.applyPageRules(url, page: page), method,
            pagedBody.flatMap { $0.isEmpty ? nil : $0 }, pageVariables
        )
    }

    /// Whether `searchUrl` is the legacy `URL,POST,body`, which only this renderer reads.
    static func isLegacyPostSearchURL(_ searchUrl: String) -> Bool {
        let parts = legacySearchURLParts(searchUrl)
        return parts.count >= 2 && parts[1].trimmingCharacters(in: .whitespaces).uppercased() == "POST"
    }

    /// `searchUrl` cut at its commas, for the legacy `URL,POST,body`. A comma inside braces is
    /// the template's — `{{key,GBK}}`, `{key,GB2312}`, `{{java.put('k', 'v' + key)}}` — and
    /// cutting there left the URL ending mid-template. Quotes count only inside braces, where
    /// they open JS strings; in the URL itself they are text. A comma inside a `<p1,p2>` page
    /// rule is the rule's: cutting `/<,page/{{page}}/>?s={{key}}` there sent `/<` and 404'd
    /// (恩京书房, YCK1330).
    private static func legacySearchURLParts(_ searchUrl: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inPageRule = false
        var quote: Character?
        var escaped = false
        for char in searchUrl {
            if depth > 0 {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if let open = quote {
                    if char == open { quote = nil }
                } else if char == "'" || char == "\"" {
                    quote = char
                } else if char == "{" {
                    depth += 1
                } else if char == "}" {
                    depth -= 1
                }
            } else if char == "{" {
                depth = 1
            } else if inPageRule {
                if char == ">" { inPageRule = false }
            } else if char == "<" {
                inPageRule = true
            } else if char == "," {
                parts.append(current)
                current = ""
                continue
            }
            current.append(char)
        }
        parts.append(current)
        return parts
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
        case .none: return Self.withLegadoUserAgent([:])
        case .dictionary(let headers): return Self.withLegadoUserAgent(headers)
        case .script: return BookSourceSession.session(for: self).headerSnapshotStartingResolution()
        }
    }

    /// The header rule as a dictionary for a request about to be sent: a `@js:` rule is
    /// evaluated now, on the source's host, as Legado evaluates it for every request
    /// (`BookSourceSession.resolvedHeaders`).
    func resolvedHeaders() async -> [String: String] {
        switch headerRule {
        case .none: return Self.withLegadoUserAgent([:])
        case .dictionary(let headers): return Self.withLegadoUserAgent(headers)
        case .script: return await BookSourceSession.session(for: self).resolvedHeaders()
        }
    }

    /// Legado's `AppConfig.userAgent` as legado-E and MD3 ship it: desktop Chrome at their
    /// Cronet version (`CronetMainVersion=128.0.0.0`).
    static let legadoDefaultUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

    /// Legado `BaseSource.getHeaderMap`: the source's headers, with `legadoDefaultUserAgent`
    /// when they name no User-Agent (in any case). Every request a source makes starts from
    /// this map — natively (`resolvedHeaders()`), on its script host (`JSCoreEngine
    /// .resolvedSourceHeaders`, which `java.*`, AnalyzeUrl requests and `source.getHeaderMap()`
    /// read), and in a WebView, whose user agent is the map's.
    ///
    /// 58% of the YCK 1329–1331 sources declare no User-Agent, so they were written against
    /// the pages a site serves desktop Chrome 128. Before 11-07 they sent iPhone Safari 17
    /// natively, a truncated `iPhone OS 18_0 … AppleWebKit/605.1.15` from `java.*`, and
    /// CFNetwork's own `YueduReader/… CFNetwork/… Darwin/…` from AnalyzeUrl requests; the YCK
    /// 1330 first run passed 24% of them against 52% of the sources with their own.
    static func withLegadoUserAgent(_ headers: [String: String]) -> [String: String] {
        guard !headers.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame })
        else { return headers }
        var headers = headers
        headers["User-Agent"] = legadoDefaultUserAgent
        return headers
    }

    /// Legado `BaseSource.getHeaderMap`'s parse of a header rule's JSON — the source's own
    /// header, or what its `@js:` / `<js>` header returned: `GSONStrict`, then the lenient
    /// `GSON` (single quotes, bare keys), into a `Map<String, String>`, where Gson reads a
    /// number or boolean as its text. nil when neither parses — Legado then sends only its
    /// default User-Agent.
    ///
    /// The one parse for both the native requests and the script host. They disagreed: the
    /// native one dropped a lenient header whole (猫眼看书's `{ 'User-Agent': 'okhttp/4.9.2',
    /// 'Authorization': … }`, YCK 1329／1331, searched with no token), and the host's mined
    /// `Key: Value` lines out of a broken one (楠楠漫画's unterminated `"Referer": "https://…/}`
    /// sent a header named `{  "User-Agent"`, and nginx answered 400).
    static func legadoHeaderMap(fromJSON text: String) -> [String: String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), let object = AnalyzeUrl.parseOptionDictionary(trimmed) else {
            return nil
        }
        var map: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let string as String:
                map[key] = string
            case let number as NSNumber:
                map[key] = CFGetTypeID(number) == CFBooleanGetTypeID()
                    ? (number.boolValue ? "true" : "false")
                    : number.stringValue
            case is NSNull:
                continue
            default:
                // An object or array where Gson expects a string: its parse throws, and
                // Legado keeps none of the map.
                return nil
            }
        }
        return map
    }

    private enum HeaderRule {
        case none
        case dictionary([String: String])
        case script
    }

    private var headerRule: HeaderRule {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }
        if JSCoreEngine.headerJSScript(trimmed) != nil { return .script }
        guard let map = Self.legadoHeaderMap(fromJSON: trimmed) else {
            AppLogger.parse("header rule is not JSON; requests carry only the default User-Agent", context: [
                "source": bookSourceName, "rule": String(trimmed.prefix(120))
            ])
            return .none
        }
        return .dictionary(map)
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
