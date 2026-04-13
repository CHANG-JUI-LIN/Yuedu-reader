import Combine
import CryptoKit
import Foundation

// MARK: - 書源網路請求 + 快取

private final class RuntimeVariableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]?

    init(_ initial: [String: String]?) {
        storage = initial
    }

    func get() -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: [String: String]?) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

// #region agent log
private func _dbgLog(_ msg: String, data: [String: Any] = [:], hyp: String = "A") {
    _ = msg
    _ = data
    _ = hyp
}
// #endregion

/// 安全建立 URL：若 `URL(string:)` 因未編碼字元（如中文）而失敗，嘗試 percent-encoding 後重試
private func safeURL(string raw: String) -> URL? {
    if let url = URL(string: raw) { return url }
    // 部分 Legado 書源回傳的章節 URL 含有未編碼中文或特殊字元
    if let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
       let url = URL(string: encoded) { return url }
    return nil
}

actor BookSourceFetcher {
    /// 供外部呼叫的 debug 日誌（驗證日誌管道）
    static func debugLog(_ msg: String, data: [String: Any] = [:]) {
        _ = msg
        _ = data
    }
    static let shared = BookSourceFetcher()
    private nonisolated static let chapterCacheRepository = ChapterCacheRepository()
    private let pipeline = BookSourceParsingPipeline()

    private enum FetchTimeoutError: LocalizedError {
        case chapterTimeout

        var errorDescription: String? {
            switch self {
            case .chapterTimeout:
                return "章節載入超時"
            }
        }
    }

    private init() {}

    // MARK: - 搜索書籍

    func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        guard !source.searchUrl.isEmpty else { throw FetchError.noSearchURL }

        let requestSpec = source.renderSearchRequest(query: query)
        let resolvedUrlStr = DefaultWebNovelParserService.shared.resolveURL(
            requestSpec.url,
            base: source.bookSourceUrl
        )
        guard let url = safeURL(string: resolvedUrlStr) else {
            throw FetchError.invalidURL(resolvedUrlStr)
        }
        let mergedHeaders = source.parsedHeaders.merging(requestSpec.headers) { _, new in new }

        let html: String
        do {
            if source.needsWebView || requestSpec.useWebView {
                html = try await Self.fetchViaWebView(url: url, headers: mergedHeaders)
            } else {
                html = try await fetchHTML(
                    url: url, method: requestSpec.method, body: requestSpec.body,
                    headers: mergedHeaders, baseURL: source.bookSourceUrl,
                    bodyCharset: requestSpec.charset,
                    allowInteractiveChallengeOn503: false)
            }
        } catch let err as FetchError {
            // 書源已驗證仍失敗：編碼或站點回傳 4xx/5xx 時視為「無結果」不計入失敗
            switch err {
            case .encodingError:
                return []
            case .httpError(let code) where [401, 403, 404, 429, 500, 502, 503].contains(code):
                return []
            case .emptyContent:
                return []
            default:
                throw err
            }
        } catch {
            // 網路錯誤、WebView 超時等：視為無結果，避免大量失敗計數
            return []
        }

        // Legado loginCheckJs：搜尋回應後執行，若回傳需登入則不解析、直接回傳空結果
        if !source.loginCheckJs.isEmpty {
            let needLogin = try await WebViewFetcher.shared.evaluateInHTML(
                html: html, baseURL: url.absoluteString, js: source.loginCheckJs)
            if needLogin {
                return []
            }
        }

        let books: [OnlineBook]
        do {
            books = try pipeline.parseSearchResults(
                html: html, baseURL: url.absoluteString, source: source)
        } catch {
            return []
        }
        return filterSearchResultsByCheckKeyWord(
            books, query: query, checkKeyWord: source.ruleSearch.checkKeyWord)
    }

    /// Legado 相容：依 checkKeyWord 過濾搜尋結果（僅保留書名/作者含關鍵字的項）
    private func filterSearchResultsByCheckKeyWord(
        _ books: [OnlineBook], query: String, checkKeyWord: String
    ) -> [OnlineBook] {
        guard !checkKeyWord.isEmpty, !query.isEmpty else { return books }
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return books }
        return books.filter { book in
            book.name.localizedCaseInsensitiveContains(key)
                || book.author.localizedCaseInsensitiveContains(key)
        }
    }

    // MARK: - 獲取書籍詳情

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> OnlineBook {
        let package = try await fetchBookInfoPackage(
            url: url,
            source: source,
            runtimeVariables: runtimeVariables
        )
        return package.onlineBook
    }

    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> BookInfoPackage {
        if let cached = loadBookInfoPackageSync(url: url, source: source) {
            return cached
        }
        // #region agent log
        _dbgLog(
            "fetchBookInfo 進入",
            data: ["url": String(url.prefix(80)), "source": source.bookSourceName], hyp: "A")
        // #endregion
        guard let bookURL = safeURL(string: url) else { throw FetchError.invalidURL(url) }
        let html: String
        if source.needsWebView {
            html = try await Self.fetchViaWebView(url: bookURL, headers: source.parsedHeaders)
        } else {
            html = try await fetchHTML(
                url: bookURL, method: "GET", body: nil,
                headers: source.parsedHeaders, baseURL: source.bookSourceUrl)
        }
        let info = try pipeline.parseBookInfo(
            html: html,
            bookUrl: url,
            baseURL: bookURL.absoluteString,
            source: source,
            runtimeVariables: runtimeVariables
        )
        let package = saveBookInfoPackage(
            info: info,
            source: source,
            rawHTML: html
        )
        // #region agent log
        _dbgLog(
            "fetchBookInfo 結果",
            data: [
                "source": source.bookSourceName, "author": package.author,
                "name": String(package.name.prefix(30)), "tocUrlEmpty": package.tocUrl.isEmpty,
            ], hyp: "A")
        // #endregion
        return package
    }

    // MARK: - WebView JS 渲染輔助方法

    /// 靜態方法，跳到 MainActor 執行 WKWebView 載入
    @MainActor
    private static func fetchViaWebView(url: URL, headers: [String: String]) async throws -> String
    {
        try await WebViewFetcher.shared.fetchHTML(url: url, headers: headers, timeout: 15)
    }

    // MARK: - 獲取目錄

    /// 抓取目錄（Legado 相容：ruleToc.chapterList/name/url、多頁 nextTocUrl、preUpdateJs）。
    /// 若 ruleToc.preUpdateJs 有值，會用 WebView 載入目錄頁並先執行該 JS 再取 HTML。
    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> [OnlineChapterRef] {
        let package = try await fetchTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables
        )
        return package.chapters
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> TOCPackage {
        if let cached = loadTOCPackageSync(tocUrl: tocUrl, source: source), !cached.chapters.isEmpty {
            // 檢查快取的目錄是否有殘留 HTML 片段的 URL（舊版 bug），若有則強制重新解析
            let hasBadURL = cached.chapters.contains { ch in
                ch.url.contains("<") || ch.url.contains("&lt;") || ch.url.contains("%3C")
            }
            if !hasBadURL {
                return cached
            }
        }
        // #region agent log
        _dbgLog(
            "fetchTOC 進入",
            data: [
                "tocUrl": String(tocUrl.prefix(80)),
                "source": source.bookSourceName,
                "chapterList": String(source.ruleToc.chapterList.prefix(80)),
                "chapterUrl": String(source.ruleToc.chapterUrl.prefix(40)),
                "chapterName": String(source.ruleToc.chapterName.prefix(40)),
                "needsWebView": source.needsWebView,
                "hasPreUpdateJs": !source.ruleToc.preUpdateJs.isEmpty,
            ], hyp: "T1")
        // #endregion
        // #region agent log
        if source.ruleToc.chapterList.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _dbgLog("fetchTOC chapterList 為空", data: ["source": source.bookSourceName], hyp: "H1")
        }
        // #endregion
        guard let url = safeURL(string: tocUrl) else { throw FetchError.invalidURL(tocUrl) }
        let html: String
        var usedWebView = false
        let baseForReferer = tocUrl
        if !source.ruleToc.preUpdateJs.isEmpty {
            html = try await WebViewFetcher.shared.fetchHTMLWithCustomJS(
                url: url, headers: source.parsedHeaders,
                jsAfterLoad: source.ruleToc.preUpdateJs, timeout: 20, jsWait: 2.0)
            usedWebView = true
        } else if source.needsWebView {
            html = try await Self.fetchViaWebView(url: url, headers: source.parsedHeaders)
            usedWebView = true
        } else {
            html = try await fetchHTML(
                url: url, method: "GET", body: nil,
                headers: source.parsedHeaders,
                baseURL: baseForReferer.isEmpty ? source.bookSourceUrl : baseForReferer)
        }
        // #region agent log
        _dbgLog(
            "fetchTOC 已取得 HTML",
            data: [
                "source": source.bookSourceName,
                "htmlLen": html.count,
                "htmlPreview": String(html.prefix(150)).replacingOccurrences(of: "\n", with: " "),
            ], hyp: "H2")
        // #endregion
        var chapters = try pipeline.parseTOC(
            html: html,
            baseURL: url.absoluteString,
            source: source,
            runtimeVariables: runtimeVariables
        )
        var htmlForNext = html

        // #region agent log
        _dbgLog(
            "fetchTOC 初次解析結果",
            data: [
                "source": source.bookSourceName,
                "chaptersCount": chapters.count,
                "htmlLen": html.count,
                "usedWebView": usedWebView,
                "htmlPreview": String(html.prefix(300)).replacingOccurrences(of: "\n", with: " "),
            ], hyp: "T1")
        // #endregion

        // 若 URLSession 取得空目錄，嘗試用 WebView 重試（許多站點目錄由 JS 動態載入）
        if chapters.isEmpty && !usedWebView {
            let webHtml = try await WebViewFetcher.shared.fetchHTML(
                url: url,
                headers: source.parsedHeaders,
                timeout: 20,
                jsWait: 4.0
            )
            chapters = try pipeline.parseTOC(
                html: webHtml,
                baseURL: url.absoluteString,
                source: source,
                runtimeVariables: runtimeVariables
            )
            htmlForNext = webHtml
            // #region agent log
            _dbgLog(
                "fetchTOC WebView 重試後",
                data: ["source": source.bookSourceName, "chaptersCount": chapters.count], hyp: "B")
            // #endregion
        }
        if chapters.isEmpty && usedWebView && source.ruleToc.preUpdateJs.isEmpty {
            let delayedHtml = try await WebViewFetcher.shared.fetchHTML(
                url: url,
                headers: source.parsedHeaders,
                timeout: 20,
                jsWait: 4.0
            )
            chapters = try pipeline.parseTOC(
                html: delayedHtml,
                baseURL: url.absoluteString,
                source: source,
                runtimeVariables: runtimeVariables
            )
            htmlForNext = delayedHtml
        }

        // 多頁目錄
        var rawHTMLPages: [String] = [htmlForNext]
        var nextURL = pipeline.extractNextTocURL(
            html: htmlForNext,
            baseURL: url.absoluteString,
            source: source,
            runtimeVariables: runtimeVariables
        )
        var pageCount = 0
        let usePreUpdateJs = !source.ruleToc.preUpdateJs.isEmpty
        while !nextURL.isEmpty && pageCount < 20 {
            guard let nextPageURL = URL(string: nextURL) else { break }
            let nextBase = nextURL.isEmpty ? source.bookSourceUrl : nextURL
            let nextHTML: String
            if usePreUpdateJs {
                nextHTML = try await WebViewFetcher.shared.fetchHTMLWithCustomJS(
                    url: nextPageURL, headers: source.parsedHeaders,
                    jsAfterLoad: source.ruleToc.preUpdateJs, timeout: 20, jsWait: 2.0)
            } else if source.needsWebView {
                nextHTML = try await Self.fetchViaWebView(
                    url: nextPageURL, headers: source.parsedHeaders)
            } else {
                nextHTML = try await fetchHTML(
                    url: nextPageURL, method: "GET", body: nil,
                    headers: source.parsedHeaders, baseURL: nextBase)
            }
            rawHTMLPages.append(nextHTML)
            chapters.append(
                contentsOf: try pipeline.parseTOC(
                    html: nextHTML,
                    baseURL: nextURL,
                    source: source,
                    runtimeVariables: runtimeVariables
                ))
            nextURL = pipeline.extractNextTocURL(
                html: nextHTML,
                baseURL: nextURL,
                source: source,
                runtimeVariables: runtimeVariables
            )
            pageCount += 1
        }
        let normalized = chapters.enumerated().map { i, ref in
            var r = ref
            r.index = i
            return r
        }
        let package = saveTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables,
            chapters: normalized,
            rawHTML: rawHTMLPages.joined(separator: "\n<!-- toc-page-break -->\n")
        )
        return package
    }

    // MARK: - 獲取章節正文

    func fetchChapter(
        ref: OnlineChapterRef, bookId: UUID, source: BookSource, chapterReferer: String? = nil
    ) async throws
        -> String
    {
        let package = try await fetchChapterPackage(
            ref: ref,
            bookId: bookId,
            source: source,
            chapterReferer: chapterReferer
        )
        return package.content
    }

    func fetchChapterPackage(
        ref: OnlineChapterRef, bookId: UUID, source: BookSource, chapterReferer: String? = nil
    ) async throws -> ChapterPackage {
        if let cached = loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: ref.index,
            expectedSourceURL: ref.url,
            expectedTOCTitle: ref.title
        ), cached.state == .cached, !cached.content.isEmpty {
            return cached
        }

        return try await withThrowingTaskGroup(of: ChapterPackage.self) { group in
            group.addTask { [self] in
                try await fetchChapterPackageInner(
                    ref: ref,
                    bookId: bookId,
                    source: source,
                    chapterReferer: chapterReferer
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 35 * 1_000_000_000)
                throw FetchTimeoutError.chapterTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func fetchChapterPackageInner(
        ref: OnlineChapterRef, bookId: UUID, source: BookSource, chapterReferer: String? = nil
    ) async throws
        -> ChapterPackage
    {
        if let cached = loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: ref.index,
            expectedSourceURL: ref.url,
            expectedTOCTitle: ref.title
        ), cached.state == .cached, !cached.content.isEmpty {
            return cached
        }
        // 安全清理：舊的目錄快取可能包含 HTML 片段（如 <a href="...">），先清理再解析
        var sanitizedRefUrl = DefaultWebNovelParserService.shared.sanitizeExtractedURL(ref.url)
        // 若清理後為相對路徑（如 /2280/1091923.html），需要重新解析為絕對 URL
        if !sanitizedRefUrl.hasPrefix("http://") && !sanitizedRefUrl.hasPrefix("https://") {
            sanitizedRefUrl = DefaultWebNovelParserService.shared.resolveURL(
                sanitizedRefUrl,
                base: chapterReferer ?? source.bookSourceUrl
            )
        }
        let requestSpec = ChapterFetcher.shared.parseChapterRequest(sanitizedRefUrl)
        let cleanUrl = requestSpec.url
        let urlWantsWebView = requestSpec.useWebView
        guard let url = safeURL(string: cleanUrl) else { throw FetchError.invalidURL(sanitizedRefUrl) }
        let runtimeBox = RuntimeVariableBox(ref.runtimeVariables)

        // 對齊 Legado getContentAwait：判斷是否需要 WebView
        // 1) 書源 bookSourceType == 1 (needsWebView)
        // 2) ruleContent.webJs 有值（需 WebView 執行 JS 後才能取到正確 HTML）
        // 3) 章節 URL 帶 ,{"webView":true}（Legado 規則常見）
        let hasWebJs = !source.ruleContent.webJs.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let requiresWebViewTransport = source.needsWebView || hasWebJs
        let useWebView = requiresWebViewTransport || urlWantsWebView
        let mergedHeaders = source.parsedHeaders.merging(requestSpec.headers) { _, new in new }
        let effectiveReferer = requestSpec.referer ?? chapterReferer ?? source.bookSourceUrl
        // 當章節 URL 明確帶 webView:true 時，直接使用 WebView 不再嘗試 HTTP
        // 之前先嘗試 HTTP 再回退 WebView 的策略會浪費一次網路請求，
        // 因為很多書源設定 webView:true 是因為頁面需要 JS 渲染內容
        let shouldAttemptHTTPFirst = false

        var requestHeaders = mergedHeaders
        if requestHeaders["Referer"] == nil && !effectiveReferer.isEmpty {
            requestHeaders["Referer"] = effectiveReferer
        }
        let requestHeadersSnapshot = requestHeaders

        // #region agent log
        let baseForReferer = effectiveReferer
        _dbgLog(
            "fetchChapter 進入",
            data: [
                "refUrl": String(ref.url.prefix(120)),
                "cleanUrl": String(cleanUrl.prefix(120)),
                "useWebView": useWebView,
                "needsWebView": source.needsWebView,
                "hasWebJs": hasWebJs,
                "urlWantsWebView": urlWantsWebView,
                "baseURL": String(baseForReferer.prefix(100)),
                "chapterReferer": chapterReferer ?? "",
                "bookSourceUrl": String(source.bookSourceUrl.prefix(80)),
                "source": source.bookSourceName,
                "index": ref.index,
                "shouldAttemptHTTPFirst": shouldAttemptHTTPFirst,
            ], hyp: "H1")
        // #endregion

        let fetchChapterHTML: @Sendable (URL, String, String?) async throws -> String = { [self] targetURL, method, body in
            func fetchViaConfiguredTransport(preferWebView: Bool) async throws -> String {
                if preferWebView {
                    if hasWebJs {
                        return try await WebViewFetcher.shared.fetchHTMLWithCustomJS(
                            url: targetURL,
                            headers: requestHeadersSnapshot,
                            jsAfterLoad: source.ruleContent.webJs,
                            timeout: 25,
                            jsWait: 2.0
                        )
                    }
                    return try await Self.fetchViaWebView(url: targetURL, headers: requestHeadersSnapshot)
                }
                return try await self.fetchHTML(
                    url: targetURL,
                    method: method,
                    body: body,
                    headers: requestHeadersSnapshot,
                    baseURL: effectiveReferer,
                    bodyCharset: requestSpec.charset
                )
            }

            if shouldAttemptHTTPFirst {
                do {
                    return try await fetchViaConfiguredTransport(preferWebView: false)
                } catch {
                    return try await fetchViaConfiguredTransport(preferWebView: true)
                }
            }

            do {
                return try await fetchViaConfiguredTransport(preferWebView: useWebView)
            } catch {
                guard urlWantsWebView && !requiresWebViewTransport else { throw error }
                return try await fetchViaConfiguredTransport(preferWebView: false)
            }
        }

        let parsePage: @Sendable (String, String) async throws -> ChapterParsePayload = { [self] html, baseURL in
            let ruleContent = source.ruleContent.content.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if ruleContent.isEmpty {
                let content = await ChapterFetcher.shared.extractWebContentSinglePage(
                    html: html, pageURL: baseURL)
                return ChapterParsePayload(
                    content: content, title: "", sourceMatched: true, isPay: ref.isPay)
            }
            do {
                let parsed = try pipeline.parseChapterResult(
                    html: html,
                    baseURL: baseURL,
                    source: source,
                    runtimeVariables: runtimeBox.get()
                )
                if let runtimeVariables = parsed.runtimeVariables, !runtimeVariables.isEmpty {
                    runtimeBox.set(runtimeVariables)
                }
                return parsed
            } catch {
                let fallback = await ChapterFetcher.shared.extractWebContentSinglePage(
                    html: html,
                    pageURL: baseURL
                )
                if !fallback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return ChapterParsePayload(
                        content: fallback,
                        title: "",
                        sourceMatched: false,
                        isPay: ref.isPay,
                        runtimeVariables: runtimeBox.get()
                    )
                }
                throw error
            }
        }
        let extractNextPages: @Sendable (String, String) async -> [String] = { [self] html, baseURL in
            self.pipeline.extractNextContentURLs(
                html: html,
                baseURL: baseURL,
                source: source,
                runtimeVariables: runtimeBox.get()
            )
        }

        let stagedRawHTML = try await fetchChapterHTML(url, requestSpec.method, requestSpec.body)

        let buildResult = try await ChapterFetcher.shared.buildChapterPackage(
            bookId: bookId,
            chapterIndex: ref.index,
            sourceURL: ref.url,
            tocTitle: ref.title,
            initialHTML: stagedRawHTML,
            initialURL: url,
            initialBaseURL: url.absoluteString,
            replaceRules: source.ruleContent.replaceRegex,
            parsePage: parsePage,
            extractNextURLs: extractNextPages
        ) { nextPageURL in
            try await fetchChapterHTML(nextPageURL, "GET", nil)
        } fetchViaJS: {
            try await WebViewFetcher.shared.fetchWebContentViaJS(
                url: url,
                headers: requestHeadersSnapshot,
                timeout: 18,
                jsWait: 2.5
            )
        } fetchBySelectors: {
            try await WebViewFetcher.shared.fetchChapterContentBySelectors(
                url: url,
                headers: requestHeadersSnapshot,
                timeout: 15,
                jsWait: 1.5
            )
        }

        saveChapterPackageToCache(
            buildResult.package,
            rawHTML: buildResult.rawHTML,
            normalizedHTML: buildResult.normalizedHTML
        )
        // #region agent log
        _dbgLog(
            "fetchChapter 成功",
            data: [
                "index": ref.index, "contentLen": buildResult.package.content.count, "source": source.bookSourceName,
            ], hyp: "A")
        // #endregion
        let reloaded = loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: ref.index,
            expectedSourceURL: ref.url,
            expectedTOCTitle: ref.title
        )
        return reloaded ?? buildResult.package
    }

    // MARK: - 無書源網頁抓取（瀏覽器轉碼書使用）

    /// 抓取任意 URL 的正文，不依賴書源規則（對齊 Legado BackstageWebView 動態提取）
    /// 優先用 App 端直接抓取 + SwiftSoup 啟發式（文本密度）→ 失敗才回退 WebView
    /// 會自動跟隨「下一頁」連結，合併多頁以補足章節內容。
    func fetchWebContent(url: String, referer: String? = nil) async throws -> String {
        guard let pageURL = URL(string: url) else { throw FetchError.invalidURL(url) }

        // 策略一：URLSession 直接抓取 + 本地解析（On-Device Parsing）
        let base = referer ?? pageURL.absoluteString
        var fullContent = ""
        var currentURL = url
        var pageCount = 0
        let maxPages = 10

        repeat {
            guard let thisURL = URL(string: currentURL) else { break }
            let html: String
            do {
                html = try await fetchHTML(
                    url: thisURL,
                    method: "GET",
                    body: nil,
                    headers: referer != nil ? ["Referer": referer!] : [:],
                    baseURL: base,
                    allowInteractiveChallengeOn503: false
                )
            } catch {
                break
            }

            let pageContent = await ChapterFetcher.shared.extractWebContentSinglePage(
                html: html, pageURL: currentURL)
            if fullContent.isEmpty {
                fullContent = pageContent
            } else {
                let trimmed = pageContent.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count > 50 {
                    fullContent += "\n\n" + trimmed
                }
            }

            pageCount += 1
            guard pageCount < maxPages else { break }
            currentURL = WebNovelParser.extractNextPageURL(
                html: html,
                currentURL: currentURL
            )
        } while !currentURL.isEmpty

        let cleanedDirect = ChapterFetcher.shared.cleanChapterContent(fullContent)
        if !cleanedDirect.isEmpty {
            return cleanedDirect
        }

        // 策略二：回退 WebView（反爬/JS 站點）
        do {
            let headers = referer != nil ? ["Referer": referer!] : [String: String]()
            let text = try await WebViewFetcher.shared.fetchWebContentViaJS(
                url: pageURL,
                headers: headers,
                timeout: 20,
                jsWait: 1.5
            )
            if !text.isEmpty {
                let cleaned = ChapterFetcher.shared.cleanChapterContent(text)
                return cleaned.isEmpty ? text : cleaned
            }
        } catch {
        }

        throw FetchError.emptyContent
    }

    // MARK: - 快取

    nonisolated func loadCachedChapterSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> String? {
        Self.chapterCacheRepository.loadCachedChapterSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    nonisolated func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> String? {
        Self.chapterCacheRepository.loadNormalizedChapterHTMLSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    nonisolated func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> Bool {
        Self.chapterCacheRepository.isChapterCached(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    nonisolated func clearChapterCache(bookId: UUID, chapterIndex: Int) {
        Self.chapterCacheRepository.clearChapterCache(bookId: bookId, chapterIndex: chapterIndex)
    }

    /// 清空該書所有章節快取（換源時呼叫）
    nonisolated func clearAllChapterCache(bookId: UUID) {
        Self.chapterCacheRepository.clearAllChapterCache(bookId: bookId)
    }

    @discardableResult
    nonisolated func saveToCache(
        content: String,
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String? = nil,
        tocTitle: String? = nil,
        extractedTitle: String? = nil,
        rawHTML: String? = nil
    ) -> String {
        Self.chapterCacheRepository.saveToCache(
            content: content,
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            extractedTitle: extractedTitle,
            rawHTML: rawHTML
        )
    }

    @discardableResult
    nonisolated func saveChapterPackageToCache(
        _ package: ChapterPackage,
        rawHTML: String?,
        normalizedHTML: String
    ) -> String {
        Self.chapterCacheRepository.saveChapterPackageToCache(
            package,
            rawHTML: rawHTML,
            normalizedHTML: normalizedHTML
        )
    }

    nonisolated func saveFailureMarker(
        bookId: UUID,
        chapterIndex: Int,
        sourceURL: String? = nil,
        tocTitle: String? = nil,
        extractedTitle: String? = nil,
        reason: String? = nil
    ) {
        Self.chapterCacheRepository.saveFailureMarker(
            bookId: bookId,
            chapterIndex: chapterIndex,
            sourceURL: sourceURL,
            tocTitle: tocTitle,
            extractedTitle: extractedTitle,
            reason: reason
        )
    }

    nonisolated func loadCachedChapterMetadataSync(bookId: UUID, chapterIndex: Int) -> CachedChapterMetadata? {
        Self.chapterCacheRepository.loadCachedChapterMetadataSync(
            bookId: bookId,
            chapterIndex: chapterIndex
        )
    }

    nonisolated func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String? = nil,
        expectedTOCTitle: String? = nil
    ) -> ChapterPackage? {
        Self.chapterCacheRepository.loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: chapterIndex,
            expectedSourceURL: expectedSourceURL,
            expectedTOCTitle: expectedTOCTitle
        )
    }

    // MARK: - HTTP 請求

    private func fetchHTML(
        url: URL, method: String, body: String?,
        headers: [String: String], baseURL: String,
        bodyCharset: String? = nil,
        allowInteractiveChallengeOn503: Bool = true
    ) async throws -> String {
        try await WebFetcher.shared.fetchHTML(
            url: url,
            method: method,
            body: body,
            headers: headers,
            baseURL: baseURL,
            bodyCharset: bodyCharset,
            allowInteractiveChallengeOn503: allowInteractiveChallengeOn503
        )
    }

}

// MARK: - RuleEngine 替換規則擴展

extension RuleEngine {
    static func applyReplaceRegex(_ text: String, rules: String) -> String {
        let trimmedRules = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRules.isEmpty else { return text }

        // 嘗試 JSON 陣列格式 [{"regex":"...", "replacement":"...", "isRegex":true}]
        if trimmedRules.hasPrefix("["),
           let data = trimmedRules.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            var result = text
            for item in arr {
                let pattern = (item["regex"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let replacement = (item["replacement"] as? String) ?? ""
                let isRegex = (item["isRegex"] as? Bool) ?? true
                guard !pattern.isEmpty else { continue }
                if isRegex {
                    if let regex = try? NSRegularExpression(pattern: pattern) {
                        let range = NSRange(result.startIndex..., in: result)
                        result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
                    }
                } else {
                    result = result.replacingOccurrences(of: pattern, with: replacement)
                }
            }
            return result
        }

        // Legado getString 格式：規則本身可以含 ##pattern##replacement 或 ##pattern##replacement##（replaceFirst）
        // 也支持 @@@ 分隔和多行格式
        var result = text
        let lines = trimmedRules.components(separatedBy: "\n").filter { !$0.isEmpty }
        for line in lines {
            var pattern: String
            var replacement: String
            var replaceFirst = false
            if line.components(separatedBy: "@@@").count > 1 {
                let parts = line.components(separatedBy: "@@@")
                pattern = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                replacement = parts[1]
            } else {
                // Legado ##pattern##replacement 或 ##pattern##replacement## 格式
                var content = line
                if content.hasPrefix("##") {
                    content = String(content.dropFirst(2))
                }
                // Legado: 尾部 ### 表示 replaceFirst（只替換第一次匹配）
                if content.hasSuffix("###") {
                    replaceFirst = true
                    content = String(content.dropLast(3))
                }
                let hashParts = content.components(separatedBy: "##")
                pattern = hashParts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                replacement = hashParts.count > 1 ? hashParts[1] : ""
            }
            guard !pattern.isEmpty else { continue }
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(result.startIndex..., in: result)
                if replaceFirst {
                    // Legado replaceFirst：找第一個匹配，只替換該匹配
                    if let match = regex.firstMatch(in: result, range: range),
                       let matchRange = Range(match.range, in: result) {
                        let matched = String(result[matchRange])
                        let replaced = regex.stringByReplacingMatches(
                            in: matched,
                            range: NSRange(matched.startIndex..., in: matched),
                            withTemplate: replacement
                        )
                        result.replaceSubrange(matchRange, with: replaced)
                    } else {
                        result = ""
                    }
                } else {
                    result = regex.stringByReplacingMatches(
                        in: result, range: range, withTemplate: replacement)
                }
            }
        }
        return result
    }
}

// MARK: - 錯誤定義

enum FetchError: LocalizedError {
    case noSearchURL
    case invalidURL(String)
    case httpError(Int)
    case cloudflareChallengeRequired(String)
    case encodingError
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .noSearchURL: return "書源未設置搜索 URL"
        case .invalidURL(let u): return "無效 URL：\(u)"
        case .httpError(let code): return "HTTP 錯誤 \(code)"
        case .cloudflareChallengeRequired(let url): return "需要人機驗證：\(url)"
        case .encodingError: return "頁面編碼無法識別"
        case .emptyContent: return "抓取到空內容"
        }
    }
}

struct CachedChapterMetadata: Codable {
    let sourceURL: String?
    let tocTitle: String?
    let extractedTitle: String?
    let contentChecksum: String
    let savedAt: Date
    let state: ChapterPackageState?
    let failureReason: String?
}

// MARK: - Debugger 供開發時測試書源使用

/// A global debugging environment for BookSourceFetcher to broadcast events
class WebCrawlerDebugger: ObservableObject {
    static let shared = WebCrawlerDebugger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let type: LogType
        let message: String
        let url: String?
        let metadata: [String: Any]?

        enum LogType {
            case info
            case request
            case response
            case parseEvent
            case error
        }
    }

    @Published var logs: [LogEntry] = []
    @Published var isRecording: Bool = false

    private init() {}

    @MainActor
    func clear() {
        logs.removeAll()
    }

    func logRequest(url: String, method: String, headers: [String: String]) {}

    func logResponse(url: String, statusCode: Int, htmlBody: String) {}

    func logParse(rule: String, matchCount: Int, url: String) {}

    func logError(_ error: Error, url: String? = nil) {}
}
