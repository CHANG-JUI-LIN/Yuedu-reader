import Foundation
import Testing
@testable import yuedu_app

/// Characterization tests (unified library, Phase 0a) for the state a custom explore page
/// builds before anything loads.
///
/// Gap, on purpose: loading a section, its failure and the waterfall's further pages are
/// not covered. They go through `BookSourceFetcher.shared.discoverBooks`, which reaches the
/// network through the JS bridge's own `URLSession` (`LegadoJSBridge.requestSession`), so
/// no stub can answer without a production change. Phase 5's HomeSection loaders take an
/// injected fetcher instead (Phase 0 plan, decision 2). These tests never call `load`.
@MainActor
@Suite("Custom explore page model (characterization)", .serialized)
struct CustomExplorePageModelTests {
    @Test("sync builds one block per component, in page order, with a section per category")
    func syncBuildsBlocksInOrder() throws {
        try withSources([makeSource("a"), makeSource("b")]) {
            let page = CustomExplorePage(id: UUID(), name: "Page", components: [
                component(.ranking, source: "a", categories: ["熱門"]),
                component(.multiCategoryRanking, source: "b", categories: ["男頻", "女頻"]),
                component(.waterfall, source: "a", categories: ["最新"]),
            ])
            let model = CustomExplorePageModel()
            model.sync(with: page)

            #expect(model.blocks.map(\.component.kind) == [.ranking, .multiCategoryRanking, .waterfall])
            #expect(model.blocks.map { $0.sections.map(\.title) } == [["熱門"], ["男頻", "女頻"], ["最新"]])
            #expect(model.blocks.map { $0.source?.bookSourceUrl } == [sourceURL("a"), sourceURL("b"), sourceURL("a")])
            #expect(model.blocks.allSatisfy { $0.sections.allSatisfy { $0.phase == .idle && $0.books.isEmpty } })
        }
    }

    @Test("a block whose source is gone keeps its place with no source and no sections")
    func missingSourceGivesAnEmptyBlock() throws {
        try withSources([makeSource("present")]) {
            let page = CustomExplorePage(id: UUID(), name: "Page", components: [
                component(.grid, source: "deleted", categories: ["熱門"]),
                component(.carousel, source: "present", categories: ["新書"]),
            ])
            let model = CustomExplorePageModel()
            model.sync(with: page)

            #expect(model.blocks.count == 2)
            #expect(model.blocks[0].source == nil)
            #expect(model.blocks[0].sections.isEmpty)
            #expect(model.blocks[1].sections.map(\.title) == ["新書"])
        }
    }

    @Test("an unchanged block keeps its sections across a sync; an edited one is rebuilt")
    func syncKeepsUnchangedBlocks() throws {
        try withSources([makeSource("keep")]) {
            let kept = component(.ranking, source: "keep", categories: ["熱門"])
            var edited = component(.grid, source: "keep", categories: ["新書"])
            let model = CustomExplorePageModel()
            model.sync(with: CustomExplorePage(id: UUID(), name: "Page", components: [kept, edited]))
            let keptSectionID = try #require(model.blocks[0].sections.first?.id)
            let editedSectionID = try #require(model.blocks[1].sections.first?.id)

            edited.title = "改過的標題"
            model.sync(with: CustomExplorePage(id: UUID(), name: "Page", components: [kept, edited]))

            #expect(model.blocks[0].sections.first?.id == keptSectionID)
            #expect(model.blocks[1].sections.first?.id != editedSectionID)
        }
    }

    @Test("waterfall paging follows the waterfall's first section")
    func waterfallPagingFollowsTheWaterfall() throws {
        try withSources([makeSource("fall")]) {
            let model = CustomExplorePageModel()
            model.sync(with: CustomExplorePage(id: UUID(), name: "Page", components: [
                component(.ranking, source: "fall", categories: ["熱門"]),
            ]))
            #expect(model.waterfallPaging.sectionID == nil)

            let waterfall = component(.waterfall, source: "fall", categories: ["最新"])
            model.sync(with: CustomExplorePage(id: UUID(), name: "Page", components: [waterfall]))
            let sectionID = try #require(model.blocks.first?.sections.first?.id)
            #expect(model.waterfallPaging.sectionID == sectionID)
            #expect(model.waterfallPaging.nextPage == 2)
            #expect(model.waterfallPaging.hasMore)
            #expect(!model.waterfallPaging.isLoading)
        }
    }

    @Test("loadMoreWaterfall does nothing before the waterfall's first page has loaded")
    func loadMoreWaterfallWaitsForTheFirstPage() throws {
        try withSources([makeSource("more")]) {
            let model = CustomExplorePageModel()
            model.loadMoreWaterfall()
            #expect(!model.waterfallPaging.isLoading)

            model.sync(with: CustomExplorePage(id: UUID(), name: "Page", components: [
                component(.waterfall, source: "more", categories: ["最新"]),
            ]))
            model.loadMoreWaterfall()

            #expect(!model.waterfallPaging.isLoading)
            #expect(model.waterfallPaging.nextPage == 2)
        }
    }

    @Test("reload with nothing requested resets sections and paging and starts no load")
    func reloadWithNothingRequested() throws {
        try withSources([makeSource("reload")]) {
            let model = CustomExplorePageModel()
            model.sync(with: CustomExplorePage(id: UUID(), name: "Page", components: [
                component(.waterfall, source: "reload", categories: ["最新"]),
            ]))
            let sectionID = model.waterfallPaging.sectionID

            model.reload()

            #expect(model.blocks.first?.sections.allSatisfy { $0.phase == .idle && $0.books.isEmpty } == true)
            #expect(model.waterfallPaging.sectionID == sectionID)
            #expect(model.waterfallPaging.nextPage == 2)
            #expect(model.waterfallPaging.hasMore)
        }
    }

    // MARK: - Helpers

    /// Runs `body` with `BookSourceStore.shared.sources` set to `sources`, then restores it.
    private func withSources(_ sources: [BookSource], _ body: () throws -> Void) throws {
        let store = BookSourceStore.shared
        let saved = store.sources
        store.sources = saved + sources
        defer { store.sources = saved }
        try body()
    }

    private func sourceURL(_ name: String) -> String {
        "https://phase0-explore.test/\(name)"
    }

    private func makeSource(_ name: String) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "Phase 0 \(name)"
        source.bookSourceUrl = sourceURL(name)
        return source
    }

    private func component(
        _ kind: CustomExploreComponent.Kind,
        source: String,
        categories: [String]
    ) -> CustomExploreComponent {
        CustomExploreComponent(kind: kind, categories: categories.map {
            ExploreCategoryReference(
                sourceURL: sourceURL(source),
                title: $0,
                url: "\(sourceURL(source))/category/\($0)/{{page}}"
            )
        })
    }
}
