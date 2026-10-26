import Foundation

/// A library row on the home, as 為你推薦 reads it.
struct ForYouLibraryRow: Sendable {
    let source: SourceInstanceKey
    let entries: [CollectionEntry]
}

/// What 為你推薦 reads from the home it is on.
@MainActor
protocol ForYouHomeRows: AnyObject {
    /// The last pull to refresh.
    var refreshedAt: Date? { get }
    /// The library rows' books, once the ones loading with the home have settled.
    func settledLibraryEntries() async -> [ForYouLibraryRow]
}

extension HomeSection {
    /// 為你推薦's own categories, added in its form.
    static let forYouCategoriesKey = "forYou.categories"
    /// The home's categories 為你推薦 leaves out, by `ExploreCategoryReference.id`.
    static let forYouExcludedKey = "forYou.excluded"

    var forYouAddedCategories: [ExploreCategoryReference] {
        decodeParameter([ExploreCategoryReference].self, forKey: Self.forYouCategoriesKey) ?? []
    }

    var forYouExcludedCategories: Set<String> {
        Set(decodeParameter([String].self, forKey: Self.forYouExcludedKey) ?? [])
    }

    /// 加入分類 in 為你推薦's form: a home category left out comes back; any other is added.
    mutating func addForYouCategory(_ reference: ExploreCategoryReference, homeSections: [HomeSection]) {
        var excluded = forYouExcludedCategories
        if excluded.remove(reference.id) != nil {
            setParameter(excluded.sorted(), forKey: Self.forYouExcludedKey)
        }
        guard !ForYouInputs.categories(on: homeSections, for: self).contains(where: { $0.id == reference.id }) else { return }
        setParameter(forYouAddedCategories + [reference], forKey: Self.forYouCategoriesKey)
    }

    /// 移除 in 為你推薦's form: one it added goes; one of the home's is left out.
    mutating func removeForYouCategory(_ reference: ExploreCategoryReference, homeSections: [HomeSection]) {
        let added = forYouAddedCategories
        if added.contains(reference) {
            setParameter(added.filter { $0 != reference }, forKey: Self.forYouCategoriesKey)
        }
        if ForYouInputs.categories(on: homeSections, for: HomeSection(layout: layout, binding: .forYou)).contains(reference) {
            setParameter((forYouExcludedCategories.union([reference.id])).sorted(), forKey: Self.forYouExcludedKey)
        }
    }

    /// Empty removes the parameter.
    private mutating func setParameter<T: Encodable & Collection>(_ value: T, forKey key: String) {
        guard !value.isEmpty else {
            parameters[key] = nil
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            parameters[key] = String(decoding: try encoder.encode(value), as: UTF8.self)
        } catch {
            AppLogger.cache("⟐ 為你推薦 option could not be stored", error: error, context: ["key": key])
        }
    }

    private func decodeParameter<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let stored = parameters[key] else { return nil }
        do {
            return try JSONDecoder().decode(type, from: Data(stored.utf8))
        } catch {
            AppLogger.cache("⟐ 為你推薦 option unreadable", error: error, context: ["key": key])
            return nil
        }
    }
}

/// The book-source categories 為你推薦 mixes (Discovery Phase 7a, maintainer's decision 1):
/// every category the 首頁配置 shows, as a row or as a source's 「最新」, and the section's own
/// additions, less what it leaves out. Nothing is guessed from a category's name.
enum ForYouInputs {
    static func categories(on sections: [HomeSection], for forYou: HomeSection) -> [ExploreCategoryReference] {
        var found: [ExploreCategoryReference] = []
        for section in sections where section.isEnabled {
            switch section.binding {
            case .sourceCategories:
                found += section.shownCategories
            case .latest:
                let prefix = HomeSection.latestCategoryKey(sourceURL: "")
                for key in section.parameters.keys.sorted() where key.hasPrefix(prefix) {
                    if let reference = section.latestCategory(forSourceURL: String(key.dropFirst(prefix.count))) {
                        found.append(reference)
                    }
                }
            default:
                continue
            }
        }
        found += forYou.forYouAddedCategories
        let excluded = forYou.forYouExcludedCategories
        var seen = Set<String>()
        return found.filter { !excluded.contains($0.id) && seen.insert($0.sourceURL + "\u{1F}" + $0.url).inserted }
    }
}

/// 為你推薦 (Discovery Phase 7a-4): the home's book-source categories, read from the
/// candidate cache and fetched again through the home's `DiscoverFirstPages` only when older
/// than 12 hours (or on pull to refresh), one at a time; the home's library rows as they
/// loaded; ranked on the device by `ForYouRanker`.
@MainActor
final class ForYouProvider: HomeSectionProviding {
    static let instanceKey = SourceInstanceKey(type: .library, id: "forYou")

    private let firstPages: DiscoverFirstPages
    private let candidates: ForYouCandidateStore
    private weak var home: (any ForYouHomeRows)?
    private let homeSections: @MainActor () -> [HomeSection]
    private let shelf: BookStore
    private let sources: @MainActor () -> [BookSource]
    private let genres: ReadingGenreRecorder
    private let exposure: ForYouExposureStore
    private let languages: @MainActor () -> ReadingLanguagePreferences
    private let now: () -> Date

    init(firstPages: DiscoverFirstPages,
         home: (any ForYouHomeRows)?,
         shelf: BookStore,
         candidates: ForYouCandidateStore = .shared,
         homeSections: @escaping @MainActor () -> [HomeSection] = { HomePageStore.shared.page?.sections ?? [] },
         sources: @escaping @MainActor () -> [BookSource] = { DiscoverViewModel.exploreSources(in: .shared) },
         genres: ReadingGenreRecorder = .shared,
         exposure: ForYouExposureStore = .shared,
         languages: @escaping @MainActor () -> ReadingLanguagePreferences = { AggregationSettingsStore.shared.readingLanguages },
         now: @escaping () -> Date = Date.init) {
        self.firstPages = firstPages
        self.home = home
        self.shelf = shelf
        self.candidates = candidates
        self.homeSections = homeSections
        self.sources = sources
        self.genres = genres
        self.exposure = exposure
        self.languages = languages
        self.now = now
    }

    var instance: SourceInstanceKey { Self.instanceKey }
    var displayName: String { localized("為你推薦") }
    var availability: ProviderAvailability { .available }
    /// It reads the pages the home has already fetched.
    var hosts: [String] { [] }

    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        section.binding == .forYou ? .withHome : nil
    }

    /// It mixes in the home's library rows (`ForYouHomeRows.settledLibraryEntries`).
    var readsHomeLibraryRows: Bool { true }

    /// The categories it reads, and 中繼資料語言偏好推薦, whose books it puts first: a home whose
    /// categories or language changed loads it again.
    func inputsKey(for section: HomeSection) -> String? {
        guard section.binding == .forYou else { return nil }
        return ForYouInputs.categories(on: homeSections(), for: section).map(\.id).joined(separator: "\u{1E}")
            + "\u{1D}" + languages().language
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        guard section.binding == .forYou else { return [] }
        let started = now()
        // Asked again: what was read before the last pull to refresh, or 12 hours ago.
        let refreshedAt = home?.refreshedAt
        let hadHome = home != nil
        let installed = Dictionary(sources().map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { first, _ in first })
        var inputs: [ForYouInput] = []
        var failed = 0
        var cacheSeconds: TimeInterval = 0
        var reads: [(category: ExploreCategoryReference, source: BookSource, books: ForYouCandidates?, fresh: Bool)] = []
        for category in ForYouInputs.categories(on: homeSections(), for: section) {
            guard let source = installed[category.sourceURL] else { continue }
            let reading = SourcePerfTrace.now
            let books = await candidates.read(sourceURL: category.sourceURL, categoryURL: category.url, sourceID: source.id)
            cacheSeconds += SourcePerfTrace.now - reading
            let fresh = books.map { cached in
                cached.isFresh(at: started) && !(refreshedAt.map { cached.fetchedAt < $0 } ?? false)
            } ?? false
            reads.append((category, source, books, fresh))
        }
        let asked = reads.count
        // The stale categories are asked for at once, a source's one after another and the
        // sources side by side, as the lanes run them (7a-5: one at a time made a cold home's
        // 為你推薦 wait for every request in turn).
        let stale = Dictionary(grouping: reads.indices.filter { !reads[$0].fresh }) { reads[$0].source.bookSourceUrl }
        let fetched = stale.values.reduce(0) { $0 + $1.count }
        let asks = reads.map { ($0.category, $0.source) }
        let fetches = stale.values.map { indices in
            Task { @MainActor in
                var pages: [(index: Int, result: Result<[OnlineBook], Error>)] = []
                for index in indices {
                    // The home went away: nothing more is asked for it.
                    if hadHome, home == nil { break }
                    let (category, source) = asks[index]
                    let fetching = SourcePerfTrace.now
                    do {
                        pages.append((index, .success(try await firstPages.firstPage(of: category, in: source).value)))
                    } catch {
                        pages.append((index, .failure(error)))
                    }
                    SourcePerfTrace.record("forYou.fetch", "source=\(source.bookSourceName) category=\(category.title)",
                                           since: fetching, thresholdMs: 0)
                }
                return pages
            }
        }
        for fetch in fetches {
            for (index, result) in await fetch.value {
                let (category, source, cached, _) = reads[index]
                switch result {
                case .success(let page):
                    reads[index].books = ForYouCandidates(sourceURL: category.sourceURL, categoryURL: category.url,
                                                          fetchedAt: now(), books: page)
                case .failure(let error):
                    failed += 1
                    AppLogger.network("⟐ 為你推薦 kept a category's earlier books", error: error, context: [
                        "source": source.bookSourceName, "category": category.title, "cached": "\(cached?.books.count ?? 0)",
                    ])
                }
            }
        }
        for read in reads {
            for (position, book) in (read.books?.books ?? []).enumerated() {
                inputs.append(ForYouInput(entry: .onlineBook(book, source: read.source), source: read.source.bookSourceUrl,
                                          position: position, tags: .sourceKind(book.kind)))
            }
        }
        SourcePerfTrace.record("forYou.cache", "categories=\(asked) fetched=\(fetched)",
                               since: SourcePerfTrace.now - cacheSeconds, thresholdMs: 0)
        if let home {
            for row in await home.settledLibraryEntries() {
                for (position, entry) in row.entries.enumerated() {
                    guard case .item(_, let summary, _) = entry else { continue }
                    inputs.append(ForYouInput(entry: entry, source: "\(row.source.type.rawValue):\(row.source.id)",
                                              position: position, tags: .raw(summary.category.map { [$0] } ?? [])))
                }
            }
        }
        // Every category failed with nothing saved: the section takes no room (maintainer,
        // 2026-10-13); each category's own row shows its failure.
        if inputs.isEmpty, asked > 0, failed == asked {
            AppLogger.network("⟐ 為你推薦 has nothing: every category failed", context: ["categories": "\(asked)"])
            return []
        }
        let date = now()
        let recent = ShelfProvider(store: shelf).continueReading(limit: HomeRow.limit).reduce(into: ForYouRanker.Recent()) { recent, entry in
            guard case .item(_, let summary, _) = entry else { return }
            recent.authors += summary.authors
            if let category = summary.category { recent.tags.append(category) }
        }
        let shown = await exposure.recentlyShown(at: date)
        let weights = await genres.profile().weights(at: date)
        let books = shelf.books, languages = languages(), seed = Self.seed(for: date), offered = inputs
        // Off the main actor: folding titles and tags costs ICU transforms, about 0.1 ms each
        // in a Debug simulator build (7a-5: 2000 shelf books and 600 candidates took 450 ms).
        let (ranked, keys) = await Task.detached(priority: .userInitiated) {
            let ranking = SourcePerfTrace.now
            let candidates = offered.map(\.candidate)
            let shelfWorks = ForYouRanker.shelfWorks(books)
            let ranked = ForYouRanker.rank(
                candidates: candidates, shelf: shelfWorks, weights: weights, recent: recent, recentlyShown: shown,
                languages: languages, seed: seed, limit: HomeRow.limit)
            SourcePerfTrace.record("forYou.rank", "candidates=\(candidates.count) shelf=\(shelfWorks.count) entries=\(ranked.count)",
                                   since: ranking, thresholdMs: 0)
            return (ranked, ranked.compactMap(ForYouRanker.workKey(of:)))
        }.value
        await exposure.record(keys, at: date)
        return ranked
    }

    /// The day, so the explored books stay put within it.
    static func seed(for date: Date) -> UInt64 {
        UInt64(max(0, Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0))
    }
}

/// A book an input offered, its tags not yet folded: `ForYouProvider` folds them off the main actor.
private struct ForYouInput: Sendable {
    enum Tags: Sendable {
        /// A book source's `kind` (`ReadingGenreProfile.tags(fromSourceKind:)`).
        case sourceKind(String)
        case raw([String])
    }

    let entry: CollectionEntry
    let source: String
    let position: Int
    let tags: Tags

    var candidate: ForYouCandidate {
        let folded = switch tags {
        case .sourceKind(let kind): ReadingGenreProfile.tags(fromSourceKind: kind)
        case .raw(let raw): ReadingGenreProfile.normalizedTags(raw)
        }
        return ForYouCandidate(entry: entry, source: source, position: position, tags: folded)
    }
}

/// `ForYouExposureLog` in `Application Support/ForYou/shown.json`, local only.
actor ForYouExposureStore {
    static let shared = ForYouExposureStore(
        fileURL: StorageLocations.support.appendingPathComponent("ForYou", isDirectory: true)
            .appendingPathComponent("shown.json"))

    private let fileURL: URL
    private var loaded: ForYouExposureLog?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func recentlyShown(at date: Date) -> Set<String> {
        log().recentlyShown(at: date)
    }

    func record(_ keys: [String], at date: Date) {
        var log = log()
        log.record(keys, at: date)
        loaded = log
        ForYouFile.write(log, to: fileURL, label: "為你推薦's shown works")
    }

    private func log() -> ForYouExposureLog {
        if let loaded { return loaded }
        let log = ForYouFile.read(ForYouExposureLog.self, from: fileURL, label: "為你推薦's shown works") ?? ForYouExposureLog()
        loaded = log
        return log
    }
}

/// The local JSON files 為你推薦 keeps: a missing file is absent; one that cannot be read or
/// decoded is absent and logged; a failed write is logged.
enum ForYouFile {
    static func read<T: Decodable>(_ type: T.Type, from url: URL, label: String) -> T? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            AppLogger.cache("⟐ \(label) unreadable", error: error, context: ["file": url.path])
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLogger.cache("⟐ \(label) unreadable", error: error, context: ["file": url.path])
            return nil
        }
    }

    static func write<T: Encodable>(_ value: T, to url: URL, label: String) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(value).write(to: url, options: .atomic)
        } catch {
            AppLogger.cache("⟐ \(label) could not be saved", error: error, context: ["file": url.path])
        }
    }
}
