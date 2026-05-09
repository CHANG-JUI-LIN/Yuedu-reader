import Foundation

// MARK: - 搜索書籍

extension BookSourceFetcher {

    func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        guard !source.searchUrl.isEmpty else { throw FetchError.noSearchURL }

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

        // Legado loginCheckJs：透過 JSCore 求值，若回傳需登入則跳過解析
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

    /// Legado 相容：依 checkKeyWord 過濾搜尋結果（僅保留書名/作者含關鍵字的項）
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
