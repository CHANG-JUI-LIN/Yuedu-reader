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
    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]? = nil,
        knownBook: OnlineBook? = nil
    ) async throws -> BookInfoPackage {
        // The merge also applies on a cache hit: a package stored before this contract existed (or
        // stored from a call that had no search result to hand) can carry the same empty fields.
        let canReName = !source.ruleBookInfo.canReName
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let cached = loadBookInfoPackageSync(url: url, source: source) {
            return cached.merging(searchResult: knownBook, canReName: canReName)
        }
        // #region agent log
        _dbgLog(
            "fetchBookInfo 進入",
            data: ["url": String(url.prefix(80)), "source": source.bookSourceName], hyp: "A")
        // #endregion

        if source.shouldUseLegadoRuntimeFetch(for: url) {
            // Shared per-source session — no fresh JS runtime for this parse.
            let session = BookSourceSession.session(for: source)
            let (html, finalUrl) = try await SourcePerfTrace.spanAsync(
                "detail.network", source.bookSourceName
            ) {
                try await session.bridgeForAsyncOperations.fetch(ruleUrl: url)
            }
            let info = try SourcePerfTrace.span("detail.parse", source.bookSourceName) {
                try session.withBridge { bridge in
                    try bridge.parseBookInfo(
                        html: html,
                        bookUrl: url,
                        baseURL: finalUrl,
                        source: source,
                        runtimeVariables: runtimeVariables
                    )
                }
            }
            return saveBookInfoPackage(
                info: info,
                source: source,
                rawHTML: html
            ).merging(searchResult: knownBook, canReName: canReName)
        }

        guard let bookURL = safeURL(string: url) else { throw FetchError.invalidURL(url) }
        let networkStart = ProcessInfo.processInfo.systemUptime
        let html: String
        if source.needsWebView {
            html = try await Self.fetchViaWebView(url: bookURL, headers: source.parsedHeaders)
        } else {
            html = try await fetchHTML(
                url: bookURL, method: "GET", body: nil,
                headers: source.parsedHeaders, baseURL: source.cleanedBookSourceURL,
                source: source)
        }
        SourcePerfTrace.record("detail.network", source.bookSourceName, since: networkStart)
        let info = try SourcePerfTrace.span("detail.parse", source.bookSourceName) {
            try pipeline.parseBookInfo(
                html: html,
                bookUrl: url,
                baseURL: bookURL.absoluteString,
                source: source,
                runtimeVariables: runtimeVariables
            )
        }
        let package = saveBookInfoPackage(
            info: info,
            source: source,
            rawHTML: html
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
}
