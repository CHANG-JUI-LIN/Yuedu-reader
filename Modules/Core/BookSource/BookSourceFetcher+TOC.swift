import Foundation

// MARK: - Fetch TOC

extension BookSourceFetcher {

    /// Fetch TOC (Legado compatible: ruleToc.chapterList/name/url, multi-page nextTocUrl, preUpdateJs).
    /// If ruleToc.preUpdateJs is set, loads the TOC page via WebView, executes the JS first, then retrieves HTML.
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

    /// - Parameter forceRefresh: when `true`, the on-disk TOC cache is ignored and
    ///   the table of contents is always re-fetched from the network. Used by the
    ///   "update online books" path (launch / foreground / pull-to-refresh) so that
    ///   serial novels actually pick up newly-published chapters instead of replaying
    ///   the stale cached list. Normal reading paths leave it `false` for speed.
    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        onFirstPageReady: ((_ chapters: [OnlineChapterRef]) -> Void)? = nil,
        forceRefresh: Bool = false
    ) async throws -> TOCPackage {
        if !forceRefresh,
            let cached = loadTOCPackageSync(tocUrl: tocUrl, source: source), !cached.chapters.isEmpty {
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

        if source.shouldUseLegadoRuntimeFetch(for: tocUrl) {
            let bridge = ModernParserBridge(source: source)
            let (html, finalUrl) = try await bridge.fetch(ruleUrl: tocUrl)
            let chapters = try bridge.parseTOC(
                html: html,
                baseURL: finalUrl,
                source: source,
                runtimeVariables: runtimeVariables
            )
            let normalized = chapters.enumerated().map { i, ref in
                var r = ref
                r.index = i
                return r
            }
            if !normalized.isEmpty {
                onFirstPageReady?(normalized)
            }
            return saveTOCPackage(
                tocUrl: tocUrl,
                source: source,
                runtimeVariables: normalized.last?.runtimeVariables ?? runtimeVariables,
                chapters: normalized,
                rawHTML: html
            )
        }

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
                baseURL: baseForReferer.isEmpty ? source.bookSourceUrl : baseForReferer,
                source: source)
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
        var chapters: [OnlineChapterRef] = try autoreleasepool {
            try pipeline.parseTOC(
                html: html,
                baseURL: url.absoluteString,
                source: source,
                runtimeVariables: runtimeVariables
            )
        }
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

        // If URLSession returns empty TOC, retry with WebView (many sites load TOC dynamically via JS)
        if chapters.isEmpty && !usedWebView {
            let webHtml = try await WebViewFetcher.shared.fetchHTML(
                url: url,
                headers: source.parsedHeaders,
                timeout: 20,
                jsWait: 4.0
            )
            chapters = try autoreleasepool {
                try pipeline.parseTOC(
                    html: webHtml,
                    baseURL: url.absoluteString,
                    source: source,
                    runtimeVariables: runtimeVariables
                )
            }
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
            chapters = try autoreleasepool {
                try pipeline.parseTOC(
                    html: delayedHtml,
                    baseURL: url.absoluteString,
                    source: source,
                    runtimeVariables: runtimeVariables
                )
            }
            htmlForNext = delayedHtml
        }

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
            runtimeVariables: runtimeVariables
        )
        var pageCount = 0
        let usePreUpdateJs = !source.ruleToc.preUpdateJs.isEmpty
        while !nextURL.isEmpty && pageCount < 20 {
            guard let nextPageURL = URL(string: nextURL) else { break }
            let nextBase = nextURL.isEmpty ? source.bookSourceUrl : nextURL
            // Network request must be outside autoreleasepool (async cannot be in synchronous closure)
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
            // autoreleasepool ensures SwiftSoup DOM objects for each page are released immediately
            let pageChapters: [OnlineChapterRef] = try autoreleasepool {
                try pipeline.parseTOC(
                    html: nextHTML,
                    baseURL: nextURL,
                    source: source,
                    runtimeVariables: runtimeVariables
                )
            }
            nextURL = pipeline.extractNextTocURL(
                html: nextHTML,
                baseURL: nextURL,
                source: source,
                runtimeVariables: runtimeVariables
            )
            chapters.append(contentsOf: pageChapters)
            pageCount += 1
        }
        let normalized = chapters.enumerated().map { i, ref in
            var r = ref
            r.index = i
            return r
        }
        // rawHTML was already written to disk page by page in the multi-page loop
        let package = saveTOCPackage(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables,
            chapters: normalized,
            rawHTML: nil
        )
        return package
    }
}
