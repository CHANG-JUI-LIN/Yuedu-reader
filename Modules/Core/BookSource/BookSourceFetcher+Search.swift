import Foundation

// MARK: - Search Books

extension BookSourceFetcher {

    func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        guard !source.searchUrl.isEmpty else { throw FetchError.noSearchURL }

        if source.shouldUseLegadoRuntimeFetch(for: source.searchUrl) {
            let books = try await ModernParserBridge(source: source)
                .searchBooks(keyword: query, page: 1)
            return filterSearchResultsByCheckKeyWord(
                books, query: query, checkKeyWord: source.ruleSearch.checkKeyWord)
        }

        let requestSpec = source.renderSearchRequest(query: query)
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
                html = try await Self.fetchViaWebView(url: url, headers: mergedHeaders)
            } else {
                html = try await fetchHTML(
                    url: url, method: requestSpec.method, body: requestSpec.body,
                    headers: mergedHeaders, baseURL: source.bookSourceUrl,
                    bodyCharset: requestSpec.charset,
                    allowInteractiveChallengeOn503: false)
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
                html: html, baseURL: url.absoluteString, source: source)
        } catch {
            return []
        }
        return filterSearchResultsByCheckKeyWord(
            books, query: query, checkKeyWord: source.ruleSearch.checkKeyWord)
    }

    /// Legado compatible: filter search results by checkKeyWord (keep only items matching keyword in title/author)
    private func filterSearchResultsByCheckKeyWord(
        _ books: [OnlineBook], query: String, checkKeyWord: String
    ) -> [OnlineBook] {
        guard !checkKeyWord.isEmpty, !query.isEmpty else { return books }
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return books }
        return books.filter { book in
            book.name.localizedCaseInsensitiveContains(key)
                || book.author.localizedCaseInsensitiveContains(key)
        }
    }
}
