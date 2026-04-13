import CryptoKit
import Foundation
import SwiftSoup

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

struct ChapterFetcher {
    let parserService: WebNovelParserService

    init(parserService: WebNovelParserService = DefaultWebNovelParserService.shared) {
        self.parserService = parserService
    }

    static let shared = ChapterFetcher()

    func buildNormalizedHTML(title: String, content: String) -> String {
        let paragraphLines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return ReaderHTMLUtilities.normalizedChapterHTML(
            title: title,
            paragraphs: paragraphLines
        )
    }

    func buildRenderableNormalizedHTML(
        title: String,
        plainTextContent: String,
        rawHTMLContent: String?
    ) -> String {
        guard
            let rawHTMLContent,
            !rawHTMLContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            Self.containsLikelyHTMLTags(rawHTMLContent),
            let document = try? SwiftSoup.parse(rawHTMLContent),
            let body = document.body()
        else {
            return buildNormalizedHTML(title: title, content: plainTextContent)
        }

        _ = try? body.select("script,noscript,iframe,object,embed").remove()
        let bodyHTML = ((try? body.html()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bodyHTML.isEmpty else {
            return buildNormalizedHTML(title: title, content: plainTextContent)
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedTitle = ReaderHTMLUtilities.escapeHTML(trimmedTitle.isEmpty ? "Untitled" : trimmedTitle)
        let heading = trimmedTitle.isEmpty
            ? ""
            : "<h1>\(ReaderHTMLUtilities.escapeHTML(trimmedTitle))</h1>\n"

        return """
        <!DOCTYPE html>
        <html lang="zh-Hant">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>\(escapedTitle)</title>
        </head>
        <body>
        <article id="reader-content">
        \(heading)\(bodyHTML)
        </article>
        </body>
        </html>
        """
    }

    private static func containsLikelyHTMLTags(_ text: String) -> Bool {
        if text.contains("<img") || text.contains("<p") || text.contains("<div") || text.contains("<span") {
            return true
        }
        guard let regex = try? NSRegularExpression(pattern: "<[a-zA-Z][^>]*>") else {
            return false
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }

    func parseChapterRequest(_ raw: String) -> ChapterRequestSpec {
        LegadoRequestParser.parseChapterRequest(raw)
    }

    func merge(_ current: ChapterParsePayload, _ next: ChapterParsePayload) -> ChapterParsePayload {
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

    func fetchPaginatedContent(
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

    func buildChapterPackage(
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
        let effectiveTitle = canonicalTitle.isEmpty ? tocTitle : canonicalTitle
        let normalizedHTML = buildRenderableNormalizedHTML(
            title: effectiveTitle,
            plainTextContent: content,
            rawHTMLContent: parsed.content
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

    func resolveContent(
        parsed: ChapterParsePayload,
        replaceRules: String,
        fetchViaJS: @escaping @Sendable () async throws -> String?,
        fetchBySelectors: @escaping @Sendable () async throws -> String?
    ) async -> String {
        let chapterTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var content = Self.sanitizeResolvedContent(parsed.content, title: chapterTitle)

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !parsed.isPay {
            do {
                if let fallback = try await fetchViaJS() {
                    content = Self.sanitizeResolvedContent(fallback, title: chapterTitle)
                }
            } catch {}
        }

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !parsed.isPay {
            do {
                if let fallback = try await fetchBySelectors() {
                    content = Self.sanitizeResolvedContent(fallback, title: chapterTitle)
                }
            } catch {}
        }

        if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsed.isPay {
            content = "[付費章節]"
        }

        content = Self.normalizeLegadoContent(content)

        if !replaceRules.isEmpty {
            content = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: "\n")
            content = parserService.applyReplaceRegex(content, rules: replaceRules)
            content = content
                .components(separatedBy: .newlines)
                .map { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? "" : "　　" + trimmed
                }
                .joined(separator: "\n")
        }

        content = Self.sanitizeResolvedContent(content, title: chapterTitle)

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
            output = Self.stripHtmlToText(output)
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
        let normalized = Self.normalizeLegadoContent(text ?? "")
        guard !normalized.isEmpty else { return "" }
        if Self.looksLikeRejectedChapterPage(normalized, title: title) {
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

    func isRejectedChapterContent(_ text: String, title: String) -> Bool {
        Self.looksLikeRejectedChapterPage(text, title: title)
    }

    func extractWebContentSinglePage(html: String, pageURL: String) async -> String {
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
            let text = parserService.extractValue(
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

    func extractNextPageURL(html: String, currentURL: String, baseURL: String) -> String {
        NextPageLinkExtractor.extractNextPageURL(
            html: html,
            currentURL: currentURL,
            baseURL: baseURL,
            resolveURL: { [parserService] href, base in
                parserService.resolveURL(href, base: base)
            }
        )
    }

    private static func stripHtmlToText(_ html: String) -> String {
        stripHtmlToTextUsingSwiftSoup(html) ?? html.strippedHTML
    }

    private static func stripHtmlToTextUsingSwiftSoup(_ html: String) -> String? {
        guard let document = try? SwiftSoup.parse(html), let body = document.body() else {
            return nil
        }

        _ = try? document.select("script,style,noscript,iframe,object,embed").remove()

        let lineBreakMarker = "__YUEDU_LINE_BREAK__"
        let lineBreakSelectors =
            "br,p,div,li,blockquote,section,article,dt,dd,figcaption,pre,header,footer,tr,h1,h2,h3,h4,h5,h6"
        if let nodes = try? document.select(lineBreakSelectors).array() {
            for node in nodes {
                try? node.appendText(lineBreakMarker)
            }
        }

        var text = (try? body.text()) ?? (try? document.text()) ?? ""
        text = text.replacingOccurrences(of: lineBreakMarker, with: "\n")
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func cleanChapterContent(_ text: String) -> String {
        ChapterContentCleaner.cleanChapterContent(text, htmlToText: Self.stripHtmlToText)
    }
}
