import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-4: 首頁配置, and the custom pages moving into them (Phase 5 plan,
/// decisions 12, 14 and 22).
@MainActor
@Suite("Home configurations")
struct HomeConfigurationTests {
    private let hot = ExploreCategoryReference(sourceURL: "https://a.test", title: "熱門", url: "/hot")
    private let new = ExploreCategoryReference(sourceURL: "https://a.test", title: "新書", url: "/new")
    private let other = ExploreCategoryReference(sourceURL: "https://b.test", title: "完本", url: "/end")

    private struct Folder {
        let url: URL
        let defaults: UserDefaults
        let suite: String
        var home: URL { url.appendingPathComponent("explore_home.json") }
        var pages: URL { url.appendingPathComponent("custom_explore_pages.json") }

        @MainActor func store() -> HomePageStore { HomePageStore(fileURL: home, defaults: defaults) }

        func cleanup() {
            try? FileManager.default.removeItem(at: url)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    private func makeFolder() throws -> Folder {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-configurations-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let suite = "HomeConfigurationTests-\(UUID().uuidString)"
        return Folder(url: url, defaults: UserDefaults(suiteName: suite)!, suite: suite)
    }

    private let oldHome = """
    {"schemaVersion":1,"sections":[
      {"id":"6B1C9C7E-6F2B-4C77-9E33-0D7F1B0E8A11","layout":"compactReadingCard","binding":{"type":"continueReading"}},
      {"id":"6B1C9C7E-6F2B-4C77-9E33-0D7F1B0E8A12","layout":"row","binding":{"type":"latest"}}
    ]}
    """

    private func page(_ name: String, _ components: [CustomExploreComponent]) -> CustomExplorePage {
        CustomExplorePage(name: name, components: components)
    }

    private func sectionIDs(_ store: HomePageStore) -> [UUID] {
        store.page?.sections.map(\.id) ?? []
    }

    // MARK: Mapping

    @Test("each custom-page kind becomes decision 14's layout; 多分類排行榜 becomes one ranked list per category")
    func mapping() {
        func layouts(_ kind: CustomExploreComponent.Kind, _ categories: [ExploreCategoryReference]) -> [HomeSectionLayout] {
            HomeSection.migrating(CustomExploreComponent(kind: kind, categories: categories), page: "p").map(\.layout)
        }
        #expect(layouts(.featuredCards, [hot]) == [.row])
        #expect(layouts(.carousel, [hot]) == [.row])
        #expect(layouts(.grid, [hot]) == [.multiRow])
        #expect(layouts(.ranking, [hot]) == [.rankedList])
        #expect(layouts(.pagedRanking, [hot]) == [.rankedList])
        #expect(layouts(.waterfall, [hot]) == [.coverGrid])

        let ranking = CustomExploreComponent(kind: .multiCategoryRanking, title: "榜", categories: [hot, new])
        let split = HomeSection.migrating(ranking, page: "p")
        #expect(split.map(\.layout) == [.rankedList, .rankedList])
        #expect(split.map(\.binding) == [.sourceCategories([hot]), .sourceCategories([new])])
        #expect(split.allSatisfy { $0.title.isEmpty && $0.id != ranking.id }, "each titled by its category, under its own id")

        let single = CustomExploreComponent(kind: .ranking, title: "熱門榜", categories: [hot])
        let kept = HomeSection.migrating(single, page: "p")
        #expect(kept.map(\.id) == [single.id])
        #expect(kept.map(\.title) == ["熱門榜"])

        #expect(layouts(.multiCategoryRanking, [hot]).isEmpty, "too few categories")
        #expect(layouts(.ranking, []).isEmpty)
        #expect(layouts(.grid, [hot, other]).isEmpty, "several sources")
    }

    // MARK: Moving the custom pages in

    @Test("a home from before 5d-4 becomes 預設, the pages become 首頁配置, and the old 首屏 page is selected")
    func movesFromOldHome() throws {
        let folder = try makeFolder()
        defer { folder.cleanup() }
        try Data(oldHome.utf8).write(to: folder.home)
        let weekend = page("週末", [CustomExploreComponent(kind: .grid, categories: [hot])])
        let charts = page("榜單", [CustomExploreComponent(kind: .multiCategoryRanking, categories: [hot, new])])
        let pagesData = try JSONEncoder().encode([weekend, charts])
        try pagesData.write(to: folder.pages)
        folder.defaults.set("page:" + charts.id.uuidString, forKey: ExploreSettings.legacyLandingKey)

        let store = folder.store()
        store.waitForPendingWritesForTesting()
        #expect(store.configurations.map(\.name) == [localized("預設"), "週末", "榜單"])
        #expect(store.selectedConfiguration == HomeConfigurationID(charts.id))
        #expect(store.page?.sections.map(\.layout) == [.rankedList, .rankedList])
        #expect(folder.defaults.string(forKey: ExploreSettings.legacyLandingKey) == nil)
        #expect(try Data(contentsOf: folder.pages) == pagesData, "the pages file is left for older builds")

        // Written as schema 2, 預設 under the key an older build reads.
        let written = try Data(contentsOf: folder.home)
        #expect(String(decoding: written, as: UTF8.self).contains("\"schemaVersion\":2"))
        #expect(try JSONDecoder().decode(HomePage.self, from: written).sections.map(\.binding) == [.continueReading, .latest])

        store.select(.defaults)
        #expect(store.page?.sections.map(\.binding) == [.continueReading, .latest])
    }

    @Test("the pages move once: a configuration deleted stays deleted")
    func movesOnce() throws {
        let folder = try makeFolder()
        defer { folder.cleanup() }
        try Data(oldHome.utf8).write(to: folder.home)
        let weekend = page("週末", [CustomExploreComponent(kind: .carousel, categories: [hot])])
        try JSONEncoder().encode([weekend]).write(to: folder.pages)

        let store = folder.store()
        store.deleteConfiguration(HomeConfigurationID(weekend.id))
        store.waitForPendingWritesForTesting()
        #expect(folder.store().configurations.map(\.name) == [localized("預設")])
    }

    @Test("a pages file that cannot be read moves in on a later launch, and the old 首屏 waits for it")
    func unreadablePagesWait() throws {
        let folder = try makeFolder()
        defer { folder.cleanup() }
        try Data(oldHome.utf8).write(to: folder.home)
        try Data("{not json".utf8).write(to: folder.pages)
        let weekend = page("週末", [CustomExploreComponent(kind: .carousel, categories: [hot])])
        folder.defaults.set("page:" + weekend.id.uuidString, forKey: ExploreSettings.legacyLandingKey)

        let first = folder.store()
        first.waitForPendingWritesForTesting()
        #expect(first.configurations.count == 1)
        #expect(first.page?.sections.map(\.binding) == [.continueReading, .latest], "the home itself still reads")
        #expect(folder.defaults.string(forKey: ExploreSettings.legacyLandingKey) != nil)

        try JSONEncoder().encode([weekend]).write(to: folder.pages)
        let later = folder.store()
        later.waitForPendingWritesForTesting()
        #expect(later.configurations.map(\.name).last == "週末")
        #expect(later.selectedConfiguration == HomeConfigurationID(weekend.id))
        #expect(folder.defaults.string(forKey: ExploreSettings.legacyLandingKey) == nil)
    }

    @Test("a first home is made with the pages beside it")
    func movesIntoFirstHome() throws {
        let folder = try makeFolder()
        defer { folder.cleanup() }
        let weekend = page("週末", [CustomExploreComponent(kind: .waterfall, categories: [hot])])
        try JSONEncoder().encode([weekend]).write(to: folder.pages)

        let store = folder.store()
        #expect(store.home == nil, "nothing is made before the home first reads it")
        let defaults = store.pageOrDefaults(mode: .publicLibraries, publicLibrariesAvailable: true, languages: [])
        #expect(defaults == HomePageDefaults.page(mode: .publicLibraries, publicLibrariesAvailable: true, languages: [],
                                                  makeID: { UUID() }).withIDs(of: defaults))
        #expect(store.configurations.map(\.name).last == "週末")
        store.select(HomeConfigurationID(weekend.id))
        #expect(store.page?.sections.map(\.layout) == [.coverGrid])
    }

    @Test("a newer build's file moves nothing")
    func newerBuildMovesNothing() throws {
        let folder = try makeFolder()
        defer { folder.cleanup() }
        let json = """
        {"schemaVersion":\(HomePage.currentSchemaVersion + 1),"sections":[
          {"id":"6B1C9C7E-6F2B-4C77-9E33-0D7F1B0E8A11","layout":"row","binding":{"type":"continueReading"}}
        ]}
        """
        try Data(json.utf8).write(to: folder.home)
        try JSONEncoder().encode([page("週末", [])]).write(to: folder.pages)
        let store = folder.store()
        #expect(store.isReadOnly)
        #expect(store.configurations.count == 1)
        store.waitForPendingWritesForTesting()
        #expect(try Data(contentsOf: folder.home) == Data(json.utf8))
    }

    // MARK: Using them

    @Test("新增首頁配置 starts from its template's sections, goes last and is selected")
    func create() throws {
        var home = HomeConfigurations(sections: [HomeSection(layout: .row, binding: .continueReading)])
        let evening = home.create(named: " 晚上 ", sections: [HomeSection(layout: .row, binding: .latest)])
        #expect(home.selectedID == evening)
        #expect(home.sections(of: evening).map(\.binding) == [.latest])
        #expect(home.sections.map(\.binding) == [.continueReading])

        let again = home.create(named: "晚上", sections: [])
        #expect(home.sections(of: again).isEmpty)
        #expect(home.listings.map(\.name) == [localized("預設"), "晚上", "晚上 2"])
        let unnamed = home.create(named: "  ", sections: [])
        #expect(home.listings.first { $0.id == unnamed }?.name == localized("首頁配置"))
    }

    @Test("預設配置 is the app's defaults even once 預設 is emptied; 空白模板 has no section")
    func templates() throws {
        let folder = try makeFolder()
        defer { folder.cleanup() }
        let store = folder.store()
        _ = store.pageOrDefaults(mode: .publicLibraries, publicLibrariesAvailable: true, languages: ["zh"])
        // The maintainer's case (2026-10-23): every section of 預設 deleted, then 預設配置.
        store.edit { $0.sections.removeAll() }
        #expect(store.page?.sections.isEmpty == true)

        let context = HomePageDefaults.Context(mode: .publicLibraries, publicLibrariesAvailable: true, languages: ["zh"])
        store.createConfiguration(named: "週末", from: .defaults, defaults: context)
        let made = try #require(store.page?.sections)
        #expect(made.map(\.binding) == HomePageDefaults.page(for: context).sections.map(\.binding))
        #expect(made.contains { if case .module = $0.binding { true } else { false } }, "the official modules' lists too")
        #expect(store.home?.sections(of: .defaults).isEmpty == true, "預設 stays as the reader left it")

        store.createConfiguration(named: "自己排", from: .blank, defaults: context)
        #expect(store.page?.sections.isEmpty == true)
        #expect(store.configurations.map(\.name) == [localized("預設"), "週末", "自己排"])
    }

    @Test("edits act on the selected configuration; 預設 is not renamed or deleted")
    func editsSelected() throws {
        let folder = try makeFolder()
        defer { folder.cleanup() }
        let store = folder.store()
        _ = store.pageOrDefaults(mode: .publicLibraries, publicLibrariesAvailable: false, languages: [])
        let defaultIDs = sectionIDs(store)

        store.createConfiguration(named: "週末", from: .defaults,
                                  defaults: HomePageDefaults.Context(mode: .publicLibraries, publicLibrariesAvailable: false,
                                                                     languages: []))
        let weekend = store.selectedConfiguration
        #expect(weekend != .defaults)
        #expect(store.page?.sections.map(\.binding) == store.home?.sections.map(\.binding))
        store.addCategory(hot, to: weekend)
        #expect(store.page?.sections.last?.binding == .sourceCategories([hot]))
        #expect(store.contains(hot, in: weekend))
        #expect(!store.contains(hot, in: .defaults))
        store.edit { $0.setLayout(.coverGrid, section: $0.sections[$0.sections.count - 1].id) }
        store.select(.defaults)
        #expect(sectionIDs(store) == defaultIDs)

        store.renameConfiguration(.defaults, to: "x")
        store.deleteConfiguration(.defaults)
        store.renameConfiguration(weekend, to: "假日")
        store.select(weekend)
        store.waitForPendingWritesForTesting()

        let reread = folder.store()
        #expect(reread.configurations.map(\.name) == [localized("預設"), "假日"])
        #expect(reread.selectedConfiguration == weekend)
        #expect(reread.page?.sections.last?.layout == .coverGrid)

        reread.deleteConfiguration(weekend)
        #expect(reread.selectedConfiguration == .defaults)
        #expect(sectionIDs(reread) == defaultIDs)
    }

    @Test("首頁配置's 編輯 moves 預設 among the reader's own, and the order is kept")
    func move() throws {
        var home = HomeConfigurations(sections: [])
        let a = home.create(named: "A", sections: [])
        let b = home.create(named: "B", sections: [])
        let c = home.create(named: "C", sections: [])
        #expect(home.listings.map(\.id) == [.defaults, a, b, c])

        // `List`'s onMove: 預設 to the end is destination 4, counted before it is taken out.
        home.move(fromOffsets: [0], toOffset: 4)
        #expect(home.listings.map(\.id) == [a, b, c, .defaults])
        home.move(fromOffsets: [3], toOffset: 1)
        #expect(home.listings.map(\.id) == [a, .defaults, b, c])
        home.move(fromOffsets: [2, 3], toOffset: 0)
        #expect(home.listings.map(\.id) == [b, c, a, .defaults])
        // Offsets past the list change nothing.
        home.move(fromOffsets: [5], toOffset: 0)
        home.move(fromOffsets: [0], toOffset: 9)
        #expect(home.listings.map(\.id) == [b, c, a, .defaults])

        // A new one goes last; deleting one before 預設 keeps it after the rest.
        let d = home.create(named: "D", sections: [])
        #expect(home.listings.map(\.id) == [b, c, a, .defaults, d])
        home.delete(b)
        #expect(home.listings.map(\.id) == [c, a, .defaults, d])
        home.delete(d)
        #expect(home.listings.map(\.id) == [c, a, .defaults])

        let reread = try JSONDecoder().decode(HomeConfigurations.self, from: JSONEncoder().encode(home))
        #expect(reread.listings.map(\.id) == [c, a, .defaults])
    }

    // MARK: 空白, built in until 2026-10-23

    private func homeWithBlank(_ blankSections: String) -> String {
        """
        {"schemaVersion":2,"sections":[
          {"id":"6B1C9C7E-6F2B-4C77-9E33-0D7F1B0E8A11","layout":"row","binding":{"type":"continueReading"}}
        ],"configurations":[{"id":"blank","name":"","sections":[\(blankSections)]}],"selected":"blank"}
        """
    }

    @Test("an empty 空白 saved by an older build goes, and 預設 is shown in its place")
    func emptyBlankGoes() throws {
        let folder = try makeFolder()
        defer { folder.cleanup() }
        try Data(homeWithBlank("").utf8).write(to: folder.home)
        let store = folder.store()
        #expect(store.configurations.map(\.id) == [.defaults])
        #expect(store.selectedConfiguration == .defaults)
        #expect(store.page?.sections.map(\.binding) == [.continueReading])
    }

    @Test("a 空白 the reader filled stays, as their own 空白, still shown")
    func filledBlankStays() throws {
        let folder = try makeFolder()
        defer { folder.cleanup() }
        try Data(homeWithBlank("""
          {"id":"0C7E2A55-3F7D-4F0E-8B3A-5D2F6C1B9E22","layout":"coverGrid","binding":{"type":"continueReading"}}
        """).utf8).write(to: folder.home)
        let store = folder.store()
        #expect(store.configurations.map(\.name) == [localized("預設"), localized("空白")])
        #expect(store.selectedConfiguration == .blank)
        #expect(store.page?.sections.map(\.layout) == [.coverGrid])

        // The reader's own now: renamed and deleted like any other.
        store.renameConfiguration(.blank, to: "晚上")
        #expect(store.configurations.map(\.name) == [localized("預設"), "晚上"])
        store.deleteConfiguration(.blank)
        #expect(store.configurations.map(\.id) == [.defaults])
        store.waitForPendingWritesForTesting()
    }
}

private extension HomePage {
    /// `self` with the section ids of `other`, to compare made-up defaults.
    func withIDs(of other: HomePage) -> HomePage {
        var page = self
        for index in page.sections.indices where other.sections.indices.contains(index) {
            page.sections[index].id = other.sections[index].id
        }
        return page
    }
}
