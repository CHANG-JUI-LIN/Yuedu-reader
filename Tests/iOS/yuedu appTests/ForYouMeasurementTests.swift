import Combine
import Foundation
import Testing
@testable import yuedu_app

// Discovery Phase 7a-5: what 為你推薦 adds to a home's requests. A home of 5 sources × 3
// categories and a Gutenberg-like library row that loads with the home; every request is
// counted for a cold home, a warm one and a pull to refresh.

private func scratch(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ForYouMeasurement-\(UUID().uuidString)")
        .appendingPathComponent(name)
}

private actor RequestCounter {
    private(set) var log: [String] = []
    func add(_ entry: String) { log.append(entry) }
    func reset() { log = [] }
}

/// A library row that loads with the home, as Gutenberg's 熱門 does, counting its requests.
@MainActor
private final class LibraryRow: HomeSectionProviding {
    let instance = SourceInstanceKey(type: .gutenberg, id: "gutenberg")
    let displayName = "Gutenberg"
    let availability: ProviderAvailability = .available
    let hosts: [String] = []
    let counter: RequestCounter
    let source = BookSource(bookSourceUrl: "https://gutenberg.test", bookSourceName: "Gutenberg")

    init(counter: RequestCounter) { self.counter = counter }

    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? {
        if case .latest = section.binding { return .withHome }
        return nil
    }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        await counter.add("library")
        try await Task.sleep(for: .milliseconds(40))
        return (0..<6).map { n in
            .onlineBook(OnlineBook(name: "Library \(n)", author: "Author \(n)", intro: "", coverUrl: "",
                                   bookUrl: "https://gutenberg.test/\(n)", tocUrl: "", wordCount: "", lastChapter: "",
                                   kind: "", sourceId: source.id, sourceName: source.bookSourceName), source: source)
        }
    }
}

@MainActor
@Suite("For You measurement", .serialized)
struct ForYouMeasurementTests {
    private let sources = (0..<5).map {
        BookSource(bookSourceUrl: "https://measure-\($0)-\(UUID().uuidString).test", bookSourceName: "源\($0)")
    }
    private let categoryURLs = ["/hot", "/new", "/end"]

    private var categories: [ExploreCategoryReference] {
        sources.flatMap { source in
            categoryURLs.map { ExploreCategoryReference(sourceURL: source.bookSourceUrl, title: $0, url: $0) }
        }
    }

    private struct Home {
        let model: HomeModel
        let page: HomePage
    }

    /// What each request takes, standing in for the network.
    private static let latency = Duration.milliseconds(40)

    /// A home made as `HomeModel.live` makes it (`HomeModel.make`), with these sources.
    private func home(counter: RequestCounter, store: ForYouCandidateStore, exposure: ForYouExposureStore,
                      shelf: BookStore, genres: ReadingGenreRecorder) -> Home {
        let sources = sources
        let sections = categories.map { HomeSection(layout: .row, binding: .sourceCategories([$0])) }
            + [HomeSection(layout: .row, binding: .forYou), HomeSection(layout: .row, binding: .latest)]
        let pages = DiscoverFirstPages(
            pageLoader: SectionPageLoader { item, _, source in
                await counter.add("\(source.bookSourceName)\(item.url ?? "")")
                try await Task.sleep(for: Self.latency)
                return (0..<8).map { n in
                    OnlineBook(name: "\(source.bookSourceName)\(item.url ?? "")-\(n)", author: "作者\(n)", intro: "",
                               coverUrl: "", bookUrl: "https://x.test/\(source.bookSourceName)\(item.url ?? "")/\(n)",
                               tocUrl: "", wordCount: "", lastChapter: "", kind: "玄幻",
                               sourceId: source.id, sourceName: source.bookSourceName)
                }
            },
            primeCookies: { _ in }, store: store, lanes: DiscoverRequestLanes())
        let library = LibraryRow(counter: counter)
        let model = HomeModel.make(firstPages: pages, waitForSources: {}) { pages, home in
            // As `SourceProviderRegistry.homeProviders` does.
            pages.beginSync()
            let rows: [any HomeSectionProviding] = sources.map { BookSourceProvider(source: $0, firstPages: pages) }
            return rows + [library, ForYouProvider(
                firstPages: pages, home: home, shelf: shelf, candidates: store,
                homeSections: { sections }, sources: { sources }, genres: genres, exposure: exposure,
                languages: { .init(languages: ["zh"], scope: .any) })]
        }
        return Home(model: model, page: HomePage(sections: sections))
    }

    private func loaded(_ model: HomeModel, _ rows: [HomeModel.Row]) async {
        let ids = Set(rows.map(\.id))
        _ = await model.$rows.values.first { all in
            all.filter { ids.contains($0.id) }.allSatisfy { if case .loaded = $0.state { true } else { false } }
        }
    }

    /// The home appears (its `.withHome` rows start), then every category row comes into view.
    /// Returns when 為你推薦 was ready, in ms from the home's appearing.
    @discardableResult
    private func appearAndScroll(_ home: Home) async -> Double {
        let model = home.model
        let started = SourcePerfTrace.now
        let withHome = model.rows.filter { $0.policy == .withHome }
        withHome.forEach { model.load($0.id) }
        await loaded(model, withHome)
        let ready = (SourcePerfTrace.now - started) * 1000
        let rest = model.rows.filter { $0.policy != .withHome }
        rest.forEach { model.load($0.id) }
        await loaded(model, model.rows)
        return ready
    }

    private func report(_ phase: String, _ log: [String], ms: Double, forYouReady: Double? = nil) {
        let categories = log.filter { $0 != "library" }
        let repeated = Dictionary(grouping: categories, by: { $0 }).filter { $0.value.count > 1 }.count
        let ready = forYouReady.map { " forYouReady=\(String(format: "%.0f", $0))ms" } ?? ""
        print("⏱ forYou.measure \(phase): requests=\(log.count) categories=\(categories.count) library=\(log.count - categories.count) repeated=\(repeated) \(String(format: "%.0f", ms))ms\(ready)")
    }

    @Test("a cold home, a warm one and a pull to refresh: one request per category and library row")
    func requests() async throws {
        let counter = RequestCounter()
        let store = ForYouCandidateStore(directory: scratch("candidates"))
        let exposure = ForYouExposureStore(fileURL: scratch("shown.json"))
        let shelf = BookStore(metadataFileURL: scratch("books_meta.json"))
        let genres = ReadingGenreRecorder(fileURL: scratch("genres.json"))

        // Cold: nothing cached.
        let cold = home(counter: counter, store: store, exposure: exposure, shelf: shelf, genres: genres)
        await cold.model.sync(with: cold.page)
        var started = SourcePerfTrace.now
        var ready = await appearAndScroll(cold)
        var log = await counter.log
        report("cold", log, ms: (SourcePerfTrace.now - started) * 1000, forYouReady: ready)
        #expect(log.filter { $0 != "library" }.count == 15)
        #expect(log.filter { $0 == "library" }.count == 1)

        // Pull to refresh: every row and every category again, once.
        await counter.reset()
        started = SourcePerfTrace.now
        cold.model.reload()
        await loaded(cold.model, cold.model.rows)
        let forYou = try #require(cold.model.rows.first { $0.section.binding == .forYou })
        _ = await cold.model.$rows.values.first { rows in
            rows.first { $0.id == forYou.id }.map { if case .loaded = $0.state { true } else { false } } ?? false
        }
        log = await counter.log
        report("refresh", log, ms: (SourcePerfTrace.now - started) * 1000)
        #expect(log.filter { $0 != "library" }.count == 15)

        // Warm: a relaunch within 12 hours. 為你推薦 adds nothing to the rows' own requests.
        await counter.reset()
        let warm = home(counter: counter, store: store, exposure: exposure, shelf: shelf, genres: genres)
        await warm.model.sync(with: warm.page)
        started = SourcePerfTrace.now
        ready = await appearAndScroll(warm)
        log = await counter.log
        report("warm", log, ms: (SourcePerfTrace.now - started) * 1000, forYouReady: ready)
        #expect(log.filter { $0 != "library" }.count == 15, "the rows' own, none of 為你推薦's")
        let entries = warm.model.rows.first { $0.section.binding == .forYou }.map { row -> Int in
            if case .loaded(let entries) = row.state { entries.count } else { 0 }
        }
        #expect(entries == HomeRow.limit)
    }

    @Test("ranking a large case: 2000 books on the shelf, 600 candidates, 600 shown")
    func largeRanking() {
        let shelf = (0..<2000).map { n in
            ReadingBook(title: "書架上的書第\(n)本", author: "書架作者\(n % 300)", source: "shelf\(n).epub", contentFilename: "shelf\(n).epub")
        }
        let candidates = (0..<600).map { n in
            let source = sources[n % sources.count]
            let book = OnlineBook(name: "候選書第\(n)本", author: "候選作者\(n % 200)", intro: "", coverUrl: "",
                                  bookUrl: "https://x.test/\(n)", tocUrl: "", wordCount: "", lastChapter: "", kind: "玄幻,都市",
                                  sourceId: source.id, sourceName: source.bookSourceName)
            return ForYouCandidate(entry: .onlineBook(book, source: source), source: source.bookSourceUrl, position: n / 5,
                                   tags: ReadingGenreProfile.tags(fromSourceKind: book.kind))
        }
        func time(_ label: String, _ work: () -> Void) {
            let started = SourcePerfTrace.now
            work()
            print("⏱ forYou.measure rank \(label): \(String(format: "%.1f", (SourcePerfTrace.now - started) * 1000))ms")
        }
        var works: [ForYouRanker.ShelfWork] = []
        time("shelfWorks(2000)") { works = ForYouRanker.shelfWorks(shelf) }
        let shown = Set(candidates.compactMap { ForYouRanker.workKey(of: $0.entry) })
        time("workKey(600)") { _ = candidates.compactMap { ForYouRanker.workKey(of: $0.entry) } }
        let languages = ReadingLanguagePreferences(languages: ["zh"], scope: .any)
        func rank(shelf: [ForYouRanker.ShelfWork], shown: Set<String>) -> [CollectionEntry] {
            ForYouRanker.rank(candidates: candidates, shelf: shelf, weights: ["玄幻": 1], recent: .init(authors: ["候選作者1"], tags: ["都市"]),
                              recentlyShown: shown, languages: languages, seed: 1, limit: HomeRow.limit)
        }
        time("rank, no shelf") { _ = rank(shelf: [], shown: []) }
        time("rank, shelf 2000") { _ = rank(shelf: works, shown: []) }
        time("rank, shelf 2000 + shown 600") { _ = rank(shelf: works, shown: shown) }
        var entries: [CollectionEntry] = []
        time("arrange(20)") { entries = languages.arrange(Array(candidates.prefix(20).map(\.entry))) }
        #expect(entries.count == 20)
    }
}
