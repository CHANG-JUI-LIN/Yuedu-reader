import CryptoKit
import Foundation

struct ChapterRequestSpec {
    var url: String
    var method: String
    var body: String?
    var headers: [String: String]
    var referer: String?
    var useWebView: Bool
    var charset: String?
}

struct ChapterParsePayload {
    var content: String
    var title: String
    var sourceMatched: Bool
    var isPay: Bool
    var runtimeVariables: [String: String]? = nil
}

struct ChapterPaginatedResult {
    var payload: ChapterParsePayload
    var rawHTMLPages: [String]
}

struct ChapterBuildResult {
    let package: ChapterPackage
    let rawHTML: String?
    let normalizedHTML: String
}

enum ChapterFetcher {
    private static func stringifyJSONValue(_ value: Any?) -> String? {
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

    private static func stringDictionary(from value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        var output: [String: String] = [:]
        for (key, rawValue) in dict {
            guard let stringValue = stringifyJSONValue(rawValue) else { continue }
            output[key] = stringValue
        }
        return output
    }

    private static func asBool(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        let text = String(describing: value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["true", "1", "yes", "y"].contains(text)
    }

    private static func normalizeLegadoOptionsJSONLike(_ raw: String) -> String {
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

    static func buildNormalizedHTML(title: String, content: String) -> String {
        let paragraphLines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ReaderHTMLUtilities.normalizedChapterHTML(
            title: title,
            paragraphs: paragraphLines
        )
    }

    static func parseChapterRequest(_ raw: String) -> ChapterRequestSpec {
        var source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let encodedRange = source.range(
            of: #",\s*%7B[\s\S]*%7D\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let prefix = String(source[..<encodedRange.lowerBound])
            let encodedSuffix = String(source[encodedRange])
            if let decodedSuffix = encodedSuffix.removingPercentEncoding {
                source = prefix + decodedSuffix
            }
        }
        guard let match = source.range(of: #",\s*\{.*\}\s*$"#, options: .regularExpression),
            let commaIndex = source[match].firstIndex(of: ",")
        else {
            return ChapterRequestSpec(
                url: source,
                method: "GET",
                body: nil,
                headers: [:],
                referer: nil,
                useWebView: false,
                charset: nil
            )
        }

        let urlPart = String(source[..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
        let optionsText = normalizeLegadoOptionsJSONLike(
            String(source[source.index(after: commaIndex)...])
        )

        guard let endBrace = optionsText.lastIndex(of: "}"),
            let data = optionsText[..<optionsText.index(after: endBrace)].data(using: .utf8),
            let options = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ChapterRequestSpec(
                url: urlPart,
                method: "GET",
                body: nil,
                headers: [:],
                referer: nil,
                useWebView: false,
                charset: nil
            )
        }

        let method = ((options["method"] as? String) ?? "GET").uppercased() == "POST"
            ? "POST" : "GET"
        return ChapterRequestSpec(
            url: urlPart,
            method: method,
            body: stringifyJSONValue(options["body"]),
            headers: stringDictionary(from: options["headers"]),
            referer: stringifyJSONValue(options["referer"]),
            useWebView: asBool(options["webView"]),
            charset: stringifyJSONValue(options["charset"])
        )
    }

    static func merge(_ current: ChapterParsePayload, _ next: ChapterParsePayload) -> ChapterParsePayload {
        var merged = current
        if merged.title.isEmpty { merged.title = next.title }
        merged.sourceMatched = merged.sourceMatched && next.sourceMatched
        merged.isPay = merged.isPay || next.isPay
        if let nextRuntime = next.runtimeVariables, !nextRuntime.isEmpty {
            merged.runtimeVariables = nextRuntime
        }
        if !next.content.isEmpty {
            merged.content = merged.content.isEmpty ? next.content : merged.content + "\n" + next.content
        }
        return merged
    }

    static func fetchPaginatedContent(
        initialHTML: String,
        initialURL: URL,
        initialBaseURL: String,
        maxPages: Int = 10,
        parsePage: @escaping @Sendable (String, String) async throws -> ChapterParsePayload,
        extractNextURLs: @escaping @Sendable (String, String) async -> [String],
        fetchNextPageHTML: @escaping @Sendable (URL) async throws -> String
    ) async throws -> ChapterPaginatedResult {
        var parsed = try await parsePage(initialHTML, initialURL.absoluteString)
        var rawHTMLPages: [String] = [initialHTML]
        var pendingURLs = await extractNextURLs(initialHTML, initialBaseURL)
        var pageCount = 0
        var visitedNextPages = Set<String>([initialURL.absoluteString])

        while !pendingURLs.isEmpty && pageCount < maxPages {
            let nextURL = pendingURLs.removeFirst()
            if visitedNextPages.contains(nextURL) { continue }
            visitedNextPages.insert(nextURL)
            guard let nextPageURL = URL(string: nextURL) else { continue }
            let nextHTML = try await fetchNextPageHTML(nextPageURL)
            rawHTMLPages.append(nextHTML)
            let nextParsed = try await parsePage(nextHTML, nextURL)
            parsed = merge(parsed, nextParsed)
            let nextBatch = await extractNextURLs(nextHTML, nextURL)
            for candidate in nextBatch where !visitedNextPages.contains(candidate) && !pendingURLs.contains(candidate) {
                pendingURLs.append(candidate)
            }
            pageCount += 1
        }

        return ChapterPaginatedResult(payload: parsed, rawHTMLPages: rawHTMLPages)
    }

    static func buildChapterPackage(
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String,
        tocTitle: String,
        initialHTML: String,
        initialURL: URL,
        initialBaseURL: String,
        replaceRules: String,
        parsePage: @escaping @Sendable (String, String) async throws -> ChapterParsePayload,
        extractNextURLs: @escaping @Sendable (String, String) async -> [String],
        fetchNextPageHTML: @escaping @Sendable (URL) async throws -> String,
        fetchViaJS: @escaping @Sendable () async throws -> String?,
        fetchBySelectors: @escaping @Sendable () async throws -> String?
    ) async throws -> ChapterBuildResult {
        let parseStart = CFAbsoluteTimeGetCurrent()
        ReaderTelemetry.shared.log(
            "chapter_parse_start",
            attributes: [
                "bookId": bookId.uuidString,
                "chapterIndex": "\(chapterIndex)",
                "sourceURL": String(sourceURL.prefix(120)),
            ]
        )

        let paginated = try await fetchPaginatedContent(
            initialHTML: initialHTML,
            initialURL: initialURL,
            initialBaseURL: initialBaseURL,
            parsePage: parsePage,
            extractNextURLs: extractNextURLs,
            fetchNextPageHTML: fetchNextPageHTML
        )
        let parsed = paginated.payload
        let content = await resolveContent(
            parsed: parsed,
            replaceRules: replaceRules,
            fetchViaJS: fetchViaJS,
            fetchBySelectors: fetchBySelectors
        )
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FetchError.emptyContent
        }
        let canonicalTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHTML = buildNormalizedHTML(
            title: canonicalTitle.isEmpty ? tocTitle : canonicalTitle,
            content: content
        )
        let rawHTML = paginated.rawHTMLPages.joined(separator: "\n<!-- staged-page-break -->\n")
        let checksum = SHA256.hash(data: Data(content.utf8)).compactMap {
            String(format: "%02x", $0)
        }.joined()
        let savedAt = Date()

        ReaderTelemetry.shared.log(
            "chapter_parse_end",
            attributes: [
                "bookId": bookId.uuidString,
                "chapterIndex": "\(chapterIndex)",
                "durationMs": "\(Int((CFAbsoluteTimeGetCurrent() - parseStart) * 1000))",
                "rawPageCount": "\(paginated.rawHTMLPages.count)",
                "contentLength": "\(content.count)",
                "sourceMatched": parsed.sourceMatched ? "true" : "false",
            ]
        )

        let package = ChapterPackage(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            canonicalTitle: canonicalTitle.isEmpty ? nil : canonicalTitle,
            content: content,
            contentChecksum: checksum,
            rawHTMLFilename: "\(chapterIndex).raw.html",
            normalizedHTMLFilename: "\(chapterIndex).normalized.xhtml",
            savedAt: savedAt,
            state: .cached,
            failureReason: nil
        )
        ReaderTelemetry.shared.log(
            "chapter_package_ready",
            attributes: [
                "bookId": bookId.uuidString,
                "chapterIndex": "\(chapterIndex)",
                "title": String(package.renderTitle.prefix(80)),
                "contentLength": "\(content.count)",
            ]
        )
        return ChapterBuildResult(package: package, rawHTML: rawHTML, normalizedHTML: normalizedHTML)
    }

    static func resolveContent(
        parsed: ChapterParsePayload,
        replaceRules: String,
        fetchViaJS: @escaping @Sendable () async throws -> String?,
        fetchBySelectors: @escaping @Sendable () async throws -> String?
    ) async -> String {
        let chapterTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var content = sanitizeResolvedContent(parsed.content, title: chapterTitle)

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !parsed.isPay {
            do {
                if let fallback = try await fetchViaJS() {
                    content = sanitizeResolvedContent(fallback, title: chapterTitle)
                }
            } catch {}
        }

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !parsed.isPay {
            do {
                if let fallback = try await fetchBySelectors() {
                    content = sanitizeResolvedContent(fallback, title: chapterTitle)
                }
            } catch {}
        }

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsed.isPay {
            content = "[付費章節]"
        }

        content = normalizeLegadoContent(content)

        if !replaceRules.isEmpty {
            content = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: "\n")
            content = DefaultWebNovelParserService.shared.applyReplaceRegex(content, rules: replaceRules)
            content = content
                .components(separatedBy: .newlines)
                .map { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? "" : "　　" + trimmed
                }
                .joined(separator: "\n")
        }

        content = sanitizeResolvedContent(content, title: chapterTitle)

        let finalNormalizedTitle = chapterTitle
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        let finalNormalizedContent = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        if finalNormalizedContent.isEmpty {
            return ""
        }
        if !finalNormalizedTitle.isEmpty && finalNormalizedContent == finalNormalizedTitle {
            return ""
        }
        return content
    }

    private static func normalizeLegadoContent(_ text: String) -> String {
        var output = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty { return "" }
        if output.contains("<") {
            output = stripHtmlToText(output)
        } else {
            output = output.replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            output = output.replacingOccurrences(of: "&ensp;", with: " ", options: .caseInsensitive)
            output = output.replacingOccurrences(of: "&emsp;", with: " ", options: .caseInsensitive)
            output = output.replacingOccurrences(of: "&thinsp;", with: "", options: .caseInsensitive)
            output = output.replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            output = output.replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            output = output.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            output = output.replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            output = output.replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
        }
        while output.contains("\n\n\n") {
            output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeResolvedContent(_ text: String?, title: String) -> String {
        let normalized = normalizeLegadoContent(text ?? "")
        guard !normalized.isEmpty else { return "" }
        if looksLikeRejectedChapterPage(normalized, title: title) {
            return ""
        }
        return normalized
    }

    private static func looksLikeRejectedChapterPage(_ text: String, title: String) -> Bool {
        let compact = text
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
        let compactTitle = title
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

        let isIISRuntimeError =
            (
                compact.contains("应用程序中的服务器错误")
                    || compact.contains("應用程式中的伺服器錯誤")
                    || compact.contains("servererrorin'/'application")
                    || compact.contains("servererrorin/application")
            )
            && (
                compact.contains("运行时错误")
                    || compact.contains("運行時錯誤")
                    || compact.contains("runtimeerror")
                    || compact.contains("web.config")
                    || compact.contains("defaultredirect")
            )

        if isIISRuntimeError {
            return true
        }

        let isReadModeHint =
            compact.contains("如遇到章节错误")
            && (
                compact.contains("关闭浏览器的阅读/畅读/小说模式")
                    || compact.contains("關閉瀏覽器的閱讀/暢讀/小說模式")
                    || (
                        compact.contains("阅读/畅读/小说模式")
                            || compact.contains("閱讀/暢讀/小說模式")
                    )
            )
            && (
                compact.contains("关闭广告屏蔽过滤功能")
                    || compact.contains("關閉廣告屏蔽過濾功能")
            )

        if isReadModeHint {
            return true
        }

        // 嚴格模式：只有帶精確 Cloudflare challenge 特徵的頁面才拒絕
        let isCloudflareChallenge =
            compact.contains("checkingyourbrowserbeforeaccessing")
            || compact.contains("verifyyouarehuman")
            || compact.contains("cf-browser-verification")
            || (compact.contains("attentionrequired") && compact.contains("cf-ray"))

        // 僅含 "cloudflare" 字眼不足以判定，需配合其他驗證特徵
        let hasCloudflareMention = compact.contains("cloudflare")
        let hasChallengeKeyword =
            compact.contains("人机验证") || compact.contains("人機驗證")
            || compact.contains("checkyourbrowser") || compact.contains("ddos")

        let isHumanVerification =
            isCloudflareChallenge
            || (hasCloudflareMention && hasChallengeKeyword)
            || (compact.contains("访问异常") && compact.contains("验证"))
            || (compact.contains("訪問異常") && compact.contains("驗證"))

        if isHumanVerification {
            return true
        }

        if !compactTitle.isEmpty && compact == compactTitle {
            return true
        }

        return false
    }

    static func isRejectedChapterContent(_ text: String, title: String) -> Bool {
        looksLikeRejectedChapterPage(text, title: title)
    }

    static func extractWebContentSinglePage(html: String, pageURL: String) async -> String {
        let parserContent = WebNovelParser.extractContent(html: html, pageURL: pageURL)
        if parserContent.count >= 120 {
            return parserContent
        }

        let articleTask = Task { @MainActor in
            try? await WebViewFetcher.shared.extractArticle(html: html, baseURL: pageURL)
        }
        let article = await articleTask.value
        if let text = article, text.count >= 200 {
            return text
        }

        let knownSelectors = [
            "#chaptercontent", "#chapter-content", "#chapterContent",
            ".chapter-content", ".read-content", "#readcontent",
            ".txtnav", "#htmlContent", ".BookText", "#BookText",
            "#content", ".content", "#read_content", ".read_content",
            ".readArea", ".novel-text", "#novelcontent",
            "#bookContent", "#articleBody", ".article-body",
            "#read", ".txt", "#txt", ".article", "#article",
            ".novel_content", "#novel_content", ".chapter_content",
            "article",
        ]

        var bestSelector = ""
        for selector in knownSelectors {
            let text = DefaultWebNovelParserService.shared.extractValue(
                fromHTML: html, rule: selector + "@text", baseURL: pageURL
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > bestSelector.count { bestSelector = trimmed }
        }
        if bestSelector.count >= 200 {
            return bestSelector
        }

        return html.strippedHTML
    }

    static func extractNextPageURL(html: String, currentURL: String, baseURL: String) -> String {
        guard let baseUrlObj = URL(string: baseURL.isEmpty ? currentURL : baseURL) else {
            return ""
        }

        let linkRelNext = #"<link[^>]+rel=["']next["'][^>]+href=["']([^"']+)["']"#
        let linkHrefFirst = #"<link[^>]+href=["']([^"']+)["'][^>]+rel=["']next["']"#
        for pattern in [linkRelNext, linkHrefFirst] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                match.numberOfRanges > 1,
                let range = Range(match.range(at: 1), in: html)
            {
                let href = String(html[range]).trimmingCharacters(in: .whitespaces)
                if !href.isEmpty, !href.hasPrefix("javascript:") {
                    return DefaultWebNovelParserService.shared.resolveURL(
                        href,
                        base: baseUrlObj.absoluteString
                    )
                }
            }
        }

        let hrefPattern =
            #"<a\s[^>]*href=["']([^"']+)["'][^>]*>[^<]*?(?:下一[頁页]|下一页|Next\s*Page|next\s*page)[^<]*</a>"#
        if let regex = try? NSRegularExpression(pattern: hrefPattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: html)
        {
            let href = String(html[range]).trimmingCharacters(in: .whitespaces)
            if !href.isEmpty, !href.hasPrefix("javascript:") {
                return DefaultWebNovelParserService.shared.resolveURL(
                    href,
                    base: baseUrlObj.absoluteString
                )
            }
        }

        if let cur = URL(string: currentURL),
            let comp = URLComponents(url: cur, resolvingAgainstBaseURL: false),
            let queryItems = comp.queryItems
        {
            let pageParam = queryItems.first {
                $0.name.lowercased() == "page" || $0.name == "p" || $0.name == "index"
            }
            if let param = pageParam, let num = Int(param.value ?? ""), num >= 1 {
                let nextNum = String(num + 1)
                let pattern = "href=[\"']([^\"']*[?&](?:page|p|index)=" + nextNum + "[^\"']*)[\"']"
                if let regex = try? NSRegularExpression(pattern: pattern),
                    let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                    match.numberOfRanges > 1,
                    let range = Range(match.range(at: 1), in: html)
                {
                    let href = String(html[range]).trimmingCharacters(in: .whitespaces)
                    if !href.isEmpty {
                        return DefaultWebNovelParserService.shared.resolveURL(
                            href,
                            base: baseUrlObj.absoluteString
                        )
                    }
                }
            }
        }

        return ""
    }

    private static func stripHtmlToText(_ html: String) -> String {
        var s = html
        if let scriptRegex = try? NSRegularExpression(
            pattern: "<(script|style|noscript)[^>]*>[\\s\\S]*?</\\1>",
            options: .caseInsensitive
        ) {
            s = scriptRegex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: ""
            )
        }
        if let brRegex = try? NSRegularExpression(pattern: "<br\\s*/?>", options: .caseInsensitive) {
            s = brRegex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n"
            )
        }
        if let blockCloseRegex = try? NSRegularExpression(
            pattern: "</(?:p|div|li|blockquote|section|article|dt|dd|figcaption|pre|header|footer|tr)>",
            options: .caseInsensitive
        ) {
            s = blockCloseRegex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n"
            )
        }
        if let headingCloseRegex = try? NSRegularExpression(pattern: "</h[1-6]>", options: .caseInsensitive) {
            s = headingCloseRegex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "\n"
            )
        }
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            s = regex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: ""
            )
        }
        if let nbspRegex = try? NSRegularExpression(pattern: "(&nbsp;)+", options: .caseInsensitive) {
            s = nbspRegex.stringByReplacingMatches(
                in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " "
            )
        }
        s = s.replacingOccurrences(of: "&ensp;", with: " ", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&emsp;", with: " ", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&thinsp;", with: "", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&zwnj;", with: "", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&zwj;", with: "", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "\u{2009}", with: "")
        s = s.replacingOccurrences(of: "\u{200C}", with: "")
        s = s.replacingOccurrences(of: "\u{200D}", with: "")
        s = s.replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&#x27;", with: "'", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&hellip;", with: "…", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&mdash;", with: "—", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&ndash;", with: "–", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&lsquo;", with: "\u{2018}", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&rsquo;", with: "\u{2019}", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&ldquo;", with: "\u{201C}", options: .caseInsensitive)
        s = s.replacingOccurrences(of: "&rdquo;", with: "\u{201D}", options: .caseInsensitive)

        if let numericRegex = try? NSRegularExpression(pattern: #"&#(\d+);"#) {
            var result = ""
            var searchStart = s.startIndex
            numericRegex.enumerateMatches(in: s, range: NSRange(s.startIndex..., in: s)) { match, _, _ in
                guard let match,
                    let fullRange = Range(match.range, in: s),
                    let numRange = Range(match.range(at: 1), in: s)
                else { return }
                result += s[searchStart..<fullRange.lowerBound]
                if let code = UInt32(s[numRange]), let scalar = Unicode.Scalar(code) {
                    result += String(Character(scalar))
                } else {
                    result += s[fullRange]
                }
                searchStart = fullRange.upperBound
            }
            result += s[searchStart...]
            s = result
        }

        if let hexRegex = try? NSRegularExpression(pattern: #"&#[xX]([0-9a-fA-F]+);"#) {
            var result = ""
            var searchStart = s.startIndex
            hexRegex.enumerateMatches(in: s, range: NSRange(s.startIndex..., in: s)) { match, _, _ in
                guard let match,
                    let fullRange = Range(match.range, in: s),
                    let hexRange = Range(match.range(at: 1), in: s)
                else { return }
                result += s[searchStart..<fullRange.lowerBound]
                if let code = UInt32(s[hexRange], radix: 16), let scalar = Unicode.Scalar(code) {
                    result += String(Character(scalar))
                } else {
                    result += s[fullRange]
                }
                searchStart = fullRange.upperBound
            }
            result += s[searchStart...]
            s = result
        }

        while s.contains("\n\n\n") {
            s = s.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanChapterContent(_ text: String) -> String {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return raw }

        let removePatterns: [(String, String)] = [
            (#"本章未完，請點擊下一頁繼續閱讀"#, ""),
            (#"本章未完，请点击下一页继续阅读"#, ""),
            (#"請記住本書首發域名：[^\s]+\.(com|net|org|cn|cc|cx|pro)"#, ""),
            (#"请记住本书首发域名：[^\s]+\.(com|net|org|cn|cc|cx|pro)"#, ""),
            (#"請記住本站域名[^\n]*"#, ""),
            (#"请记住本站域名[^\n]*"#, ""),
        ]
        for (pattern, replacement) in removePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                raw = regex.stringByReplacingMatches(
                    in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: replacement
                )
            }
        }

        raw = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if raw.contains("<") {
            raw = stripHtmlToText(raw)
        }

        var lines = raw.components(separatedBy: .newlines)
        let adPatterns: [String] = [
            #"請記住本站域名|请记住本站|記住本站|本站域名"#,
            #"支持正版閱讀|支援正版閱讀|請支持正版|請到.*訂閱本書"#,
            #"最新章節請到|防盜章節"#,
            #"一秒記住|一秒记住|一秒钟记住"#,
            #"chaptererror|chapter\s*error"#,
            #"最新網址|最新网址"#,
            #"^\s*https?://\S+\s*$"#,
            #"^[\s\u{3000}\.\-_\*]{0,5}$"#,
            #"^(上一章|下一章|上一頁|下一页|返回目錄|返回目录)\s*$"#,
        ]
        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return false }
            for pattern in adPatterns {
                if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                    regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
                {
                    return false
                }
            }
            return true
        }

        if let regex = try? NSRegularExpression(pattern: #"^(.{5,}?)\s{1,8}\1$"#) {
            lines = lines.map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count >= 10 else { return line }
                if let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                    match.numberOfRanges > 1,
                    let range = Range(match.range(at: 1), in: trimmed)
                {
                    return String(trimmed[range])
                }
                return line
            }
        }

        let dateRegex = try? NSRegularExpression(pattern: #"^\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?$"#)
        let chapTitleRegex = try? NSRegularExpression(
            pattern: #"^第\s*[\d零一二三四五六七八九十百千萬万]+\s*[章回卷節节篇部]"#
        )
        var dropCount = 0
        for line in lines.prefix(15) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                dropCount += 1
                continue
            }
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if dateRegex?.firstMatch(in: trimmed, range: range) != nil {
                dropCount += 1
                continue
            }
            if trimmed.hasPrefix("作者") || trimmed.hasPrefix("作 者") {
                dropCount += 1
                continue
            }
            if trimmed.count < 60, chapTitleRegex?.firstMatch(in: trimmed, range: range) != nil {
                dropCount += 1
                continue
            }
            break
        }
        if dropCount > 0 {
            lines = Array(lines.dropFirst(dropCount))
        }

        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return false }
            if trimmed.count < 60 && trimmed.components(separatedBy: ">").count >= 3 { return false }
            if trimmed.count < 30 && trimmed.contains("收藏")
                && (trimmed.contains("目录") || trimmed.contains("目錄") || trimmed.contains("设置") || trimmed.contains("設置"))
            {
                return false
            }
            return true
        }

        var result: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let previous = result.last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed != previous || trimmed.isEmpty {
                result.append(line)
            }
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
