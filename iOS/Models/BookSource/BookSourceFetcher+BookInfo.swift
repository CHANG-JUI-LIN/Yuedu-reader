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
        guard let bookURL = safeURL(string: url) else { throw FetchError.invalidURL(url) }
        let html: String
        if source.needsWebView {
            html = try await Self.fetchViaWebView(url: bookURL, headers: source.parsedHeaders)
        } else {
            html = try await fetchHTML(
                url: bookURL, method: "GET", body: nil,
                headers: source.parsedHeaders, baseURL: source.bookSourceUrl)
        }
        let info = try pipeline.parseBookInfo(
            html: html,
            bookUrl: url,
            baseURL: bookURL.absoluteString,
            source: source,
            runtimeVariables: runtimeVariables
        )
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
