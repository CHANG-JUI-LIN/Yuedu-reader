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
            case .sourceCategories(let references):
                found += references
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

    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        section.binding == .forYou ? .withHome : nil
    }

    /// The categories it reads: a home whose categories changed loads it again.
    func inputsKey(for section: HomeSection) -> String? {
        guard section.binding == .forYou else { return nil }
        return ForYouInputs.categories(on: homeSections(), for: section).map(\.id).joined(separator: "\u{1E}")
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        guard section.binding == .forYou else { return [] }
        let started = now()
        // Asked again: what was read before the last pull to refresh, or 12 hours ago.
        let refreshedAt = home?.refreshedAt
        let hadHome = home != nil
        let installed = Dictionary(sources().map { ($0.bookSourceUrl, $0) }, uniquingKeysWith: { first, _ in first })
        var inputs: [ForYouCandidate] = []
        var failed = 0
        var asked = 0
        for category in ForYouInputs.categories(on: homeSections(), for: section) {
            guard let source = installed[category.sourceURL] else { continue }
            asked += 1
            var books = await candidates.read(sourceURL: category.sourceURL, categoryURL: category.url, sourceID: source.id)
            let fresh = books.map { cached in
                cached.isFresh(at: started) && !(refreshedAt.map { cached.fetchedAt < $0 } ?? false)
            } ?? false
            if !fresh {
                // The home went away: nothing more is asked for it.
                if hadHome, home == nil { break }
                do {
                    let fetched = try await firstPages.firstPage(of: category, in: source).value
                    books = ForYouCandidates(sourceURL: category.sourceURL, categoryURL: category.url, fetchedAt: now(), books: fetched)
                } catch {
                    failed += 1
                    AppLogger.network("⟐ 為你推薦 kept a category's earlier books", error: error, context: [
                        "source": source.bookSourceName, "category": category.title, "cached": "\(books?.books.count ?? 0)",
                    ])
                }
            }
            for (position, book) in (books?.books ?? []).enumerated() {
                inputs.append(ForYouCandidate(entry: .onlineBook(book, source: source), source: source.bookSourceUrl,
                                              position: position, tags: ReadingGenreProfile.tags(fromSourceKind: book.kind)))
            }
        }
        if let home {
            for row in await home.settledLibraryEntries() {
                for (position, entry) in row.entries.enumerated() {
                    guard case .item(_, let summary, _) = entry else { continue }
                    inputs.append(ForYouCandidate(entry: entry, source: "\(row.source.type.rawValue):\(row.source.id)",
                                                  position: position,
                                                  tags: ReadingGenreProfile.normalizedTags(summary.category.map { [$0] } ?? [])))
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
        let ranked = ForYouRanker.rank(
            candidates: inputs, shelf: ForYouRanker.shelfWorks(shelf.books),
            weights: await genres.profile().weights(at: date), recent: recent, recentlyShown: shown,
            languages: languages(), seed: Self.seed(for: date), limit: HomeRow.limit)
        await exposure.record(ranked.compactMap(ForYouRanker.workKey(of:)), at: date)
        return ranked
    }

    /// The day, so the explored books stay put within it.
    static func seed(for date: Date) -> UInt64 {
        UInt64(max(0, Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0))
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
