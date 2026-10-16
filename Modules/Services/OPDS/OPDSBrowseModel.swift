import Combine
import Foundation

/// The saved-library list and the public bookstore share request, search,
/// pagination and error ownership. Layout changes never create another loader.
@MainActor
final class OPDSBrowseModel: ObservableObject {
    let route: OPDSFeedRoute
    @Published private(set) var entries: [OPDSEntry] = []
    @Published private(set) var nextPageURL: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var didLoad = false
    @Published private(set) var loadError: String?
    private(set) var failedWhileLoadingMore = false
    private var search: OPDSSearch?
    private var query = ""
    private var requestID = UUID()
    private let fetchOverride: ((URL) async throws -> OPDSFeed)?
    private let registry: SourceProviderRegistry

    /// - Parameter fetch: replaces the server request, for tests and previews.
    init(route: OPDSFeedRoute, fetch: ((URL) async throws -> OPDSFeed)? = nil, registry: SourceProviderRegistry? = nil) {
        self.route = route
        fetchOverride = fetch
        self.registry = registry ?? .shared
    }

    /// The route's source, resolved at each request (unified library 2a): Gutenberg or a saved
    /// OPDS or Calibre connection. Nil once the connection is removed.
    private var provider: (any OPDSFeedProviding)? {
        registry.opdsProvider(catalogID: route.catalogID)
    }

    private func fetch(_ url: URL, provider: any OPDSFeedProviding, isSearch: Bool) async throws -> OPDSFeed {
        if let fetchOverride { return try await fetchOverride(url) }
        return try await provider.feed(url, isSearch: isSearch)
    }

    func load(query: String = "") async {
        let id = UUID()
        requestID = id
        isLoading = true
        loadError = nil
        failedWhileLoadingMore = false
        defer { if requestID == id { isLoading = false } }
        guard let provider, let url = URL(string: route.url) else {
            loadError = SourceFailure.connectionRemoved.localizedDescription
            return
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let requestURL: URL
            if !query.isEmpty {
                // Gutenberg searches its own URL; a catalog searches what its root advertised.
                guard let resolved = try await provider.searchURL(query: query, search: search) else {
                    loadError = localized("此目錄不支援搜尋")
                    return
                }
                requestURL = resolved
            } else { requestURL = url }
            let feed = try await fetch(requestURL, provider: provider, isSearch: !query.isEmpty)
            try Task.checkCancellation()
            guard requestID == id else { return }
            entries = feed.entries
            nextPageURL = feed.nextPageURL
            self.query = query
            if query.isEmpty { search = feed.search }
            didLoad = true
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            AppLogger.network("OPDS feed failed", error: SourceFailure.loggable(error), context: ["url": route.url])
            loadError = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let provider, let nextPageURL, !isLoadingMore, !isLoading else { return }
        let id = requestID
        isLoadingMore = true
        loadError = nil
        failedWhileLoadingMore = false
        defer { isLoadingMore = false }
        do {
            let feed = try await fetch(nextPageURL, provider: provider, isSearch: !query.isEmpty)
            try Task.checkCancellation()
            guard requestID == id else { return }
            let existing = Set(entries.map(\.id))
            entries.append(contentsOf: feed.entries.filter { !existing.contains($0.id) })
            self.nextPageURL = feed.nextPageURL
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            failedWhileLoadingMore = true
            AppLogger.network("OPDS next page failed", error: SourceFailure.loggable(error), context: ["url": nextPageURL.absoluteString])
            loadError = error.localizedDescription
        }
    }
}
