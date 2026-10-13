import Foundation

/// The one place a book-source category's first page is fetched for a home (Discovery Phase
/// 7a-1): the home's category rows, its 「最新」 rows and 為你推薦 all ask here.
///
/// - **One request at a time per source.** A source's rules share one JS runtime, and
///   `BookSourceSession` does not serialize discover fetches (`SectionLoadPolicy.serialPerSource`),
///   so a 為你推薦 refresh must never run beside the source's own row.
/// - **One request per category in flight.** A row and 為你推薦 asking for the same category
///   together share the request.
/// - **Cookies primed once per source per sync**, before its first fetch, as the source's own
///   page primes once per load (`primeDiscoverCookiesIfNeeded` drops the site's token).
/// - **Every page is saved** to `ForYouCandidateStore`, so 為你推薦 reads what the rows
///   already fetched.
///
/// One per home: `SourceProviderRegistry.homeProviders` hands it to the providers it makes,
/// and calls `beginSync()` each time it makes them.
@MainActor
final class DiscoverFirstPages {
    typealias PrimeCookies = @Sendable (BookSource) async -> Void

    private struct Key: Hashable {
        let sourceURL: String
        let categoryURL: String
    }

    private let pageLoader: SectionPageLoader
    private let primeCookies: PrimeCookies
    private let store: ForYouCandidateStore
    private let now: @Sendable () -> Date
    private var inFlight: [Key: (id: UUID, task: Task<[OnlineBook], Error>)] = [:]
    /// The last fetch queued for each source; the next one starts after it.
    private var laneTails: [String: Task<[OnlineBook], Error>] = [:]
    private var primed: Set<String> = []

    init(
        pageLoader: SectionPageLoader = .live,
        primeCookies: @escaping PrimeCookies = { await BookSourceFetcher.shared.primeDiscoverCookies(in: $0) },
        store: ForYouCandidateStore = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.pageLoader = pageLoader
        self.primeCookies = primeCookies
        self.store = store
        self.now = now
    }

    /// The providers were made again: each source primes its cookies again before its next fetch.
    func beginSync() {
        primed.removeAll()
    }

    /// The category's first page, without the books it repeats. Joins a request for the same
    /// category already on its way; otherwise queues behind the source's other fetches.
    /// Failures are logged by `SectionPageLoader` and thrown to every asker.
    func firstPage(of category: ExploreCategoryReference, in source: BookSource) -> Task<[OnlineBook], Error> {
        let key = Key(sourceURL: source.bookSourceUrl, categoryURL: category.url)
        if let running = inFlight[key] { return running.task }
        let id = UUID()
        let previous = laneTails[key.sourceURL]
        let primes = primed.insert(key.sourceURL).inserted
        let pageLoader = pageLoader, primeCookies = primeCookies, store = store, now = now
        // On the main actor, so the request is forgotten before anyone waiting on it resumes:
        // an ask after a failure fetches again.
        let task = Task<[OnlineBook], Error> { @MainActor in
            defer { if inFlight[key]?.id == id { inFlight[key] = nil } }
            _ = await previous?.result
            if primes { await primeCookies(source) }
            guard let item = category.cardItem else { return [] }
            let section = DiscoverShowcaseSection(item: item, coverBaseURL: source.bookSourceUrl,
                                                  coverHeaders: source.parsedHeaders)
            let books = try await pageLoader.books(page: 1, of: section, in: source, after: []).map(\.book)
            await store.write(ForYouCandidates(sourceURL: key.sourceURL, categoryURL: key.categoryURL,
                                               fetchedAt: now(), books: books))
            return books
        }
        inFlight[key] = (id, task)
        laneTails[key.sourceURL] = task
        return task
    }
}
