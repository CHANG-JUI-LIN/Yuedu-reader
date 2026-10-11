import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5d-5: the section form's editor (Phase 5 plan, decision 23).
@MainActor
@Suite("Home section editor")
struct HomeSectionEditorTests {
    private let hot = ExploreCategoryReference(sourceURL: "https://a.test", title: "熱門", url: "/hot")

    private func makeStore() throws -> (HomePageStore, () -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("home-section-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let suite = "HomeSectionEditorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = HomePageStore(fileURL: url.appendingPathComponent("explore_home.json"), defaults: defaults)
        store.save(HomePage(sections: [
            HomeSection(layout: .compactReadingCard, binding: .continueReading),
            HomeSection(layout: .row, binding: .latest),
        ]))
        return (store, {
            store.waitForPendingWritesForTesting()
            try? FileManager.default.removeItem(at: url)
            defaults.removePersistentDomain(forName: suite)
        })
    }

    private func preview() -> HomeModel {
        HomeModel(providers: { [] }, waitForSources: {})
    }

    @Test("新增欄目 changes nothing until 新增, which puts the section at the end")
    func addsAtTheEnd() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let before = store.page
        let editor = HomeSectionEditor(newSectionIn: store, layout: .coverGrid, preview: preview())
        #expect(editor.add() == false, "no binding yet")
        #expect(editor.previewPage == nil)

        editor.choose(.sourceCategories([hot]))
        editor.setTitle("熱門書")
        #expect(store.page == before, "the form holds the section until 新增")
        #expect(editor.add())
        let added = try #require(store.page?.sections.last)
        #expect(store.page?.sections.count == 3)
        #expect(added.binding == .sourceCategories([hot]))
        #expect(added.layout == .coverGrid)
        #expect(added.title == "熱門書")
        #expect(added.isEnabled)
    }

    @Test("a section on the home is written back in its place on every change")
    func writesInPlace() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        var latest = try #require(store.page?.sections[1])
        latest.setLatestCategory(hot, forSourceURL: hot.sourceURL)
        store.edit { $0.replaceSection(latest) }
        let editor = HomeSectionEditor(section: latest, store: store, preview: preview())

        editor.setLayout(HomeSectionLayout(style: .list, ranked: true))
        #expect(store.page?.sections[1].layout == .rankedList)
        editor.setEnabled(false)
        #expect(store.page?.sections[1].isEnabled == false)
        #expect(editor.previewPage?.sections.first?.isEnabled == true, "the preview shows a hidden section")

        #expect(store.page?.sections[1].parameters.isEmpty == false)
        editor.choose(.related)
        #expect(store.page?.sections[1].binding == .related)
        #expect(store.page?.sections[1].parameters.isEmpty == true, "the parameters of what it showed go with it")
        #expect(store.page?.sections[1].id == latest.id)

        editor.delete()
        #expect(store.page?.sections.map(\.binding) == [.continueReading])
    }

    @Test("the title follows the choice until the reader names it")
    func titleFollowsTheChoice() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let editor = HomeSectionEditor(newSectionIn: store, layout: .row, preview: preview())

        // A feed cannot name itself: the item's name becomes the title.
        editor.choose(.gutenbergFeed(url: "https://g.test/popular"), itemTitle: "熱門")
        #expect(editor.draft.title == "熱門")
        editor.choose(.gutenbergFeed(url: "https://g.test/new"), itemTitle: "最新上架")
        #expect(editor.draft.title == "最新上架")
        // A category names itself: the title is left empty, to follow it.
        editor.choose(.sourceCategories([hot]), itemTitle: "熱門")
        #expect(editor.draft.title.isEmpty)

        editor.setTitle("我的書單")
        editor.choose(.gutenbergFeed(url: "https://g.test/popular"), itemTitle: "熱門")
        #expect(editor.draft.title == "我的書單", "a title the reader gave stays")
    }

    @Test("最新 keeps one category per book source, in its parameters")
    func latestCategories() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let latest = try #require(store.page?.sections[1])
        let editor = HomeSectionEditor(section: latest, store: store, preview: preview())
        let other = ExploreCategoryReference(sourceURL: "https://b.test", title: "新書", url: "/new")
        let replaced = ExploreCategoryReference(sourceURL: hot.sourceURL, title: "完本", url: "/end")

        editor.setLatestCategory(hot, forSourceURL: hot.sourceURL)
        editor.setLatestCategory(other, forSourceURL: other.sourceURL)
        editor.setLatestCategory(replaced, forSourceURL: hot.sourceURL)
        #expect(editor.latestCategories == [replaced, other])
        #expect(store.page?.sections[1].latestCategory(forSourceURL: hot.sourceURL) == replaced)

        editor.setLatestCategory(nil, forSourceURL: hot.sourceURL)
        #expect(editor.latestCategories == [other])
        #expect(store.page?.sections[1].latestCategory(forSourceURL: hot.sourceURL) == nil)

        editor.setLatestCategory(other, filterValues: ["頻道": "女"], forSourceURL: other.sourceURL)
        #expect(editor.filterValues(forSourceURL: other.sourceURL) == ["頻道": "女"])
        #expect(store.page?.sections[1].filterValues(forSourceURL: other.sourceURL) == ["頻道": "女"])
    }
}

/// Unified library 5d-5: a section's own discover filters (Phase 5 plan, decision 23).
@MainActor
@Suite("Home section filters")
struct HomeSectionFilterTests {
    private let url = "https://g.test"

    /// 光遇's shape: the filters the rule read, and a category whose URL carries them.
    private func items(_ overlay: [String: String]) -> [ModernParserBridge.DiscoverItem] {
        let mode = overlay["发现页类型"] ?? "小说"
        let platform = overlay["发现页来源"] ?? "全部"
        return [
            .init(title: "类型", type: "select", action: "show(infoMap['类型'],'发现页类型')",
                  chars: ["小说", "听书"], default: mode),
            .init(title: "平台", type: "select", action: "show(infoMap['平台'],'发现页来源')",
                  chars: ["全部", "番茄", "七猫"], default: platform),
            .init(title: "热门", url: "https://g.test/hot?m=\(mode)&p=\(platform)"),
        ]
    }

    private func source() -> BookSource {
        var source = BookSource()
        source.bookSourceName = "光遇"
        source.bookSourceUrl = url
        return source
    }

    @Test("the categories list under the section's values, and a new 类型 starts its platform where the source's page would")
    func listsUnderTheSectionsValues() async throws {
        var asked: [[String: String]] = []
        let stored: [String: Any] = ["发现页类型": "小说", "__discoverSourceByMode": ["听书": "七猫"]]
        let listing = SourceCategoryListing(
            source: source(), filterValues: ["发现页类型": "小说", "发现页来源": "番茄"],
            loadItems: { _, overlay in asked.append(overlay); return self.items(overlay) },
            storedVariables: { _ in stored })

        await listing.load()
        #expect(asked == [["发现页类型": "小说", "发现页来源": "番茄"]])
        #expect(listing.filterValues == ["发现页类型": "小说", "发现页来源": "番茄"])
        #expect(listing.groups.flatMap(\.items).map(\.raw.url) == ["https://g.test/hot?m=小说&p=番茄"])

        let mode = try #require(listing.filters.first { $0.paramKey == "发现页类型" })
        await listing.select(mode, value: "听书")
        #expect(asked.last == ["发现页类型": "听书", "发现页来源": "七猫"], "the per-类型 memory, read and not written")
        #expect(listing.groups.flatMap(\.items).map(\.raw.url) == ["https://g.test/hot?m=听书&p=七猫"])

        let platform = try #require(listing.filters.first { $0.paramKey == "发现页来源" })
        await listing.select(platform, value: "全部")
        #expect(asked.last == ["发现页类型": "听书", "发现页来源": "全部"], "the other filter keeps its value")
    }

    @Test("the values are kept by source, the same values as the same parameter")
    func keepsTheValuesBySource() {
        var section = HomeSection(layout: .row, binding: .latest)
        section.setFilterValues(["b": "2", "a": "1"], forSourceURL: url)
        #expect(section.filterValues(forSourceURL: url) == ["a": "1", "b": "2"])
        #expect(section.filterValues(forSourceURL: "https://other.test").isEmpty)
        #expect(HomeSection.filterParameters(["a": "1", "b": "2"], sourceURL: url)
                == HomeSection.filterParameters(["b": "2", "a": "1"], sourceURL: url))

        let hot = ExploreCategoryReference(sourceURL: url, title: "热门", url: "/hot")
        section.setLatestCategory(hot, forSourceURL: url)
        section.setLatestCategory(nil, forSourceURL: url)
        #expect(section.parameters.isEmpty, "a source taken out of 最新 takes its filters with it")
    }
}
