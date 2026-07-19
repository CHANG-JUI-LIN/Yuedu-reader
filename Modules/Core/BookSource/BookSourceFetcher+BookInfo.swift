import Foundation

// MARK: - Fetch Book Details

extension BookSourceFetcher {

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
            )
        }

        guard let bookURL = safeURL(string: url) else { throw FetchError.invalidURL(url) }
        let networkStart = ProcessInfo.processInfo.systemUptime
        let html: String
        if source.needsWebView {
            html = try await Self.fetchViaWebView(url: bookURL, headers: source.parsedHeaders)
        } else {
            html = try await fetchHTML(
                url: bookURL, method: "GET", body: nil,
                headers: source.parsedHeaders, baseURL: source.bookSourceUrl,
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
}
