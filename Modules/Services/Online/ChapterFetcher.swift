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
    var webViewDelayMs: Int = 0
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
    static let shared = ChapterFetcher()

    func buildNormalizedHTML(title: String, content: String) -> String {
        return ReaderHTMLUtilities.normalizedChapterHTML(
            title: title,
            paragraphs: ReaderHTMLUtilities.paragraphs(fromPlainText: content)
        )
    }

    func buildRenderableNormalizedHTML(
        title: String,
        plainTextContent: String,
        rawHTMLContent: String?,
        reviewContext: ReaderHTMLUtilities.LegadoReviewContext? = nil
    ) async -> String {
        let raw = rawHTMLContent ?? ""
        let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksHTML = !rawTrimmed.isEmpty && Self.containsLikelyHTMLTags(raw)
        AppLogger.parse("⟐ buildRenderableNormalizedHTML", context: [
            "title": title,
            "branch": looksHTML ? "HTML(SwiftSoup)" : "PLAIN(escaped)",
            "rawLen": rawTrimmed.count,
            "plainLen": plainTextContent.count,
            "hasImg": raw.contains("<img"),
            "hasDataImg": raw.contains("data:image"),
            "hasUsehtml": raw.range(of: "usehtml", options: .caseInsensitive) != nil,
            "rawComment": Self.countOccurrences(of: "<comment", in: raw, caseInsensitive: true),
            "rawShowCmt": Self.countOccurrences(of: "showCmt", in: raw, caseInsensitive: true),
            "rawAndroidShowCmt": Self.countOccurrences(of: "androidshowCmt", in: raw, caseInsensitive: true),
            "rawYdreview": Self.countOccurrences(of: "ydreview://", in: raw, caseInsensitive: true),
            "plainYdreview": Self.countOccurrences(of: "ydreview://", in: plainTextContent, caseInsensitive: true),
            "rawHead": String(rawTrimmed.prefix(240))
        ])
        guard looksHTML else {
            return buildNormalizedHTML(title: title, content: plainTextContent)
        }
        let originalRawHTML = raw

        // Clean Legado data-URI click-config suffixes (`,{json}`) and unwrap <usehtml> first,
        // otherwise the unbalanced quotes inside the suffix break SwiftSoup's attribute parsing
        // and the rest of the chapter leaks out as literal text.
        let cleanedRawHTML = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(
            originalRawHTML,
            reviewContext: reviewContext
        )

        // ⟐ sanitizeClickConfig — show whether the `,{json}` click-config suffix is actually
        // stripped at fetch time. rawCommas vs cleanCommas: if cleanCommas > 0 the suffix
        // SURVIVED → SwiftSoup will break on it. `sample` shows the surviving suffix + the
        // char right after it (reveals why the strip regex's lookahead missed it).
        AppLogger.parse("⟐ sanitizeClickConfig", context: [
            "title": title,
            "rawCommas": Self.countOccurrences(of: ",{", in: originalRawHTML),
            "cleanCommas": Self.countOccurrences(of: ",{", in: cleanedRawHTML),
            "rawImg": Self.countOccurrences(of: "<img", in: originalRawHTML, caseInsensitive: true),
            "cleanImg": Self.countOccurrences(of: "<img", in: cleanedRawHTML, caseInsensitive: true),
            "rawSample": Self.clickConfigSample(in: originalRawHTML),
            "cleanSample": Self.clickConfigSample(in: cleanedRawHTML)
        ])

        // Rewrite Legado iOS paragraph-review markers into anchors before parsing, so the
        // markers survive the SwiftSoup round-trip regardless of how <comment> is handled.
        // Then, if the content is newline-separated plain-text paragraphs with only inline runs
        // (no block tags) — e.g. 段評-injected content joins paragraphs with "\n" + inline bubble
        // <img>s — wrap each line in <p> so SwiftSoup doesn't collapse the breaks into one block.
        let rawHTMLContent = ReaderHTMLUtilities.wrapNewlineParagraphsIfNeeded(
            ReaderHTMLUtilities.rewriteReviewComments(cleanedRawHTML)
        )
        AppLogger.parse("⟐ reviewHTML rewrite", context: [
            "title": title,
            "cleanLen": cleanedRawHTML.count,
            "outLen": rawHTMLContent.count,
            "cleanComment": Self.countOccurrences(of: "<comment", in: cleanedRawHTML, caseInsensitive: true),
            "outComment": Self.countOccurrences(of: "<comment", in: rawHTMLContent, caseInsensitive: true),
            "outYdreview": Self.countOccurrences(of: "ydreview://", in: rawHTMLContent, caseInsensitive: true),
            "reviewImage": Self.countOccurrences(of: "yd-review-image", in: rawHTMLContent, caseInsensitive: true),
            "clickConfig": Self.countOccurrences(of: ",{", in: originalRawHTML),
            "outHead": String(rawHTMLContent.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240))
        ])

        // SwiftSoup.parse is CPU-intensive synchronous work AND degrades to a hang on the ~275KB
        // of inline base64 SVG a 段評-heavy 起点 chapter carries (96 bubbles). The base64 payloads
        // are opaque to structural parsing, so lift them out, parse the slimmed (~few-KB) HTML,
        // then restore — keeps SwiftSoup's cleaning behavior without feeding it the bloat.
        // Run in a detached task to avoid blocking the cooperative thread pool.
        let (slimmedHTML, payloadRestore) = ReaderHTMLUtilities.extractDataURIPayloads(rawHTMLContent)
        let bodyHTMLSlim = await Task.detached(priority: .userInitiated) {
            guard let document = try? SwiftSoup.parse(slimmedHTML),
                  let body = document.body() else { return "" }
            _ = try? body.select("script,noscript,iframe,object,embed").remove()
            return ((try? body.html()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        let bodyHTML = ReaderHTMLUtilities.restoreDataURIPayloads(bodyHTMLSlim, restore: payloadRestore)

        guard !bodyHTML.isEmpty else {
            return buildNormalizedHTML(title: title, content: plainTextContent)
        }

        // A chapter title may carry a 本章说 comment bubble appended as a bare `data:image/...` URI
        // (起點: `titleRow = title + Bubble`). Split it off so the text becomes the heading and the
        // bubble is rendered as the source's image (text-sized, like body 段評), not literal text.
        let (titleTextPart, titleBubbleHTML) = Self.splitTitleBubble(title, reviewContext: reviewContext)
        let trimmedTitle = ReaderHTMLUtilities.displayText(fromHTMLFragment: titleTextPart)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let escapedTitle = ReaderHTMLUtilities.escapeHTML(trimmedTitle.isEmpty ? "Untitled" : trimmedTitle)
        let heading = (trimmedTitle.isEmpty && titleBubbleHTML == nil)
            ? ""
            : "<h1>\(ReaderHTMLUtilities.escapeHTML(trimmedTitle))\(titleBubbleHTML ?? "")</h1>\n"

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

    /// Splits a chapter title into its text part and an optional comment-bubble `<img>` HTML.
    /// 起點 appends a 本章说 bubble to the title as a bare `data:image/...,{clickconfig}` URI; we
    /// wrap that into an `<img>` and run it through the same sanitizer as body bubbles (strips the
    /// click-config suffix, adds the review anchor + text-size marker). Returns `(title, nil)` when
    /// no bubble is present.
    private static func splitTitleBubble(
        _ title: String,
        reviewContext: ReaderHTMLUtilities.LegadoReviewContext?
    ) -> (text: String, bubbleHTML: String?) {
        guard let r = title.range(of: "data:image") else { return (title, nil) }
        let textPart = String(title[..<r.lowerBound])
        let bubbleURI = String(title[r.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bubbleURI.isEmpty else { return (textPart, nil) }
        let sanitized = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(
            "<img src=\"\(bubbleURI)\">",
            reviewContext: reviewContext
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return (textPart, sanitized.isEmpty ? nil : sanitized)
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

    /// Returns the first `,{…}` click-config suffix plus ~60 chars of trailing context (base64
    /// collapsed), so a device log shows the exact suffix shape and the char that follows it.
    private static func clickConfigSample(in text: String) -> String {
        guard let r = text.range(of: ",{") else { return "(none)" }
        // back up ~12 chars to show the tail of the data URI, then take a window forward.
        let startIdx = text.index(r.lowerBound, offsetBy: -12, limitedBy: text.startIndex) ?? text.startIndex
        let endIdx = text.index(r.lowerBound, offsetBy: 140, limitedBy: text.endIndex) ?? text.endIndex
        let window = String(text[startIdx..<endIdx])
        return window.replacingOccurrences(
            of: #"base64,[A-Za-z0-9+/=]+"#, with: "base64,…", options: .regularExpression
        )
    }

    private static func countOccurrences(
        of needle: String,
        in text: String,
        caseInsensitive: Bool = false
    ) -> Int {
        guard !needle.isEmpty, !text.isEmpty else { return 0 }
        let haystack = caseInsensitive ? text.lowercased() : text
        let target = caseInsensitive ? needle.lowercased() : needle
        return max(0, haystack.components(separatedBy: target).count - 1)
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
        replaceRuleScope: String = "",
        reviewContext: ReaderHTMLUtilities.LegadoReviewContext? = nil,
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
            sourceUrl: ReplaceRuleScope.resolve(
                chapterURL: sourceURL,
                bookSourceURL: replaceRuleScope
            ),
            fetchViaJS: fetchViaJS,
            fetchBySelectors: fetchBySelectors
        )
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FetchError.emptyContent
        }
        let canonicalTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = canonicalTitle.isEmpty ? tocTitle : canonicalTitle
        let effectiveReviewContext = reviewContext?.withRuntimeVariables(parsed.runtimeVariables)
        let normalizedHTML = await buildRenderableNormalizedHTML(
            title: effectiveTitle,
            plainTextContent: content,
            rawHTMLContent: parsed.content,
            reviewContext: effectiveReviewContext
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
        sourceUrl: String = "",
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

        // Audiobook chapters resolve to a bare media URL (or <audio> markup), not prose.
        // Text-cleanup replace rules must not run on them: the stock "水印去除" preset
        // deletes every http… token, which erased the audio URL and surfaced as
        // "Fetched empty content" in the player. Mirrors the manga-image exemption below.
        let isDirectAudio = DirectChapterAudioResolver.looksLikeAudioContent(content)

        if !replaceRules.isEmpty && !isDirectAudio {
            content = content
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: "\n")
            content = RuleEngine.applyReplaceRegex(content, rules: replaceRules)
            content = content
                .components(separatedBy: .newlines)
                .map { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? "" : "　　" + trimmed
                }
                .joined(separator: "\n")
        }

        content = Self.sanitizeResolvedContent(content, title: chapterTitle)

        // Apply user-configured global replace rules (after per-source rules).
        // Default/global text cleanup can include tag stripping; don't run it on
        // image-bearing chapters because that erases manga pages and novel illustrations.
        let globalRules = ReplaceRuleStore.shared.rules(for: sourceUrl)
        if !globalRules.isEmpty && !Self.containsContentImageTag(content) && !isDirectAudio {
            content = ReplaceRuleEngine.apply(globalRules, to: content)
        }

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
        if Self.containsContentImageTag(output) {
            return Self.preserveImageBearingHTML(output)
        }
        if output.contains("<") {
            // SwiftSoup follows HTML whitespace rules: literal CR/LF inside one block element is
            // ordinary whitespace. Promote source line breaks before extracting text so Legado
            // rules that return one `<p>` containing many paragraphs do not become one long line.
            output = output.replacingOccurrences(of: "\n", with: "<br>")
            output = Self.stripHtmlToText(output)
        } else {
            output = Self.decodeBasicHTMLEntities(output)
            if Self.containsContentImageTag(output) {
                return Self.preserveImageBearingHTML(output)
            }
        }
        while output.contains("\n\n\n") {
            output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func containsContentImageTag(_ text: String) -> Bool {
        text.range(
            of: #"<\s*(?:img|image)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func preserveImageBearingHTML(_ html: String) -> String {
        var output = html
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&ensp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&emsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&thinsp;", with: "", options: .caseInsensitive)
        output = output.replacingOccurrences(
            of: #"(?is)<(script|style|noscript|iframe|object|embed)\b[^>]*>.*?</\1\s*>"#,
            with: "",
            options: .regularExpression
        )
        output = output.replacingOccurrences(
            of: #"(?is)<(script|style|noscript|iframe|object|embed)\b[^>]*>"#,
            with: "",
            options: .regularExpression
        )
        while output.contains("\n\n\n") {
            output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeBasicHTMLEntities(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&nbsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&ensp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&emsp;", with: " ", options: .caseInsensitive)
            .replacingOccurrences(of: "&thinsp;", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "&lt;", with: "<", options: .caseInsensitive)
            .replacingOccurrences(of: "&gt;", with: ">", options: .caseInsensitive)
            .replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
            .replacingOccurrences(of: "&quot;", with: "\"", options: .caseInsensitive)
            .replacingOccurrences(of: "&apos;", with: "'", options: .caseInsensitive)
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

        // Strict mode: only reject pages with precise Cloudflare challenge signatures
        let isCloudflareChallenge =
            compact.contains("checkingyourbrowserbeforeaccessing")
            || compact.contains("verifyyouarehuman")
            || compact.contains("cf-browser-verification")
            || (compact.contains("attentionrequired") && compact.contains("cf-ray"))

        // "cloudflare" alone is insufficient; require additional verification keywords
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
        let parserContentIsCollapsed = ReaderHTMLUtilities.isLikelyCollapsedChapterText(parserContent)
        if parserContent.count >= 120,
           !parserContentIsCollapsed {
            return parserContent
        }

        let localHTMLContent = Self.extractLocalHTMLContent(html: html, pageURL: pageURL)
        if parserContentIsCollapsed, localHTMLContent.count >= 80 {
            return localHTMLContent
        }

        let articleTask = Task { @MainActor in
            try? await WebViewFetcher.shared.extractArticle(html: html, baseURL: pageURL)
        }
        let article = await articleTask.value
        if let text = article,
           text.count >= 200,
           !ReaderHTMLUtilities.isLikelyCollapsedChapterText(text) {
            return text
        }

        if localHTMLContent.count >= 80 {
            return localHTMLContent
        }

        return localHTMLContent.isEmpty ? html.strippedHTML : localHTMLContent
    }

    private static func extractLocalHTMLContent(html: String, pageURL: String) -> String {
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
            let selectorHTML = RuleEngine.extractValue(
                fromHTML: html, rule: selector + "@html", baseURL: pageURL
            )
            let trimmed = Self.stripHtmlToText(selectorHTML).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > bestSelector.count { bestSelector = trimmed }
        }
        if bestSelector.count >= 80 {
            return bestSelector
        }

        let fallback = Self.stripHtmlToText(html).trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback
    }

    func extractNextPageURL(html: String, currentURL: String, baseURL: String) -> String {
        NextPageLinkExtractor.extractNextPageURL(
            html: html,
            currentURL: currentURL,
            baseURL: baseURL,
            resolveURL: { href, base in
                RuleEngine.resolveURL(href, base: base)
            }
        )
    }

    private static func stripHtmlToText(_ html: String) -> String {
        stripHtmlToTextUsingSwiftSoup(html) ?? ""
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
                _ = try? node.appendText(lineBreakMarker)
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
