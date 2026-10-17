import Foundation
import Testing
@testable import yuedu_app

/// Open Library module plan, OL1: a `search` or `lookup` entry's `detail`, the record's own page
/// asked for what its row lacks (Open Library's description is at `/works/<id>.json`, not in its
/// search). One request for the record that is the copy's, only for a field still missing.
@MainActor
@Suite("Module detail requests", .serialized)
struct ModuleDetailTests {
    private static let isbn = "9787536692930"

    // MARK: - Validator

    private func module(_ object: [String: Any]) -> Data {
        var base: [String: Any] = ["id": "d.test", "title": "d", "version": "1.0", "requiredVersion": "3.0",
                                   "hosts": ["example.com"], "modules": [[String: Any]]()]
        base.merge(object) { _, new in new }
        return try! JSONSerialization.data(withJSONObject: base)
    }

    private func search(detail: [String: Any]) -> [String: Any] {
        ["search": ["request": ["url": "https://example.com/s?q={{keyword}}"],
                    "list": ["items": "$.docs[*]", "title": "$.title", "url": "$.key"],
                    "detail": detail]]
    }

    @Test("a detail reads the item's url and gives a description or tags")
    func accepted() throws {
        let validated = try RuleModuleValidator.validate(module(search(detail: [
            "request": ["url": "{{url}}.json"], "intro": "$.description", "tags": "$.subjects[*]",
        ])), appVersion: "3.0.0")
        #expect(validated.search?.detail?.request.url == "{{url}}.json")
        #expect(validated.search?.detail?.intro == "$.description")
        _ = try RuleModuleValidator.validate(module(search(detail: [
            "request": ["url": "https://example.com/detail?u={{url}}"], "intro": "$.d",
        ])), appVersion: "3.0.0")
    }

    @Test("a detail is refused where it cannot run, gives nothing, or reaches past the module")
    func refused() {
        func rejection(_ data: Data) -> RuleModuleRejection? {
            do { _ = try RuleModuleValidator.validate(data, appVersion: "3.0.0"); return nil } catch { return error }
        }
        let list: [String: Any] = ["items": "li", "title": "h3@text"]
        #expect(rejection(module(["modules": [["id": "a", "title": "a", "request": ["url": "https://example.com/a"],
                                               "list": list, "detail": ["request": ["url": "{{url}}"], "intro": "p@text"]]]]))
                == .unknownValue(field: "modules[0].detail", value: "detail"), "a home list is never asked for a record's page")
        #expect(rejection(module(search(detail: ["request": ["url": "{{url}}.json"]])))
                == .missingField("search.detail.intro"), "a detail with neither a description nor tags asks for nothing")
        #expect(rejection(module(search(detail: ["request": ["url": "{{url}}?q={{keyword}}"], "intro": "$.d"])))
                == .undeclaredTemplate(field: "search.detail.request.url", name: "keyword"))
        #expect(rejection(module(search(detail: ["request": ["url": "https://other.example/{{url}}"], "intro": "$.d"])))
                == .hostNotAllowed(field: "search.detail.request.url", host: "other.example"))
        #expect(rejection(module(search(detail: ["request": ["url": "{{url}}.json"], "intro": "@js:result"])))
                == .javaScript(field: "search.detail.intro"))
        var unversioned: [String: Any] = ["id": "d.test", "title": "d", "version": "1.0", "hosts": ["example.com"],
                                          "modules": [[String: Any]]()]
        unversioned.merge(search(detail: ["request": ["url": "{{url}}.json"], "intro": "$.d"])) { _, new in new }
        #expect(rejection(try! JSONSerialization.data(withJSONObject: unversioned))
                == .needsRequiredVersion(field: "search.detail", minimum: "3.0"))
    }

    // MARK: - Fill

    private struct Fixture {
        let provider: ModuleProvider
        let folder: URL
        func cleanUp() { try? FileManager.default.removeItem(at: folder) }
    }

    private func fixture(_ object: [String: Any]) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleDetail-\(UUID().uuidString)")
        let store = RuleModuleStore(directory: folder)
        let library = RuleModuleLibrary(store: store, appVersion: "3.0.0", officialFiles: { [] })
        let installed = try await library.install(module(object), from: nil).module
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)), store: store,
                                      now: { Date() })
        return Fixture(provider: ModuleProvider(module: installed, client: client), folder: folder)
    }

    private var lookupModule: [String: Any] {
        ["lookup": ["request": ["url": "https://example.com/isbn/{{isbn}}"],
                    "list": ["items": "$.docs[*]", "title": "$.title", "url": "$.key", "isbn": "$.isbn", "intro": "$.intro"],
                    "detail": ["request": ["url": "{{url}}.json"], "intro": "$.description", "tags": "$.subjects[*]"]]]
    }

    private func query(missing: Set<MetadataField>, isbn: Bool = true) -> MetadataFillQuery {
        MetadataFillQuery(copyID: UUID(), title: "三體", authors: ["劉慈欣"],
                          identifiers: isbn ? [ExternalIdentifier.normalized(.isbn13, Self.isbn)!] : [],
                          copySource: .localLibrary, missing: missing)
    }

    @Test("the copy's record gives what its page holds: one more request, for the record found")
    func lookupDetail() async throws {
        let f = try await fixture(lookupModule)
        defer { f.cleanUp() }
        ModuleStub.install([
            "example.com/isbn/\(Self.isbn)": .json(#"{"docs":[{"title":"三體","key":"/works/OL1W","isbn":"\#(Self.isbn)"}]}"#),
            "example.com/works/OL1W.json": .json(#"{"description":"地球往事。","subjects":["科幻","長篇小說"]}"#),
        ])
        let result = try await ModuleFillProvider(provider: f.provider).lookUp(query(missing: [.intro, .tags]))
        #expect(result.values[.intro] == .text("地球往事。"))
        #expect(result.values[.tags] == .texts(["科幻", "長篇小說"]))
        #expect(ModuleStub.urls == ["https://example.com/isbn/\(Self.isbn)", "https://example.com/works/OL1W.json"])
    }

    @Test("no detail request when the row has what is missing, or nothing the detail gives is missing")
    func lookupNoDetail() async throws {
        let f = try await fixture(lookupModule)
        defer { f.cleanUp() }
        ModuleStub.install([
            "example.com/isbn/\(Self.isbn)": .json(#"{"docs":[{"title":"三體","key":"/works/OL1W","isbn":"\#(Self.isbn)","intro":"列表裡的簡介。"}]}"#),
            "example.com/works/OL1W.json": .json(#"{"description":"地球往事。"}"#),
        ])
        let filler = ModuleFillProvider(provider: f.provider)
        #expect(try await filler.lookUp(query(missing: [.intro])).values[.intro] == .text("列表裡的簡介。"))
        #expect(ModuleStub.urls == ["https://example.com/isbn/\(Self.isbn)"])

        ModuleStub.install([
            "example.com/isbn/\(Self.isbn)": .json(#"{"docs":[{"title":"三體","key":"/works/OL1W","isbn":"\#(Self.isbn)"}]}"#),
        ])
        _ = try await filler.lookUp(query(missing: [.publisher]))
        #expect(ModuleStub.urls == ["https://example.com/isbn/\(Self.isbn)"], "only a publisher is missing: the page is not asked")
    }

    @Test("a detail that fails throws, so the ledger asks again; one outside the hosts is never sent")
    func lookupDetailFails() async throws {
        let f = try await fixture(lookupModule)
        defer { f.cleanUp() }
        ModuleStub.install([
            "example.com/isbn/\(Self.isbn)": .json(#"{"docs":[{"title":"三體","key":"/works/OL1W","isbn":"\#(Self.isbn)"}]}"#),
            "example.com/works/OL1W.json": .status(500),
        ])
        let filler = ModuleFillProvider(provider: f.provider)
        await #expect(throws: (any Error).self) { try await filler.lookUp(query(missing: [.intro])) }

        ModuleStub.install([
            "example.com/isbn/\(Self.isbn)": .json(#"{"docs":[{"title":"三體","key":"https://elsewhere.example/w","isbn":"\#(Self.isbn)"}]}"#),
        ])
        await #expect(throws: (any Error).self) { try await filler.lookUp(query(missing: [.intro])) }
        #expect(ModuleStub.urls == ["https://example.com/isbn/\(Self.isbn)"], "the record's url names another host: not asked")
    }

    @Test("a search asks the detail of the one result that is the copy's work, not of every row")
    func searchDetail() async throws {
        let f = try await fixture(["search": ["request": ["url": "https://example.com/s?q={{keyword}}"],
                                              "list": ["items": "$.docs[*]", "title": "$.title", "author": "$.author", "url": "$.key"],
                                              "detail": ["request": ["url": "{{url}}.json"], "intro": "$.description"]]])
        defer { f.cleanUp() }
        ModuleStub.install([
            "example.com/s": .json(#"{"docs":[{"title":"三體","author":"別人","key":"/works/OL9W"},{"title":"三體","author":"劉慈欣","key":"/works/OL1W"}]}"#),
            "example.com/works/OL1W.json": .json(#"{"description":"地球往事。"}"#),
        ])
        let result = try await ModuleFillProvider(provider: f.provider).lookUp(query(missing: [.intro], isbn: false))
        #expect(result.values[.intro] == .text("地球往事。"))
        #expect(ModuleStub.urls == ["https://example.com/s?q=%E4%B8%89%E9%AB%94", "https://example.com/works/OL1W.json"])
    }
}
