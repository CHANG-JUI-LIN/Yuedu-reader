import Foundation
import Testing
@testable import yuedu_app

/// Phase 6f-2: a module row's 查看全部, its list page by page. Requests are answered by
/// `ModuleStub` (keyed by host and path), so each page has a path of its own.
@MainActor
@Suite("Module list page", .serialized)
struct ModuleListPageTests {
    private func moduleJSON() -> Data {
        let object: [String: Any] = [
            "id": "m.list", "title": "清單模組", "version": "1.0", "hosts": ["example.com"],
            "modules": [[
                "id": "new", "title": "新書",
                "params": [
                    ["name": "sort", "type": "enumeration",
                     "enumOptions": [["title": "熱門", "value": "hot"], ["title": "最新", "value": "new"]]],
                    ["name": "page", "type": "page"],
                ],
                "request": ["url": "https://example.com/{{sort}}/{{page}}"],
                "list": ["items": "li", "title": "h3@text", "url": "a@href"],
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func html(_ titles: [String]) -> String {
        "<ul>" + titles.map { "<li><h3>\($0)</h3><a href=\"/b/\($0)\">x</a></li>" }.joined() + "</ul>"
    }

    private struct Fixture {
        let library: RuleModuleLibrary
        let client: RuleModuleClient
        let folder: URL
    }

    private func makeFixture(installed: Bool = true) async throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleListPage-\(UUID().uuidString)")
        let store = RuleModuleStore(directory: folder)
        let library = RuleModuleLibrary(store: store, appVersion: "2.0.8", officialFiles: { [] })
        if installed { try await library.install(moduleJSON(), from: nil) } else { await library.load() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModuleStub.self]
        let client = RuleModuleClient(fetcher: WebFetcher(session: URLSession(configuration: configuration)), store: store,
                                      now: { Date() })
        return Fixture(library: library, client: client, folder: folder)
    }

    private let route = ModuleListRoute(moduleID: "m.list", entryID: "new", title: "新書", parameters: ["sort": "new"])

    private func titles(_ model: ModuleListModel) -> [String] {
        model.entries.compactMap { if case .item(_, let summary, _) = $0 { summary.title } else { nil } }
    }

    @Test("page after page with the section's own values, until a page brings nothing")
    func pages() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install([
            "example.com/new/1": .html(html(["一", "二"])),
            "example.com/new/2": .html(html(["三"])),
            "example.com/new/3": .html("<ul></ul>"),
        ])
        let model = ModuleListModel(route: route, library: f.library, client: f.client)

        await model.load()
        #expect(model.state == .loaded)
        #expect(titles(model) == ["一", "二"])
        #expect(model.canLoadMore)
        await model.loadMore()
        #expect(titles(model) == ["一", "二", "三"])
        #expect(model.canLoadMore)
        await model.loadMore()
        #expect(titles(model) == ["一", "二", "三"])
        #expect(!model.canLoadMore, "an empty page ends the list")
        #expect(ModuleStub.urls == ["https://example.com/new/1", "https://example.com/new/2", "https://example.com/new/3"])
    }

    @Test("a site that answers every page with the same books ends the list instead of repeating them")
    func repeatedPageEnds() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install([
            "example.com/new/1": .html(html(["一", "二"])),
            "example.com/new/2": .html(html(["二", "一"])),
        ])
        let model = ModuleListModel(route: route, library: f.library, client: f.client)
        await model.load()
        await model.loadMore()
        #expect(titles(model) == ["一", "二"], "no card twice")
        #expect(!model.canLoadMore)
    }

    @Test("a failed first page is the page's state; a failed next page keeps what was read")
    func failures() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.folder) }
        ModuleStub.install(["example.com/new/1": .status(403)])
        let failed = ModuleListModel(route: route, library: f.library, client: f.client)
        await failed.load()
        guard case .failed = failed.state else { Issue.record("state \(failed.state)"); return }

        ModuleStub.install(["example.com/new/1": .html(html(["一"])), "example.com/new/2": .status(500)])
        let model = ModuleListModel(route: route, library: f.library, client: f.client)
        await model.load()
        await model.loadMore()
        #expect(titles(model) == ["一"])
        #expect(model.loadMoreError != nil)
        #expect(model.canLoadMore, "載入更多 tries the same page again")
    }

    @Test("a module removed meanwhile, or a list it no longer has, says so")
    func missing() async throws {
        let f = try await makeFixture(installed: false)
        defer { try? FileManager.default.removeItem(at: f.folder) }
        let model = ModuleListModel(route: route, library: f.library, client: f.client)
        await model.load()
        #expect(model.state == .missing)

        let g = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: g.folder) }
        let gone = ModuleListModel(route: ModuleListRoute(moduleID: "m.list", entryID: "gone", title: "", parameters: [:]),
                                   library: g.library, client: g.client)
        await gone.load()
        #expect(gone.state == .missing)
    }

    @Test("查看全部 of a module row opens its list with the section's values")
    func showAll() {
        let section = HomeSection(layout: .row, title: "新書", binding: .module(moduleID: "m.list", entryID: "new"),
                                  parameters: ["sort": "new"])
        let row = HomeModel.Row(id: "r", section: section, source: SourceInstanceKey(type: .module, id: "m.list"),
                                sourceName: "清單模組", policy: .parallel, state: .idle, inputsKey: nil)
        #expect(ExplorePlace.showAll(row, aozoraIndex: nil) == .explore(.moduleList(route)))
    }
}
