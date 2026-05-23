import Foundation

// MARK: - Discover / Explore

extension BookSourceFetcher {

    func discoverItems(
        page: Int = 1,
        in source: BookSource
    ) async -> [ModernParserBridge.DiscoverItem] {
        guard source.enabledExplore,
              !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }

        return await ModernParserBridge(source: source).getExploreItems(page: page)
    }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int = 1,
        in source: BookSource
    ) async throws -> [OnlineBook] {
        guard let rawURL = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty,
              !rawURL.hasPrefix("{{"),
              !rawURL.hasPrefix("{\\{")
        else { return [] }

        let bridge = ModernParserBridge(source: source)
        let (html, finalURL) = try await bridge.fetch(ruleUrl: rawURL, page: page)
        return bridge.parseExploreResults(html: html, baseURL: finalURL, source: source)
    }
}
