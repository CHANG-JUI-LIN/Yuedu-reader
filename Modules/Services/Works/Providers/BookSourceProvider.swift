import Foundation

/// A book source (來源配置) on the Explore home (unified library 5b): its discover categories
/// as rows, and the category the reader picked to stand for its 「最新」 (design §13.3).
///
/// Pages come through the home's `DiscoverFirstPages` (Discovery Phase 7a-1), which primes the
/// discover cookies once per source per sync, as the source's own page primes them (audit
/// §12.3), queues the source's fetches one at a time and saves each page for 為你推薦.
@MainActor
final class BookSourceProvider: HomeSectionProviding {
    let source: BookSource
    private let firstPages: DiscoverFirstPages

    init(source: BookSource, firstPages: DiscoverFirstPages) {
        self.source = source
        self.firstPages = firstPages
    }

    /// A provider with a first-page fetcher and a queue of its own, for tests.
    convenience init(
        source: BookSource,
        pageLoader: SectionPageLoader,
        primeCookies: @escaping DiscoverFirstPages.PrimeCookies
    ) {
        self.init(source: source, firstPages: DiscoverFirstPages(pageLoader: pageLoader, primeCookies: primeCookies,
                                                                 lanes: DiscoverRequestLanes()))
    }

    var instance: SourceInstanceKey { SourceInstanceKey(type: .bookSource, id: source.bookSourceUrl) }
    var displayName: String { source.bookSourceName }
    var availability: ProviderAvailability { .available }
    var hosts: [String] { BookSourceManifest.hosts(of: source) }
    var additionalCapabilities: Set<ProviderCapability> { BookSourceManifest.capabilities(of: source) }
    var rateLimit: String? { BookSourceManifest.rateLimit(of: source) }

    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        categories(for: section).isEmpty ? nil : .serialPerSource
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        let categories = categories(for: section)
        if section.drawsCategoryCards { return try await cards(of: categories) }
        guard let category = categories.first, category.cardItem != nil else { return [] }
        do {
            let books = try await firstPages.firstPage(of: category, in: source).value
            return books.prefix(HomeRow.limit).map { entry($0) }
        } catch {
            throw try SourceFailure.classify(error)
        }
    }

    /// The categories a section shows from this source: its own (`HomeSection.shownCategories`),
    /// or the one picked for 「最新」.
    private func categories(for section: HomeSection) -> [ExploreCategoryReference] {
        switch section.binding {
        case .sourceCategories:
            return section.shownCategories.filter { $0.sourceURL == source.bookSourceUrl }
        case .latest:
            return section.latestCategory(forSourceURL: source.bookSourceUrl).map { [$0] } ?? []
        default:
            return []
        }
    }

    /// 分類卡片: a card per category, in the section's order, each its first page's first covers.
    /// The pages are asked for together and come one at a time, each the request a row of the
    /// category or 為你推薦 makes. A category that fails or holds no book has no card, in the log;
    /// the section fails only when no card is left and a page failed.
    private func cards(of categories: [ExploreCategoryReference]) async throws -> [CollectionEntry] {
        let started = SourcePerfTrace.now
        let pages = categories.map { category in
            (category, category.cardItem == nil ? nil : firstPages.firstPage(of: category, in: source))
        }
        var cards: [CollectionEntry] = []
        var failure: Error?
        for (category, page) in pages {
            let context = ["source": source.bookSourceUrl, "category": category.title]
            guard let page else {
                AppLogger.network("⟐ category card is not a discover category", context: context)
                continue
            }
            do {
                let books = try await page.value
                guard !books.isEmpty else {
                    AppLogger.network("⟐ category card's first page has no book", context: context)
                    continue
                }
                cards.append(.collection(.sourceCategory(category, firstPage: books, source: source)))
            } catch {
                AppLogger.network("⟐ category card's first page failed", error: error, context: context)
                if failure == nil { failure = error }
            }
        }
        SourcePerfTrace.record("home.categoryCards", "categories=\(categories.count) cards=\(cards.count)",
                               since: started, thresholdMs: 0, mainThreadStallBreadcrumb: false)
        if cards.isEmpty, let failure { throw try SourceFailure.classify(failure) }
        return cards
    }

    private func entry(_ book: OnlineBook) -> CollectionEntry {
        .onlineBook(book, source: source)
    }
}

extension CollectionEntry {
    /// A book-source book as 作品詳情 opens it: a row of Explore's home (`BookSourceProvider`) and
    /// a result of 搜索 (`WorkDetailRoute(searchResult:)`, unified library 5f-4c) make the same item.
    ///
    /// - Parameters:
    ///   - contentKind: a search result's kind, snapshotted when it arrived; nil infers it.
    ///   - blurb: a search result's row text, made when it arrived; nil reads the book's intro.
    ///     A search route never parses its HTML again where the destination is built
    ///     (Technotes/iOS17SearchWatchdogPostmortem.md, guardrail 5).
    static func onlineBook(_ book: OnlineBook, source: BookSource,
                           contentKind: OnlineBookContentKind? = nil, blurb: String? = nil) -> CollectionEntry {
        let record = SourceRecord.derived(from: book, source: source, contentKind: contentKind)
        let base = URL(string: source.bookSourceUrl)
        let cover = URL(string: book.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)
            .map(\.absoluteURL)
            .flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        let blurb = blurb ?? SearchResultIPSDiagnostics.sanitizeIntroForSearchRow(
            OnlineBookDetailPresentationPolicy.sanitizeIntro(book.intro)
        )
        return .item(record,
                     WorkSummary(title: book.name, authors: record.authors,
                                 cover: cover.map { .remote($0, headers: source.parsedHeaders) } ?? .generated(seed: book.name),
                                 blurb: blurb, language: nil, contentKind: record.contentKind,
                                 category: WorkSummary.category(fromSourceKind: book.kind)),
                     .onlineBook(FrozenOnlineBook(book: book)))
    }
}

extension WorkDetailRoute {
    /// 搜索's result as 作品詳情 opens it (unified library 5f-4c, decision 29), built from the
    /// snapshot the route froze at the tap (Technotes/iOS17SearchWatchdogPostmortem.md, guardrail 1).
    /// The version is the origin the result's own page opens on — an audiobook's first audio
    /// origin, else the first — so the versions, the pin and the shelf lookup name the source shown.
    ///
    /// Nil when the result has no origin, or its source is no longer installed.
    @MainActor
    init?(searchResult: SearchBook, sources: BookSourceStore = .shared) {
        let kind = searchResult.inferredContentKind()
        guard let origin = (kind == .audio ? searchResult.preferredOrigin(for: .audio) : nil) ?? searchResult.origins.first
        else { return nil }
        guard let source = sources.source(id: origin.sourceId) else {
            AppLogger.error("⟐ search result's source is gone", context: ["source": origin.sourceName])
            return nil
        }
        let book = OnlineBook(detailOrigin: origin, in: searchResult)
        self.init(CollectionEntry.onlineBook(book, source: source, contentKind: searchResult.contentKind(for: origin) ?? kind,
                                             blurb: searchResult.displayIntro))
    }
}

extension HomeSection {
    /// The parameter holding the category picked for a book source's 「最新」 (design §13.3:
    /// 「由使用者指定一個發現分類代表它」). One per source, on the one 「最新」 section.
    static func latestCategoryKey(sourceURL: String) -> String {
        "latest.category:" + sourceURL
    }

    func latestCategory(forSourceURL sourceURL: String) -> ExploreCategoryReference? {
        guard let stored = parameters[Self.latestCategoryKey(sourceURL: sourceURL)] else { return nil }
        do {
            let reference = try JSONDecoder().decode(ExploreCategoryReference.self, from: Data(stored.utf8))
            return reference.sourceURL == sourceURL ? reference : nil
        } catch {
            AppLogger.cache("⟐ home 「最新」 category unreadable", error: error, context: ["source": sourceURL])
            return nil
        }
    }

    mutating func setLatestCategory(_ reference: ExploreCategoryReference?, forSourceURL sourceURL: String) {
        let key = Self.latestCategoryKey(sourceURL: sourceURL)
        guard let reference else {
            parameters[key] = nil
            setFilterValues([:], forSourceURL: sourceURL)
            return
        }
        do {
            parameters[key] = String(decoding: try JSONEncoder().encode(reference), as: UTF8.self)
        } catch {
            AppLogger.cache("⟐ home 「最新」 category could not be stored", error: error, context: ["source": sourceURL])
        }
    }

    // MARK: Discover filters

    /// The parameter holding the discover filter values a book source's category was picked
    /// under (unified library 5d-5, decision 23): the section's own, kept here instead of in
    /// the source's shared variables, by source, so 最新 keeps one set per source.
    ///
    /// The source reads them when it lists its categories (`SourceCategoryListing`); a source
    /// that writes them into the category's URL (光遇) shows them in the section. A source that
    /// reads them again when it loads the books reads its shared ones there.
    static func filtersKey(sourceURL: String) -> String {
        "filters:" + sourceURL
    }

    func filterValues(forSourceURL sourceURL: String) -> [String: String] {
        Self.filterValues(in: parameters, sourceURL: sourceURL)
    }

    static func filterValues(in parameters: [String: String], sourceURL: String) -> [String: String] {
        guard let stored = parameters[filtersKey(sourceURL: sourceURL)] else { return [:] }
        do {
            return try JSONDecoder().decode([String: String].self, from: Data(stored.utf8))
        } catch {
            AppLogger.cache("⟐ home section's discover filters unreadable", error: error, context: ["source": sourceURL])
            return [:]
        }
    }

    /// Empty values remove the parameter.
    mutating func setFilterValues(_ values: [String: String], forSourceURL sourceURL: String) {
        parameters.merge(Self.filterParameters(values, sourceURL: sourceURL)) { $1 }
        if values.isEmpty { parameters[Self.filtersKey(sourceURL: sourceURL)] = nil }
    }

    /// The parameter for `values`, keys sorted so the same values are the same parameter
    /// (`HomeModel.sync` keeps a row whose parameters did not change).
    static func filterParameters(_ values: [String: String], sourceURL: String) -> [String: String] {
        guard !values.isEmpty else { return [:] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return [filtersKey(sourceURL: sourceURL): String(decoding: try encoder.encode(values), as: UTF8.self)]
        } catch {
            AppLogger.cache("⟐ home section's discover filters could not be stored", error: error, context: ["source": sourceURL])
            return [:]
        }
    }
}
