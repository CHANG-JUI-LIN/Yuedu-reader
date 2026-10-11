import Combine
import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5b: the one next-page loader of a book-source category (Phase 5 plan,
/// decision 3) — the loading that the Phase 0a characterization could not reach without an
/// injected fetcher. The custom page's waterfall, which paged through it too, went with 5d-4.

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
