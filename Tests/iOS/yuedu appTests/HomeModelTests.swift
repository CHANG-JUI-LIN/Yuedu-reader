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
    let policy: (HomeSection) -> SectionLoadPolicy?
    var gates: [Gate] = []
    var failure: (any Error)?
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
    model.items.compactMap { if case .row(let row) = $0 { return row } else { return nil } }
}

@MainActor
private func until(_ model: HomeModel, _ condition: @escaping ([HomeModel.Row]) -> Bool) async {
    _ = await model.$items.values.first { items in
        condition(items.compactMap { if case .row(let row) = $0 { return row } else { return nil } })
    }
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
        #expect(home.items.isEmpty)
        sources.open()
        await syncing.value
        #expect(home.isReady)
        #expect(rows(home).map(\.source) == [a.instance])
    }

    @Test("「最新」 is one row per source that serves it, in provider order, skipping the excluded")
    func latestExpands() async {
        let a = FakeProvider("a") { _ in .serialPerSource }
        let b = FakeProvider("b", type: .opds) { section in
            if case .latest(let excluded) = section.binding, !excluded.contains(SourceInstanceKey(type: .opds, id: "b")) { return .parallel }
            return nil
        }
        let c = FakeProvider("c", type: .aozora) { _ in nil }
        let home = model([a, b, c])
        await home.sync(with: HomePage(sections: [HomeSection(layout: .row, binding: .latest(excluded: []))]))
        #expect(rows(home).map(\.source.id) == ["a", "b"])

        await home.sync(with: HomePage(sections: [
            HomeSection(layout: .row, binding: .latest(excluded: [SourceInstanceKey(type: .opds, id: "b")])),
        ]))
        #expect(rows(home).map(\.source.id) == ["a"])
    }

    @Test("我的書庫 is a tile per source; a hidden section and one nothing serves have no row")
    func tilesAndUnserved() async {
        let a = FakeProvider("a") { _ in nil }
        let b = FakeProvider("b", type: .webDAV) { _ in nil }
        let home = model([a, b])
        let tiles = HomeSection(layout: .tiles, binding: .myLibrary)
        await home.sync(with: HomePage(sections: [
            tiles,
            HomeSection(layout: .row, binding: .continueReading, isEnabled: false),
            HomeSection(layout: .row, binding: .related),
            HomeSection(layout: .row, binding: .unknown(.object(["type": .string("later")]))),
        ]))
        #expect(home.items == [.tiles(sectionID: tiles.id, [
            HomeModel.Tile(source: a.instance, name: "a"), HomeModel.Tile(source: b.instance, name: "b"),
        ])])
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

    @Test("an on-demand row sends nothing until the reader asks")
    func onDemand() async throws {
        let g = FakeProvider("g", type: .gutenberg) { _ in .onDemandOnly }
        let home = model([g])
        await home.sync(with: HomePage(sections: [HomeSection(layout: .row, binding: .gutenbergFeed(url: "https://g.test/feed"))]))
        let row = try #require(rows(home).first)

        home.load(row.id)
        #expect(home.row(row.id)?.state == .awaitingRequest)
        #expect(g.loads.isEmpty)

        home.request(row.id)
        await until(home) { isLoaded($0[0].state) }
        #expect(g.loads.count == 1)

        home.reload()
        #expect(home.row(row.id)?.state == .awaitingRequest)
        #expect(g.loads.count == 1)
    }

    @Test("a failed row says why, and 重試 loads it again")
    func failureAndRetry() async throws {
        let a = FakeProvider("a", type: .opds) { _ in .parallel }
        a.failure = RowFailed()
        let home = model([a])
        await home.sync(with: HomePage(sections: [HomeSection(layout: .row, binding: .latest(excluded: []))]))
        let row = try #require(rows(home).first)

        home.load(row.id)
        await until(home) { $0[0].state == .failed("伺服器沒有回應") }
        a.failure = nil
        home.request(row.id)
        await until(home) { isLoaded($0[0].state) }
        #expect(a.loads.count == 2)
    }

    @Test("a sync keeps what an unchanged row loaded and rebuilds a changed one")
    func syncKeepsRows() async throws {
        let a = FakeProvider("a", type: .opds) { _ in .parallel }
        let home = model([a])
        var section = HomeSection(layout: .row, binding: .latest(excluded: []))
        await home.sync(with: HomePage(sections: [section]))
        let row = try #require(rows(home).first)
        home.load(row.id)
        await until(home) { isLoaded($0[0].state) }

        await home.sync(with: HomePage(sections: [section]))
        #expect(isLoaded(rows(home)[0].state))

        section.title = "新標題"
        await home.sync(with: HomePage(sections: [section]))
        #expect(rows(home)[0].state == .idle)
        home.load(row.id)
        await until(home) { isLoaded($0[0].state) }
        #expect(a.loads.count == 2)
    }

    @Test("Gutenberg's bundled lists load without a request, and its feeds wait for the reader")
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
            HomeSection(layout: .row, binding: .latest(excluded: [])),
        ]))
        #expect(rows(home).map(\.policy) == [.local, .onDemandOnly, .onDemandOnly])
        for row in rows(home) { home.load(row.id) }
        await until(home) { isLoaded($0[0].state) }

        guard case .loaded(let entries) = rows(home)[0].state else { Issue.record("not loaded"); return }
        #expect(entries.count == collection.books.count)
        if case .item(_, _, .gutenberg(let book)) = entries.first {
            #expect(book == collection.books.first)
        } else {
            Issue.record("expected a Gutenberg book")
        }
        #expect(rows(home)[1].state == .awaitingRequest)
        #expect(rows(home)[2].state == .awaitingRequest)
        #expect(requests == 0)
    }

    @Test("in China Gutenberg serves no section at all")
    func gutenbergInChina() {
        let availability = PublicLibraryAvailability(defaults: UserDefaults(suiteName: "HomeModelTests-\(UUID().uuidString)")!)
        availability.receive(countryCode: "CHN")
        let gutenberg = GutenbergProvider(availability: availability) { _ in OPDSFeed() }
        #expect(gutenberg.loadPolicy(for: HomeSection(layout: .row, binding: .gutenbergCollection(id: "chinese"))) == nil)
        #expect(gutenberg.loadPolicy(for: HomeSection(layout: .row, binding: .latest(excluded: []))) == nil)
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
        sections.append(HomeSection(layout: .row, binding: .latest(excluded: books.map(\.instance) + [aozora.instance])))
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

    @Test("「最新」 is served only with a picked category, and not when excluded")
    func latest() {
        let source = source()
        let provider = BookSourceProvider(source: source, pageLoader: SectionPageLoader { _, _, _ in [] }, primeCookies: { _ in })
        var section = HomeSection(layout: .row, binding: .latest(excluded: []))
        #expect(provider.loadPolicy(for: section) == nil)

        section.setLatestCategory(ExploreCategoryReference(sourceURL: source.bookSourceUrl, title: "最新", url: "/new"),
                                  forSourceURL: source.bookSourceUrl)
        #expect(provider.loadPolicy(for: section) == .serialPerSource)
        #expect(section.latestCategory(forSourceURL: source.bookSourceUrl)?.url == "/new")

        section.binding = .latest(excluded: [provider.instance])
        #expect(provider.loadPolicy(for: section) == nil)
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
        let section = HomeSection(layout: .row, binding: .latest(excluded: []))
        #expect(provider.loadPolicy(for: section) == .local)
        let names = try await provider.load(section).compactMap { entry -> String? in
            if case .item(_, _, .webDAVFile(let file, let id)) = entry, id == connection.id { return file.name }
            return nil
        }
        #expect(names == ["新.epub", "舊.epub", "無日期.epub"])
        #expect(WebDAVProvider(connection: connection) { WebDAVBrowseClient(serverUrl: "", username: "", password: "") }
            .loadPolicy(for: section) == nil)
    }
}
