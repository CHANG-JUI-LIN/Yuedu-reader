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
/// and calls `beginSync()` each time it makes them. The queue and the requests on their way
/// are the app's (`DiscoverRequestLanes.shared`), not the home's: 探索's home, a library's home
/// and a section form's preview can be open at once, and a source's JS runtime must still see
/// one discover fetch at a time.
@MainActor
final class DiscoverFirstPages {
    typealias PrimeCookies = @Sendable (BookSource) async -> Void

    private let pageLoader: SectionPageLoader
    private let primeCookies: PrimeCookies
    private let store: ForYouCandidateStore
    private let lanes: DiscoverRequestLanes
    private let now: @Sendable () -> Date
    private var primed: Set<String> = []

    init(
        pageLoader: SectionPageLoader = .live,
        primeCookies: @escaping PrimeCookies = { await BookSourceFetcher.shared.primeDiscoverCookies(in: $0) },
        store: ForYouCandidateStore = .shared,
        lanes: DiscoverRequestLanes = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.pageLoader = pageLoader
        self.primeCookies = primeCookies
        self.store = store
        self.lanes = lanes
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
        let key = DiscoverRequestLanes.Key(sourceURL: source.bookSourceUrl, categoryURL: category.url)
        if let running = lanes.running(key) { return running }
        let primes = primed.insert(key.sourceURL).inserted
        let pageLoader = pageLoader, primeCookies = primeCookies, store = store, now = now
        return lanes.enqueue(key) {
            if primes { await primeCookies(source) }
            guard let item = category.cardItem else { return [] }
            let section = DiscoverShowcaseSection(item: item, coverBaseURL: source.bookSourceUrl,
                                                  coverHeaders: source.parsedHeaders)
            let books = try await pageLoader.books(page: 1, of: section, in: source, after: []).map(\.book)
            await store.write(ForYouCandidates(sourceURL: key.sourceURL, categoryURL: key.categoryURL,
                                               fetchedAt: now(), books: books))
            return books
        }
    }
}

/// The app's discover requests by source: one at a time per source, and one per category on
/// its way, whichever home asked.
@MainActor
final class DiscoverRequestLanes {
    static let shared = DiscoverRequestLanes()

    struct Key: Hashable {
        let sourceURL: String
        let categoryURL: String
    }

    private var inFlight: [Key: (id: UUID, task: Task<[OnlineBook], Error>)] = [:]
    /// The last request queued for each source; the next one starts after it.
    private var tails: [String: Task<[OnlineBook], Error>] = [:]

    /// The request for `key` on its way, to join.
    func running(_ key: Key) -> Task<[OnlineBook], Error>? {
        inFlight[key]?.task
    }

    /// Runs `work` after the source's requests queued before it.
    func enqueue(_ key: Key, _ work: @escaping @MainActor () async throws -> [OnlineBook]) -> Task<[OnlineBook], Error> {
        let id = UUID()
        let previous = tails[key.sourceURL]
        // On the main actor, so the request is forgotten before anyone waiting on it resumes:
        // an ask after a failure fetches again.
        let task = Task<[OnlineBook], Error> { @MainActor in
            defer { if inFlight[key]?.id == id { inFlight[key] = nil } }
            _ = await previous?.result
            return try await work()
        }
        inFlight[key] = (id, task)
        tails[key.sourceURL] = task
        return task
    }
}
