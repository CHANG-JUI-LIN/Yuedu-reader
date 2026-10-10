import Foundation

/// Where a category's pages after the first stand (Phase 5 plan, decision 3): which page
/// comes next, whether there is one, and whether one is on its way or failed.
struct SectionPaging: Equatable, Sendable {
    private(set) var nextPage: Int
    private(set) var hasMore = true
    private(set) var isLoading = false
    /// Why the last page failed; cleared when the next one starts.
    private(set) var errorReason: String?

    /// A category whose first page is already shown asks for page 2 next.
    init(firstPageLoaded: Bool) {
        nextPage = firstPageLoaded ? 2 : 1
    }

    /// The page to ask for, or nil when one is already on its way or there are no more.
    mutating func start() -> Int? {
        guard hasMore, !isLoading else { return nil }
        isLoading = true
        errorReason = nil
        return nextPage
    }

    /// A page arrived with `newBooks` books not already shown. None means the category has
    /// run out — a source that repeats its last page for every later one included.
    mutating func receive(newBooks: Int, page: Int) {
        if newBooks == 0 {
            hasMore = false
        } else {
            nextPage = page + 1
            hasMore = true
        }
        isLoading = false
    }

    /// The page failed; the same page is asked for again on retry.
    mutating func fail(_ reason: String) {
        errorReason = reason
        isLoading = false
    }
}

/// The one loader of a book-source category's pages: fetch, drop the books already shown,
/// and make them displayable. `DiscoverCategoryBookList` (查看全部 and the list layout) and a
/// custom page's waterfall both page through it.
struct SectionPageLoader: Sendable {
    typealias FetchPage = @Sendable (ModernParserBridge.DiscoverItem, Int, BookSource) async throws -> [OnlineBook]

    /// Injected so the paging can be tested without the network (Phase 0 plan, decision 2).
    let fetchPage: FetchPage

    static let live = SectionPageLoader { item, page, source in
        try await BookSourceFetcher.shared.discoverBooks(from: item, page: page, in: source)
    }

    /// `page` of `section`, without the books in `existing`. Failures are logged here and
    /// rethrown for the caller to show.
    func books(
        page: Int,
        of section: DiscoverShowcaseSection,
        in source: BookSource,
        after existing: [OnlineBook]
    ) async throws -> [DiscoverBookDisplay] {
        do {
            let loaded = try await fetchPage(section.item.raw, page, source)
            let additional = DiscoverViewModel.uniqueAdditionalBooks(loaded, existing: existing)
            return await DiscoverViewModel.makeDisplays(additional, source: source)
        } catch {
            AppLogger.network("⟐ discover category page failed", error: error, context: [
                "category": section.title, "source": source.bookSourceName, "page": page,
            ])
            throw error
        }
    }
}
