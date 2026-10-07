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

    init(route: OPDSFeedRoute, fetch: ((URL) async throws -> OPDSFeed)? = nil) {
        self.route = route
        fetchOverride = fetch
    }

    private var client: OPDSClient? {
        let store = RemoteLibraryConnectionStore.shared
        return store.connection(id: route.catalogID).map { store.client(for: $0) }
    }

    private func fetch(_ url: URL, client: OPDSClient, isSearch: Bool) async throws -> OPDSFeed {
        if let fetchOverride { return try await fetchOverride(url) }
        if route.catalogID == PublicLibraryID.gutenberg.rawValue {
            return try await PublicLibraryFeedTransport.fetch(url)
        }
        return try await client.fetchFeed(url, isSearch: isSearch)
    }

    func load(query: String = "") async {
        let id = UUID()
        requestID = id
        isLoading = true
        loadError = nil
        failedWhileLoadingMore = false
        defer { if requestID == id { isLoading = false } }
        guard let client, let url = URL(string: route.url) else {
            loadError = localized("書庫連線已移除，請重新加入伺服器。")
            return
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let requestURL: URL
            if !query.isEmpty, route.catalogID == PublicLibraryID.gutenberg.rawValue {
                requestURL = PublicLibrary.gutenbergSearchURL(query: query)
            } else if !query.isEmpty {
                guard let search, let resolved = try await client.searchFeedURL(search: search, query: query) else {
                    loadError = localized("此目錄不支援搜尋")
                    return
                }
                requestURL = resolved
            } else { requestURL = url }
            let feed = try await fetch(requestURL, client: client, isSearch: !query.isEmpty)
            try Task.checkCancellation()
            guard requestID == id else { return }
            entries = feed.entries
            nextPageURL = feed.nextPageURL
            self.query = query
            if query.isEmpty { search = feed.search }
            didLoad = true
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            AppLogger.network("OPDS feed failed", error: error, context: ["url": route.url])
            loadError = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let client, let nextPageURL, !isLoadingMore, !isLoading else { return }
        let id = requestID
        isLoadingMore = true
        loadError = nil
        failedWhileLoadingMore = false
        defer { isLoadingMore = false }
        do {
            let feed = try await fetch(nextPageURL, client: client, isSearch: !query.isEmpty)
            try Task.checkCancellation()
            guard requestID == id else { return }
            let existing = Set(entries.map(\.id))
            entries.append(contentsOf: feed.entries.filter { !existing.contains($0.id) })
            self.nextPageURL = feed.nextPageURL
        } catch {
            guard !Task.isCancelled, requestID == id else { return }
            failedWhileLoadingMore = true
            AppLogger.network("OPDS next page failed", error: error, context: ["url": nextPageURL.absoluteString])
            loadError = error.localizedDescription
        }
    }
}
