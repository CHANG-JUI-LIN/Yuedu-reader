import Foundation
import Testing
@testable import yuedu_app

/// Feedback #29: an aggregate source's 平台 menu opened, and a choice in it changed nothing.
/// legado-E and MD3 keep a select's choice in the source's explore `infoMap` under its title
/// and show that before the kind's `default`; the page wrote only the source variable and
/// showed `default`, so a source whose `default` is a constant snapped back to it.
@MainActor
@Suite("Discover select and infoMap", .serialized)
struct DiscoverSelectInfoMapTests {
    /// The shape of the gyks aggregate source: the select's `default` is a constant.
    private let platform = ModernParserBridge.DiscoverItem(
        title: "平台",
        type: "select",
        action: "show(infoMap['平台'],'发现页来源')",
        chars: ["番茄", "七猫"],
        default: "番茄"
    )

    @Test("a select shows its infoMap value over its default, and its default over a value it no longer offers")
    func shownFromInfoMap() {
        #expect(DiscoverViewModel.extractFilters(from: [platform]).first?.selected == "番茄")
        #expect(DiscoverViewModel.extractFilters(from: [platform], values: ["平台": "七猫"]).first?.selected == "七猫")
        #expect(DiscoverViewModel.extractFilters(from: [platform], values: ["平台": "喜馬拉雅"]).first?.selected == "番茄")
    }

    @Test("a choice is kept in infoMap, and the page reloads showing it though the source's default is another")
    func choiceSurvivesReload() async throws {
        var source = BookSource()
        source.bookSourceName = "Select infoMap"
        source.bookSourceUrl = "https://discover-select.test/\(UUID().uuidString)"
        source.enabledExplore = true
        // No request: the explore rule lists the select and one category named after the
        // platform it reads from infoMap.
        source.exploreUrl = """
        @js:
        var chosen = infoMap.get('平台') || '番茄';
        JSON.stringify([
          {title: '平台', type: 'select', chars: ['番茄', '七猫'], action: "show(infoMap['平台'],'发现页来源')", default: '番茄'},
          {title: chosen + '熱門', url: 'https://discover-select.test/' + chosen + '/{{page}}'}
        ]);
        """
        let infoMapKey = "infoMap_" + source.bookSourceUrl
        defer {
            LegadoCacheBridge(sourceId: source.bookSourceUrl).delete(infoMapKey)
            BookSourceRuntimeStateStore.shared.setSourceVariableJSON(nil, for: source.bookSourceUrl)
        }

        let model = DiscoverViewModel(source: source)
        model.reload()
        try await waitUntil { !model.isLoadingItems && !model.filters.isEmpty }
        let shown = try #require(model.filters.first)
        #expect(shown.selected == "番茄")

        await model.selectFilter(shown, value: "七猫")?.value
        try await waitUntil { !model.isLoadingItems && !model.filters.isEmpty }

        #expect(model.filters.first?.selected == "七猫")
        #expect(model.sections.map(\.title) == ["七猫熱門"])
        #expect(await DiscoverQuickActionRunner.infoMapValues(source: source)["平台"] == "七猫")
    }

    private func waitUntil(timeout: TimeInterval = 10, condition: @MainActor @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for the page to load")
    }
}
