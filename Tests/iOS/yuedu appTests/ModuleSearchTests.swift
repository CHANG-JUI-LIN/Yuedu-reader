import Foundation
import Testing
@testable import yuedu_app

/// Phase 6g: a module with a search takes part in 搜索 on submit, beside the saved libraries,
/// against its own timeout. Requests are answered by `ModuleStub` (keyed by host and path).
@MainActor
@Suite("Modules in 搜索", .serialized)
struct ModuleSearchTests {
    private func moduleJSON(id: String, title: String, search: Bool) -> Data {
        var object: [String: Any] = [
            "id": id, "title": title, "version": "1.0", "hosts": ["example.com"],
            "modules": [[
                "id": "new", "title": "新書",
                "request": ["url": "https://example.com/new"],
                "list": ["items": "li", "title": "h3@text"],
            ]],
        ]
        if search {
            object["search"] = [
                "title": "搜尋",
                "request": ["url": "https://example.com/s?k={{keyword}}"],
                "list": ["items": "li", "title": "h3@text", "author": "span@text", "url": "a@href"],
            ]
        }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func html(_ books: [(String, String)]) -> String {
        "<ul>" + books.map { "<li><h3>\($0.0)</h3><span>\($0.1)</span><a href=\"/b/\($0.0)\">x</a></li>" }.joined() + "</ul>"
    }

    private struct Fixture {
        let searching: ModuleProvider
        let plain: ModuleProvider
        let folder: URL
    }

    private func makeFixture() async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleSearch-\(UUID().uuidString)")
        let store = RuleModuleStore(directory: folder)
        let library = RuleModuleLibrary(store: store, appVersion: "2.0.8")
        let searching = try await library.install(moduleJSON(id: "m.search", title: "搜尋模組", search: true), from: nil).module
        let plain = try await library.install(moduleJSON(id: "m.plain", title: "清單模組", search: false), from: nil).module
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)), store: store,
                                      now: { Date() })
        return Fixture(searching: ModuleProvider(module: searching, client: client),
                       plain: ModuleProvider(module: plain, client: client), folder: folder)
    }

    private func makeStore() throws -> (BookStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleSearchShelf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json")), folder)
    }

    private func answers(_ search: ModuleSearch, _ query: String) async -> [LibrarySearchAnswer] {
        var answers: [LibrarySearchAnswer] = []
        await search.search(query) { answers.append($0) }
        return answers
    }

    @Test("a module with a search answers with data-only books; one without is not asked")
    func results() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["example.com/s": .html(html([("三體", "劉慈欣"), ("球狀閃電", "劉慈欣")]))])
        let search = ModuleSearch(providers: { [f.searching, f.plain] })

        let answers = await answers(search, " 三體 ")
        let answer = try #require(answers.first)
        #expect(answers.count == 1, "the module without a search is not asked")
        #expect(answer.connectionID == "module:m.search")
        #expect(answer.name == "搜尋模組")
        #expect(answer.outcome == .results)
        #expect(answer.entries.count == 2)
        let route = try #require(answer.entries.first.flatMap(WorkDetailRoute.init))
        #expect(route.summary.title == "三體")
        #expect(route.summary.authors == ["劉慈欣"])
        #expect(route.opening == .bibliographic)
        #expect(!route.isReadable)
        #expect(ModuleStub.urls == ["https://example.com/s?k=%E4%B8%89%E9%AB%94"], "the trimmed keyword, encoded")
    }

    @Test("no book is empty; a refusal and a site that hangs fail on their own")
    func emptyAndFailed() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["example.com/s": .html("<ul></ul>")])
        #expect(await answers(ModuleSearch(providers: { [f.searching] }), "zzzz").map(\.outcome) == [.empty])

        ModuleStub.install(["example.com/s": .status(403)])
        let refused = await answers(ModuleSearch(providers: { [f.searching] }), "三體")
        guard case .failed(let reason) = try #require(refused.first).outcome else {
            Issue.record("expected a failure, got \(refused)")
            return
        }
        #expect(!reason.isEmpty)

        ModuleStub.install(["example.com/s": .hang])
        let started = ContinuousClock.now
        let hung = await answers(ModuleSearch(providers: { [f.searching] }, timeout: .milliseconds(300)), "三體")
        guard case .failed = try #require(hung.first).outcome else {
            Issue.record("expected a timeout, got \(hung)")
            return
        }
        #expect(ContinuousClock.now - started < .seconds(5), "its own timeout, not the request's")
    }

    @Test("nothing is sent before submit, nor for an empty query")
    func onSubmitOnly() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let (store, shelf) = try makeStore()
        defer { try? FileManager.default.removeItem(at: shelf) }
        ModuleStub.install(["example.com/s": .html(html([("三體", "劉慈欣")]))])

        #expect(!ModuleSearch(providers: { [f.plain] }).isAvailable, "no module with a search: nothing to ask")
        let model = LibrarySearchModel(searches: [ModuleSearch(providers: { [f.searching] })])
        #expect(model.isAvailable)
        #expect(ModuleStub.urls.isEmpty, "made and asked whether it would search: nothing sent")

        model.start("   ", store: store)
        await model.waitForTesting()
        #expect(ModuleStub.urls.isEmpty)
        #expect(model.matches.isEmpty)

        model.start("三體", store: store)
        await model.waitForTesting()
        #expect(ModuleStub.urls.count == 1)
        #expect(model.matches.map(\.rowContent.detail) == ["搜尋模組"], "the row names its module")
    }

    @Test("the libraries' section asks its parts together; a failed module is its own status line")
    func besideTheLibraries() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let (store, shelf) = try makeStore()
        defer { try? FileManager.default.removeItem(at: shelf) }
        ModuleStub.install(["example.com/s": .status(500)])
        let library = AnsweringStub(answer: LibrarySearchAnswer(connectionID: "calibre", name: "Calibre", outcome: .empty, entries: []))
        let model = LibrarySearchModel(searches: [library, ModuleSearch(providers: { [f.searching] })])

        model.start("三體", store: store)
        #expect(model.isSearching)
        await model.waitForTesting()
        #expect(!model.isSearching, "until the last part has answered")
        #expect(library.queries == ["三體"])
        #expect(model.failures.map(\.id) == ["module:m.search"])
        #expect(model.failures.first?.line.contains("搜尋模組") == true)
    }

    @Test("a module's book is one work with the shelf's copy of it, which leads")
    func mergesWithTheShelf() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let (store, shelf) = try makeStore()
        defer { try? FileManager.default.removeItem(at: shelf) }
        ModuleStub.install(["example.com/s": .html(html([("三體", "劉慈欣"), ("球狀閃電", "劉慈欣")]))])
        let model = LibrarySearchModel(searches: [ModuleSearch(providers: { [f.searching] })])
        model.start("三體", store: store)
        await model.waitForTesting()

        let copy = ReadingBook(title: "三體", author: "劉慈欣", source: "local", contentFilename: "\(UUID().uuidString).epub")
        store.saveReadingBook(copy)
        let entry = try #require(ShelfProvider(store: store).items([copy]).first)
        let works = UnifiedSearchModel(sourceURL: { _ in nil })
        await works.update(UnifiedSearchParts(shelf: [ShelfSearchMatch(book: copy, route: try #require(WorkDetailRoute(entry)))],
                                              libraries: model.matches), query: "三體")

        let row = try #require(works.rows.first)
        #expect(row.members.count == 2, "\(row.members.map(\.title))")
        #expect(row.work.availability == .onShelf)
        #expect(row.work.lead.kind == .shelf)
        #expect(row.work.members.last?.kind == .bibliographic)
        #expect(row.work.sourceCount == 0, "data only: no place to read it from")
        #expect(works.rows.count == 2, "球狀閃電 is its own work")
    }

    @Test("its manifest advertises a search on submit")
    func capabilities() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        #expect(await f.searching.capabilities().search == .onSubmit)
        #expect(await f.plain.capabilities().search == CollectionSearchSupport.none)
        #expect(await f.searching.manifest().capabilities.contains(.search(.onSubmit)))
    }
}

/// A part that answers at once with what it was given.
@MainActor
private final class AnsweringStub: SearchAnswering {
    let answer: LibrarySearchAnswer
    private(set) var queries: [String] = []

    init(answer: LibrarySearchAnswer) { self.answer = answer }

    var isAvailable: Bool { true }

    func search(_ query: String, onAnswer: (LibrarySearchAnswer) -> Void) async {
        queries.append(query)
        onAnswer(answer)
    }
}
