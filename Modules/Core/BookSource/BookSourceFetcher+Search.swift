import Foundation

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
        onHasMore: ((Bool?) -> Void)? = nil
    ) async throws -> [OnlineBook] {
        guard !source.searchUrl.isEmpty else { throw FetchError.noSearchURL }
        let cacheDays = GlobalSettings.shared.searchCacheDays
        let cacheEligible = page == 1 && earlyFilter == nil
        if page == 1, let cached = SearchResultCache.shared.freshBooks(
            query: query,
            source: source,
            days: cacheDays
        ) {
            onHasMore?(nil)
            guard let earlyFilter else { return cached }
            return cached.filter { earlyFilter($0.name, $0.author) }
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
            return filtered
        }

        let requestSpec = source.renderSearchRequest(query: query, page: page)
        let resolvedUrlStr = RuleEngine.resolveURL(
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
                let jsWait = requestSpec.webViewDelayMs > 0 ? TimeInterval(requestSpec.webViewDelayMs) / 1000.0 : nil
                html = try await Self.fetchViaWebView(url: url, headers: mergedHeaders, jsWait: jsWait)
            } else {
                html = try await fetchHTML(
                    url: url, method: requestSpec.method, body: requestSpec.body,
                    headers: mergedHeaders, baseURL: source.bookSourceUrl,
                    bodyCharset: requestSpec.charset,
                    allowInteractiveChallengeOn503: false,
                    source: source)
            }
        } catch let err as FetchError {
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
            return []
        }

        // Legado loginCheckJs: evaluate via JSCore; skip parsing if login is required
        if pipeline.checkLoginRequired(html: html, baseURL: url.absoluteString, source: source) {
            return []
        }

        let books: [OnlineBook]
        do {
            books = try pipeline.parseSearchResults(
                html: html, baseURL: url.absoluteString, source: source,
                earlyFilter: earlyFilter)
        } catch {
            onHasMore?(false)
            return []
        }

        if let onHasMore {
            let hasMoreRule = source.ruleSearch.hasMoreRule
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !hasMoreRule.isEmpty {
                onHasMore(BookSourceSession.session(for: source).withBridge {
                    $0.evaluateHasMoreRule(hasMoreRule, html: html)
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
        return filtered
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

        return SearchStreamingOutcome(
            books: try await search(query: query, in: source),
            streamed: false
        )
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
