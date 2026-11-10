import Foundation

// MARK: - Fetch TOC

extension BookSourceFetcher {

    /// Private metadata carried with the first chapter so content JS receives
    /// Legado's `nextChapterUrl` binding without changing the public TOC model.
    static let nextChapterRuntimeVariableKey = "__legado.nextChapterUrl"

    /// The TOC as Legado's `BookChapterList.getChapterList` finishes it from the chapters of
    /// every page, in the order they were read (legado-E, MD3 and upstream agree):
    /// - a `-` before `ruleToc.chapterList` reverses the whole list, and so does a book that a
    ///   rule gave `book.setReverseToc(true)`; both together cancel out, as there;
    /// - the chapters are numbered in that order, each carrying the next one's URL for the
    ///   content stage (Legado's `nextChapterUrl`);
    /// - the book learns its chapter count and latest chapter, which content rules read —
    ///   神漫画 (YCK 1329) numbers its pages from the end, `book.totalChapterNum - index`.
    ///
    /// Legado also drops chapters whose URL came earlier (`LinkedHashSet` on `BookChapter.url`).
    /// That is not done here: it renumbers the chapters of a shelf book whose TOC has repeats,
    /// and reading positions are chapter numbers.
    private func assembledTOC(
        _ pageChapters: [OnlineChapterRef],
        source: BookSource,
        runtimeVariables: [String: String]?
    ) -> (chapters: [OnlineChapterRef], runtimeVariables: [String: String]?) {
        var ordered = pageChapters
        if ModernParserBridge.tocListRule(source.ruleToc.chapterList).reverses {
            ordered.reverse()
        }
        if runtimeVariables?[LegadoBookBridge.reverseTocRuntimeKey] == "true" {
            ordered.reverse()
        }
        let chapters = normalizedChaptersWithNextURL(ordered)
        guard let last = chapters.last else { return (chapters, runtimeVariables) }
        var variables = runtimeVariables ?? [:]
        variables["book.totalChapterNum"] = String(chapters.count)
        if !last.title.isEmpty { variables["book.latestChapterTitle"] = last.title }
        return (chapters, variables)
    }

    private func normalizedChaptersWithNextURL(
        _ chapters: [OnlineChapterRef]
    ) -> [OnlineChapterRef] {
        chapters.enumerated().map { index, ref in
            var normalized = ref
            normalized.index = index
            if chapters.indices.contains(index + 1) {
                var variables = normalized.runtimeVariables ?? [:]
                variables[Self.nextChapterRuntimeVariableKey] = chapters[index + 1].url
                normalized.runtimeVariables = variables
            }
            return normalized
        }
    }

    /// Fetch TOC for source validation. Legado's checker calls `getChapterListAwait`
    /// with its default `runPerJs = false`, so validation must not execute
    /// `ruleToc.preUpdateJs` or open a WebView for it.
    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil
    ) async throws -> [OnlineChapterRef] {
        let package = try await fetchTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables,
            runPreUpdateJs: false
        )
        return package.chapters
    }

    /// - Parameter forceRefresh: when `true`, the on-disk TOC cache is ignored and
    ///   the table of contents is always re-fetched from the network. Used by the
    ///   "update online books" path (launch / foreground / pull-to-refresh) so that
    ///   serial novels actually pick up newly-published chapters instead of replaying
    ///   the stale cached list. Normal reading paths leave it `false` for speed.
    /// Cached TOC for this URL if a usable one is on disk (same validity rules
    /// as `fetchTOCPackage`'s fast path). Lets UI layers render a previously
    /// fetched chapter list instantly while fresh data loads.
    func cachedTOCPackage(tocUrl: String, source: BookSource) -> TOCPackage? {
        guard let cached = loadTOCPackageSync(tocUrl: tocUrl, source: source),
              !cached.chapters.isEmpty else { return nil }
        let hasBadURL = cached.chapters.contains { ch in
            ch.url.contains("<") || ch.url.contains("&lt;") || ch.url.contains("%3C")
        }
        return hasBadURL ? nil : cached
    }

    /// - Parameter writesCache: `false` when the caller only looks at the table of contents —
    ///   書源驗證 checks books that are not on the shelf, and caching their TOC wrote a full
    ///   package per checked source that nothing read back.
    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        onFirstPageReady: ((_ chapters: [OnlineChapterRef]) -> Void)? = nil,
        forceRefresh: Bool = false,
        runPreUpdateJs: Bool = true,
        writesCache: Bool = true
    ) async throws -> TOCPackage {
        try await fetchTOCPackage(
            tocUrl: tocUrl, source: source, runtimeVariables: runtimeVariables,
            onFirstPageReady: onFirstPageReady, forceRefresh: forceRefresh,
            runPreUpdateJs: runPreUpdateJs, writesCache: writesCache, detailPage: nil
        )
    }

    /// - Parameter detailPage: the book's detail page, when the caller has just read it
    ///   (`OnlineBook.detailPage`). A TOC at the book's own URL is read from it.
    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        onFirstPageReady: ((_ chapters: [OnlineChapterRef]) -> Void)? = nil,
        forceRefresh: Bool = false,
        runPreUpdateJs: Bool = true,
        writesCache: Bool = true,
        detailPage: BookDetailPage?
    ) async throws -> TOCPackage {
        if !forceRefresh, let cached = cachedTOCPackage(tocUrl: tocUrl, source: source) {
            return cached
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

        var effectiveTOCURL = tocUrl
        var effectiveRuntimeVariables = runtimeVariables
        if runPreUpdateJs,
           !source.ruleToc.preUpdateJs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let session = BookSourceSession.session(for: source)
            do {
                let result = try await session.withTurn { bridge in
                    try bridge.runTOCPreUpdateJS(
                        source.ruleToc.preUpdateJs,
                        tocURL: tocUrl,
                        runtimeVariables: runtimeVariables
                    )
                }
                effectiveTOCURL = result.tocURL
                effectiveRuntimeVariables = result.runtimeVariables
            } catch {
                // Legado logs preUpdateJs failures and continues with the original
                // book/URL. Preserve that contract without changing transport.
                AppLogger.parse("TOC preUpdateJs failed", context: [
                    "source": source.bookSourceName,
                    "error": error.localizedDescription
                ])
            }
        }

        // Crashlytics 4eaef04b died inside the next-page rule of a source it could not name:
        // the report's open book was not the one being fetched, and one ran in the background
        // with no book open. Every fetch that will read that rule says whose it is first.
        if !source.ruleToc.nextTocUrl.isEmpty {
            CrashContext.breadcrumb(
                "toc next-page rule: \(source.bookSourceName) \(String(effectiveTOCURL.prefix(80)))"
            )
        }

        // Legado `WebBook.getChapterListAwait` (legado-E, MD3 and upstream agree): a TOC at the
        // book's own URL is read from the detail page the detail stage just read (`tocHtml`),
        // with that URL as both its base and its redirect URL, and is not requested again. Over
        // half the sources of the YCK packs have no tocUrl rule (1330: 458 of 794), so each of
        // their books fetched its page twice, and on a slow site the second fetch was the one
        // that timed out (轻之文库, YCK1331).
        if let detailPage, !detailPage.html.isEmpty, detailPage.url == effectiveTOCURL {
            let firstPage = try await SourcePerfTrace.spanAsync("toc.parse", source.bookSourceName) {
                try await self.pipeline.parseTOCPage(
                    html: detailPage.html,
                    baseURL: effectiveTOCURL,
                    ruleURL: effectiveTOCURL,
                    source: source,
                    runtimeVariables: effectiveRuntimeVariables
                )
            }
            return try await completeTOCPackage(
                firstPage: firstPage, firstPageURL: effectiveTOCURL, tocUrl: tocUrl, source: source,
                runtimeVariables: effectiveRuntimeVariables, onFirstPageReady: onFirstPageReady,
                writesCache: writesCache
            )
        }

        if source.shouldUseLegadoRuntimeFetch(for: effectiveTOCURL) {
            // Reuse the per-source session's bridge (JS runtime + jsLib) instead
            // of standing up a fresh one for this fetch+parse pair.
            let session = BookSourceSession.session(for: source)
            let (html, finalUrl) = try await SourcePerfTrace.spanAsync(
                "toc.network", source.bookSourceName
            ) {
                try await session.fetch(ruleUrl: effectiveTOCURL, runtimeVariables: effectiveRuntimeVariables)
            }
            let parsed = try await session.parse { bridge in
                try SourcePerfTrace.span("toc.parse", source.bookSourceName) {
                    let page = try bridge.parseTOCPage(
                        html: html,
                        baseURL: finalUrl,
                        ruleURL: effectiveTOCURL,
                        source: source,
                        runtimeVariables: effectiveRuntimeVariables
                    )
                    return (page.chapters, page.nextTocURLs, bridge.lastTOCRuntimeVariables)
                }
            }
            return try await completeTOCPackage(
                firstPage: (chapters: parsed.0, nextTocURLs: parsed.1, runtimeVariables: parsed.2),
                firstPageURL: finalUrl, tocUrl: tocUrl, source: source,
                runtimeVariables: effectiveRuntimeVariables, onFirstPageReady: onFirstPageReady,
                writesCache: writesCache
            )
        }

        guard let url = safeURL(string: effectiveTOCURL) else {
            throw FetchError.invalidURL(effectiveTOCURL)
        }
        let html: String
        var usedWebView = false
        let baseForReferer = effectiveTOCURL
        let tocNetworkStart = ProcessInfo.processInfo.systemUptime
        let headers = await source.resolvedHeaders()
        if source.needsWebView {
            let rendered = try await Self.fetchViaWebView(url: url, headers: headers)
            html = await pipeline.applyLoginCheck(renderedHTML: rendered, url: url, source: source)
            usedWebView = true
        } else {
            html = try await fetchStageHTML(
                url: url, method: "GET", body: nil,
                headers: headers,
                baseURL: baseForReferer.isEmpty ? source.cleanedBookSourceURL : baseForReferer,
                source: source)
        }
        SourcePerfTrace.record("toc.network", source.bookSourceName, since: tocNetworkStart)
        // #region agent log
        _dbgLog(
            "fetchTOC 已取得 HTML",
            data: [
                "source": source.bookSourceName,
                "htmlLen": html.count,
                "htmlPreview": String(html.prefix(150)).replacingOccurrences(of: "\n", with: " "),
            ], hyp: "H2")
        // #endregion
        let firstPage = try await SourcePerfTrace.spanAsync("toc.parse", source.bookSourceName) {
            try await self.pipeline.parseTOCPage(
                html: html,
                baseURL: url.absoluteString,
                ruleURL: effectiveTOCURL,
                source: source,
                runtimeVariables: effectiveRuntimeVariables
            )
        }
        // #region agent log
        _dbgLog(
            "fetchTOC 初次解析結果",
            data: [
                "source": source.bookSourceName,
                "chaptersCount": firstPage.chapters.count,
                "htmlLen": html.count,
                "usedWebView": usedWebView,
                "htmlPreview": String(html.prefix(300)).replacingOccurrences(of: "\n", with: " "),
            ], hyp: "T1")
        // #endregion

        // Empty means the configured rule/transport produced no chapters. Legado
        // does not silently switch an ordinary HTTP source to WebView here; WebView
        // is selected above only when the source explicitly requests it through
        // `needsWebView` or `preUpdateJs`. The former global retry added 15–20 s to
        // every dead rule and hid parser failures behind a second transport.
        return try await completeTOCPackage(
            firstPage: firstPage, firstPageURL: url.absoluteString, tocUrl: tocUrl, source: source,
            runtimeVariables: effectiveRuntimeVariables, onFirstPageReady: onFirstPageReady,
            writesCache: writesCache
        )
    }

    /// A TOC from its parsed first page on, however that page came (the detail page, either
    /// transport): the first page shown as soon as it is parsed, the pages after it, and the
    /// package.
    private func completeTOCPackage(
        firstPage: (chapters: [OnlineChapterRef], nextTocURLs: [String], runtimeVariables: [String: String]?),
        firstPageURL: String,
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: ((_ chapters: [OnlineChapterRef]) -> Void)?,
        writesCache: Bool
    ) async throws -> TOCPackage {
        if !firstPage.chapters.isEmpty, let onFirstPageReady {
            onFirstPageReady(assembledTOC(
                firstPage.chapters, source: source, runtimeVariables: firstPage.runtimeVariables ?? runtimeVariables
            ).chapters)
        }
        let following = try await fetchFollowingTOCPages(
            firstPage.nextTocURLs,
            firstPageURL: firstPageURL,
            source: source,
            runtimeVariables: runtimeVariables
        )
        return finishTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: Self.mergedTOCRuntimeVariables(
                firstPage.runtimeVariables ?? runtimeVariables, following.runtimeVariables
            ),
            chapters: firstPage.chapters + following.chapters,
            writesCache: writesCache
        )
    }

    /// The pages after the first, walked as Legado's `BookChapterList` walks them (legado,
    /// MD3 and Sigma agree). One next URL: follow page by page, each page's first next URL,
    /// until a page comes round again — the pages read are the only limit, as there; a cap of
    /// 20 pages here cut long tables of contents short. Several: a page-select TOC listing
    /// every page, fetched together and merged in list order, and not asked for next pages.
    private func fetchFollowingTOCPages(
        _ nextURLs: [String],
        firstPageURL: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> (chapters: [OnlineChapterRef], runtimeVariables: [[String: String]]) {
        switch nextURLs.count {
        case 0:
            return ([], [])
        case 1:
            var chapters: [OnlineChapterRef] = []
            var pageRuntimeVariables: [[String: String]] = []
            var read: Set<String> = [firstPageURL]
            var nextURL = nextURLs[0]
            let chainStart = SourcePerfTrace.now
            // How far a table of contents walked, in one line: 書源檢查's CPU exceptions came with
            // logs of nothing but next-page rules (Crashlytics c0ec35f1, 20727455).
            defer {
                SourcePerfTrace.record(
                    "toc.nextPageChain",
                    "pages=\(read.count - 1) chapters=\(chapters.count) \(source.bookSourceName)",
                    since: chainStart,
                    thresholdMs: 0
                )
            }
            while !nextURL.isEmpty, read.insert(nextURL).inserted {
                let pageStart = ProcessInfo.processInfo.systemUptime
                let page = try await fetchFollowingTOCPage(nextURL, source: source, runtimeVariables: runtimeVariables)
                // Legado parses a followed page against the URL it asked for, as both its
                // `baseUrl` and its `redirectUrl` (`BookChapterList`).
                let parsed = try await pipeline.parseTOCPage(
                    html: page.html,
                    baseURL: nextURL,
                    ruleURL: nextURL,
                    source: source,
                    runtimeVariables: runtimeVariables
                )
                chapters.append(contentsOf: parsed.chapters)
                if let pageRuntime = parsed.runtimeVariables { pageRuntimeVariables.append(pageRuntime) }
                nextURL = parsed.nextTocURLs.first ?? ""
                SourcePerfTrace.record(
                    "toc.nextPage", "page=\(read.count - 1) \(source.bookSourceName)", since: pageStart
                )
            }
            return (chapters, pageRuntimeVariables)
        default:
            // Every page is on the source's one host, as with a download, so the fan-out
            // takes the download ceiling of the same 並發數 knob (Legado: `threadCount`).
            let width = await MainActor.run {
                NetworkSearchSettings.clampedDownloadConcurrency(GlobalSettings.shared.searchConcurrency)
            }
            let fanOutStart = ProcessInfo.processInfo.systemUptime
            var pages = [(chapters: [OnlineChapterRef], runtimeVariables: [String: String]?)?](
                repeating: nil, count: nextURLs.count
            )
            try await withThrowingTaskGroup(
                of: (Int, [OnlineChapterRef], [String: String]?).self
            ) { group in
                var nextIndex = 0
                func addPage() {
                    let index = nextIndex
                    let pageURL = nextURLs[index]
                    nextIndex += 1
                    group.addTask {
                        let page = try await self.fetchFollowingTOCPage(
                            pageURL, source: source, runtimeVariables: runtimeVariables
                        )
                        let parsed = try await self.pipeline.parseTOCResult(
                            html: page.html,
                            baseURL: page.finalURL,
                            ruleURL: pageURL,
                            source: source,
                            runtimeVariables: runtimeVariables
                        )
                        return (index, parsed.chapters, parsed.runtimeVariables)
                    }
                }
                while nextIndex < min(width, nextURLs.count) { addPage() }
                for try await (index, chapters, pageRuntime) in group {
                    pages[index] = (chapters, pageRuntime)
                    if nextIndex < nextURLs.count { addPage() }
                }
            }
            SourcePerfTrace.record(
                "toc.nextPages", "pages=\(nextURLs.count) \(source.bookSourceName)", since: fanOutStart
            )
            return (
                pages.flatMap { $0?.chapters ?? [] },
                pages.compactMap { $0?.runtimeVariables }
            )
        }
    }

    /// A page after the first, by the same transport choice as the first: a URL carrying
    /// options or JS goes through the Legado runtime (`AnalyzeUrl`), as every page does in
    /// Legado; any other through WebView when the source asks for it, else plain HTTP.
    ///
    /// An HTTP error status is a page like any other here, as in Legado, whose
    /// `newCallStrResponse` hands back the error body: it parses to no chapters and the other
    /// pages stand (maintainer, 2026-10-20). The runtime fetch already reads it that way.
    /// A transport failure still fails the table of contents.
    private func fetchFollowingTOCPage(
        _ pageURL: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> (html: String, finalURL: String) {
        if source.shouldUseLegadoRuntimeFetch(for: pageURL) {
            let (html, finalURL) = try await BookSourceSession.session(for: source)
                .fetch(ruleUrl: pageURL, runtimeVariables: runtimeVariables)
            return (html, finalURL)
        }
        guard let url = safeURL(string: pageURL) else {
            throw FetchError.invalidURL(pageURL)
        }
        let headers = await source.resolvedHeaders()
        if source.needsWebView {
            return (try await Self.fetchViaWebView(url: url, headers: headers), pageURL)
        }
        let page = try await SourceRateLimit.run(source: source) {
            try await self.webFetcher.fetchPage(
                url: url, method: "GET", body: nil,
                headers: headers, baseURL: pageURL, client: .okHttp, cookieJar: source.enabledCookieJar
            )
        }
        if !(200...299).contains(page.statusCode) {
            AppLogger.network("TOC following page answered an error status", context: [
                "source": source.bookSourceName,
                "url": String(pageURL.prefix(120)),
                "statusCode": page.statusCode,
            ])
        }
        guard let html = HTMLResponseDecoder.decode(
            data: page.data, response: page.response, declaredCharset: nil
        ) else {
            throw FetchError.encodingError
        }
        WebCrawlerDebugger.logResponse(url: pageURL, statusCode: page.statusCode, htmlBody: html)
        return (html, pageURL)
    }

    /// The first page's runtime variables with each following page's laid over them in order.
    private static func mergedTOCRuntimeVariables(
        _ first: [String: String]?,
        _ following: [[String: String]]
    ) -> [String: String]? {
        guard !following.isEmpty else { return first }
        var merged = first ?? [:]
        for page in following {
            merged.merge(page) { _, new in new }
        }
        return merged
    }

    /// Both transports end here, with the chapters of every page in the order they were read:
    /// the TOC is assembled here once, and `writesCache` holds for each of them.
    private func finishTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables pageRuntimeVariables: [String: String]?,
        chapters pageChapters: [OnlineChapterRef],
        writesCache: Bool
    ) -> TOCPackage {
        let (chapters, runtimeVariables) = assembledTOC(
            pageChapters, source: source, runtimeVariables: pageRuntimeVariables
        )
        return writesCache
            ? saveTOCPackage(tocUrl: tocUrl, source: source, runtimeVariables: runtimeVariables, chapters: chapters)
            : makeTOCPackage(tocUrl: tocUrl, source: source, runtimeVariables: runtimeVariables, chapters: chapters)
    }
}
