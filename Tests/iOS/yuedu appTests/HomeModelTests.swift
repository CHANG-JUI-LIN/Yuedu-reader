import Combine
import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5b: what each source puts on the home, and when its rows may send a
/// request (Phase 5 plan, 5b steps 2 and 5).

/// Opens once; a wait before or after the opening both return.
@MainActor
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A source that serves what `policy` says, records each load, and holds each load until
/// its gate opens.
@MainActor
private final class FakeProvider: HomeSectionProviding {
    let instance: SourceInstanceKey
    let displayName: String
    let availability: ProviderAvailability = .available
    let hosts: [String] = []
    let policy: (HomeSection) -> SectionLoadPolicy?
    var gates: [Gate] = []
    var failure: (any Error)?
    var readsHomeLibraryRows = false
    /// Stands in for the network's answer time (step 6's measurement).
    var latency: Duration?
    private(set) var loads: [UUID] = []
    private(set) var inFlight = 0
    private(set) var mostInFlight = 0

    init(_ id: String, type: ProviderType = .bookSource, policy: @escaping (HomeSection) -> SectionLoadPolicy?) {
        instance = SourceInstanceKey(type: type, id: id)
        displayName = id
        self.policy = policy
    }

    func loadPolicy(for section: HomeSection) -> SectionLoadPolicy? { policy(section) }

    func load(_ section: HomeSection) async throws -> [CollectionEntry] {
        let gate = loads.count < gates.count ? gates[loads.count] : nil
        loads.append(section.id)
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        await gate?.wait()
        if let latency { try await Task.sleep(for: latency) }
        inFlight -= 1
        if let failure { throw failure }
        return [.location(CollectionLocation(id: "\(instance.id)/\(loads.count)", title: displayName))]
    }
}

private struct RowFailed: Error, LocalizedError {
    var errorDescription: String? { "伺服器沒有回應" }
}

@MainActor
private func model(_ providers: [any HomeSectionProviding], sources: Gate? = nil) -> HomeModel {
    HomeModel(providers: { providers }, waitForSources: { await sources?.wait() })
}

@MainActor
private func rows(_ model: HomeModel) -> [HomeModel.Row] {
    model.rows
}

@MainActor
private func until(_ model: HomeModel, _ condition: @escaping ([HomeModel.Row]) -> Bool) async {
    for await rows in model.$rows.values where condition(rows) { break }
}

private func isLoaded(_ state: HomeModel.RowState) -> Bool {
    if case .loaded = state { return true }
    return false
}

@MainActor
@Suite("Home model", .serialized, .timeLimit(.minutes(1)))
struct HomeModelTests {
    private let category = ExploreCategoryReference(sourceURL: "a", title: "熱門", url: "/hot")

    @Test("no row is built before the book-source library is read")
    func waitsForSources() async {
        let sources = Gate()
        let a = FakeProvider("a") { _ in .serialPerSource }
        let home = model([a], sources: sources)
        let page = HomePage(sections: [HomeSection(layout: .row, binding: .sourceCategories([category]))])
        let syncing = Task { await home.sync(with: page) }

        #expect(!home.isReady)
        #expect(home.rows.isEmpty)
        sources.open()
        await syncing.value
        #expect(home.isReady)
        #expect(rows(home).map(\.source) == [a.instance])
    }

    @Test("a new layout or title keeps what a row loaded (5d-3): only how it is drawn changed")
    func layoutKeepsContent() async {
        let a = FakeProvider("a") { _ in .parallel }
        let home = model([a])
        var section = HomeSection(layout: .row, binding: .sourceCategories([category]))
        await home.sync(with: HomePage(sections: [section]))
        home.load(rows(home)[0].id)
        await until(home) { $0.first.map { isLoaded($0.state) } ?? false }

        // A layout of books to another; 排行榜 (what `.rankedList` reads as since 2026-10-27) is a
        // layout of lists, whose rows are its cards'.
        section.layout = .list
        section.title = "排行"
        await home.sync(with: HomePage(sections: [section]))
        #expect(isLoaded(rows(home)[0].state))
        #expect(rows(home)[0].section.layout == .list)
        #expect(a.loads.count == 1)
    }

    @Test("turning 顯示在最新 off for one source keeps the other sources' rows loaded")
    func exclusionKeepsOtherRows() async {
        let a = FakeProvider("a") { _ in .parallel }
        let b = FakeProvider("b", type: .opds) { _ in .parallel }
        let home = model([a, b])
        let section = HomeSection(layout: .row, binding: .latest)
        await home.sync(with: HomePage(sections: [section]))
        for row in rows(home) { home.load(row.id) }
        await until(home) { $0.allSatisfy { isLoaded($0.state) } }

        await home.sync(with: HomePage(sections: [section]), hiddenFromLatest: [b.instance])
        #expect(rows(home).map(\.source.id) == ["a"])
        #expect(isLoaded(rows(home)[0].state))
        #expect(a.loads.count == 1)
    }

    @Test("a row that reads the home's library rows loads again when one comes or goes (為你推薦)", .timeLimit(.minutes(1)))
    func libraryRowsChangeReloadsTheirReader() async throws {
        let reader = FakeProvider("forYou") { $0.binding == .forYou ? .parallel : nil }
        reader.readsHomeLibraryRows = true
        let a = FakeProvider("a") { $0.binding == .latest ? .parallel : nil }
        let library = FakeProvider("b", type: .opds) { $0.binding == .latest ? .parallel : nil }
        let home = model([reader, a, library])
        let page = HomePage(sections: [HomeSection(layout: .row, binding: .forYou), HomeSection(layout: .row, binding: .latest)])
        await home.sync(with: page)
        // 為你推薦 waits for the library rows on their way (`settledLibraryEntries`); this
        // reader is asked after them.
        for row in rows(home) where row.source != reader.instance { home.load(row.id) }
        await until(home) { $0.allSatisfy { $0.source == reader.instance || isLoaded($0.state) } }
        for row in rows(home) where row.source == reader.instance { home.load(row.id) }
        await until(home) { $0.allSatisfy { isLoaded($0.state) } }

        await home.sync(with: page, hiddenFromLatest: [a.instance])
        #expect(reader.loads.count == 1, "a book source's row is not one it reads")
        await home.sync(with: page, hiddenFromLatest: [a.instance, library.instance])
        await until(home) { $0.allSatisfy { isLoaded($0.state) } }
        #expect(reader.loads.count == 2)
        #expect(library.loads.count == 1)

        // It comes back: the reader starts again at once, before the library row's view asks
        // for it, and once more when the library row has loaded.
        await home.sync(with: page, hiddenFromLatest: [a.instance])
        await until(home) { $0.allSatisfy { $0.source != reader.instance || isLoaded($0.state) } }
        let libraryRow = try #require(rows(home).first { $0.source == library.instance })
        home.load(libraryRow.id)
        await until(home) { $0.allSatisfy { isLoaded($0.state) } && reader.loads.count == 4 }
        #expect(reader.loads.count == 4)
        #expect(library.loads.count == 2)
    }

    @Test("a row whose inputs change while it loads loads again, and the earlier load's books are dropped", .timeLimit(.minutes(1)))
    func inputsChangeDuringALoad() async throws {
        let reader = FakeProvider("forYou") { $0.binding == .forYou ? .parallel : nil }
        reader.readsHomeLibraryRows = true
        let gate = Gate()
        reader.gates = [gate]
        let library = FakeProvider("b", type: .opds) { $0.binding == .latest ? .parallel : nil }
        let home = model([reader, library])
        let page = HomePage(sections: [HomeSection(layout: .row, binding: .forYou), HomeSection(layout: .row, binding: .latest)])
        await home.sync(with: page)
        let readerRow = try #require(rows(home).first { $0.source == reader.instance })
        home.load(readerRow.id)
        await until(home) { $0.first { $0.id == readerRow.id }?.state == .loading }

        // The library goes while the first load is on its way.
        await home.sync(with: page, hiddenFromLatest: [library.instance])
        gate.open()
        await until(home) { rows in
            guard case .loaded(let entries)? = rows.first(where: { $0.id == readerRow.id })?.state else { return false }
            return entries == [.location(CollectionLocation(id: "forYou/2", title: "forYou"))]
        }
        #expect(reader.loads.count == 2)
    }

    @Test("a row whose content changed under the same id loads again by itself once it had loaded")
    func changedContentReloads() async {
        let a = FakeProvider("a") { _ in .parallel }
        let home = model([a])
        var section = HomeSection(layout: .row, binding: .sourceCategories([category]))
        await home.sync(with: HomePage(sections: [section]))
        home.load(rows(home)[0].id)
        await until(home) { $0.first.map { isLoaded($0.state) } ?? false }

        section.parameters = ["sort": "new"]
        await home.sync(with: HomePage(sections: [section]))
        await until(home) { $0.first.map { isLoaded($0.state) } ?? false }
        #expect(a.loads.count == 2)
    }

    @Test("「最新」 is one row per source that serves it, in provider order, skipping those 顯示在最新 turns off")
    func latestExpands() async {
        let a = FakeProvider("a") { _ in .serialPerSource }
        let b = FakeProvider("b", type: .opds) { _ in .parallel }
        let c = FakeProvider("c", type: .aozora) { _ in nil }
        let home = model([a, b, c])
        let page = HomePage(sections: [HomeSection(layout: .row, binding: .latest)])
        await home.sync(with: page)
        #expect(rows(home).map(\.source.id) == ["a", "b"])

        await home.sync(with: page, hiddenFromLatest: [SourceInstanceKey(type: .opds, id: "b")])
        #expect(rows(home).map(\.source.id) == ["a"])
    }

    /// 5d-1 (settled decision 12): 我的書庫 is off the home, its libraries reached from 範圍.
    @Test("我的書庫, a hidden section and one nothing serves have no row; the rest keep their order")
    func unservedHaveNoRow() async {
        let shelf = FakeProvider("local", type: .library) { section in
            if case .related = section.binding { return .local }
            return nil
        }
        let a = FakeProvider("a") { _ in nil }
        let home = HomeModel(providers: { [shelf, a] }, waitForSources: {})
        let related = HomeSection(layout: .row, binding: .related)
        await home.sync(with: HomePage(sections: [
            HomeSection(layout: .tiles, binding: .myLibrary),
            HomeSection(layout: .row, binding: .continueReading, isEnabled: false),
            related,
            HomeSection(layout: .row, binding: .unknown(.object(["type": .string("later")]))),
        ]))
        #expect(home.rows.map(\.section.id) == [related.id])
        #expect(home.isReady)
    }

    @Test("one source's rows load one at a time; another source's do not wait for them")
    func serialPerSource() async throws {
        let a = FakeProvider("a") { section in
            if case .sourceCategories(let references) = section.binding, references.first?.sourceURL == "a" { return .serialPerSource }
            return nil
        }
        let b = FakeProvider("b") { section in
            if case .sourceCategories(let references) = section.binding, references.first?.sourceURL == "b" { return .serialPerSource }
            return nil
        }
        let first = Gate(), second = Gate()
        a.gates = [first, second]
        let home = model([a, b])
        let other = ExploreCategoryReference(sourceURL: "b", title: "新書", url: "/new")
        await home.sync(with: HomePage(sections: [
            HomeSection(layout: .row, binding: .sourceCategories([category])),
            HomeSection(layout: .row, binding: .sourceCategories([ExploreCategoryReference(sourceURL: "a", title: "完本", url: "/end")])),
            HomeSection(layout: .row, binding: .sourceCategories([other])),
        ]))
        for row in rows(home) { home.load(row.id) }

        // B's row loads while A's first is still held.
        await until(home) { $0.count == 3 && isLoaded($0[2].state) }
        #expect(a.loads.count == 1)
        #expect(rows(home)[1].state == .idle)

        first.open()
        await until(home) { isLoaded($0[0].state) && $0[1].state == .loading }
        second.open()
        await until(home) { isLoaded($0[1].state) }
        #expect(a.mostInFlight == 1)
        #expect(a.loads.count == 2)
    }

    @Test("重試, 載入 and pull to refresh never start a second load of a queued or loading row")
    func noDuplicateLoads() async throws {
        let a = FakeProvider("a") { _ in .serialPerSource }
        let first = Gate(), second = Gate()
        a.gates = [first, second]
        let home = model([a])
        await home.sync(with: HomePage(sections: [
            HomeSection(layout: .row, binding: .sourceCategories([category])),
            HomeSection(layout: .row, binding: .sourceCategories([ExploreCategoryReference(sourceURL: "a", title: "完本", url: "/end")])),
        ]))
        let ids = rows(home).map(\.id)
        ids.forEach(home.load)
        await until(home) { $0[0].state == .loading }

        home.request(ids[1])   // queued, still idle
        home.request(ids[0])   // loading
        home.reload()
        first.open()
        second.open()
        await until(home) { $0.allSatisfy { isLoaded($0.state) } }
        #expect(a.loads.count == 2)
    }

    @Test("a row that loads with the home starts when the home appears, view or not; other rows wait for their view")
    func withHome() async throws {
        let g = FakeProvider("g", type: .gutenberg) { section in
            if case .gutenbergFeed = section.binding { return .withHome }
            return nil
        }
        let a = FakeProvider("a", type: .opds) { section in
            if case .opdsFeed = section.binding { return .parallel }
            return nil
        }
        let home = model([g, a])
        await home.sync(with: HomePage(sections: [
            HomeSection(layout: .row, binding: .gutenbergFeed(url: "https://g.test/feed")),
            HomeSection(layout: .row, binding: .opdsFeed(connectionID: "a", url: "https://a.test/feed")),
        ]))
        #expect(g.loads.isEmpty)

        // No row's view has asked: only the one that loads with the home starts.
        home.homeAppeared(in: nil)
        await until(home) { isLoaded($0[0].state) }
        #expect(g.loads.count == 1)
        #expect(a.loads.isEmpty)
        #expect(rows(home)[1].state == .idle)

        // Its view coming into view, or the home appearing again, sends nothing more.
        home.load(rows(home)[0].id)
        home.homeAppeared(in: nil)
        #expect(g.loads.count == 1)

        home.reload()
        await until(home) { isLoaded($0[0].state) && g.loads.count == 2 }
        #expect(a.loads.isEmpty)
    }

    @Test("with 範圍 on another source, the rows that load with the home send nothing (5d-3b)")
    func homeAppearedFollowsScope() async {
        let g = FakeProvider(PublicLibraryID.gutenberg.rawValue, type: .gutenberg) { section in
            if case .gutenbergFeed = section.binding { return .withHome }
            return nil
        }
        let home = model([g])
        await home.sync(with: HomePage(sections: [HomeSection(layout: .row, binding: .gutenbergFeed(url: "https://g.test/feed"))]))
        home.homeAppeared(in: SourceInstanceKey(type: .aozora, id: PublicLibraryID.aozora.rawValue))
        #expect(g.loads.isEmpty)
        #expect(rows(home)[0].state == .idle)

        home.homeAppeared(in: g.instance)
        await until(home) { isLoaded($0[0].state) }
        #expect(g.loads.count == 1)
    }

    @Test("coming back into view loads again only the rows read from this device, and only those already loaded")
    func reloadLocal() async throws {
        let shelf = FakeProvider("local", type: .library) { section in
            if case .continueReading = section.binding { return .local }
            return nil
        }
        let feed = FakeProvider("f", type: .opds) { _ in .parallel }
        let home = model([shelf, feed])
        await home.sync(with: HomePage(sections: [
            HomeSection(layout: .row, binding: .continueReading),
            HomeSection(layout: .row, binding: .latest),
        ]))
        home.reloadLocal()
        #expect(shelf.loads.isEmpty, "a row never shown is not loaded")

        rows(home).map(\.id).forEach(home.load)
        await until(home) { $0.allSatisfy { isLoaded($0.state) } }
        home.reloadLocal()
        await until(home) { _ in shelf.loads.count == 2 }
        await until(home) { $0.allSatisfy { isLoaded($0.state) } }
        #expect(shelf.loads.count == 2)
        #expect(feed.loads.count == 1)
    }

    @Test("a failed row says why, and 重試 loads it again")
    func failureAndRetry() async throws {
        let a = FakeProvider("a", type: .opds) { _ in .parallel }
        a.failure = RowFailed()
        let home = model([a])
        await home.sync(with: HomePage(sections: [HomeSection(layout: .row, binding: .latest)]))
        let row = try #require(rows(home).first)

        home.load(row.id)
        await until(home) { $0[0].state == .failed("伺服器沒有回應") }
        a.failure = nil
        home.request(row.id)
        await until(home) { isLoaded($0[0].state) }
        #expect(a.loads.count == 2)
    }

    @Test("a sync keeps what an unchanged row loaded")
    func syncKeepsRows() async throws {
        let a = FakeProvider("a", type: .opds) { _ in .parallel }
        let home = model([a])
        let section = HomeSection(layout: .row, binding: .latest)
        await home.sync(with: HomePage(sections: [section]))
        let row = try #require(rows(home).first)
        home.load(row.id)
        await until(home) { isLoaded($0[0].state) }

        await home.sync(with: HomePage(sections: [section]))
        #expect(isLoaded(rows(home)[0].state))
        #expect(a.loads.count == 1)
    }

    @Test("Gutenberg's bundled lists load without a request, with Gutenberg's covers; its feeds load with the home")
    func gutenbergRequests() async throws {
        let availability = PublicLibraryAvailability(defaults: UserDefaults(suiteName: "HomeModelTests-\(UUID().uuidString)")!)
        var requests = 0
        let gutenberg = GutenbergProvider(availability: availability) { _ in
            requests += 1
            return OPDSFeed()
        }
        let home = model([gutenberg])
        let collection = try #require(PublicLibraryCollection.all.first)
        await home.sync(with: HomePage(sections: [
            HomeSection(layout: .row, binding: .gutenbergCollection(id: collection.id)),
            HomeSection(layout: .row, binding: .gutenbergFeed(url: "https://www.gutenberg.org/ebooks.opds/")),
            HomeSection(layout: .row, binding: .latest),
        ]))
        #expect(rows(home).map(\.policy) == [.local, .withHome, .withHome])
        home.load(rows(home)[0].id)
        await until(home) { isLoaded($0[0].state) }

        guard case .loaded(let entries) = rows(home)[0].state else { Issue.record("not loaded"); return }
        #expect(entries.count == collection.books.count)
        if case .item(_, let summary, .gutenberg(let book)) = entries.first {
            #expect(book == collection.books.first)
            #expect(summary.cover == book.coverURL.map { .remote($0, headers: [:]) })
        } else {
            Issue.record("expected a Gutenberg book")
        }
        #expect(requests == 0)

        home.homeAppeared(in: nil)
        await until(home) { $0.allSatisfy { isLoaded($0.state) } }
        #expect(requests == 2)
    }

    @Test("in China Gutenberg serves no section at all")
    func gutenbergInChina() {
        let availability = PublicLibraryAvailability(defaults: UserDefaults(suiteName: "HomeModelTests-\(UUID().uuidString)")!)
        availability.receive(countryCode: "CHN")
        let gutenberg = GutenbergProvider(availability: availability) { _ in OPDSFeed() }
        #expect(gutenberg.loadPolicy(for: HomeSection(layout: .row, binding: .gutenbergCollection(id: "chinese"))) == nil)
        #expect(gutenberg.loadPolicy(for: HomeSection(layout: .row, binding: .latest)) == nil)
    }
}

// MARK: - Measurement (5b step 6)

@MainActor
@Suite("Home model scheduling measurement", .serialized, .timeLimit(.minutes(1)))
struct HomeModelSchedulingTests {
    /// 20 rows over 5 sources: three book sources with four categories each (serial per
    /// source), an OPDS connection with four rows (parallel), Aozora with four (on-device).
    /// Every network row answers in 100 ms. These are injected timings on the simulator in
    /// Debug: they measure the home's scheduling, not any network.
    @Test("20 rows over 5 sources: the on-device rows come first, each book source's rows queue")
    func twentyRows() async throws {
        let latency = Duration.milliseconds(100)
        let books = (1...3).map { index in
            let id = "s\(index)"
            let provider = FakeProvider(id) { section in
                if case .sourceCategories(let references) = section.binding, references.first?.sourceURL == id { return .serialPerSource }
                return nil
            }
            provider.latency = latency
            return provider
        }
        let opds = FakeProvider("o", type: .opds) { section in
            switch section.binding {
            case .latest, .opdsFeed: .parallel
            default: nil
            }
        }
        opds.latency = latency
        let aozora = FakeProvider("z", type: .aozora) { section in
            switch section.binding {
            case .aozoraNew, .aozoraIndex: .local
            default: nil
            }
        }
        var sections: [HomeSection] = []
        for provider in books {
            for title in ["熱門", "新書", "完本", "排行"] {
                sections.append(HomeSection(layout: .row, binding: .sourceCategories([
                    ExploreCategoryReference(sourceURL: provider.instance.id, title: title, url: "/\(title)"),
                ])))
            }
        }
        sections.append(HomeSection(layout: .row, binding: .latest))
        for index in 1...3 {
            sections.append(HomeSection(layout: .row, binding: .opdsFeed(connectionID: "o", url: "https://o.test/\(index)")))
        }
        sections.append(HomeSection(layout: .row, binding: .aozoraNew))
        for kind in ["authors", "titles", "categories"] {
            sections.append(HomeSection(layout: .row, binding: .aozoraIndex(kind: kind)))
        }
        let home = model(books + [opds, aozora])
        await home.sync(with: HomePage(sections: sections))
        #expect(rows(home).count == 20)

        let clock = ContinuousClock()
        let start = clock.now
        for row in rows(home) { home.load(row.id) }
        await until(home) { $0.contains { isLoaded($0.state) } }
        let first = clock.now - start
        await until(home) { $0.allSatisfy { isLoaded($0.state) } }
        let all = clock.now - start

        print("⏱ home.schedule rows=20 sources=5 first=\(first) all=\(all)")
        #expect(books.allSatisfy { $0.mostInFlight == 1 && $0.loads.count == 4 })
        #expect(opds.mostInFlight == 4)
        #expect(aozora.loads.count == 4)
        // Four 100 ms answers in a row per book source, and nothing waiting on another source.
        #expect(all < .milliseconds(1_000))
        #expect(all >= .milliseconds(400))
    }
}

// MARK: - Providers

private actor Calls {
    private(set) var log: [String] = []
    func add(_ entry: String) { log.append(entry) }
}

private func onlineBook(_ name: String, cover: String = "") -> OnlineBook {
    OnlineBook(name: name, author: "作者甲", intro: "<p>簡介</p>", coverUrl: cover, bookUrl: "https://src.test/book/\(name)",
               tocUrl: "", wordCount: "", lastChapter: "", kind: "", sourceId: UUID(), sourceName: "S")
}

@MainActor
@Suite("Book source home provider")
struct BookSourceProviderTests {
    private func source() -> BookSource {
        var source = BookSource()
        source.bookSourceName = "測試源"
        source.bookSourceUrl = "https://src.test"
        return source
    }

    @Test("a category row primes the cookies, then loads page 1 into frozen book snapshots")
    func categoryRow() async throws {
        let calls = Calls()
        let source = source()
        let provider = BookSourceProvider(
            source: source,
            pageLoader: SectionPageLoader { item, page, _ in
                await calls.add("fetch \(item.url ?? "") \(page)")
                return [onlineBook("甲", cover: "/c/甲.jpg"), onlineBook("乙"), onlineBook("甲")]
            },
            primeCookies: { _ in await calls.add("prime") }
        )
        let section = HomeSection(layout: .row, binding: .sourceCategories([
            ExploreCategoryReference(sourceURL: source.bookSourceUrl, title: "熱門", url: "/hot/{{page}}"),
        ]))
        #expect(provider.loadPolicy(for: section) == .serialPerSource)

        let entries = try await provider.load(section)
        #expect(await calls.log == ["prime", "fetch /hot/{{page}} 1"])
        #expect(entries.count == 2)
        guard case .item(let record, let summary, .onlineBook(let frozen)) = entries.first else {
            Issue.record("expected a book-source item"); return
        }
        #expect(frozen.book.name == "甲")
        #expect(record.key.instance == SourceInstanceKey(type: .bookSource, id: source.bookSourceUrl))
        #expect(summary.cover == .remote(URL(string: "https://src.test/c/%E7%94%B2.jpg")!, headers: [:]))
        #expect(summary.blurb?.contains("<p>") == false)
    }

    @Test("two rows of one source prime the cookies once")
    func primesOnce() async throws {
        let calls = Calls()
        let source = source()
        let provider = BookSourceProvider(source: source, pageLoader: SectionPageLoader { _, _, _ in [onlineBook("甲")] },
                                          primeCookies: { _ in await calls.add("prime") })
        for title in ["熱門", "完本"] {
            _ = try await provider.load(HomeSection(layout: .row, binding: .sourceCategories([
                ExploreCategoryReference(sourceURL: source.bookSourceUrl, title: title, url: "/\(title)"),
            ])))
        }
        #expect(await calls.log == ["prime"])
    }

    @Test("「最新」 is served only with a picked category")
    func latest() {
        let source = source()
        let provider = BookSourceProvider(source: source, pageLoader: SectionPageLoader { _, _, _ in [] }, primeCookies: { _ in })
        var section = HomeSection(layout: .row, binding: .latest)
        #expect(provider.loadPolicy(for: section) == nil)

        section.setLatestCategory(ExploreCategoryReference(sourceURL: source.bookSourceUrl, title: "最新", url: "/new"),
                                  forSourceURL: source.bookSourceUrl)
        #expect(provider.loadPolicy(for: section) == .serialPerSource)
        #expect(section.latestCategory(forSourceURL: source.bookSourceUrl)?.url == "/new")
    }

    @Test("another source's category is not this source's to serve")
    func otherSource() {
        let provider = BookSourceProvider(source: source(), pageLoader: SectionPageLoader { _, _, _ in [] }, primeCookies: { _ in })
        let section = HomeSection(layout: .row, binding: .sourceCategories([
            ExploreCategoryReference(sourceURL: "https://other.test", title: "熱門", url: "/hot"),
        ]))
        #expect(provider.loadPolicy(for: section) == nil)
    }
}

@MainActor
@Suite("Home rows from the shelf and WebDAV", .serialized)
struct LocalHomeRowTests {
    private func folder() throws -> (URL, () -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HomeRows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (folder, { try? FileManager.default.removeItem(at: folder) })
    }

    @Test("繼續閱讀 is the copies opened most recently, newest first, never-opened left out")
    func continueReading() async throws {
        let (folder, cleanup) = try folder()
        defer { cleanup() }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        defer { store.waitForQueuedWrites() }
        var older = ReadingBook(title: "舊", author: "", source: "local_epub", contentFilename: "a.epub")
        older.lastOpenedDate = Date(timeIntervalSinceReferenceDate: 100)
        var newer = ReadingBook(title: "新", author: "", source: "local_epub", contentFilename: "b.epub")
        newer.lastOpenedDate = Date(timeIntervalSinceReferenceDate: 200)
        let unopened = ReadingBook(title: "未讀", author: "", source: "local_epub", contentFilename: "c.epub")
        [older, newer, unopened].forEach { store.saveReadingBook($0) }

        let entries = try await ShelfProvider(store: store).load(HomeSection(layout: .row, binding: .continueReading))
        let copies = entries.compactMap { entry -> UUID? in
            if case .item(_, _, .copy(let id)) = entry { return id }
            return nil
        }
        #expect(copies == [newer.id, older.id])
    }

    @Test("a WebDAV connection's 「最新」 is its indexed books, newest on the server first")
    func webDAVLatest() async throws {
        let (folder, cleanup) = try folder()
        defer { cleanup() }
        let records = RemoteRecordStore(directory: folder)
        let root = URL(string: "https://dav.test/books/")!
        let connection = OPDSCatalog(name: "DAV", url: root.absoluteString, kind: .webDAV)
        var state = WebDAVIndexState(connectionID: connection.id, root: root)
        state.records = [
            ("舊.epub", "Mon, 01 Jan 2024 00:00:00 GMT"), ("無日期.epub", nil), ("新.epub", "Tue, 01 Oct 2024 08:00:00 GMT"),
        ].map { name, date in
            let entry = WebDAVBrowseClient.Entry(url: root.appendingPathComponent(name), name: name, isDirectory: false, size: 1)
            return IndexedFile(record: SourceRecord.derived(from: entry, connectionID: connection.id, root: root)!,
                               etag: nil, lastModified: date, size: 1)
        }
        records.save(state)
        records.waitForPendingWritesForTesting()

        let provider = WebDAVProvider(connection: connection, records: records) { WebDAVBrowseClient(serverUrl: root.absoluteString, username: "", password: "") }
        let section = HomeSection(layout: .row, binding: .latest)
        #expect(provider.loadPolicy(for: section) == .local)
        let names = try await provider.load(section).compactMap { entry -> String? in
            if case .item(_, _, .webDAVFile(let file, let id)) = entry, id == connection.id { return file.name }
            return nil
        }
        #expect(names == ["新.epub", "舊.epub", "無日期.epub"])
        #expect(WebDAVProvider(connection: connection) { WebDAVBrowseClient(serverUrl: "", username: "", password: "") }
            .loadPolicy(for: section) == nil)
    }

    @Test("an HTTP date reads the same by position as through DateFormatter")
    func serverDates() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        for text in ["Tue, 01 Oct 2024 08:00:00 GMT", "Thu, 29 Feb 2024 23:59:59 GMT", "Sat, 01 Jan 2000 00:00:00 GMT",
                     "Fri, 31 Dec 1999 12:34:56 GMT", "Sun, 06 Nov 1994 08:49:37 GMT"] {
            #expect(WebDAVProvider.serverDate(text) == formatter.date(from: text), "\(text)")
        }
        // RFC 850, which some servers still send, goes to the formatter's own rules.
        #expect(WebDAVProvider.serverDate("Sunday, 06-Nov-94 08:49:37 GMT") == formatter.date(from: "Sunday, 06-Nov-94 08:49:37 GMT"))
        #expect(WebDAVProvider.serverDate("Tue, 01 Foo 2024 08:00:00 GMT") == nil)
        #expect(WebDAVProvider.serverDate("") == nil)
    }

    /// Phase 2's measured size: 20,470 books. A row of 20 must not cost the whole index on the
    /// main actor.
    @Test("「最新」 over a 20,000-book index")
    func webDAVLatestAtScale() async throws {
        let (folder, cleanup) = try folder()
        defer { cleanup() }
        let records = RemoteRecordStore(directory: folder)
        let root = URL(string: "https://dav.test/books/")!
        let connection = OPDSCatalog(name: "DAV", url: root.absoluteString, kind: .webDAV)
        var state = WebDAVIndexState(connectionID: connection.id, root: root)
        let base = Date(timeIntervalSinceReferenceDate: 700_000_000)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        state.records = (0..<20_000).map { index in
            IndexedFile(record: SourceRecord(key: SourceItemKey(instance: SourceInstanceKey(type: .webDAV, id: connection.id), item: "d\(index / 10)/b\(index).epub"),
                                             title: "b\(index)", authors: [], language: nil, contentKind: .text, identifiers: [],
                                             copyID: nil, acquisitions: [.download(format: "epub")]),
                        etag: "\"\(index)\"", lastModified: formatter.string(from: base.addingTimeInterval(Double((index * 7919) % 20_000) * 60)), size: 1)
        }
        records.save(state)
        records.waitForPendingWritesForTesting()

        let provider = WebDAVProvider(connection: connection, records: records) { WebDAVBrowseClient(serverUrl: root.absoluteString, username: "", password: "") }
        let clock = ContinuousClock()
        let start = clock.now
        // The main actor keeps turning while the row loads: the longest gap between two turns
        // is how long the load held it.
        var longestGap = Duration.zero
        let ticking = Task { @MainActor in
            var last = clock.now
            while !Task.isCancelled {
                await Task.yield()
                let now = clock.now
                longestGap = max(longestGap, now - last)
                last = now
            }
        }
        let entries = try await provider.load(HomeSection(layout: .row, binding: .latest))
        let elapsed = clock.now - start
        ticking.cancel()
        print("⏱ home.webdav.latest files=20000 elapsed=\(elapsed) mainActorLongestGap=\(longestGap)")
        #expect(longestGap < .milliseconds(100))
        #expect(entries.count == HomeRow.limit)
        let first = entries.first.flatMap { entry -> String? in
            if case .item(let record, _, _) = entry { return record.title }
            return nil
        }
        // The newest is the index whose (index * 7919) % 20000 is 19999.
        let newest = (0..<20_000).max { ($0 * 7919) % 20_000 < ($1 * 7919) % 20_000 }!
        #expect(first == "b\(newest)")
    }
}
