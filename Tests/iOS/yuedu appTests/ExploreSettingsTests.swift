import Foundation
import Testing
@testable import yuedu_app

struct ExploreSettingsTests {
    @Test("a category is a chart when its title holds any keyword, whatever the letter case")
    func sectionStyleFollowsKeywords() {
        let defaults = ExploreSettings.defaultRankedKeywords
        #expect(DiscoverViewModel.sectionStyle(for: "月票榜", rankedKeywords: defaults) == .ranked)
        #expect(DiscoverViewModel.sectionStyle(for: "TOP 50", rankedKeywords: defaults) == .ranked)
        #expect(DiscoverViewModel.sectionStyle(for: "精选推荐", rankedKeywords: defaults) == .featured)
        // An edited list decides on its own.
        #expect(DiscoverViewModel.sectionStyle(for: "精选推荐", rankedKeywords: ["推荐"]) == .ranked)
        #expect(DiscoverViewModel.sectionStyle(for: "月票榜", rankedKeywords: []) == .featured)
    }

    @Test("a section prefetches only the covers it shows before a swipe, not its whole page")
    func coverPrefetchStaysOnTheFirstScreen() {
        // A shelf's first screen, iPad included; a chart, its 豎排展示數 (unset: the default).
        #expect(DiscoverViewModel.firstScreenCoverCount(for: .featured) == 8)
        let stored = UserDefaults.standard.object(forKey: ExploreSettings.chartBookCountKey)
        defer { UserDefaults.standard.set(stored, forKey: ExploreSettings.chartBookCountKey) }
        UserDefaults.standard.removeObject(forKey: ExploreSettings.chartBookCountKey)
        #expect(DiscoverViewModel.firstScreenCoverCount(for: .ranked) == ExploreSettings.defaultChartBookCount)
        UserDefaults.standard.set(6, forKey: ExploreSettings.chartBookCountKey)
        #expect(DiscoverViewModel.firstScreenCoverCount(for: .ranked) == 6)
    }

    @Test("chart keywords are stored one per line, blank lines dropped")
    func keywordsRoundTrip() {
        let keywords = ["榜", "排行", "top"]
        #expect(ExploreSettings.decodeKeywords(ExploreSettings.encodeKeywords(keywords)) == keywords)
        #expect(ExploreSettings.decodeKeywords("榜\n\n热门\n") == ["榜", "热门"])
        #expect(ExploreSettings.decodeKeywords("").isEmpty)
    }

    @Test("the discover page's settings and 封面並發數 read the keys 探索設定 stored before 5d-1b")
    func settingsKeepTheirOldKeys() {
        #expect(ExploreSettings.sourcePageLayoutKey == "explore.sourcePageLayout")
        #expect(ExploreSettings.rankedKeywordsKey == "explore.rankedKeywords")
        #expect(ExploreSettings.chartBookCountKey == "explore.chartBookCount")
        #expect(ExploreSettings.shelfBookCountKey == "explore.shelfBookCount")
        #expect(ExploreSettings.preloadCountKey == "explore.preloadCount")
        #expect(BookCoverLoader.downloadLimitKey == "coverDownloadLimit")
        #expect(ExploreSourcePageLayout(rawValue: "list") == .list)
        #expect(ExploreSourcePageLayout(rawValue: "magazine") == .magazine)
    }

    @Test("the cover gate holds a download past the limit until one finishes")
    func coverGateQueuesPastTheLimit() async {
        let gate = CoverDownloadGate()
        await gate.enter(limit: 2)
        await gate.enter(limit: 2)
        let third = Task { await gate.enter(limit: 2) }
        while await gate.waitingCount == 0 { await Task.yield() }
        #expect(await gate.runningCount == 2)

        await gate.leave()
        await third.value
        #expect(await gate.waitingCount == 0)
        #expect(await gate.runningCount == 2)
    }

    @Test("with no limit every cover download goes straight through")
    func coverGateWithoutLimit() async {
        let gate = CoverDownloadGate()
        for _ in 0..<5 { await gate.enter(limit: 0) }
        #expect(await gate.runningCount == 5)
        #expect(await gate.waitingCount == 0)
    }

    @Test("a saved 首屏 source becomes 範圍 once; a page waits for configurations; anything else goes")
    func legacyLandingMigrates() throws {
        let suite = "ExploreSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = ExploreSettings.legacyLandingKey

        defaults.set("source:https://fanqienovel.com", forKey: key)
        ExploreSettings.migrateLegacyLanding(sourceURLs: ["https://fanqienovel.com"], defaults: defaults)
        #expect(defaults.string(forKey: ExploreSettings.scopeKey) == "bookSource:https://fanqienovel.com")
        #expect(defaults.object(forKey: key) == nil)

        // A scope the reader chose wins; a deleted source is dropped.
        defaults.set("gutenberg:builtin.gutenberg", forKey: ExploreSettings.scopeKey)
        defaults.set("source:https://fanqienovel.com", forKey: key)
        ExploreSettings.migrateLegacyLanding(sourceURLs: ["https://fanqienovel.com"], defaults: defaults)
        #expect(defaults.string(forKey: ExploreSettings.scopeKey) == "gutenberg:builtin.gutenberg")
        #expect(defaults.object(forKey: key) == nil)
        defaults.removeObject(forKey: ExploreSettings.scopeKey)
        defaults.set("source:https://gone.example", forKey: key)
        ExploreSettings.migrateLegacyLanding(sourceURLs: [], defaults: defaults)
        #expect(defaults.object(forKey: ExploreSettings.scopeKey) == nil)
        #expect(defaults.object(forKey: key) == nil)

        let page = "page:" + UUID().uuidString
        defaults.set(page, forKey: key)
        ExploreSettings.migrateLegacyLanding(sourceURLs: [], defaults: defaults)
        #expect(defaults.string(forKey: key) == page, "kept for 5d-4's configurations")
    }

    /// A source's explore list: two groups of categories with a filter and a page link
    /// among them, and one category the source lists twice.
    private static let discoverRaw: [ModernParserBridge.DiscoverItem] = [
        .init(title: "🟥 排行榜 🟥"),
        .init(title: "月票榜", url: "/rank/month"),
        .init(title: "畅销榜", url: "/rank/sales"),
        .init(title: "频道", type: "select", action: "频道", chars: ["男频", "女频"], default: "男频"),
        .init(title: "分類"),
        .init(title: "月票榜", url: "/rank/month"),
        .init(title: "玄幻", url: "/tag/fantasy"),
        .init(title: "官网", url: "@js:java.startBrowser(\"https://example.com\", \"官网\")"),
    ]

    @Test("發現頁設定 lists each category once, under the labels the source draws before them")
    func discoverCategoryGroups() {
        let groups = DiscoverViewModel.categoryGroups(from: Self.discoverRaw, defaultTitle: "分類")
        #expect(groups.map(\.title) == ["🟥 排行榜 🟥", "分類"])
        #expect(groups.map { $0.items.map(\.title) } == [["月票榜", "畅销榜"], ["玄幻"]])

        // A label that is only a drawn line names no group.
        let separated = DiscoverViewModel.categoryGroups(
            from: [.init(title: "━━━━━━"), .init(title: "推荐", url: "/recommend")],
            defaultTitle: "分類"
        )
        #expect(separated.map(\.title) == ["分類"])
    }

    @MainActor
    @Test("picked categories are the only ones shown, until none is picked")
    func discoverCategorySelection() throws {
        var source = BookSource()
        source.bookSourceName = "發現頁設定測試"
        source.bookSourceUrl = "https://discover-settings.test"
        let storageKey = DiscoverViewModel.categorySelectionKey(sourceURL: source.bookSourceUrl)
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }

        let discover = DiscoverViewModel(source: source)
        discover.items = Self.discoverRaw.compactMap(DiscoverViewModel.mapItem)
        let month = try #require(discover.items.first { $0.title == "月票榜" })
        let sales = try #require(discover.items.first { $0.title == "畅销榜" })
        #expect(discover.isCategoryShown(month) && !discover.isCategorySelected(month))
        #expect(!discover.hasCustomCategorySelection)

        discover.toggleCategorySelection(month)
        #expect(discover.isCategorySelected(month))
        #expect(!discover.isCategoryShown(sales))
        #expect(discover.sections.map(\.item.title) == ["月票榜"])
        // Another visit to the source's page keeps the pick.
        #expect(DiscoverViewModel(source: source).isCategorySelected(month))

        // Picking another keeps the section already there, books and all.
        let monthID = try #require(discover.sections.first?.id)
        discover.toggleCategorySelection(sales)
        #expect(discover.sections.map(\.item.title) == ["月票榜", "畅销榜"])
        #expect(discover.sections.first?.id == monthID)

        // Unpicking the last one shows every category again.
        discover.toggleCategorySelection(month)
        discover.toggleCategorySelection(sales)
        #expect(!discover.hasCustomCategorySelection)
        #expect(UserDefaults.standard.object(forKey: storageKey) == nil)
        #expect(discover.sections.map(\.item.title) == ["月票榜", "畅销榜", "玄幻"])
    }

    /// Follow-up 3 of the Phase 5 plan: the pick is the source's, keyed by its address, so
    /// it survives the source being imported again (a new device-local id).
    @MainActor
    @Test("a pick survives the source being imported again")
    func categorySelectionSurvivesReimport() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://discover-reimport.test"
        let storageKey = DiscoverViewModel.categorySelectionKey(sourceURL: source.bookSourceUrl)
        defer { UserDefaults.standard.removeObject(forKey: storageKey) }

        let discover = DiscoverViewModel(source: source)
        discover.items = Self.discoverRaw.compactMap(DiscoverViewModel.mapItem)
        let month = try #require(discover.items.first { $0.title == "月票榜" })
        discover.toggleCategorySelection(month)

        var reimported = source
        reimported.id = UUID()
        #expect(DiscoverViewModel(source: reimported).isCategorySelected(month))
    }

    /// A pick made before the change, under the source's old id, is read and kept where it was.
    @MainActor
    @Test("a pick stored under the old id is read, and the old value stays")
    func categorySelectionReadsTheOldKey() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://discover-old-key.test"
        let oldKey = "discover.categorySelection." + source.id.uuidString
        let storageKey = DiscoverViewModel.categorySelectionKey(sourceURL: source.bookSourceUrl)
        defer {
            UserDefaults.standard.removeObject(forKey: oldKey)
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
        let items = Self.discoverRaw.compactMap(DiscoverViewModel.mapItem)
        let month = try #require(items.first { $0.title == "月票榜" })
        UserDefaults.standard.set([month.stableKey], forKey: oldKey)

        let discover = DiscoverViewModel(source: source)
        #expect(discover.isCategorySelected(month))
        #expect(UserDefaults.standard.stringArray(forKey: storageKey) == [month.stableKey])
        #expect(UserDefaults.standard.stringArray(forKey: oldKey) == [month.stableKey])

        // 全部顯示 clears the pick wherever it was stored, so the old one does not come back.
        discover.items = items
        discover.showAllCategories()
        #expect(UserDefaults.standard.object(forKey: storageKey) == nil)
        #expect(UserDefaults.standard.object(forKey: oldKey) == nil)
        #expect(!DiscoverViewModel(source: source).hasCustomCategorySelection)
    }

    @Test("explore buttons, inputs and toggles become controls; a button without an action runs its url")
    func discoverQuickActions() throws {
        let raw: [ModernParserBridge.DiscoverItem] = [
            .init(title: "登录", type: "button", action: "java.toast('hi')"),
            .init(title: "旧按钮", url: "@js:java.toast('old')", type: "button"),
            .init(title: "搜索关键词", type: "text", action: "java.refreshExplore()", viewName: "'关键词'"),
            .init(title: "排序", style: ["layout_justifySelf": "right"], type: "toggle", chars: ["热度", "最新"], default: "最新"),
            .init(title: "玄幻", url: "/tag/fantasy"),
            .init(title: "登录", type: "button", action: "java.toast('hi')"),
        ]
        let actions = DiscoverQuickAction.actions(from: raw)
        #expect(actions.map(\.title) == ["登录", "旧按钮", "搜索关键词", "排序"])
        #expect(actions[1].script == "java.toast('old')")
        #expect(actions[2].literalDisplayName == "关键词")
        #expect(actions[2].displayNameScript == nil)
        let toggle = actions[3]
        #expect(toggle.valueTrails)
        #expect(toggle.toggleValue(in: [:]) == "最新")
        #expect(toggle.toggleValue(in: ["排序": "热度"]) == "热度")
        #expect(toggle.toggleValue(after: "最新") == "热度")
    }

    @Test("a 發現頁設定 chip whose name does not fit one column takes two rather than wrapping, in its place")
    func discoverChipGridSpansLongNames() {
        // 快捷操作 on a 440pt phone: 376pt inside the card, four 88pt columns.
        let grid = DiscoverChipGrid(width: 376, minimumColumnWidth: 72, spacing: 8)
        #expect(grid.columns == 4)
        #expect(grid.columnWidth == 88)
        // 全部顯示, 搜索书名或作者, 🔍搜索, 更新配置, 更新书源, 书源设置, 登录番茄 ↗
        let slots = grid.slots(oneLineWidths: [72, 121, 64, 76, 76, 76, 90])
        #expect(slots.map(\.span) == [1, 2, 1, 1, 1, 1, 2])
        #expect(slots.map(\.row) == [0, 0, 0, 1, 1, 1, 2])
        #expect(slots.map(\.column) == [0, 1, 3, 0, 1, 2, 0])
        #expect(grid.width(of: slots[1]) == 184)
        #expect(grid.x(of: slots[2]) == 288)
        // A name exactly one column wide stays in one; past two it takes three; past the
        // row it takes the row.
        #expect(grid.slots(oneLineWidths: [88]).map(\.span) == [1])
        #expect(grid.slots(oneLineWidths: [185]).map(\.span) == [3])
        #expect(grid.slots(oneLineWidths: [500]).map(\.span) == [4])
    }

    @Test("the explore infoMap a source's script saves is there in its next session")
    func exploreInfoMapPersists() {
        var source = BookSource()
        source.bookSourceName = "infoMap 測試"
        source.bookSourceUrl = "https://infomap.test/" + UUID().uuidString
        defer { LegadoCacheBridge(sourceId: source.bookSourceUrl).delete("infoMap_" + source.bookSourceUrl) }

        let engine = JSCoreEngine()
        engine.bookSource = source
        _ = engine.evaluate("infoMap.put('关键词', '三体'); infoMap.save();")
        engine.setExploreInfoMapValue("最新", forKey: "排序")

        let next = JSCoreEngine()
        next.bookSource = source
        #expect(next.exploreInfoMapValues() == ["关键词": "三体", "排序": "最新"])
        #expect(next.evaluate("infoMap.get('关键词')") == "三体")
    }
}
