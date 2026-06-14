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
                try await Task.sleep(nanoseconds: AppConfig.chapterFetchTimeoutSeconds * 1_000_000_000)
                throw FetchTimeoutError.chapterTimeout
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    private func fetchChapterPackageInner(
        ref: OnlineChapterRef, bookId: UUID, source: BookSource, chapterReferer: String? = nil
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
        if source.shouldUseLegadoRuntimeFetch(for: ref.url) {
            return try await fetchLegadoRuntimeChapterPackage(
                ref: ref,
                bookId: bookId,
                source: source
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
        let mergedHeaders = source.parsedHeaders.merging(requestSpec.headers) { _, new in new }
        let effectiveReferer = requestSpec.referer ?? chapterReferer ?? source.bookSourceUrl
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
                    runtimeVariables: runtimeBox.get(),
                    chapterRef: ref
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
            reviewContext: source.legadoReviewContext,
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

    private func fetchLegadoRuntimeChapterPackage(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource
    ) async throws -> ChapterPackage {
        logChapterFetchGate(ref: ref, source: source)
        guard !ref.shouldRenderAsVolumeSeparator else {
            throw FetchError.volumeSeparator(ref.title)
        }
        let bridge = ModernParserBridge(source: source)
        let (html, finalUrl) = try await bridge.fetch(ruleUrl: ref.url)
        let parsed = try bridge.parseChapterResult(
            html: html,
            baseURL: finalUrl,
            source: source,
            runtimeVariables: ref.runtimeVariables,
            chapterRef: ref
        )
        let content = await ChapterFetcher.shared.resolveContent(
            parsed: parsed,
            replaceRules: source.ruleContent.replaceRegex,
            sourceUrl: ref.url,
            fetchViaJS: { nil },
            fetchBySelectors: { nil }
        )
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FetchError.emptyContent
        }
        let canonicalTitle = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = canonicalTitle.isEmpty ? ref.title : canonicalTitle
        let normalizedHTML = await ChapterFetcher.shared.buildRenderableNormalizedHTML(
            title: effectiveTitle,
            plainTextContent: content,
            rawHTMLContent: parsed.content,
            reviewContext: source.legadoReviewContext
        )
        let checksum = SHA256.hash(data: Data(content.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let package = ChapterPackage(
            bookId: bookId,
            chapterIndex: ref.index,
            sourceURL: ref.url,
            tocTitle: ref.title,
            canonicalTitle: canonicalTitle.isEmpty ? nil : canonicalTitle,
            content: content,
            contentChecksum: checksum,
            rawHTMLFilename: "\(ref.index).raw.html",
            normalizedHTMLFilename: "\(ref.index).normalized.xhtml",
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
        saveChapterPackageToCache(
            package,
            rawHTML: html,
            normalizedHTML: normalizedHTML
        )
        return loadChapterPackageSync(
            bookId: bookId,
            chapterIndex: ref.index,
            expectedSourceURL: ref.url,
            expectedTOCTitle: ref.title
        ) ?? package
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
