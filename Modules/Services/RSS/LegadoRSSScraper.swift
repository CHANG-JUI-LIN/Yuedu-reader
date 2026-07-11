import Foundation

/// Legado-compatible RSS scraping built on the same stack as book sources:
/// `AnalyzeUrl` for request construction (URL option JSON, `{{page}}` templates,
/// POST bodies, charset) and `ModernRuleEngine` for rule evaluation (CSS / XPath /
/// JSONPath / regex / JS segments, `||`/`&&` combinators, `##` replacements).
/// Mirrors Legado's `Rss.getArticles` + `RssParserByRule`.
enum LegadoRSSScraper {

    // MARK: - Sort categories (Legado RssSource.sortUrls())

    /// Resolve the source's category tabs. `@js:`/`<js>` sortUrl rules are
    /// evaluated with JSCoreEngine before splitting.
    static func resolveSortEntries(for source: RSSSource) async -> [RSSSortEntry] {
        let raw = source.sortUrl?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            return LegadoSortURLParser.entries(from: nil, fallbackURL: source.url)
        }
        guard LegadoSortURLParser.needsJSEvaluation(raw) else {
            return LegadoSortURLParser.entries(from: raw, fallbackURL: source.url)
        }

        let js = LegadoSortURLParser.jsBody(raw) ?? ""
        let sourceURL = source.url
        let evaluated: String? = await Task.detached(priority: .userInitiated) {
            let jsEngine = JSCoreEngine()
            wireNetworkHandler(jsEngine)
            return jsEngine.evaluateIsolated(js, bindings: [
                "baseUrl": sourceURL,
                "baseURL": sourceURL
            ])
        }.value
        return LegadoSortURLParser.entries(from: evaluated, fallbackURL: source.url)
    }

    // MARK: - Scrape (Legado Rss.getArticles + RssParserByRule.parseXML)

    static func scrape(source: RSSSource, entry: RSSSortEntry? = nil, page: Int = 1) async throws -> [RSSItem] {
        var listRule = source.ruleArticles?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !listRule.isEmpty else {
            throw ScraperError.invalidRule("ruleArticles")
        }

        let entryURL = normalizedRequestURL(entry?.url ?? source.url)
        let jsEngine = JSCoreEngine()
        wireNetworkHandler(jsEngine)

        let analyzeUrl = AnalyzeUrl(
            ruleUrl: entryURL,
            page: page,
            sourceHeader: source.header,
            baseUrl: source.url,
            jsEvaluator: { [weak jsEngine] js, bindings in
                jsEngine?.evaluateIsolated(js, bindings: bindings)
            }
        )

        let (body, finalURL) = try await fetchBody(
            analyzeUrl: analyzeUrl,
            headerJSON: source.header
        )

        // Legado: a leading '-' on ruleArticles reverses the article list.
        var reverse = false
        if listRule.hasPrefix("-") {
            reverse = true
            listRule.removeFirst()
        }

        let engine = ModernRuleEngine()
        engine.jsEvaluator = { [weak engine, weak jsEngine] jsCode, prevResult in
            guard let engine, let jsEngine else { return nil }
            var bindings: [String: Any] = [
                "baseUrl": engine.baseUrl,
                "baseURL": engine.baseUrl
            ]
            if let content = engine.content {
                bindings["src"] = content
            }
            return jsEngine.evaluateIsolated(jsCode, result: prevResult, bindings: bindings)
        }
        engine.setContent(body, baseUrl: finalURL)

        let elements = engine.getElements(ruleStr: listRule)
        guard !elements.isEmpty else {
            throw ScraperError.noArticlesFound
        }

        var items: [RSSItem] = []
        items.reserveCapacity(elements.count)

        for element in elements {
            engine.setContent(element, baseUrl: finalURL)

            let title = RSSContentSanitizer.cleanText(engine.getString(ruleStr: source.ruleTitle))
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let link = engine.getString(ruleStr: source.ruleLink, isUrl: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let description = descriptionRuleIsEmpty(source) ? "" : engine.getString(ruleStr: source.ruleDescription)
            let pubDateText = engine.getString(ruleStr: source.rulePubDate)
            let imageURL = engine.getString(ruleStr: source.ruleImage, isUrl: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let finalDescription: String
            var finalContentHTML: String
            if !description.isEmpty {
                finalContentHTML = description
                finalDescription = RSSContentSanitizer.summary(from: description)
            } else {
                finalContentHTML = ""
                finalDescription = ""
            }
            if !imageURL.isEmpty {
                let imgTag = "<img src=\"\(imageURL)\" style=\"max-width:100%;height:auto;margin-bottom:1em;\" />"
                finalContentHTML = imgTag + finalContentHTML
            }

            let itemID = link.isEmpty ? "\(source.id)::\(title)" : link
            items.append(RSSItem(
                id: itemID,
                title: title,
                link: link,
                pubDate: parseDate(pubDateText),
                description: finalDescription,
                contentHTML: finalContentHTML,
                author: nil,
                imageURL: imageURL.isEmpty ? nil : imageURL,
                sourceId: source.id
            ))
        }

        if reverse {
            items.reverse()
        }

        guard !items.isEmpty else {
            throw ScraperError.noArticlesFound
        }
        return items
    }

    // MARK: - Article content (Legado Rss.getContent, ruleContent on the article page)

    /// Fetch an article's full content by applying the source's ruleContent to the
    /// article page. Returns HTML, or nil when the source has no ruleContent.
    static func fetchArticleContent(source: RSSSource, articleLink: String) async throws -> String? {
        let contentRule = source.ruleContent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !contentRule.isEmpty else { return nil }

        let jsEngine = JSCoreEngine()
        wireNetworkHandler(jsEngine)

        let analyzeUrl = AnalyzeUrl(
            ruleUrl: normalizedRequestURL(articleLink),
            sourceHeader: source.header,
            baseUrl: source.url,
            jsEvaluator: { [weak jsEngine] js, bindings in
                jsEngine?.evaluateIsolated(js, bindings: bindings)
            }
        )
        let (body, finalURL) = try await fetchBody(analyzeUrl: analyzeUrl, headerJSON: source.header)

        let engine = ModernRuleEngine()
        engine.jsEvaluator = { [weak engine, weak jsEngine] jsCode, prevResult in
            guard let engine, let jsEngine else { return nil }
            var bindings: [String: Any] = [
                "baseUrl": engine.baseUrl,
                "baseURL": engine.baseUrl
            ]
            if let content = engine.content {
                bindings["src"] = content
            }
            return jsEngine.evaluateIsolated(jsCode, result: prevResult, bindings: bindings)
        }
        engine.setContent(body, baseUrl: finalURL)

        let html = engine.getString(ruleStr: contentRule)
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Fetch

    /// Execute the AnalyzeUrl request (or WebView fetch when required) and decode
    /// the response body honoring the rule's charset option.
    private static func fetchBody(
        analyzeUrl: AnalyzeUrl,
        headerJSON: String?
    ) async throws -> (body: String, finalURL: String) {
        guard var request = analyzeUrl.toURLRequest(), let originalURL = request.url else {
            throw ScraperError.invalidURL
        }

        if let upgraded = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)?.url?.upgradedToHTTPS() {
            request.url = upgraded
        }

        // Merge source-level headers (AnalyzeUrl carries only per-rule option headers).
        for (key, value) in parsedHeaders(headerJSON) where request.value(forHTTPHeaderField: key) == nil {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let requestURL = request.url ?? originalURL

        if analyzeUrl.useWebView {
            let jsWait = analyzeUrl.webViewDelayTime > 0
                ? TimeInterval(analyzeUrl.webViewDelayTime) / 1000.0
                : nil
            let html = try await BookSourceFetcher.fetchViaWebView(
                url: requestURL,
                headers: request.allHTTPHeaderFields ?? [:],
                jsWait: jsWait
            )
            return (html, requestURL.absoluteString)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            if isATSBlocked(error) {
                throw ScraperError.atsBlocked
            }
            throw error
        }

        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw ScraperError.httpError
        }

        guard let body = decodeBody(data, charsetOption: analyzeUrl.charset, response: response) else {
            throw ScraperError.encodingError
        }
        let finalURL = (response.url ?? requestURL).absoluteString
        return (body, finalURL)
    }

    /// Decode response data: rule charset option → HTTP charset → UTF-8 → GB18030.
    static func decodeBody(_ data: Data, charsetOption: String?, response: URLResponse?) -> String? {
        if let charset = charsetOption, !charset.isEmpty {
            if let s = String(data: data, encoding: encodingFromCharset(charset)) { return s }
        }
        if let textEncodingName = response?.textEncodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(textEncodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                if let s = String(data: data, encoding: encoding) { return s }
            }
        }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: encodingFromCharset("gbk")) { return s }
        return nil
    }

    private static func encodingFromCharset(_ charset: String) -> String.Encoding {
        switch charset.lowercased() {
        case "gbk", "gb2312", "gb18030":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
                )
            )
        case "big5":
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5.rawValue)
                )
            )
        default:
            return .utf8
        }
    }

    // MARK: - Helpers

    /// Legado sourceUrls often omit the scheme ("shuyuan.nyasama.net"). Prefix
    /// https:// for host-like strings so AnalyzeUrl/URLSession accept them.
    /// Template/option syntax is preserved untouched.
    static func normalizedRequestURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:")
            || trimmed.hasPrefix("//") || trimmed.hasPrefix("/")
            || trimmed.hasPrefix("<js>") || lower.hasPrefix("@js:") || trimmed.hasPrefix("{{") {
            return trimmed
        }
        // Host-like: "example.com/path" or "example.com,{...}"
        let beforeSlash = trimmed.split(separator: "/", maxSplits: 1).first ?? ""
        let head = beforeSlash.split(separator: ",", maxSplits: 1).first ?? ""
        if head.contains("."), !head.contains(" ") {
            return "https://" + trimmed
        }
        return trimmed
    }

    private static func descriptionRuleIsEmpty(_ source: RSSSource) -> Bool {
        (source.ruleDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func parsedHeaders(_ headerJSON: String?) -> [String: String] {
        guard let headerJSON, let data = headerJSON.data(using: .utf8),
              let headers = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return headers
    }

    private static let defaultUserAgent =
        "Mozilla/5.0 (Linux; Android 8.1.0; zh-CN) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/78.0.3904.108 Mobile Safari/537.36"

    /// Wire java.ajax()-style network access for JS rules. Runs on the JS engine's
    /// dedicated serial queue, so blocking on a semaphore is safe (same pattern as
    /// ModernParserBridge).
    private static func wireNetworkHandler(_ jsEngine: JSCoreEngine) {
        jsEngine.networkHandler = { request in
            let semaphore = DispatchSemaphore(value: 0)
            var result: String?
            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                if let data {
                    result = LegadoJSBridge.decodeData(data, response: response)
                }
                semaphore.signal()
            }
            task.resume()
            _ = semaphore.wait(timeout: .now() + 30)
            return result
        }
    }

    private static func isATSBlocked(_ error: Error) -> Bool {
        if let urlError = error as? URLError,
           urlError.code == .appTransportSecurityRequiresSecureConnection {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == -1022
    }

    private static let dateFormatters: [DateFormatter] = {
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss Z",
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEE, d MMM yyyy HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd",
            "MM-dd HH:mm",
            "MM/dd/yyyy",
            "dd/MM/yyyy"
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    private static func parseDate(_ string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in dateFormatters {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        // Unix timestamps (seconds or milliseconds) are common in JSON APIs.
        if let epoch = Double(trimmed) {
            if epoch > 1_000_000_000_000 { return Date(timeIntervalSince1970: epoch / 1000) }
            if epoch > 1_000_000_000 { return Date(timeIntervalSince1970: epoch) }
        }
        return nil
    }
}

enum ScraperError: LocalizedError {
    case invalidURL
    case invalidRule(String)
    case httpError
    case encodingError
    case noArticlesFound
    case atsBlocked

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return localized("RSS URL 無效")
        case .invalidRule(let name):
            return String(format: localized("規則 %@ 格式無效"), name)
        case .httpError:
            return localized("HTTP 請求失敗")
        case .encodingError:
            return localized("網頁編碼錯誤")
        case .noArticlesFound:
            return localized("沒有找到文章")
        case .atsBlocked:
            return localized("此來源使用不安全的 HTTP 連線，已被 iOS 安全政策阻擋。")
        }
    }
}
