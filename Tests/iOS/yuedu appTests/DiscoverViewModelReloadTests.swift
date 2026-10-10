import Foundation
import Testing
@testable import yuedu_app

/// Characterization tests (unified library, Phase 0a) for `DiscoverViewModel.reload`.
///
/// The cache path runs without network: the category list is stored in
/// `DiscoverKindsCache.shared` first, under the key `reload()` computes for a source with
/// no runtime variable. Entries use fixed keys under `phase0-discover.test`, so a rerun
/// overwrites them instead of adding more.
///
/// Gap, on purpose: `reload(forceRefresh: true)`, a cache miss for a source with explore on,
/// `loadSection` and paging all reach the network through the JS bridge's own `URLSession`,
/// which no stub can answer without a production change (Phase 0 plan, decision 2).
@MainActor
@Suite("Discover reload (characterization)", .serialized)
struct DiscoverViewModelReloadTests {
    @Test("a cached category list becomes the page's categories, sections and page links")
    func cachedCategoriesBuildThePage() async throws {
        let source = makeSource("cached", exploreEnabled: true)
        let hot = item("熱門", path: "hot")
        let raw: [ModernParserBridge.DiscoverItem] = [
            .init(title: "☆ 排行榜 ☆", url: ""),
            hot,
            item("新書", path: "new"),
            hot,
            .init(title: "官網", url: "java.startBrowser('https://phase0-discover.test/site','官網')"),
        ]
        DiscoverKindsCache.shared.store(raw, forKey: cacheKey(for: source))

        let model = DiscoverViewModel(source: source)
        model.reload()
        try await waitUntil { !model.isLoadingItems }

        #expect(model.rawItems.count == raw.count)
        // The label is not a category; the repeated 熱門 is one category; the page link
        // is an item but not a section.
        #expect(model.items.map(\.title) == ["熱門", "新書", "熱門", "官網"])
        #expect(model.sections.map(\.title) == ["熱門", "新書"])
        #expect(model.sections.allSatisfy { $0.phase == .idle && $0.books.isEmpty })
        #expect(model.pageItems.map(\.title) == ["官網"])
        #expect(model.filters.isEmpty)
        #expect(model.sourceNotice == nil)
    }

    @Test("a reload maps fresh items, so every section starts anew")
    func reloadStartsSectionsAnew() async throws {
        let source = makeSource("fresh-sections", exploreEnabled: true)
        DiscoverKindsCache.shared.store([item("熱門", path: "hot")], forKey: cacheKey(for: source))

        let model = DiscoverViewModel(source: source)
        model.reload()
        try await waitUntil { !model.isLoadingItems }
        let firstID = try #require(model.sections.first?.id)

        model.reload()
        try await waitUntil { !model.isLoadingItems && !model.sections.isEmpty }

        #expect(model.sections.map(\.title) == ["熱門"])
        #expect(model.sections.first?.id != firstID)
    }

    @Test("with explore off, reload ends with an empty page and no notice")
    func exploreOffGivesAnEmptyPage() async throws {
        let source = makeSource("explore-off", exploreEnabled: false)

        let model = DiscoverViewModel(source: source)
        model.reload()
        try await waitUntil { !model.isLoadingItems }

        #expect(model.rawItems.isEmpty)
        #expect(model.items.isEmpty)
        #expect(model.sections.isEmpty)
        #expect(model.sourceNotice == nil)
    }

    @Test("with no selected source, reload clears the page at once")
    func noSelectedSourceClears() {
        let model = DiscoverViewModel(source: makeSource("cleared", exploreEnabled: true))
        model.selectedSourceId = nil

        model.reload()

        #expect(model.items.isEmpty)
        #expect(model.sections.isEmpty)
        #expect(model.rawItems.isEmpty)
        #expect(model.filters.isEmpty)
        #expect(!model.isLoadingItems)
    }

    // MARK: - Helpers

    private func makeSource(_ name: String, exploreEnabled: Bool) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "Phase 0 \(name)"
        source.bookSourceUrl = "https://phase0-discover.test/\(name)"
        source.enabledExplore = exploreEnabled
        source.exploreUrl = exploreEnabled ? "https://phase0-discover.test/\(name)/explore" : ""
        return source
    }

    private func item(_ title: String, path: String) -> ModernParserBridge.DiscoverItem {
        .init(title: title, url: "https://phase0-discover.test/category/\(path)/{{page}}")
    }

    /// The key `reload()` uses for a source that has no runtime variable.
    private func cacheKey(for source: BookSource) -> String {
        DiscoverKindsCache.key(sourceUrl: source.bookSourceUrl, exploreUrl: source.exploreUrl, variableJSON: nil)
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for reload to finish")
    }
}
