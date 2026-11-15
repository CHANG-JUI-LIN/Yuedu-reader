import Foundation

/// An installed module's reviews of a work (format 3.0.1): finds the module's records of the
/// work, then reads each one's reviews.
///
/// Which records, in this order:
/// 1. the page's own record, when this module listed the work: no matching, it is the work;
/// 2. the record whose ISBN is one of the work's, through `lookup`, as the filler knows a copy's;
/// 3. the search results that are the same work (`ModuleFillProvider.sameWork`: title or alias,
///    a compatible author, the same kind), in the site's order.
///
/// Step 3 differs from the filler on purpose. The filler takes a value from one record, so two
/// candidates are a question it cannot answer and it fills nothing. Reviews of every upload or
/// edition of a work are still that work's reviews, and a site of uploads (20 results, 15
/// titles for one author) lists several of each book: the first `recordLimit` are read and
/// their reviews joined. A work that names no author is not searched for: a title alone is
/// not a work.
@MainActor
struct ModuleReviewProvider {
    /// Records read per work: each is a request under the module's `rateLimit`.
    nonisolated static let recordLimit = 3
    /// 作品詳情 asks module after module: a site that hangs must not hold up the rest.
    nonisolated static let timeout: Duration = .seconds(20)

    let provider: ModuleProvider
    private let client: RuleModuleClient
    private let timeout: Duration

    init(provider: ModuleProvider, client: RuleModuleClient = RuleModuleClient(), timeout: Duration = ModuleReviewProvider.timeout) {
        self.provider = provider
        self.client = client
        self.timeout = timeout
    }

    /// Nil when the module has no reviews block or no record of the work. Throws when finding the
    /// records failed, or when every record's reviews did.
    func reviews(for query: WorkReviewQuery) async throws -> WorkReviewSet? {
        let module = provider.module
        guard let block = module.reviews else { return nil }
        let key = Self.cacheKey(query)
        if let cached = client.cachedReviews(block, key: key, in: module) {
            return WorkReviewSet(moduleID: module.id, moduleTitle: module.title, reviews: cached.reviews, rating: cached.rating)
        }
        let records = try await records(for: query).filter { RuleModuleClient.canAskReviews(of: $0, by: block) }
        var reviews: [WorkReview] = []
        var rating: WorkRating?
        var seen = Set<String>()
        let client = client, timeout = timeout
        // A record whose request fails does not take the other records' reviews with it. The real
        // case (2026-11-14): this kind of site answered 502 to 2 requests of 16, and a work matched
        // by title is asked for up to three records, so failing the whole work on one of them
        // would hide the section on a third of such openings. Nothing is retried, and a set with a
        // record missing is never kept as the work's (the next opening asks again). It can go
        // when a work is asked for one record only.
        var failure: (any Error)?
        var answered = 0
        for record in records.prefix(Self.recordLimit) {
            do {
                let read = try await LibrarySearch.within(timeout) { try await client.reviews(of: record, by: block, in: module) }
                answered += 1
                // One reader's review under two uploads is one review.
                reviews += read.reviews.filter { seen.insert("\($0.author ?? "")\u{1F}\($0.text)").inserted }
                if rating == nil { rating = read.rating }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
                AppLogger.network("⟐ module reviews: a record's request failed", error: SourceFailure.loggable(error),
                                  context: ["module": module.id])
            }
        }
        if answered == 0, let failure { throw failure }
        reviews = Array(reviews.prefix(RuleModuleClient.reviewLimit))
        if failure == nil { client.saveReviews(reviews, rating: rating, by: block, key: key, in: module) }
        return WorkReviewSet(moduleID: module.id, moduleTitle: module.title, reviews: reviews, rating: rating)
    }

    /// The module's records of the work (the type's note), most certain first.
    func records(for query: WorkReviewQuery) async throws -> [RuleListItem] {
        let module = provider.module, provider = provider, timeout = timeout
        let searches = module.search.map { $0.listedKinds.contains(query.contentKind) && $0.takes(keyword: query.title) } ?? false
        // Asked once, for the page's own record and for the same work alike.
        var searched: [RuleListItem]?
        func searchItems() async throws -> [RuleListItem] {
            if let searched { return searched }
            let title = query.title
            let items = try await LibrarySearch.within(timeout) { try await provider.searchItems(title) } ?? []
            searched = items
            return items
        }

        if let own = query.record, own.instance == provider.instance, searches,
           let record = try await searchItems().first(where: { $0.bookUrl == own.item }) {
            return [record]
        }
        if let lookup = module.lookup, lookup.listedKinds.contains(query.contentKind) {
            let prefixes = lookup.isbnPrefixes ?? []
            if let isbn = query.isbns.first(where: { isbn in prefixes.isEmpty || prefixes.contains { isbn.hasPrefix($0) } }) {
                let items = try await LibrarySearch.within(timeout) { try await provider.lookupItems(isbn: isbn) } ?? []
                if let record = ModuleFillProvider.record(in: items, isbn: isbn) { return [record] }
            }
        }
        guard searches, let search = module.search, !query.authors.isEmpty else { return [] }
        return ModuleFillProvider.sameWork(in: try await searchItems(), of: search, title: query.title,
                                           authors: query.authors, contentKind: query.contentKind)
    }

    /// The search results called what the work is called, for a work that names no author
    /// (`records` finds none for it: a title alone is not a work). The caller must tell the
    /// work among them by something else; 本章說 does by its chapters.
    func titleRecords(for query: WorkReviewQuery) async throws -> [RuleListItem] {
        let module = provider.module, provider = provider, timeout = timeout
        guard let search = module.search, search.listedKinds.contains(query.contentKind), search.takes(keyword: query.title) else {
            return []
        }
        let title = query.title
        let items = try await LibrarySearch.within(timeout) { try await provider.searchItems(title) } ?? []
        var seen = Set<String>()
        return ModuleFillProvider.sameTitle(in: items, of: search, title: query.title, contentKind: query.contentKind)
            .filter { seen.insert($0.bookUrl.isEmpty ? "\($0.name)\u{1F}\($0.author)" : $0.bookUrl).inserted }
    }

    /// The work as the cache names it: what was asked, folded as it is matched.
    nonisolated static func cacheKey(_ query: WorkReviewQuery) -> [String: String] {
        ["title": WorkMatchKey.title(query.title),
         "authors": query.authors.map(WorkMatchKey.author).sorted().joined(separator: "\u{1F}"),
         "isbns": query.isbns.joined(separator: ","),
         "kind": query.contentKind.rawValue,
         "record": query.record.map { "\($0.instance.id)\u{1F}\($0.item)" } ?? ""]
    }
}
