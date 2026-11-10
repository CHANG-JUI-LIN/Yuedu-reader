import Foundation

// MARK: - Fetch Book Details

extension BookSourceFetcher {

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        knownBook: OnlineBook? = nil
    ) async throws -> OnlineBook {
        let package = try await fetchBookInfoPackage(
            url: url,
            source: source,
            runtimeVariables: runtimeVariables,
            knownBook: knownBook
        )
        return package.onlineBook
    }

    /// - Parameter knownBook: the book as the search/discover stage knew it, when the caller came
    ///   from there. Detail rules routinely omit fields the search result already carried — 431 of
    ///   1912 real sources have an empty `ruleBookInfo.name` — and legado's `analyzeBookInfo`
    ///   updates the book it was handed rather than building a new one. Passing it here reproduces
    ///   that contract; see `BookInfoPackage.merging(searchResult:canReName:)`.
    /// - Parameter usesCache: `false` when the caller needs the site's answer now and keeps
    ///   none of it — 書源驗證. A stored package neither answers (Legado's `CheckSourceService`
    ///   requests every detail page it checks, so a site that has died since fails there) nor is
    ///   written: those books are not on the shelf, and caching them wrote a package per checked
    ///   source that nothing opened from there.
    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables callerRuntimeVariables: [String: String]? = nil,
        knownBook: OnlineBook? = nil,
        usesCache: Bool = true
    ) async throws -> BookInfoPackage {
        // The merge also applies on a cache hit: a package stored before this contract existed (or
        // stored from a call that had no search result to hand) can carry the same empty fields.
        let canReName = !source.ruleBookInfo.canReName
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // Every transport below parses against this: the search result as the book.
        let runtimeVariables = knownBook?.detailStageRuntimeVariables(callerRuntimeVariables)
            ?? callerRuntimeVariables
        if usesCache, let cached = loadBookInfoPackageSync(url: url, source: source) {
            return cached.merging(searchResult: knownBook, canReName: canReName)
        }
        // #region agent log
        _dbgLog(
            "fetchBookInfo 進入",
            data: ["url": String(url.prefix(80)), "source": source.bookSourceName], hyp: "A")
        // #endregion

        // Legado `WebBook.getBookInfoAwait`: a book whose search or discover page was its own
        // page carries that page (`infoHtml`), and the detail rules read it rather than a second
        // request — for a page a POST search answered, `bookUrl` is that search URL.
        if let knownBook, knownBook.bookUrl == url,
           let infoHtml = knownBook.infoHtml, !infoHtml.isEmpty {
            let info = try await SourcePerfTrace.spanAsync("detail.parse", source.bookSourceName) {
                try await self.pipeline.parseBookInfo(
                    html: infoHtml, bookUrl: url, baseURL: url,
                    source: source, runtimeVariables: runtimeVariables
                )
            }
            return finishBookInfoPackage(
                info: info, source: source, usesCache: usesCache
            ).merging(searchResult: knownBook, canReName: canReName)
        }

        if source.shouldUseLegadoRuntimeFetch(for: url) {
            // Shared per-source session — no fresh JS runtime for this parse.
            let session = BookSourceSession.session(for: source)
            let (html, finalUrl) = try await SourcePerfTrace.spanAsync(
                "detail.network", source.bookSourceName
            ) {
                try await session.fetch(ruleUrl: url, runtimeVariables: runtimeVariables)
            }
            let info = try await session.parse { bridge in
                try SourcePerfTrace.span("detail.parse", source.bookSourceName) {
                    try bridge.parseBookInfo(
                        html: html,
                        bookUrl: url,
                        baseURL: finalUrl,
                        source: source,
                        runtimeVariables: runtimeVariables
                    )
                }
            }
            return finishBookInfoPackage(
                info: info,
                source: source,
                usesCache: usesCache
            ).merging(searchResult: knownBook, canReName: canReName)
        }

        guard let bookURL = safeURL(string: url) else { throw FetchError.invalidURL(url) }
        let networkStart = ProcessInfo.processInfo.systemUptime
        let html: String
        let headers = await source.resolvedHeaders()
        if source.needsWebView {
            let rendered = try await Self.fetchViaWebView(url: bookURL, headers: headers)
            html = await pipeline.applyLoginCheck(renderedHTML: rendered, url: bookURL, source: source)
        } else {
            html = try await fetchStageHTML(
                url: bookURL, method: "GET", body: nil,
                headers: headers, baseURL: source.cleanedBookSourceURL,
                source: source)
        }
        SourcePerfTrace.record("detail.network", source.bookSourceName, since: networkStart)
        let info = try await SourcePerfTrace.spanAsync("detail.parse", source.bookSourceName) {
            try await self.pipeline.parseBookInfo(
                html: html,
                bookUrl: url,
                baseURL: bookURL.absoluteString,
                source: source,
                runtimeVariables: runtimeVariables
            )
        }
        let package = finishBookInfoPackage(
            info: info,
            source: source,
            usesCache: usesCache
        ).merging(searchResult: knownBook, canReName: canReName)
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

    /// Both transports end here, so `usesCache` holds for each of them.
    private func finishBookInfoPackage(
        info: OnlineBook,
        source: BookSource,
        usesCache: Bool
    ) -> BookInfoPackage {
        usesCache
            ? saveBookInfoPackage(info: info, source: source)
            : makeBookInfoPackage(info: info, source: source)
    }
}

extension OnlineBook {
    /// The variables the detail stage runs with when it starts from this search or discover
    /// result. Legado's `WebBook.getBookInfoAwait` runs the detail rules against the book the
    /// search made (`SearchBook.toBook()`), so `book.name`, `book.author` and the rest are this
    /// result's until a detail rule replaces them; without them a detail rule that reads
    /// `book.name` read "". The result's fields win over the same keys in `runtimeVariables`:
    /// those are what the search stage's shared `book` last held, not this book's.
    func detailStageRuntimeVariables(_ runtimeVariables: [String: String]?) -> [String: String]? {
        var variables = runtimeVariables ?? [:]
        let fields: [(String, String)] = [
            ("book.name", name), ("book.author", author), ("book.bookUrl", bookUrl),
            ("book.tocUrl", tocUrl), ("book.coverUrl", coverUrl), ("book.intro", intro),
            ("book.kind", kind), ("book.wordCount", wordCount), ("book.latestChapterTitle", lastChapter)
        ]
        for (key, value) in fields where !value.isEmpty {
            variables[key] = value
        }
        return variables.isEmpty ? nil : variables
    }
}
