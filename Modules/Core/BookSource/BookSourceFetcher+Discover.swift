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
            NSLog("❖DISC❖ %@", "\(source.bookSourceName) discoverItems SKIP enabledExplore=\(source.enabledExplore)")
            return []
        }

        let items = await ModernParserBridge(source: source).getExploreItems(page: page)
        let cats = items.prefix(5).map { "\($0.title ?? "nil")[\($0.type ?? "-")]" }.joined(separator: ", ")
        NSLog("❖DISC❖ %@", "\(source.bookSourceName) discoverItems categories=\(items.count) :: \(cats)")
        return items
    }

    /// Prime any site cookie the source's discover endpoints need but don't set themselves
    /// (e.g. 起点 rankings read `_csrfToken`, only issued by browsing the site). No-op for
    /// sources that don't reference such a cookie, or once it's already present.
    func primeDiscoverCookies(in source: BookSource) async {
        await ModernParserBridge(source: source).primeDiscoverCookiesIfNeeded()
    }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int = 1,
        in source: BookSource
    ) async throws -> [OnlineBook] {
        guard let rawURL = item.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawURL.isEmpty
        else {
            NSLog("❖DISC❖ %@", "\(source.bookSourceName) discoverBooks SKIP empty item.url (title=\(item.title ?? "nil"))")
            return []
        }

        NSLog("❖DISC❖ %@", "\(source.bookSourceName) discoverBooks fetch page=\(page) url=\(rawURL.prefix(100))")
        let bridge = ModernParserBridge(source: source)
        do {
            let (html, finalURL) = try await bridge.fetch(ruleUrl: rawURL, page: page)
            let head = String(html.prefix(80)).replacingOccurrences(of: "\n", with: " ")
            NSLog("❖DISC❖ %@", "\(source.bookSourceName) discoverBooks html=\(html.count) bytes head=\(head)")
            let books = bridge.parseExploreResults(html: html, baseURL: finalURL, source: source)
            NSLog("❖DISC❖ %@", "\(source.bookSourceName) discoverBooks RESULT books=\(books.count)")
            return books
        } catch {
            NSLog("❖DISC❖ %@", "\(source.bookSourceName) discoverBooks ERROR: \(error.localizedDescription)")
            throw error
        }
    }
}
