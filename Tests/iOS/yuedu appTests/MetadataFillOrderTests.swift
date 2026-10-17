import Combine
import Foundation
import Testing
@testable import yuedu_app

/// Phase 6h: 資料來源, Emby's 中繼資料下載器 (maintainer, 2026-10-15). The places that fill a
/// copy's empty fields, checked or not and in priority order; a module fills through its search.
@MainActor
@Suite("Metadata fill order and modules", .serialized)
struct MetadataFillOrderTests {
    private typealias Entry = MetadataFillOrder.Entry

    @Test("a reader who never opened the list asks what Phase 3 asked, in the same order")
    func builtInOrder() {
        let order = MetadataFillOrder.resolved(stored: [], modules: ["m", OfficialRuleModules.openLibraryID])
        #expect(order.entries == [Entry(place: .module(OfficialRuleModules.openLibraryID), isEnabled: true),
                                  Entry(place: .bookSources, isEnabled: true), Entry(place: .module("m"), isEnabled: true)],
                "Open Library, now a module, still comes before 來源配置")
        #expect(MetadataFillOrder.resolved(stored: [], modules: []).entries == [Entry(place: .bookSources, isEnabled: true)],
                "with the official modules turned off only 來源配置 is left")
    }

    @Test("Open Library's stored place and check become the module's; its first entry counts")
    func openLibraryMigration() throws {
        let suite = "MetadataFillOrderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([["place": "bookSources", "enabled": "1"], ["place": "openLibrary", "enabled": "0"],
                      ["place": "module:openlibrary", "enabled": "1"]], forKey: MetadataFillOrderStore.defaultsKey)
        let order = MetadataFillOrderStore(defaults: defaults).order(modules: [OfficialRuleModules.openLibraryID])
        #expect(order.entries == [Entry(place: .bookSources, isEnabled: true),
                                  Entry(place: .module(OfficialRuleModules.openLibraryID), isEnabled: false)],
                "the reader's order and the unchecked box stand")
    }

    @Test("a new module joins at the end, checked; the reader's order and checks stand; a removed module is left out")
    func resolution() {
        let stored = [Entry(place: .module("a"), isEnabled: false), Entry(place: .bookSources, isEnabled: true),
                      Entry(place: .module("gone"), isEnabled: true), Entry(place: .module("ol"), isEnabled: false),
                      Entry(place: .bookSources, isEnabled: false)]
        let order = MetadataFillOrder.resolved(stored: stored, modules: ["a", "ol", "b"])
        #expect(order.entries == [Entry(place: .module("a"), isEnabled: false), Entry(place: .bookSources, isEnabled: true),
                                  Entry(place: .module("ol"), isEnabled: false), Entry(place: .module("b"), isEnabled: true)])
    }

    @Test("only checked places become providers, first first; a module needs a search")
    func providers() async throws {
        let f = try await ModuleFixture.make()
        defer { f.cleanUp() }
        let order = MetadataFillOrder(entries: [Entry(place: .module("m.search"), isEnabled: true),
                                                Entry(place: .module("m.off"), isEnabled: false),
                                                Entry(place: .module("m.plain"), isEnabled: true),
                                                Entry(place: .bookSources, isEnabled: true)])
        #expect(order.providers(modules: [f.searching.module, f.plain.module]).map(\.key)
                == [ModuleProvider.instanceKey(moduleID: "m.search"), BookSourceFillProvider.allSourcesKey])
    }

    @Test("the store keeps the order; a removed module's check comes back when it is installed again")
    func store() throws {
        let suite = "MetadataFillOrderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MetadataFillOrderStore(defaults: defaults)
        let ol = OfficialRuleModules.openLibraryID
        var order = store.order(modules: ["m", ol])
        order.entries[2].isEnabled = false
        order.entries.swapAt(0, 2)
        store.save(order)
        #expect(MetadataFillOrderStore(defaults: defaults).order(modules: ["m", ol]) == order, "read back as saved")

        let withoutModule = store.order(modules: [ol])
        #expect(withoutModule.entries.map(\.place) == [.bookSources, .module(ol)])
        store.save(withoutModule)
        #expect(store.order(modules: ["m", ol]).entries.last == Entry(place: .module("m"), isEnabled: false),
                "unchecked before removal, unchecked after")

        defaults.set([["place": "somewhere"], ["enabled": "1"]], forKey: MetadataFillOrderStore.defaultsKey)
        #expect(MetadataFillOrderStore(defaults: defaults).stored.isEmpty, "unknown entries are skipped")
    }

    @Test("the runner's first provider gives the value: the list's order is the priority")
    func firstPlaceWins() async throws {
        for (first, second) in [("甲", "乙"), ("乙", "甲")] {
            let a = FakeProvider(key: SourceInstanceKey(type: .module, id: first), intro: "\(first)的簡介")
            let b = FakeProvider(key: SourceInstanceKey(type: .module, id: second), intro: "\(second)的簡介")
            let ledger = MetadataFillLedger(worksDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("order-\(UUID().uuidString)"))
            var written: [ImportedMetadata] = []
            let runner = MetadataFillRunner(providers: [a, b], ledger: ledger, write: { written.append($0) })
            let id = UUID()
            await runner.fill([MetadataFillCandidate(copyID: id, title: "三體", authors: ["劉慈欣"], identifiers: [],
                                                     copySource: .localLibrary, sidecarSourceItem: .copy(id), hasOwnCover: true,
                                                     values: [], decisions: [])])
            let intros: [MetadataPayload] = written.flatMap(\.values).filter { $0.field == .intro }.map(\.value)
            let expected: [MetadataPayload] = [.text("\(first)的簡介")]
            #expect(intros == expected, "the field was filled: the next place's value for it is not written")
            #expect(b.queries.allSatisfy { !$0.missing.contains(.intro) })
        }
    }

    // MARK: - ModuleFillProvider

    @Test("a module fills 簡介 and 分類 from a search result of the same title and author")
    func moduleFills() async throws {
        let f = try await ModuleFixture.make()
        defer { f.cleanUp() }
        ModuleStub.install(["example.com/s": .html(ModuleFixture.html([
            ("三體", "別人", "不是這本", "科幻"),
            ("三體", "劉慈欣", "地球往事。", "科幻,長篇"),
        ]))])
        let filler = ModuleFillProvider(provider: f.searching)
        let result = try await filler.lookUp(query())
        #expect(result.values[.intro] == .text("地球往事。"))
        #expect(result.values[.tags] == .texts(["科幻", "長篇"]), "every category the item's kind names")
        #expect(result.values[.cover] == nil && result.identifiers.isEmpty, "level B: no cover, no identifier")
        #expect(result.sourceItem?.instance == ModuleProvider.instanceKey(moduleID: "m.search"))
        #expect(ModuleStub.urls == ["https://example.com/s?k=%E4%B8%89%E9%AB%94"])

        ModuleStub.install(["example.com/s": .html(ModuleFixture.html([("三體", "別人", "不是這本", "科幻")]))])
        #expect(try await filler.lookUp(query()).values.isEmpty, "another author's 三體 gives nothing")

        ModuleStub.install(["example.com/s": .html(ModuleFixture.html([
            ("三體", "劉慈欣", "地球往事。", "科幻"), ("三體", "劉慈欣", "另一個版本。", "科幻"),
        ]))])
        #expect(try await filler.lookUp(query()).values.isEmpty, "two results are the same work: which one is unknown, so neither")
    }

    @Test("a refusal or a hanging site throws, so the ledger asks again later")
    func moduleFailures() async throws {
        let f = try await ModuleFixture.make()
        defer { f.cleanUp() }
        ModuleStub.install(["example.com/s": .status(403)])
        await #expect(throws: (any Error).self) { try await ModuleFillProvider(provider: f.searching).lookUp(query()) }
        ModuleStub.install(["example.com/s": .hang])
        let started = ContinuousClock.now
        await #expect(throws: (any Error).self) {
            try await ModuleFillProvider(provider: f.searching, timeout: .milliseconds(300)).lookUp(query())
        }
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("not asked for a copy from the module itself, without an author, or with only a cover missing")
    func moduleCanLookUp() async throws {
        let f = try await ModuleFixture.make()
        defer { f.cleanUp() }
        let filler = ModuleFillProvider(provider: f.searching)
        #expect(filler.canLookUp(query()))
        var own = query()
        own.copySource = ModuleProvider.instanceKey(moduleID: "m.search")
        #expect(!filler.canLookUp(own))
        var anonymous = query()
        anonymous.authors = [" "]
        #expect(!filler.canLookUp(anonymous))
        var coverOnly = query()
        coverOnly.missing = [.cover]
        #expect(!filler.canLookUp(coverOnly))
    }

    // MARK: - Coordinator

    @Test("unchecking a place stops the running pass: it is asked nothing more")
    func uncheckStopsThePass() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("FillOrder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        store.saveReadingBook(ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "a.txt"))
        store.saveReadingBook(ReadingBook(title: "球狀閃電", author: "劉慈欣", source: "local", contentFilename: "b.txt"))

        let changed = PassthroughSubject<Void, Never>()
        let module = FakeProvider(key: SourceInstanceKey(type: .module, id: "m"), intro: "")
        var checked = true
        module.onLookUp = {
            // The reader unchecks the module while it answers its first copy.
            checked = false
            changed.send()
        }
        let coordinator = MetadataFillCoordinator(store: store, makeProviders: { checked ? [module] : [] },
                                                  placesChanged: changed.eraseToAnyPublisher(),
                                                  network: AllowingNetwork(), isEnabled: { true }, isLowPower: { false })
        coordinator.setActive(true)
        await coordinator.waitUntilIdleForTesting()
        #expect(module.titles.count == 1, "asked for one copy, then nothing: \(module.titles)")
    }

    private func query() -> MetadataFillQuery {
        MetadataFillQuery(copyID: UUID(), title: "三體", authors: ["劉慈欣"], identifiers: [], copySource: .localLibrary,
                          missing: [.intro, .tags, .cover])
    }
}

/// Two installed modules on a stubbed session: `m.search` with a search, `m.plain` without.
@MainActor
private struct ModuleFixture {
    let searching: ModuleProvider
    let plain: ModuleProvider
    let folder: URL

    static func make() async throws -> ModuleFixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleFill-\(UUID().uuidString)")
        let store = RuleModuleStore(directory: folder)
        let library = RuleModuleLibrary(store: store, appVersion: "2.0.8", officialFiles: { [] })
        let searching = try await library.install(json(id: "m.search", search: true), from: nil).module
        let plain = try await library.install(json(id: "m.plain", search: false), from: nil).module
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)), store: store,
                                      now: { Date() })
        return ModuleFixture(searching: ModuleProvider(module: searching, client: client),
                             plain: ModuleProvider(module: plain, client: client), folder: folder)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    static func json(id: String, search: Bool) -> Data {
        var object: [String: Any] = [
            "id": id, "title": id, "version": "1.0", "hosts": ["example.com"],
            "modules": [["id": "new", "title": "新書", "request": ["url": "https://example.com/new"],
                         "list": ["items": "li", "title": "h3@text"]]],
        ]
        if search {
            object["search"] = ["request": ["url": "https://example.com/s?k={{keyword}}"],
                                "list": ["items": "li", "title": "h3@text", "author": ".a@text", "url": "a@href",
                                         "intro": ".i@text", "kind": ".k@text"]]
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    static func html(_ books: [(String, String, String, String)]) -> String {
        "<ul>" + books.enumerated().map { index, book in
            "<li><h3>\(book.0)</h3><span class=\"a\">\(book.1)</span><p class=\"i\">\(book.2)</p><span class=\"k\">\(book.3)</span><a href=\"/b/\(index)\">x</a></li>"
        }.joined() + "</ul>"
    }
}

@MainActor
private final class FakeProvider: MetadataFillProvider {
    let key: SourceInstanceKey
    let grade: MetadataMatchGrade = .b
    let intro: String
    var titles: [String] = []
    var queries: [MetadataFillQuery] = []
    var onLookUp: (() -> Void)?

    init(key: SourceInstanceKey, intro: String) {
        self.key = key
        self.intro = intro
    }

    func canLookUp(_ query: MetadataFillQuery) -> Bool { true }

    func lookUp(_ query: MetadataFillQuery) async throws -> MetadataFillResult {
        titles.append(query.title)
        queries.append(query)
        onLookUp?()
        return MetadataFillResult(values: intro.isEmpty ? [:] : [.intro: .text(intro)])
    }
}

@MainActor
private final class AllowingNetwork: NetworkPathProviding {
    var allowsBackgroundWork: Bool { true }
    var allowsBackgroundWorkPublisher: AnyPublisher<Bool, Never> { Just(true).eraseToAnyPublisher() }
}
