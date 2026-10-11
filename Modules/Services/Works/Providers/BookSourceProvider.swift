import Foundation

/// A book source (來源配置) on the Explore home (unified library 5b): its discover categories
/// as rows, and the category the reader picked to stand for its 「最新」 (design §13.3).
///
/// Pages come through `SectionPageLoader`, the one loader of a category's pages, after the
/// discover cookies are primed as the source's own page primes them (audit §12.3).
@MainActor
final class BookSourceProvider: HomeSectionProviding {
    let source: BookSource
    private let pageLoader: SectionPageLoader
    private let primeCookies: @Sendable (BookSource) async -> Void
    /// Priming drops the site's token and fetches the search page again
    /// (`primeDiscoverCookiesIfNeeded`), so it runs once per provider, that is once per home
    /// sync, as the source's own page primes once per load, not once per row.
    private var priming: Task<Void, Never>?

    init(
        source: BookSource,
        pageLoader: SectionPageLoader = .live,
        primeCookies: @escaping @Sendable (BookSource) async -> Void = { await BookSourceFetcher.shared.primeDiscoverCookies(in: $0) }
    ) {
        self.source = source
        self.pageLoader = pageLoader
        self.primeCookies = primeCookies
    }

    var instance: SourceInstanceKey { SourceInstanceKey(type: .bookSource, id: source.bookSourceUrl) }
    var displayName: String { source.bookSourceName }
    var availability: ProviderAvailability { .available }

    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        category(for: section) == nil ? nil : .serialPerSource
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        guard let category = category(for: section), let item = category.cardItem else { return [] }
        if priming == nil {
            let prime = primeCookies, source = source
            priming = Task { await prime(source) }
        }
        await priming?.value
        let section = DiscoverShowcaseSection(item: item, coverBaseURL: source.bookSourceUrl, coverHeaders: source.parsedHeaders)
        do {
            let displays = try await pageLoader.books(page: 1, of: section, in: source, after: [])
            return displays.prefix(HomeRow.limit).map { entry($0.book) }
        } catch {
            throw try SourceFailure.classify(error)
        }
    }

    /// The category a section shows from this source: its own, or the one picked for 「最新」.
    private func category(for section: HomeSection) -> ExploreCategoryReference? {
        switch section.binding {
        case .sourceCategories(let references):
            return references.first { $0.sourceURL == source.bookSourceUrl }
        case .latest:
            return section.latestCategory(forSourceURL: source.bookSourceUrl)
        default:
            return nil
        }
    }

    private func entry(_ book: OnlineBook) -> CollectionEntry {
        let record = SourceRecord.derived(from: book, source: source)
        let base = URL(string: source.bookSourceUrl)
        let cover = URL(string: book.coverUrl.trimmingCharacters(in: .whitespacesAndNewlines), relativeTo: base)
            .map(\.absoluteURL)
            .flatMap { $0.scheme?.hasPrefix("http") == true ? $0 : nil }
        let blurb = SearchResultIPSDiagnostics.sanitizeIntroForSearchRow(
            OnlineBookDetailPresentationPolicy.sanitizeIntro(book.intro)
        )
        return .item(record,
                     WorkSummary(title: book.name, authors: record.authors,
                                 cover: cover.map { .remote($0, headers: source.parsedHeaders) } ?? .generated(seed: book.name),
                                 blurb: blurb, language: nil, contentKind: record.contentKind),
                     .onlineBook(FrozenOnlineBook(book: book)))
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
