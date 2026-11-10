import CryptoKit
import Foundation

// MARK: - Fetch Chapter Content

extension BookSourceFetcher {

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
        try await fetchChapterPackage(
            ref: ref, bookId: bookId, source: source, chapterReferer: chapterReferer, isVideoEpisode: false
        )
    }

    /// `isVideoEpisode`: what the content script hands to `java.openVideoPlayer` or
    /// `java.startBrowser` is the episode's content (`ModernParserBridge.parseChapterResult`).
    ///
    /// No deadline of its own: each request bounds itself, as in Legado, whose
    /// `WebBook.getContentAwait` sets none above OkHttp's 60 s call timeout and
    /// `BackstageWebView`'s 60 s (`WebFetcher.sourceRequestTimeout` here). A 35 s cap over the
    /// whole chapter used to race the fetch and cut off pages those transports allow: 17k's
    /// WebView chapter (YCK 1330#54) finished loading at 37 s and failed with
    /// `Chapter load timeout`.
    func fetchChapterPackage(
        ref: OnlineChapterRef, bookId: UUID, source: BookSource, chapterReferer: String?,
        isVideoEpisode: Bool
    ) async throws -> ChapterPackage {
        try await fetchChapterPackageInner(
            ref: ref,
            bookId: bookId,
            source: source,
            chapterReferer: chapterReferer,
            isVideoEpisode: isVideoEpisode
        )
    }

    private func fetchChapterPackageInner(
        ref: OnlineChapterRef, bookId: UUID, source: BookSource, chapterReferer: String? = nil,
        isVideoEpisode: Bool
    ) async throws
        -> ChapterPackage
    {
        logChapterFetchGate(ref: ref, source: source)
        guard !ref.shouldRenderAsVolumeSeparator else {
            throw FetchError.volumeSeparator(ref.title)
        }

        if let cached = loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: ref.index,
            expectedSourceURL: ref.url,
            expectedTOCTitle: ref.title
        ), cached.state == .cached, !cached.content.isEmpty {
            return cached
        }
        if source.readsChapterURLAsContent {
            return try saveChapterURLPackage(ref: ref, bookId: bookId)
        }
        if source.shouldUseLegadoRuntimeFetch(for: ref.url) {
            return try await fetchLegadoRuntimeChapterPackage(
                ref: ref,
                bookId: bookId,
                source: source,
                isVideoEpisode: isVideoEpisode
            )
        }
        // Sanitize: old TOC cache may contain HTML fragments (e.g. <a href="...">), sanitize before parsing
        var sanitizedRefUrl = RuleEngine.sanitizeExtractedURL(ref.url)
        // If sanitized result is a relative path (e.g. /2280/1091923.html), resolve to absolute URL
        if !sanitizedRefUrl.hasPrefix("http://") && !sanitizedRefUrl.hasPrefix("https://") {
            sanitizedRefUrl = RuleEngine.resolveURL(
                sanitizedRefUrl,
                base: chapterReferer ?? source.bookSourceUrl
            )
        }
        let requestSpec = ChapterFetcher.shared.parseChapterRequest(sanitizedRefUrl)
        let cleanUrl = requestSpec.url
        let urlWantsWebView = requestSpec.useWebView
        guard let url = safeURL(string: cleanUrl) else { throw FetchError.invalidURL(sanitizedRefUrl) }
        let runtimeBox = RuntimeVariableBox(ref.runtimeVariables)

        // Align with Legado getContentAwait: determine if WebView is needed
        let hasWebJs = !source.ruleContent.webJs.trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let requiresWebViewTransport = source.needsWebView || hasWebJs
        let useWebView = requiresWebViewTransport || urlWantsWebView
        let mergedHeaders = await source.resolvedHeaders().merging(requestSpec.headers) { _, new in new }
        let effectiveReferer = requestSpec.referer ?? chapterReferer ?? source.bookSourceUrl
        let shouldAttemptHTTPFirst = false

        // No Referer the source did not ask for: Legado sends none (its AnalyzeUrl, WebBook and
        // BackstageWebView add none). The chapter's TOC page, else the source URL, went out as
        // one on every chapter request, page and WebView load until 11-09.
        var requestHeaders = mergedHeaders
        if requestHeaders["Referer"] == nil, let referer = requestSpec.referer, !referer.isEmpty {
            requestHeaders["Referer"] = referer
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

        let effectiveWebViewDelay = requestSpec.webViewDelayMs > 0 ? TimeInterval(requestSpec.webViewDelayMs) / 1000.0 : nil
        // `checksLogin`: the chapter's first page — Legado runs `loginCheckJs` on that
        // response (`fetchStageHTML`), a WebView-rendered one included, and not on next pages.
        let fetchChapterHTML: @Sendable (URL, String, String?, Bool) async throws -> String = {
            [self] targetURL, method, body, checksLogin in
            func fetchViaConfiguredTransport(preferWebView: Bool) async throws -> String {
                if preferWebView {
                    let rendered: String
                    if hasWebJs {
                        rendered = try await WebViewFetcher.shared.fetchHTMLWithCustomJS(
                            url: targetURL,
                            headers: requestHeadersSnapshot,
                            jsAfterLoad: source.ruleContent.webJs,
                            timeout: WebFetcher.sourceRequestTimeout,
                            jsWait: effectiveWebViewDelay ?? AppConfig.webViewExplicitJSWait
                        )
                    } else {
                        rendered = try await Self.fetchViaWebView(url: targetURL, headers: requestHeadersSnapshot, jsWait: effectiveWebViewDelay)
                    }
                    guard checksLogin else { return rendered }
                    return await self.pipeline.applyLoginCheck(renderedHTML: rendered, url: targetURL, source: source)
                }
                if checksLogin {
                    return try await self.fetchStageHTML(
                        url: targetURL,
                        method: method,
                        body: body,
                        headers: requestHeadersSnapshot,
                        baseURL: effectiveReferer,
                        charset: requestSpec.charset,
                        source: source
                    )
                }
                // A next page carries no options of the first page's: Legado builds its
                // AnalyzeUrl from the next URL alone, so its charset is detected. An HTTP error
                // status is a page like any other, as for a TOC's following page: Legado's
                // `newCallStrResponse` hands back the error body, which reads as no text and no
                // further link. 黄金书屋 (YCK1331) builds its last page's next link from that
                // page's own URL (`…/2.html/2.html`), and the 404 used to fail the chapter.
                return try await SourceRateLimit.run(source: source) {
                    try await self.webFetcher.fetchDecodedPage(
                        url: targetURL, method: method, body: body,
                        headers: requestHeadersSnapshot, baseURL: effectiveReferer,
                        throwsOnErrorStatus: false, client: .okHttp, cookieJar: source.enabledCookieJar
                    )
                }.html
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

        let parsePage: @Sendable (String, String, String) async throws -> ChapterParsePayload = { [self] html, baseURL, ruleURL in
            let ruleContent = source.ruleContent.content.trimmingCharacters(
                in: .whitespacesAndNewlines)
            // Not a fallback: a source with no content rule has no other way to its text, and
            // reading the page with the heuristic is how such a source reads at all
            // (`BookSourceCheckCPUTests.textSourceWithoutContentRuleReadsPage`). The page reaching
            // it is bounded by `WebFetcher.responseByteLimit`, like every other page.
            if ruleContent.isEmpty {
                let content = await ChapterFetcher.shared.extractWebContentSinglePage(
                    html: html, pageURL: baseURL)
                return ChapterParsePayload(
                    content: content, title: "", sourceMatched: true, isPay: ref.isPay)
            }
            // A rule that matches nothing is the source's answer, as in Legado: no heuristic
            // stands in for it. (A `catch` here used to read the page with the heuristic when the
            // rule threw; `ModernParserBridge.parseChapterResult` throws nothing, so it never ran.)
            let parsed = try await SourcePerfTrace.spanAsync("chapter.parse", source.bookSourceName) {
                try await self.pipeline.parseChapterResult(
                    html: html,
                    baseURL: baseURL,
                    ruleURL: ruleURL,
                    source: source,
                    runtimeVariables: runtimeBox.get(),
                    chapterRef: ref,
                    nextChapterURL: ref.runtimeVariables?[Self.nextChapterRuntimeVariableKey],
                    isVideoEpisode: isVideoEpisode
                )
            }
            if let runtimeVariables = parsed.runtimeVariables, !runtimeVariables.isEmpty {
                runtimeBox.set(runtimeVariables)
            }
            return parsed
        }
        let extractNextPages: @Sendable (String, String, String) async -> [String] = { [self] html, baseURL, ruleURL in
            let next = await self.pipeline.extractNextContentURLs(
                html: html,
                baseURL: baseURL,
                ruleURL: ruleURL,
                source: source,
                runtimeVariables: runtimeBox.get(),
                chapterRef: ref
            )
            // What the rule put is the chapter's, for its next page to read.
            if let runtimeVariables = next.runtimeVariables {
                runtimeBox.set(runtimeVariables)
            }
            return next.urls
        }

        let stagedRawHTML = try await SourcePerfTrace.spanAsync(
            "chapter.network", source.bookSourceName
        ) {
            try await fetchChapterHTML(url, requestSpec.method, requestSpec.body, true)
        }

        let buildResult = try await ChapterFetcher.shared.buildChapterPackage(
            bookId: bookId,
            chapterIndex: ref.index,
            sourceURL: ref.url,
            tocTitle: ref.title,
            initialHTML: stagedRawHTML,
            initialURL: url,
            initialBaseURL: url.absoluteString,
            reviewContext: source.legadoReviewContext.withChapter(ref),
            nextChapterURL: ref.runtimeVariables?[Self.nextChapterRuntimeVariableKey],
            parsePage: parsePage,
            extractNextURLs: extractNextPages
        ) { link in
            // A link carrying options or JS is the runtime's to read (`AnalyzeUrl`), as a TOC's
            // following page is (`fetchFollowingTOCPage`); any other goes as before.
            if source.shouldUseLegadoRuntimeFetch(for: link) {
                return try await BookSourceSession.session(for: source).fetch(
                    ruleUrl: link, runtimeVariables: runtimeBox.get(), contentStage: true
                ).0
            }
            // The request goes out as OkHttp sends the link, `%XX` escapes as they are.
            guard let pageURL = AnalyzeUrl.requestURL(link) else { throw FetchError.invalidURL(link) }
            return try await fetchChapterHTML(pageURL, "GET", nil, false)
        }

        try saveChapterPackageToCache(
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
        guard let reloaded else { throw ChapterCacheWriteError.verificationFailed }
        return reloaded
    }

    /// An audio source's chapter when the source has no content rule: its URL, unfetched.
    private func saveChapterURLPackage(ref: OnlineChapterRef, bookId: UUID) throws -> ChapterPackage {
        let checksum = SHA256.hash(data: Data(ref.url.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let package = ChapterPackage(
            bookId: bookId,
            chapterIndex: ref.index,
            sourceURL: ref.url,
            tocTitle: ref.title,
            canonicalTitle: nil,
            content: ref.url,
            contentChecksum: checksum,
            rawHTMLFilename: "\(ref.index).raw.html",
            normalizedHTMLFilename: "\(ref.index).normalized.xhtml",
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
        try saveChapterPackageToCache(package, rawHTML: nil, normalizedHTML: nil)
        guard let reloaded = loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: ref.index,
            expectedSourceURL: ref.url,
            expectedTOCTitle: ref.title
        ) else {
            throw ChapterCacheWriteError.verificationFailed
        }
        return reloaded
    }

    private func fetchLegadoRuntimeChapterPackage(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        isVideoEpisode: Bool
    ) async throws -> ChapterPackage {
        logChapterFetchGate(ref: ref, source: source)
        guard !ref.shouldRenderAsVolumeSeparator else {
            throw FetchError.volumeSeparator(ref.title)
        }
        // Shared per-source session: the JS runtime (and jsLib) stays warm
        // across chapters instead of booting per fetch.
        let session = BookSourceSession.session(for: source)
        let (html, finalUrl) = try await SourcePerfTrace.spanAsync(
            "chapter.network", source.bookSourceName
        ) {
            try await session.fetch(
                ruleUrl: ref.url, runtimeVariables: ref.runtimeVariables, contentStage: true
            )
        }
        guard let firstURL = URL(string: finalUrl) else { throw FetchError.invalidURL(finalUrl) }
        // The chapter's pages go through `buildChapterPackage`, as on the native path: this path
        // used to read the first page only, so a runtime source's `nextContentUrl` was never read.
        let runtimeBox = RuntimeVariableBox(ref.runtimeVariables)
        let nextChapterURL = ref.runtimeVariables?[Self.nextChapterRuntimeVariableKey]
        let buildResult = try await ChapterFetcher.shared.buildChapterPackage(
            bookId: bookId,
            chapterIndex: ref.index,
            sourceURL: ref.url,
            tocTitle: ref.title,
            initialHTML: html,
            initialURL: firstURL,
            initialBaseURL: finalUrl,
            reviewContext: source.legadoReviewContext
                .withRuntimeVariables(ref.runtimeVariables)
                .withChapter(ref),
            nextChapterURL: nextChapterURL,
            parsePage: { html, baseURL, ruleURL in
                let parsed = try await session.parse { bridge in
                    try SourcePerfTrace.span("chapter.parse", source.bookSourceName) {
                        try bridge.parseChapterResult(
                            html: html,
                            baseURL: baseURL,
                            ruleURL: ruleURL,
                            source: source,
                            runtimeVariables: runtimeBox.get(),
                            chapterRef: ref,
                            nextChapterURL: nextChapterURL,
                            isVideoEpisode: isVideoEpisode
                        )
                    }
                }
                if let runtimeVariables = parsed.runtimeVariables, !runtimeVariables.isEmpty {
                    runtimeBox.set(runtimeVariables)
                }
                return parsed
            },
            extractNextURLs: { [self] html, baseURL, ruleURL in
                let next = await self.pipeline.extractNextContentURLs(
                    html: html, baseURL: baseURL, ruleURL: ruleURL, source: source,
                    runtimeVariables: runtimeBox.get(), chapterRef: ref
                )
                if let runtimeVariables = next.runtimeVariables {
                    runtimeBox.set(runtimeVariables)
                }
                return next.urls
            },
            // Legado reads a next page with an AnalyzeUrl of its own link, options and all, and
            // the content rule's `webJs` (`BookContent.getContent`).
            fetchNextPageHTML: { link in
                try await session.fetch(
                    ruleUrl: link, runtimeVariables: runtimeBox.get(), contentStage: true
                ).0
            }
        )
        try saveChapterPackageToCache(
            buildResult.package,
            rawHTML: buildResult.rawHTML,
            normalizedHTML: buildResult.normalizedHTML
        )
        guard let reloaded = loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: ref.index,
            expectedSourceURL: ref.url,
            expectedTOCTitle: ref.title
        ) else {
            throw ChapterCacheWriteError.verificationFailed
        }
        return reloaded
    }

    private func logChapterFetchGate(ref: OnlineChapterRef, source: BookSource) {
        guard ref.isVolume || ref.hasVolumeSeparatorTitle else { return }
        AppLogger.parse("⟐ chapterFetch gate", context: [
            "source": source.bookSourceName,
            "index": ref.index,
            "title": ref.title,
            "isVolume": ref.isVolume,
            "volumeTitle": ref.hasVolumeSeparatorTitle,
            "shouldSkip": ref.shouldRenderAsVolumeSeparator,
            "hasURL": ref.hasLoadableContentURL,
            "urlLen": ref.sanitizedContentURL.count,
            "urlHead": String(ref.sanitizedContentURL.prefix(120))
        ])
    }
}

extension BookSource {
    /// Legado's `WebBook.getContentAwait` (legado, legado-E and MD3 alike): a source with no
    /// content rule reads the chapter URL as the chapter (正文规则为空,使用章节链接). For an
    /// audio source that URL is the stream the player opens. Fetching it instead downloaded
    /// whole audio files and parsed them as pages: in 書源檢查 asmr's 37.8 MB stream took
    /// 61 s of CPU and 轻音潇社's overflowed a thread's stack (Crashlytics c0ec35f1), and the
    /// player found no URL in the parsed text. A video source's chapter URL is its episode's
    /// stream the same way (稀饭影视 has no content rule). Text sources keep the content
    /// heuristic, which reads their pages.
    var readsChapterURLAsContent: Bool {
        (bookSourceType == 1 || bookSourceType == 4)
            && ruleContent.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
