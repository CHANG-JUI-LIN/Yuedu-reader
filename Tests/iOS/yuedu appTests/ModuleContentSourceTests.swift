import Foundation
import Testing
@testable import yuedu_app

/// Phase 6f: an installed module's lists in 選擇內容來源, the section form's parameters, and
/// module rows on the Explore home.
@MainActor
@Suite("Modules in 選擇內容來源", .serialized)
struct ModuleContentSourceTests {
    private func moduleJSON(id: String = "m.one", title: String = "第一模組", version: String = "1.0") -> Data {
        let object: [String: Any] = [
            "id": id, "title": title, "version": version, "hosts": ["example.com"],
            "modules": [[
                "id": "new", "title": "新書",
                "params": [
                    ["name": "q", "title": "關鍵字", "type": "input"],
                    ["name": "n", "title": "數量", "type": "count", "value": 20],
                    ["name": "site", "type": "constant", "value": "tw"],
                    ["name": "sort", "title": "排序", "type": "enumeration",
                     "enumOptions": [["title": "熱門", "value": "hot"], ["title": "最新", "value": "new"]]],
                    ["name": "page", "type": "page"],
                ],
                "request": ["url": "https://example.com/new?q={{q}}&n={{n}}&site={{site}}&sort={{sort}}&p={{page}}"],
                "list": ["items": "li", "title": "h3@text"],
            ], [
                "id": "top", "title": "排行",
                "request": ["url": "https://example.com/top"],
                "list": ["items": "li", "title": "h3@text"],
            ]],
            "search": [
                "title": "搜尋",
                "request": ["url": "https://example.com/s?k={{keyword}}"],
                "list": ["items": "li", "title": "h3@text"],
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: object)
    }

    private func makeLibrary() -> (RuleModuleLibrary, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModuleContentSource-\(UUID().uuidString)")
        return (RuleModuleLibrary(store: RuleModuleStore(directory: folder), appVersion: "2.0.8", officialFiles: { [] }), folder)
    }

    private func makeStore() -> (HomePageStore, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("module-content-source-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let suite = "ModuleContentSourceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = HomePageStore(fileURL: url.appendingPathComponent("explore_home.json"), defaults: defaults)
        store.save(HomePage(sections: [HomeSection(layout: .row, binding: .latest)]))
        return (store, {
            store.waitForPendingWritesForTesting()
            try? FileManager.default.removeItem(at: url)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    @Test("a module's list is the module's, named by its title; a removed module by its id")
    func owner() async throws {
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await library.install(moduleJSON(), from: nil)

        #expect(HomeSectionBinding.module(moduleID: "m.one", entryID: "new").contentOwner == .module(id: "m.one"))
        #expect(HomeContentOwner.module(id: "m.one").name(sources: .shared, connections: .shared, modules: library) == "第一模組")
        #expect(HomeContentOwner.module(id: "gone").name(sources: .shared, connections: .shared, modules: library) == "gone")
    }

    @Test("選擇內容來源 lists a module's lists, never its search")
    func choices() async throws {
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let module = try await library.install(moduleJSON(), from: nil).module

        let choices = HomeContentChoice.lists(of: module)
        #expect(choices.map(\.binding) == [.module(moduleID: "m.one", entryID: "new"), .module(moduleID: "m.one", entryID: "top")])
        #expect(choices.map(\.itemTitle) == ["新書", "排行"], "the list's name becomes the section's title")
    }

    @Test("the form offers input, count and enumeration; each shows its value before one is set")
    func editableParameters() async throws {
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let entry = try #require(try await library.install(moduleJSON(), from: nil).module.modules.first)

        #expect(entry.editableParams.map(\.name) == ["q", "n", "sort"], "not constant, page or offset")
        let byName = Dictionary(uniqueKeysWithValues: entry.params.map { ($0.name, $0) })
        #expect(try #require(byName["n"]).currentValue(in: [:], language: "ja") == "20")
        #expect(try #require(byName["sort"]).currentValue(in: [:], language: "ja") == "hot",
                "an enumeration's first option; one that does not follow the language ignores it")
        #expect(try #require(byName["sort"]).currentValue(in: ["sort": "new"], language: nil) == "new")
        #expect(try #require(byName["q"]).currentValue(in: [:], language: nil) == "")
        #expect(entry.values(["sort": "new"], position: 3, language: nil)
                == ["q": "", "n": "20", "site": "tw", "sort": "new", "page": "3"],
                "the request is filled from the same values")
    }

    @Test("a choice that follows 中繼資料語言偏好推薦 starts on that language's option, else its default")
    func followsLanguage() {
        let region = RuleModule.Param(name: "region", type: "enumeration", value: "en", enumOptions: [
            .init(title: "華語（繁）", value: "zh-Hant"), .init(title: "華語（簡）", value: "zh-Hans"),
            .init(title: "日本", value: "jp", language: "ja"), .init(title: "英語", value: "en"),
        ], followsLanguage: true)
        #expect(region.currentValue(in: [:], language: "zh-Hans") == "zh-Hans")
        #expect(region.currentValue(in: [:], language: "zh-Hant") == "zh-Hant")
        #expect(region.currentValue(in: [:], language: "ja") == "jp", "an option's language over its value")
        #expect(region.currentValue(in: [:], language: "ko") == "en", "no Korean list: the default")
        #expect(region.currentValue(in: ["region": "jp"], language: "en") == "jp", "the reader's pick stays")
        #expect(region.currentValue(in: [:], language: nil) == "en")

        let simplifiedOnly = RuleModule.Param(name: "region", type: "enumeration", enumOptions: [
            .init(title: "English", value: "en"), .init(title: "简体", value: "zh-Hans"),
        ], followsLanguage: true)
        #expect(simplifiedOnly.currentValue(in: [:], language: "zh-Hant") == "zh-Hans", "the language in another script")
        #expect(simplifiedOnly.currentValue(in: [:], language: "fr") == "en", "no default: the first option")
    }

    @MainActor private final class Language {
        var tag: String
        init(_ tag: String) { self.tag = tag }
    }

    @Test("a row whose 地區 follows 中繼資料語言偏好推薦 loads again when the language changes; a picked 地區 does not")
    func rowsFollowTheLanguage() async throws {
        let module = try RuleModuleValidator.validate(Data("""
        {"id":"m.region","title":"地區模組","version":"1.0","requiredVersion":"3.0","hosts":["example.com"],
         "modules":[{"id":"top","title":"熱門","request":{"url":"https://example.com/{{region}}.json"},
                     "list":{"items":"$.works[*]","title":"$.title"},
                     "params":[{"name":"region","type":"enumeration","followsLanguage":true,"value":"en",
                                "enumOptions":[{"title":"日本","value":"ja"},{"title":"英語","value":"en"}]}]}]}
        """.utf8), appVersion: RuleModuleVersion.app)
        let language = Language("ja")
        let provider = ModuleProvider(module: module, language: { language.tag })
        let home = HomeModel(providers: { [provider] }, waitForSources: {})
        let following = HomeSection(layout: .row, binding: .module(moduleID: "m.region", entryID: "top"))
        var picked = HomeSection(layout: .row, binding: .module(moduleID: "m.region", entryID: "top"))
        picked.parameters = ["region": "ja"]
        let page = HomePage(sections: [following, picked])

        await home.sync(with: page)
        let before = home.rows.map(\.inputsKey)
        language.tag = "en"
        await home.sync(with: page)
        let after = home.rows.map(\.inputsKey)
        #expect(home.rows.count == 2)
        #expect(before[0] != after[0], "the followed 地區 is now 英語's: the row is a new row")
        #expect(after[0]?.hasSuffix("region=en") == true)
        #expect(before[1] == after[1], "the reader's own 地區 is not the language's")
    }

    @Test("a chosen list titles the section; its parameters are written with it and cleared to the default")
    func editorRoundTrip() async throws {
        let (store, cleanup) = makeStore()
        defer { cleanup() }
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let module = try await library.install(moduleJSON(), from: nil).module
        let choice = try #require(HomeContentChoice.lists(of: module).first)

        let editor = HomeSectionEditor(newSectionIn: store, layout: .row, preview: HomeModel(providers: { [] }, waitForSources: {}))
        editor.choose(choice.binding, parameters: choice.parameters, itemTitle: choice.itemTitle)
        editor.setParameter("sort", to: "new")
        editor.setParameter("q", to: "龍")
        #expect(editor.add())
        let added = try #require(store.page?.sections.last)
        #expect(added.binding == .module(moduleID: "m.one", entryID: "new"))
        #expect(added.title == "新書")
        #expect(added.parameters == ["sort": "new", "q": "龍"])

        let existing = HomeSectionEditor(section: added, store: store, preview: HomeModel(providers: { [] }, waitForSources: {}))
        existing.setParameter("q", to: nil)
        #expect(store.page?.sections.last?.parameters == ["sort": "new"], "written back in place")

        let decoded = try JSONDecoder().decode(HomeSection.self, from: JSONEncoder().encode(added))
        #expect(decoded == added)
    }

    @Test("the home serves a module's sections while it is installed; once removed, the section has no row")
    func rowsFollowTheLibrary() async throws {
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        try await library.install(moduleJSON(), from: nil)

        let providers = SourceProviderRegistry.moduleProviders(in: library)
        #expect(providers.map(\.instance) == [SourceInstanceKey(type: .module, id: "m.one")])

        let home = HomeModel(providers: { SourceProviderRegistry.moduleProviders(in: library) }, waitForSources: {})
        let page = HomePage(sections: [HomeSection(layout: .row, binding: .module(moduleID: "m.one", entryID: "new"))])
        await home.sync(with: page)
        #expect(home.rows.map(\.source) == [SourceInstanceKey(type: .module, id: "m.one")])
        // Named by the list, not the module: the home names no source (decision 19, 6f274457).
        #expect(home.rows.first?.sourceName == "新書")

        try await library.remove(id: "m.one")
        await home.sync(with: page)
        #expect(home.rows.isEmpty, "as for a removed connection: nothing serves the section")
    }

    @Test("an update restarts the module's rows: their inputs carry its version")
    func inputsFollowTheVersion() async throws {
        let (library, folder) = makeLibrary()
        defer { try? FileManager.default.removeItem(at: folder) }
        let one = try await library.install(moduleJSON(version: "1.0"), from: nil).module
        let two = try await library.update(id: "m.one", with: moduleJSON(version: "1.1")).module
        let section = HomeSection(layout: .row, binding: .module(moduleID: "m.one", entryID: "new"))
        #expect(ModuleProvider(module: one).inputsKey(for: section) != ModuleProvider(module: two).inputsKey(for: section))
    }
}
