import Foundation

// MARK: - Discover / Explore

extension BookSourceFetcher {

    func discoverItems(
        page: Int = 1,
        in source: BookSource
    ) async throws -> [ModernParserBridge.DiscoverItem] {
        try await discoverItems(page: page, in: source, variableOverlay: [:])
    }

    /// - Parameter variableOverlay: discover filter values the explore rule reads in place of
    ///   the source's stored ones, without storing them (an Explore home section's, 5d-5).
    func discoverItems(
        page: Int = 1,
        in source: BookSource,
        variableOverlay: [String: String]
    ) async throws -> [ModernParserBridge.DiscoverItem] {
        guard source.enabledExplore,
              !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return []
        }

        return try await BookSourceSession.session(for: source).host
            .getExploreItems(page: page, variableOverlay: variableOverlay)
    }

    /// Prime any site cookie the source's discover endpoints need but don't set themselves
    /// (e.g. 起点 rankings read `_csrfToken`, only issued by browsing the site). No-op for
    /// sources that don't reference such a cookie, or once it's already present.
    func primeDiscoverCookies(in source: BookSource) async {
        await BookSourceSession.session(for: source).host.primeDiscoverCookiesIfNeeded()
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

        let books = try await BookSourceSession.session(for: source).host.exploreBooks(ruleUrl: rawURL, page: page)
        // Every explore row's cover, not just the ones a screen prefetches: `BookCoverLoader`
        // only sees a URL, and an unregistered cover from a `coverDecodeJs` source is drawn
        // from its encrypted bytes — blank (FB-135: 探索 sections, 查看全部, the related row).
        for book in books {
            CoverDecodeService.shared.registerIfNeeded(
                coverUrl: book.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines),
                source: source
            )
        }
        return books
    }
}
