import Foundation

// MARK: - Discover / Explore

extension BookSourceFetcher {

    func discoverItems(
        page: Int = 1,
        in source: BookSource
    ) async -> [ModernParserBridge.DiscoverItem] {
        guard source.enabledExplore,
              !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }

        return await BookSourceSession.session(for: source)
            .bridgeForAsyncOperations.getExploreItems(page: page)
    }

    /// Prime any site cookie the source's discover endpoints need but don't set themselves
    /// (e.g. 起点 rankings read `_csrfToken`, only issued by browsing the site). No-op for
    /// sources that don't reference such a cookie, or once it's already present.
    func primeDiscoverCookies(in source: BookSource) async {
        await BookSourceSession.session(for: source)
            .bridgeForAsyncOperations.primeDiscoverCookiesIfNeeded()
    }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int = 1,
        in source: BookSource
    ) async throws -> [OnlineBook] {
        guard let rawURL = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty
        else {
            return []
        }

        let bridge = BookSourceSession.session(for: source).bridgeForAsyncOperations
        let (html, finalURL) = try await bridge.fetch(ruleUrl: rawURL, page: page)
        return bridge.parseExploreResults(html: html, baseURL: finalURL, source: source)
    }
}
