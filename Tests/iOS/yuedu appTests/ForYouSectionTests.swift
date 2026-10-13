import Combine
import Foundation
import Testing
@testable import yuedu_app

// Discovery Phase 7a-4: 為你推薦 as a home section — its binding, its place on the home, and its
// provider reading the candidate cache before asking anything.

private func scratch(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ForYouSection-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(name)
}

@MainActor
@Suite("For You section", .serialized)
struct ForYouSectionTests {
    @Test("the binding round-trips as forYou")
    func binding() throws {
        let section = HomeSection(layout: .row, binding: .forYou)
        let data = try JSONEncoder().encode(section)
        #expect(String(decoding: data, as: UTF8.self).contains(#""type":"forYou""#))
        #expect(try JSONDecoder().decode(HomeSection.self, from: data) == section)
        #expect(HomeSectionBinding.appData.contains(.forYou))
        #expect(HomeSectionBinding.forYou.contentOwner == .appData)
        #expect(section.displayTitle(sourceName: "") == localized("為你推薦"))
    }

    @Test("the defaults put it after 系列下一本, in both modes and in China")
    func defaults() {
        for mode in [ExploreMode.bookSources, .publicLibraries] {
            for available in [true, false] {
                let bindings = HomePageDefaults.page(mode: mode, publicLibrariesAvailable: available).sections.map(\.binding)
                #expect(Array(bindings.prefix(3)) == [.continueReading, .nextInSeries, .forYou])
            }
        }
    }

    private func savedHome(_ sections: [HomeSection], selecting configuration: String? = nil) -> URL {
        let url = scratch("explore_home.json")
        let store = HomePageStore(fileURL: url)
        store.save(HomePage(sections: sections))
        if let configuration {
            store.createConfiguration(named: configuration, from: .defaults)
        }
        store.waitForPendingWritesForTesting()
        return url
    }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "ForYouSection-\(UUID().uuidString)")!
    }

    @Test("a saved home gets it once, after 系列下一本, and keeps it deleted")
    func insertedOnce() {
        let url = savedHome([HomeSection(layout: .compactReadingCard, binding: .continueReading),
                             HomeSection(layout: .row, binding: .nextInSeries),
                             HomeSection(layout: .row, binding: .latest)])
        let defaults = suite()
        let store = HomePageStore(fileURL: url, defaults: defaults, insertsForYouOnce: true)
        #expect(store.page?.sections.map(\.binding) == [.continueReading, .nextInSeries, .forYou, .latest])
        store.edit { $0.sections.removeAll { $0.binding == .forYou } }
        store.waitForPendingWritesForTesting()

        let reopened = HomePageStore(fileURL: url, defaults: defaults, insertsForYouOnce: true)
        #expect(reopened.page?.sections.map(\.binding) == [.continueReading, .nextInSeries, .latest])
        #expect(HomePageStore(fileURL: url, defaults: suite()).page?.sections.contains { $0.binding == .forYou } == false,
                "a store that does not insert reads the home as saved")
    }

    @Test("it goes into the 首頁配置 the reader is on")
    func selectedConfiguration() {
        let url = savedHome([HomeSection(layout: .compactReadingCard, binding: .continueReading)], selecting: "我的")
        let store = HomePageStore(fileURL: url, defaults: suite(), insertsForYouOnce: true)
        #expect(store.selectedConfiguration != .defaults)
        #expect(store.page?.sections.map(\.binding) == [.continueReading, .forYou])
        #expect(store.home?.sections(of: .defaults).map(\.binding) == [.continueReading])
    }

    @Test("a new install's defaults count as the one time")
    func newInstall() {
        let url = scratch("explore_home.json")
        let defaults = suite()
        let store = HomePageStore(fileURL: url, defaults: defaults, insertsForYouOnce: true)
        _ = store.pageOrDefaults(mode: .publicLibraries, publicLibrariesAvailable: true)
        store.edit { $0.sections.removeAll { $0.binding == .forYou } }
        store.waitForPendingWritesForTesting()
        let reopened = HomePageStore(fileURL: url, defaults: defaults, insertsForYouOnce: true)
        #expect(reopened.page?.sections.contains { $0.binding == .forYou } == false)
    }

    @Test("its inputs: the home's categories and 「最新」's, its own, less the left out")
    func inputs() {
        let hot = ExploreCategoryReference(sourceURL: "a", title: "熱門", url: "/hot")
        let new = ExploreCategoryReference(sourceURL: "b", title: "最新", url: "/new")
        let added = ExploreCategoryReference(sourceURL: "c", title: "完本", url: "/end")
        let hidden = ExploreCategoryReference(sourceURL: "d", title: "隱藏", url: "/hidden")
        var latest = HomeSection(layout: .row, binding: .latest)
        latest.setLatestCategory(new, forSourceURL: "b")
        var forYou = HomeSection(layout: .row, binding: .forYou)
        forYou.parameters[HomeSection.forYouCategoriesKey] = String(decoding: try! JSONEncoder().encode([added, hot]), as: UTF8.self)
        forYou.parameters[HomeSection.forYouExcludedKey] = String(decoding: try! JSONEncoder().encode([hidden.id]), as: UTF8.self)
        let sections = [HomeSection(layout: .row, binding: .sourceCategories([hot])), latest,
                        HomeSection(layout: .row, binding: .sourceCategories([hidden])),
                        HomeSection(layout: .row, binding: .sourceCategories([added]), isEnabled: false), forYou]
        #expect(ForYouInputs.categories(on: sections, for: forYou) == [hot, new, added])
    }
}

@MainActor
private final class FakeHome: ForYouHomeRows {
    var refreshedAt: Date?
    var rows: [ForYouLibraryRow] = []
    func settledLibraryEntries() async -> [ForYouLibraryRow] { rows }
}

private actor Requests {
    private(set) var log: [String] = []
    func add(_ entry: String) { log.append(entry) }
}

@MainActor
@Suite("For You provider")
struct ForYouProviderTests {
    /// The real clock: `DiscoverFirstPages` dates what it saves by it.
    private let now = Date()
    private let source = BookSource(bookSourceUrl: "https://for-you-\(UUID().uuidString).test", bookSourceName: "為你測試源")

    private var category: ExploreCategoryReference {
        ExploreCategoryReference(sourceURL: source.bookSourceUrl, title: "熱門", url: "/hot")
    }

    private func book(_ name: String) -> OnlineBook {
        OnlineBook(name: name, author: "作者\(name)", intro: "", coverUrl: "", bookUrl: "https://x.test/\(name)", tocUrl: "",
                   wordCount: "", lastChapter: "", kind: "玄幻", sourceId: source.id, sourceName: source.bookSourceName)
    }

    private struct Fixture {
        let provider: ForYouProvider
        let pages: DiscoverFirstPages
        let candidates: ForYouCandidateStore
        let requests: Requests
        let home: FakeHome
        let section: HomeSection
    }

    private func fixture(fails: Bool = false, sections: [HomeSection]? = nil) -> Fixture {
        let requests = Requests()
        let candidates = ForYouCandidateStore(directory: scratch("candidates"))
        let names = ["甲", "乙", "丙"].map(book)
        let pages = DiscoverFirstPages(
            pageLoader: SectionPageLoader { item, _, _ in
                await requests.add("fetch \(item.url ?? "")")
                if fails { throw URLError(.notConnectedToInternet) }
                return names
            },
            primeCookies: { _ in }, store: candidates, lanes: DiscoverRequestLanes())
        let home = FakeHome()
        let forYou = HomeSection(layout: .row, binding: .forYou)
        let homeSections = sections ?? [HomeSection(layout: .row, binding: .sourceCategories([category])), forYou]
        let shelf = BookStore(metadataFileURL: scratch("books_meta.json"))
        let source = source, now = now
        let provider = ForYouProvider(
            firstPages: pages, home: home, shelf: shelf, candidates: candidates,
            homeSections: { homeSections }, sources: { [source] },
            genres: ReadingGenreRecorder(fileURL: scratch("genres.json")),
            exposure: ForYouExposureStore(fileURL: scratch("shown.json")),
            languages: { .init(languages: ["zh"], scope: .any) }, now: { now })
        return Fixture(provider: provider, pages: pages, candidates: candidates, requests: requests, home: home, section: forYou)
    }

    private func titles(_ entries: [CollectionEntry]) -> [String] {
        entries.compactMap { if case .item(_, let summary, _) = $0 { summary.title } else { nil } }
    }

    @Test("a fresh cache sends no request")
    func freshCache() async throws {
        let f = fixture()
        #expect(f.provider.loadPolicy(for: f.section) == .withHome)
        await f.candidates.write(ForYouCandidates(sourceURL: source.bookSourceUrl, categoryURL: "/hot",
                                                  fetchedAt: now.addingTimeInterval(-3600), books: [book("快取")]))
        let entries = try await f.provider.load(f.section)
        #expect(titles(entries) == ["快取"])
        #expect(await f.requests.log.isEmpty)
    }

    @Test("a stale category is asked for once; pull to refresh counts as stale")
    func stale() async throws {
        let f = fixture()
        await f.candidates.write(ForYouCandidates(sourceURL: source.bookSourceUrl, categoryURL: "/hot",
                                                  fetchedAt: now.addingTimeInterval(-13 * 3600), books: [book("舊")]))
        let entries = try await f.provider.load(f.section)
        #expect(Set(titles(entries)) == ["甲", "乙", "丙"])
        #expect(await f.requests.log == ["fetch /hot"])

        // What was just saved is fresh …
        _ = try await f.provider.load(f.section)
        #expect(await f.requests.log.count == 1)
        // … until the reader pulls to refresh.
        f.home.refreshedAt = Date().addingTimeInterval(60)
        _ = try await f.provider.load(f.section)
        #expect(await f.requests.log.count == 2)
    }

    @Test("a row that already loaded the category leaves 為你推薦 nothing to ask")
    func sharesTheRow() async throws {
        let f = fixture()
        let row = BookSourceProvider(source: source, firstPages: f.pages)
        _ = try await row.load(HomeSection(layout: .row, binding: .sourceCategories([category])))
        let provider = ForYouProvider(
            firstPages: f.pages, home: f.home, shelf: BookStore(metadataFileURL: scratch("books_meta.json")),
            candidates: f.candidates, homeSections: { [HomeSection(layout: .row, binding: .sourceCategories([category]))] },
            sources: { [source] }, genres: ReadingGenreRecorder(fileURL: scratch("genres.json")),
            exposure: ForYouExposureStore(fileURL: scratch("shown.json")), languages: { .init(languages: ["zh"], scope: .any) })
        let entries = try await provider.load(f.section)
        #expect(entries.count == 3)
        #expect(await f.requests.log == ["fetch /hot"])
    }

    @Test("a failure keeps the earlier books, and says so in the log")
    func failureKeepsBooks() async throws {
        let f = fixture(fails: true)
        await f.candidates.write(ForYouCandidates(sourceURL: source.bookSourceUrl, categoryURL: "/hot",
                                                  fetchedAt: now.addingTimeInterval(-13 * 3600), books: [book("舊")]))
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))
        let entries = try await f.provider.load(f.section)
        #expect(titles(entries) == ["舊"])
        let lines = DiagnosticLog.shared.snapshot().filter { !before.contains($0.id) && $0.message.contains("kept a category's earlier books") }
        #expect(lines.count == 1)
    }

    @Test("with nothing cached and every category failed, the section takes no room")
    func emptyWhenNothing() async throws {
        let f = fixture(fails: true)
        let before = Set(DiagnosticLog.shared.snapshot().map(\.id))
        #expect(try await f.provider.load(f.section).isEmpty)
        let lines = DiagnosticLog.shared.snapshot().filter { !before.contains($0.id) && $0.message.contains("為你推薦 has nothing") }
        #expect(lines.count == 1)
    }

    @Test("the home's library rows count, and send no request")
    func libraryRows() async throws {
        let f = fixture(sections: [HomeSection(layout: .row, binding: .forYou)])
        let library = BookSource(bookSourceUrl: "https://lib.test", bookSourceName: "書庫")
        f.home.rows = [ForYouLibraryRow(source: SourceInstanceKey(type: .gutenberg, id: "gutenberg"),
                                        entries: [.onlineBook(book("書庫書"), source: library)])]
        let entries = try await f.provider.load(f.section)
        #expect(titles(entries) == ["書庫書"])
        #expect(await f.requests.log.isEmpty)
    }

    @Test("every load of a day gives the same section; the next day explores books not shown")
    func stableWithinADay() async throws {
        let sources = (0..<4).map { BookSource(bookSourceUrl: "https://day-\($0)-\(UUID().uuidString).test", bookSourceName: "源\($0)") }
        let categories = sources.map { ExploreCategoryReference(sourceURL: $0.bookSourceUrl, title: "熱門", url: "/hot") }
        let candidates = ForYouCandidateStore(directory: scratch("candidates"))
        let exposure = ForYouExposureStore(fileURL: scratch("shown.json"))
        let genres = ReadingGenreRecorder(fileURL: scratch("genres.json"))
        let shelf = BookStore(metadataFileURL: scratch("books_meta.json"))
        let calendar = Calendar.current
        let day1 = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: Date())!
        let day2 = day1.addingTimeInterval(24 * 3600)
        let pages = DiscoverFirstPages(pageLoader: SectionPageLoader { _, _, _ in Issue.record("nothing is asked"); return [] },
                                       primeCookies: { _ in }, store: candidates, lanes: DiscoverRequestLanes())
        func provider(at date: Date) async -> ForYouProvider {
            for (index, source) in sources.enumerated() {
                let books = (0..<10).map { n in
                    OnlineBook(name: "\(index)-\(n)", author: "作者\(index)-\(n)", intro: "", coverUrl: "", bookUrl: "https://x.test/\(index)/\(n)",
                               tocUrl: "", wordCount: "", lastChapter: "", kind: "", sourceId: source.id, sourceName: source.bookSourceName)
                }
                await candidates.write(ForYouCandidates(sourceURL: source.bookSourceUrl, categoryURL: "/hot",
                                                        fetchedAt: date.addingTimeInterval(-3600), books: books))
            }
            return ForYouProvider(firstPages: pages, home: nil, shelf: shelf, candidates: candidates,
                                  homeSections: { [HomeSection(layout: .row, binding: .sourceCategories(categories))] },
                                  sources: { sources }, genres: genres, exposure: exposure,
                                  languages: { .init(languages: ["zh"], scope: .any) }, now: { date })
        }
        let section = HomeSection(layout: .row, binding: .forYou)
        let first = titles(try await provider(at: day1).load(section))
        let again = titles(try await provider(at: day1.addingTimeInterval(3600)).load(section))
        #expect(first.count == HomeRow.limit)
        #expect(again == first)

        let next = titles(try await provider(at: day2).load(section))
        let explored = stride(from: 3, to: next.count, by: 4).map { next[$0] }
        #expect(explored.count == HomeRow.limit / 4)
        #expect(Set(explored).isDisjoint(with: first))
    }

    @Test("the home's categories changing loads it again")
    func restartsOnNewInputs() async throws {
        let f = fixture()
        let other = ExploreCategoryReference(sourceURL: source.bookSourceUrl, title: "完本", url: "/end")
        var sections = [HomeSection(layout: .row, binding: .sourceCategories([category])), f.section]
        let source = source
        let model = HomeModel(providers: {
            [ForYouProvider(firstPages: f.pages, home: nil, shelf: BookStore(metadataFileURL: scratch("books_meta.json")),
                            candidates: f.candidates, homeSections: { sections }, sources: { [source] },
                            genres: ReadingGenreRecorder(fileURL: scratch("genres.json")),
                            exposure: ForYouExposureStore(fileURL: scratch("shown.json")),
                            languages: { .init(languages: ["zh"], scope: .any) })]
        }, waitForSources: {})
        await model.sync(with: HomePage(sections: sections))
        let id = try #require(model.rows.first?.id)
        func loaded() async {
            _ = await model.$rows.values.first { $0.first.map { if case .loaded = $0.state { true } else { false } } ?? false }
        }
        model.load(id)
        await loaded()
        #expect(await f.requests.log == ["fetch /hot"])

        sections.insert(HomeSection(layout: .row, binding: .sourceCategories([other])), at: 1)
        await model.sync(with: HomePage(sections: sections))
        // A new row, idle, then loading again on its own.
        await loaded()
        #expect(await f.requests.log == ["fetch /hot", "fetch /end"])
    }
}
