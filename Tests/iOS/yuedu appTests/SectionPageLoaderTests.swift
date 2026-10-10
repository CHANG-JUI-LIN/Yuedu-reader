import Combine
import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5b: the one next-page loader of a book-source category (Phase 5 plan,
/// decision 3), and the custom page's waterfall paging through it — the loading that the
/// Phase 0a characterization could not reach without an injected fetcher.

@Suite("Section paging")
struct SectionPagingTests {
    @Test("a category already showing its first page asks for page 2, then the next")
    func pagesInOrder() {
        var paging = SectionPaging(firstPageLoaded: true)
        #expect(paging.start() == 2)
        paging.receive(newBooks: 5, page: 2)
        #expect(paging.start() == 3)
        #expect(SectionPaging(firstPageLoaded: false).nextPage == 1)
    }

    @Test("a page on its way is not asked for twice")
    func oneAtATime() {
        var paging = SectionPaging(firstPageLoaded: true)
        #expect(paging.start() == 2)
        #expect(paging.isLoading)
        #expect(paging.start() == nil)
    }

    @Test("a page with nothing new ends the category")
    func emptyEnds() {
        var paging = SectionPaging(firstPageLoaded: true)
        _ = paging.start()
        paging.receive(newBooks: 0, page: 2)
        #expect(!paging.hasMore)
        #expect(!paging.isLoading)
        #expect(paging.start() == nil)
    }

    @Test("a failed page keeps its reason until the retry asks for the same page")
    func failureRetriesSamePage() {
        var paging = SectionPaging(firstPageLoaded: true)
        _ = paging.start()
        paging.fail("逾時")
        #expect(paging.errorReason == "逾時")
        #expect(!paging.isLoading)
        #expect(paging.start() == 2)
        #expect(paging.errorReason == nil)
    }
}

/// Records what the loader asked for and answers from a script.
private actor FetchScript {
    private(set) var calls: [(url: String?, page: Int)] = []
    private var answers: [Int: Result<[OnlineBook], Error>]

    init(_ answers: [Int: Result<[OnlineBook], Error>]) {
        self.answers = answers
    }

    func answer(_ item: ModernParserBridge.DiscoverItem, page: Int) throws -> [OnlineBook] {
        calls.append((item.url, page))
        return try (answers[page] ?? .success([])).get()
    }

    func set(_ page: Int, _ answer: Result<[OnlineBook], Error>) {
        answers[page] = answer
    }

    var pages: [Int] { calls.map(\.page) }

    nonisolated func loader() -> SectionPageLoader {
        SectionPageLoader { item, page, _ in try await self.answer(item, page: page) }
    }
}

private struct PageFailed: Error, LocalizedError {
    var errorDescription: String? { "第二頁失敗" }
}

private func book(_ name: String) -> OnlineBook {
    OnlineBook(name: name, author: "作者", intro: "", coverUrl: "", bookUrl: "https://books.test/\(name)",
               tocUrl: "", wordCount: "", lastChapter: "", kind: "", sourceId: UUID(), sourceName: "S")
}

private func makeSource(_ name: String) -> BookSource {
    var source = BookSource()
    source.bookSourceName = "5b \(name)"
    source.bookSourceUrl = "https://phase5-loader.test/\(name)"
    return source
}

private func section(_ title: String, of source: BookSource) throws -> DiscoverShowcaseSection {
    let item = try #require(ExploreCategoryReference(
        sourceURL: source.bookSourceUrl, title: title, url: "\(source.bookSourceUrl)/\(title)/{{page}}"
    ).cardItem)
    return DiscoverShowcaseSection(item: item, coverBaseURL: source.bookSourceUrl, coverHeaders: [:])
}

@Suite("Section page loader")
struct SectionPageLoaderTests {
    @Test("a page drops the books already shown and repeats within itself")
    func dedups() async throws {
        let source = makeSource("dedup")
        let script = FetchScript([2: .success([book("甲"), book("乙"), book("乙"), book("丙")])])
        let displays = try await script.loader().books(
            page: 2, of: try section("熱門", of: source), in: source, after: [book("甲")]
        )
        #expect(displays.map(\.book.name) == ["乙", "丙"])
        #expect(await script.pages == [2])
        #expect(await script.calls.first?.url == "\(source.bookSourceUrl)/熱門/{{page}}")
    }

    @Test("a failure reaches the caller")
    func failurePropagates() async throws {
        let source = makeSource("fail")
        let script = FetchScript([2: .failure(PageFailed())])
        await #expect(throws: PageFailed.self) {
            _ = try await script.loader().books(page: 2, of: try section("熱門", of: source), in: source, after: [])
        }
    }
}

@MainActor
@Suite("Custom page waterfall paging", .serialized, .timeLimit(.minutes(1)))
struct CustomExploreWaterfallPagingTests {
    private func withSource(_ source: BookSource, _ body: () async throws -> Void) async rethrows {
        let store = BookSourceStore.shared
        let saved = store.sources
        store.sources = saved + [source]
        defer { store.sources = saved }
        try await body()
    }

    private func waterfallPage(_ source: BookSource) -> CustomExplorePage {
        CustomExplorePage(name: "頁", components: [
            CustomExploreComponent(kind: .waterfall, categories: [ExploreCategoryReference(
                sourceURL: source.bookSourceUrl, title: "最新", url: "\(source.bookSourceUrl)/最新/{{page}}"
            )]),
        ])
    }

    private func loadFirstPage(_ model: CustomExplorePageModel) async throws {
        let sectionID = try #require(model.waterfallPaging.sectionID)
        model.load(sectionID)
        _ = await model.$blocks.values.first { $0.first?.sections.first?.phase == .loaded }
    }

    private func settle(_ model: CustomExplorePageModel) async {
        _ = await model.$waterfallPaging.values.first { !$0.isLoading }
    }

    private func names(_ model: CustomExplorePageModel) -> [String] {
        model.blocks.first?.sections.first?.books.map(\.book.name) ?? []
    }

    @Test("the waterfall loads page 1, then appends page 2 without repeats, and ends on a page of repeats")
    func pagesThrough() async throws {
        let source = makeSource("pages")
        let script = FetchScript([
            1: .success([book("甲"), book("乙")]),
            2: .success([book("乙"), book("丙")]),
            3: .success([book("甲"), book("丙")]),
        ])
        try await withSource(source) {
            let model = CustomExplorePageModel(pageLoader: script.loader())
            model.sync(with: waterfallPage(source))
            try await loadFirstPage(model)
            #expect(names(model) == ["甲", "乙"])

            model.loadMoreWaterfall()
            await settle(model)
            #expect(names(model) == ["甲", "乙", "丙"])
            #expect(model.waterfallPaging.nextPage == 3)

            model.loadMoreWaterfall()
            await settle(model)
            #expect(names(model) == ["甲", "乙", "丙"])
            #expect(!model.waterfallPaging.hasMore)

            model.loadMoreWaterfall()
            #expect(await script.pages == [1, 2, 3])
        }
    }

    @Test("a failed page shows its reason, and the retry asks for the same page")
    func failureRetries() async throws {
        let source = makeSource("retry")
        let script = FetchScript([1: .success([book("甲")]), 2: .failure(PageFailed())])
        try await withSource(source) {
            let model = CustomExplorePageModel(pageLoader: script.loader())
            model.sync(with: waterfallPage(source))
            try await loadFirstPage(model)

            model.loadMoreWaterfall()
            await settle(model)
            #expect(model.waterfallPaging.errorReason == "第二頁失敗")
            #expect(model.waterfallPaging.nextPage == 2)

            await script.set(2, .success([book("乙")]))
            model.loadMoreWaterfall()
            await settle(model)
            #expect(model.waterfallPaging.errorReason == nil)
            #expect(names(model) == ["甲", "乙"])
            #expect(await script.pages == [1, 2, 2])
        }
    }
}
