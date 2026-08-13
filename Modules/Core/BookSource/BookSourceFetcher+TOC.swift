import Foundation

// MARK: - Fetch TOC

extension BookSourceFetcher {

    /// Private metadata carried with the first chapter so content JS receives
    /// Legado's `nextChapterUrl` binding without changing the public TOC model.
    static let nextChapterRuntimeVariableKey = "__legado.nextChapterUrl"

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

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        onFirstPageReady: ((_ chapters: [OnlineChapterRef]) -> Void)? = nil,
        forceRefresh: Bool = false,
        runPreUpdateJs: Bool = true
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
                let result = try session.withBridge { bridge in
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

        if source.shouldUseLegadoRuntimeFetch(for: effectiveTOCURL) {
            // Reuse the per-source session's bridge (JS runtime + jsLib) instead
            // of standing up a fresh one for this fetch+parse pair.
            let session = BookSourceSession.session(for: source)
            let (html, finalUrl) = try await SourcePerfTrace.spanAsync(
                "toc.network", source.bookSourceName
            ) {
                try await session.bridgeForAsyncOperations.fetch(ruleUrl: effectiveTOCURL)
            }
            let parsed = try SourcePerfTrace.span("toc.parse", source.bookSourceName) {
                try session.withBridge { bridge in
                    let chapters = try bridge.parseTOC(
                        html: html,
                        baseURL: finalUrl,
                        source: source,
                        runtimeVariables: effectiveRuntimeVariables
                    )
                    return (chapters, bridge.lastTOCRuntimeVariables)
                }
            }
            let normalized = normalizedChaptersWithNextURL(parsed.0)
            if !normalized.isEmpty {
                onFirstPageReady?(normalized)
            }
            return saveTOCPackage(
                tocUrl: tocUrl,
                source: source,
                runtimeVariables: parsed.1 ?? effectiveRuntimeVariables,
                chapters: normalized,
                rawHTML: html
            )
        }

        guard let url = safeURL(string: effectiveTOCURL) else {
            throw FetchError.invalidURL(effectiveTOCURL)
        }
        let html: String
        var usedWebView = false
        let baseForReferer = effectiveTOCURL
        let tocNetworkStart = ProcessInfo.processInfo.systemUptime
        if source.needsWebView {
            html = try await Self.fetchViaWebView(url: url, headers: source.parsedHeaders)
            usedWebView = true
        } else {
            html = try await fetchHTML(
                url: url, method: "GET", body: nil,
                headers: source.parsedHeaders,
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
        let firstPage = try SourcePerfTrace.span(
            "toc.parse", source.bookSourceName
        ) {
            try autoreleasepool {
                try pipeline.parseTOCResult(
                    html: html,
                    baseURL: url.absoluteString,
                    source: source,
                    runtimeVariables: effectiveRuntimeVariables
                )
            }
        }
        var chapters = firstPage.chapters
        var tocRuntimeVariables = firstPage.runtimeVariables ?? effectiveRuntimeVariables
        let htmlForNext = html

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

        // Empty means the configured rule/transport produced no chapters. Legado
        // does not silently switch an ordinary HTTP source to WebView here; WebView
        // is selected above only when the source explicitly requests it through
        // `needsWebView` or `preUpdateJs`. The former global retry added 15–20 s to
        // every dead rule and hid parser failures behind a second transport.

        // Progressive loading: notify caller immediately after first page parse, don't wait for multi-page fetch
        if !chapters.isEmpty, let onFirstPageReady {
            let firstPageNormalized = chapters.enumerated().map { i, ref in
                var r = ref; r.index = i; return r
            }
            onFirstPageReady(firstPageNormalized)
        }

        // Multi-page TOC — write to disk page by page to avoid accumulating all rawHTMLPages in memory
        let rawHTMLPath = tocRawHTMLPath(tocUrl: tocUrl, source: source)
        let dir = tocCacheDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Write first page
        let pageBreak = "\n<!-- toc-page-break -->\n"
        try? htmlForNext.write(to: rawHTMLPath, atomically: false, encoding: .utf8)
        var nextURL = pipeline.extractNextTocURL(
            html: htmlForNext,
            baseURL: url.absoluteString,
            source: source,
            runtimeVariables: effectiveRuntimeVariables
        )
        var pageCount = 0
        while !nextURL.isEmpty && pageCount < 20 {
            guard let nextPageURL = URL(string: nextURL) else { break }
            let nextBase = nextURL.isEmpty ? source.bookSourceUrl : nextURL
            let pageStart = ProcessInfo.processInfo.systemUptime
            // Network request must be outside autoreleasepool (async cannot be in synchronous closure)
            let nextHTML: String
            if source.needsWebView {
                nextHTML = try await Self.fetchViaWebView(
                    url: nextPageURL, headers: source.parsedHeaders)
            } else {
                nextHTML = try await fetchHTML(
                    url: nextPageURL, method: "GET", body: nil,
                    headers: source.parsedHeaders, baseURL: nextBase,
                    source: source)
            }
            // Append to disk instead of keeping in memory
            if let handle = try? FileHandle(forWritingTo: rawHTMLPath) {
                handle.seekToEndOfFile()
                if let data = (pageBreak + nextHTML).data(using: .utf8) {
                    handle.write(data)
                }
                handle.closeFile()
            }
            // One session-serialized call parses chapters AND the next-page URL
            // from a single DOM (autoreleasepool drains SwiftSoup per page).
            let pageResult = try autoreleasepool {
                try pipeline.parseTOCPage(
                    html: nextHTML,
                    baseURL: nextURL,
                    source: source,
                    runtimeVariables: effectiveRuntimeVariables
                )
            }
            nextURL = pageResult.nextTocURL
            chapters.append(contentsOf: pageResult.chapters)
            if let pageRuntime = pageResult.runtimeVariables {
                var merged = tocRuntimeVariables ?? [:]
                merged.merge(pageRuntime) { _, new in new }
                tocRuntimeVariables = merged
            }
            pageCount += 1
            SourcePerfTrace.record(
                "toc.nextPage", "page=\(pageCount) \(source.bookSourceName)", since: pageStart
            )
        }
        let normalized = normalizedChaptersWithNextURL(chapters)
        // rawHTML was already written to disk page by page in the multi-page loop
        let package = saveTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: tocRuntimeVariables,
            chapters: normalized,
            rawHTML: nil
        )
        return package
    }
}
