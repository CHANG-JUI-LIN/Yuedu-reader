import Foundation

enum BookSourceSearchFailureMode: Sendable {
    /// Interactive search treats an unreachable source like an empty result so one
    /// broken site does not fail the whole aggregate search UI.
    case emptyResult
    /// Source validation needs the transport error itself so it can fail that source
    /// immediately, matching Legado's `checkSource` coroutine instead of continuing
    /// into discovery and holding a validation worker for another timeout window.
    case propagateTransportError
}

/// Why one source's search failed, for the log. Never carries the request URL: a search
/// URL contains the reader's keyword.
enum BookSourceSearchFailure: Error, Equatable, Sendable {
    case http(Int)
    case encoding
    case emptyContent
    case transport(String)
    case parse(String)
    /// The search was cancelled (a timeout or a newer search). Not the source's fault and
    /// not logged.
    case cancelled

    var logReason: String {
        switch self {
        case .http(let code): "HTTP \(code)"
        case .encoding: "page encoding not recognized"
        case .emptyContent: "empty response"
        case .transport(let description): "transport: \(description)"
        case .parse(let description): "parse: \(description)"
        case .cancelled: "cancelled"
        }
    }

    /// What the native search path does with an error from its request stage. This is the
    /// mapping `search` has always applied, in both failure modes: these errors come back
    /// as "no results" and every other one is thrown. `propagateTransportError` throws only
    /// the errors that are not `FetchError`s.
    enum Disposition: Equatable, Sendable {
        /// Reported to the caller as no results; recorded as this failure.
        case reportedAsEmpty(BookSourceSearchFailure)
        case thrown
    }

    static func disposition(of error: Error, mode: BookSourceSearchFailureMode) -> Disposition {
        if let fetchError = error as? FetchError {
            switch fetchError {
            case .encodingError:
                return .reportedAsEmpty(.encoding)
            case .httpError(let code) where [401, 403, 404, 429, 500, 502, 503].contains(code):
                return .reportedAsEmpty(.http(code))
            case .emptyContent:
                return .reportedAsEmpty(.emptyContent)
            default:
                return .thrown
            }
        }
        if mode == .propagateTransportError { return .thrown }
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return .reportedAsEmpty(.cancelled)
        }
        return .reportedAsEmpty(.transport(error.localizedDescription))
    }
}

/// One source's answer to one search page: books, a legitimately empty page, or a failure
/// that `search(…)` has always reported to its callers as an empty page.
enum BookSourceSearchOutcome: Sendable {
    case results([OnlineBook])
    case empty
    case failed(BookSourceSearchFailure)

    var books: [OnlineBook] {
        if case .results(let books) = self { return books }
        return []
    }

    var failure: BookSourceSearchFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    init(books: [OnlineBook]) {
        self = books.isEmpty ? .empty : .results(books)
    }
}

/// Legado aggregate sources accept qualified searches such as
/// `m:book name@source`. The full expression must reach the source's search JS,
/// while local result matching must compare against the book-name portion only.
enum LegadoSearchKeyword {
    static func matchingTitle(from rawQuery: String) -> String {
        var value = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2 {
            let prefix = value.prefix(2).lowercased()
            if ["x:", "t:", "m:", "d:", "x：", "t：", "m：", "d："].contains(prefix) {
                value.removeFirst(2)
            }
        }
        if let separator = value.firstIndex(of: "@") {
            value = String(value[..<separator])
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Search Books

extension BookSourceFetcher {

    struct SearchStreamingOutcome {
        let books: [OnlineBook]
        let streamed: Bool
        /// Set when the native path failed and reported the failure as no results. Nil for
        /// cache hits and the JS runtime, whose errors are thrown.
        var failure: BookSourceSearchFailure? = nil
    }

    /// - Parameters:
    ///   - page: 1-based result page (載入更多 passes 2+; only page 1 is cached).
    ///   - earlyFilter: applied at parse time right after name/author extraction
    ///     so rejected items skip the remaining rule evaluations (換源 strict
    ///     matching). Filtered runs never write the shared search cache.
    ///   - onHasMore: reports the source's own next-page verdict (`hasMoreRule`,
    ///     native path only). nil = unknown → caller uses heuristics.
    func search(
        query: String,
        in source: BookSource,
        page: Int = 1,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)? = nil,
        onHasMore: ((Bool?) -> Void)? = nil,
        failureMode: BookSourceSearchFailureMode = .emptyResult
    ) async throws -> [OnlineBook] {
        try await searchOutcome(
            query: query, in: source, page: page,
            earlyFilter: earlyFilter, onHasMore: onHasMore, failureMode: failureMode
        ).books
    }

    /// `search(…)` with the difference between a legitimately empty page and a failure kept.
    /// Throws exactly what `search(…)` throws; a failure it has always reported as no results
    /// comes back as `.failed` and is logged once, here.
    func searchOutcome(
        query: String,
        in source: BookSource,
        page: Int = 1,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)? = nil,
        onHasMore: ((Bool?) -> Void)? = nil,
        failureMode: BookSourceSearchFailureMode = .emptyResult
    ) async throws -> BookSourceSearchOutcome {
        guard !source.searchUrl.isEmpty else { throw FetchError.noSearchURL }
        let cacheDays = GlobalSettings.shared.searchCacheDays
        let cacheEligible = page == 1 && earlyFilter == nil
        if page == 1, let cached = SearchResultCache.shared.freshBooks(
            query: query,
            source: source,
            days: cacheDays
        ) {
            onHasMore?(nil)
            guard let earlyFilter else { return BookSourceSearchOutcome(books: cached) }
            return BookSourceSearchOutcome(books: cached.filter { earlyFilter($0.name, $0.author) })
        }

        if source.shouldUseLegadoRuntimeFetch(for: source.searchUrl) {
            var books = try await BookSourceSession.session(for: source)
                .bridgeForAsyncOperations
                .searchBooks(keyword: query, page: page)
            onHasMore?(nil)
            if let earlyFilter {
                // The JS runtime already parsed everything; filtering here just
                // keeps the returned list consistent with the native path.
                books = books.filter { earlyFilter($0.name, $0.author) }
            }
            let filtered = Self.filterSearchResultsByCheckKeyWord(
                books, query: query, checkKeyWord: source.ruleSearch.checkKeyWord)
            if cacheEligible {
                SearchResultCache.shared.store(
                    books: filtered,
                    query: query,
                    source: source,
                    days: cacheDays
                )
            }
            return BookSourceSearchOutcome(books: filtered)
        }

        // A search URL with JSON options went to the runtime above, so this one has none.
        let request = await source.renderSearchURL(query: query, page: page)
        let resolvedUrlStr = RuleEngine.resolveURL(
            request.url,
            base: source.cleanedBookSourceURL
        )
        guard let url = safeURL(string: resolvedUrlStr) else {
            throw FetchError.invalidURL(resolvedUrlStr)
        }
        let headers = source.parsedHeaders

        let html: String
        do {
            if source.needsWebView {
                let rendered = try await Self.fetchViaWebView(url: url, headers: headers)
                html = await SourceScriptThread.run {
                    self.pipeline.applyLoginCheck(renderedHTML: rendered, url: url, source: source)
                }
            } else {
                html = try await fetchStageHTML(
                    url: url, method: request.method, body: request.body,
                    headers: headers, baseURL: source.cleanedBookSourceURL,
                    source: source)
            }
        } catch {
            switch BookSourceSearchFailure.disposition(of: error, mode: failureMode) {
            case .thrown:
                throw error
            case .reportedAsEmpty(let failure):
                Self.logReportedAsEmpty(failure, source: source, host: url.host, mode: failureMode)
                return .failed(failure)
            }
        }

        let books: [OnlineBook]
        do {
            books = try await SourceScriptThread.run {
                try self.pipeline.parseSearchResults(
                    html: html, baseURL: url.absoluteString, source: source,
                    earlyFilter: earlyFilter)
            }
        } catch {
            onHasMore?(false)
            let failure = BookSourceSearchFailure.parse(error.localizedDescription)
            Self.logReportedAsEmpty(failure, source: source, host: url.host, mode: failureMode)
            return .failed(failure)
        }

        if let onHasMore {
            let hasMoreRule = source.ruleSearch.hasMoreRule
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !hasMoreRule.isEmpty {
                onHasMore(await SourceScriptThread.run {
                    BookSourceSession.session(for: source).withBridge {
                        $0.evaluateHasMoreRule(hasMoreRule, html: html)
                    }
                })
            } else if books.isEmpty {
                // Legado's blank-rule fallback: an empty list page means no more.
                onHasMore(false)
            } else {
                onHasMore(nil)
            }
        }

        let filtered = Self.filterSearchResultsByCheckKeyWord(
            books, query: query, checkKeyWord: source.ruleSearch.checkKeyWord)
        if cacheEligible {
            SearchResultCache.shared.store(
                books: filtered,
                query: query,
                source: source,
                days: cacheDays
            )
        }
        return BookSourceSearchOutcome(books: filtered)
    }

    /// One line per failed source, so a source that keeps failing can be found in the log
    /// instead of looking like a source without the book. Source name, host and reason only:
    /// the URL and the query carry what the reader searched for.
    ///
    /// Only for searches that show the reader a failure as "no results". 書源驗證
    /// (`.propagateTransportError`) already lists every source's failure in its own results,
    /// and a run over tens of thousands of sources would push everything else out of the
    /// diagnostic log (maintainer's choice, 2026-10-10).
    private static func logReportedAsEmpty(
        _ failure: BookSourceSearchFailure,
        source: BookSource,
        host: String?,
        mode: BookSourceSearchFailureMode
    ) {
        guard mode == .emptyResult, failure != .cancelled else { return }
        let message = "search failed; shown as no results: \(source.bookSourceName) (\(host ?? "")) \(failure.logReason)"
        if case .parse = failure {
            AppLogger.parse(message, level: .warning)
        } else {
            AppLogger.network(message, level: .warning)
        }
    }

    /// Page fetch for 載入更多: books plus the source's own next-page verdict.
    func searchPage(
        query: String,
        in source: BookSource,
        page: Int
    ) async throws -> (books: [OnlineBook], hasMore: Bool?) {
        var hasMore: Bool? = nil
        let books = try await search(
            query: query, in: source, page: page,
            onHasMore: { hasMore = $0 }
        )
        return (books, hasMore)
    }

    func searchStreaming(
        query: String,
        in source: BookSource,
        onBatch: @escaping @Sendable ([OnlineBook]) async -> Void
    ) async throws -> SearchStreamingOutcome {
        guard !source.searchUrl.isEmpty else { throw FetchError.noSearchURL }
        let cacheDays = GlobalSettings.shared.searchCacheDays
        if let cached = SearchResultCache.shared.freshBooks(
            query: query,
            source: source,
            days: cacheDays
        ) {
            return SearchStreamingOutcome(books: cached, streamed: false)
        }

        if source.shouldUseLegadoRuntimeFetch(for: source.searchUrl) {
            let outcome = try await BookSourceSession.session(for: source)
                .bridgeForAsyncOperations
                .searchBooksStreaming(keyword: query, page: 1) { books in
                    let filtered = Self.filterSearchResultsByCheckKeyWord(
                        books, query: query, checkKeyWord: source.ruleSearch.checkKeyWord)
                    guard !filtered.isEmpty else { return }
                    await onBatch(filtered)
                }
            let filtered = Self.filterSearchResultsByCheckKeyWord(
                outcome.books, query: query, checkKeyWord: source.ruleSearch.checkKeyWord)
            SearchResultCache.shared.store(
                books: filtered,
                query: query,
                source: source,
                days: cacheDays
            )
            return SearchStreamingOutcome(books: filtered, streamed: outcome.streamed)
        }

        let outcome = try await searchOutcome(query: query, in: source)
        return SearchStreamingOutcome(books: outcome.books, streamed: false, failure: outcome.failure)
    }

    /// Legado compatible: filter search results by checkKeyWord (keep only items matching keyword in title/author)
    private static func filterSearchResultsByCheckKeyWord(
        _ books: [OnlineBook], query: String, checkKeyWord: String
    ) -> [OnlineBook] {
        guard !checkKeyWord.isEmpty, !query.isEmpty else { return books }
        let key = LegadoSearchKeyword.matchingTitle(from: query).lowercased()
        guard !key.isEmpty else { return books }
        return books.filter { book in
            book.name.localizedCaseInsensitiveContains(key)
                || book.author.localizedCaseInsensitiveContains(key)
        }
    }
}
