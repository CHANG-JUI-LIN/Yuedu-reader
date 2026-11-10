import Foundation
import Testing

@testable import yuedu_app

/// Legado's 書源校驗 (`CheckSourceService.doCheckSource`) tags a source without a search URL
/// 搜索链接规则为空 and one whose explore rule yields no URL 发现规则为空, then fails the source
/// only for its *invalid* groups — `BookSource.getInvalidGroupNames` keeps groups holding 失效,
/// and 校验超时. Those two tags are neither, so such a source passes on its other track. And it
/// checks discovery whenever `exploreUrl` is set; `enabledExplore` only hides the 发现 page.
@MainActor
@Suite("Book source check: empty search / explore rules")
struct BookSourceCheckEmptyRuleTests {

    @Test("a source without a search URL passes on its discovery track")
    func noSearchURLPassesOnDiscovery() async throws {
        var source = BookSource(bookSourceUrl: "https://explore-only.yuedu.test", bookSourceName: "只有發現")
        source.exploreUrl = "排行::https://explore-only.yuedu.test/rank"
        let fetcher = EmptyRuleFetcher(sections: [.init(title: "排行", url: source.bookSourceUrl + "/rank")])

        let (item, stored) = try await Self.check(source, fetcher: fetcher)

        #expect(item.outcome(.search).status == .skipped)
        #expect(item.outcome(.search).summary == localized("搜索鏈接規則為空"))
        #expect(item.outcome(.discovery).status == .pass)
        #expect(item.outcome(.content).status == .pass)
        #expect(item.overallPass)
        #expect(item.failureCategory == nil)
        // Legado tags the source and, as it passed, leaves no error line.
        #expect(stored.bookSourceGroup == "搜索链接规则为空")
        #expect(stored.bookSourceComment.isEmpty)
    }

    @Test("an explore rule with no URL skips discovery instead of failing the source")
    func exploreWithoutURLSkipsDiscovery() async throws {
        var source = BookSource(bookSourceUrl: "https://no-explore-url.yuedu.test", bookSourceName: "發現沒網址")
        source.searchUrl = source.bookSourceUrl + "/search?q={{key}}"
        source.exploreUrl = "@js:[]"
        // A filter dropdown has no URL; Legado takes the first kind that has one.
        let fetcher = EmptyRuleFetcher(sections: [.init(title: "篩選", url: nil, type: "select")])

        let (item, _) = try await Self.check(source, fetcher: fetcher)

        #expect(item.outcome(.search).status == .pass)
        #expect(item.outcome(.discovery).status == .skipped)
        #expect(item.outcome(.discovery).summary == localized("發現規則為空"))
        #expect(item.overallPass)
    }

    @Test("discovery is checked even when the discover page is switched off")
    func discoveryCheckedWhenExploreDisabled() async throws {
        var source = BookSource(bookSourceUrl: "https://explore-off.yuedu.test", bookSourceName: "發現關閉")
        source.searchUrl = source.bookSourceUrl + "/search?q={{key}}"
        source.exploreUrl = "排行::https://explore-off.yuedu.test/rank"
        source.enabledExplore = false
        let fetcher = EmptyRuleFetcher(
            sections: [.init(title: "排行", url: source.bookSourceUrl + "/rank")],
            discoverReturnsBooks: false
        )

        let (item, stored) = try await Self.check(source, fetcher: fetcher)

        #expect(item.outcome(.search).status == .pass)
        #expect(item.outcome(.discovery).status == .fail)
        #expect(item.failureCategory == .discoveryFailed)
        #expect(!item.overallPass)
        // What Legado writes onto the source: the group, and the reason above the comment.
        #expect(stored.bookSourceGroup == "发现失效")
        #expect(stored.bookSourceComment == "// Error: 发现失效")
    }

    private static func check(
        _ source: BookSource,
        fetcher: EmptyRuleFetcher
    ) async throws -> (BookSourceCheckItem, BookSource) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookSourceCheckEmptyRule-\(UUID().uuidString)")
        let store = BookSourceStore(directory: directory)
        store.replaceSourcesFromSync([source])
        let checker = BookSourceHealthChecker(fetcher: fetcher, store: store)
        checker.policy.badAction = .markOnly
        checker.prepare(sources: [source])
        await checker.runAll()
        store.waitForQueuedWrites()
        let stored = try #require(store.source(id: source.id))
        try FileManager.default.removeItem(at: directory)
        let item = try #require(checker.items.first)
        #expect(item.isFinished)
        return (item, stored)
    }
}

/// Every stage answers from memory: one book per search / discovery, a one-chapter TOC.
private actor EmptyRuleFetcher: BookSourceHealthCheckFetching {
    private let sections: [ModernParserBridge.DiscoverItem]
    private let discoverReturnsBooks: Bool

    init(sections: [ModernParserBridge.DiscoverItem], discoverReturnsBooks: Bool = true) {
        self.sections = sections
        self.discoverReturnsBooks = discoverReturnsBooks
    }

    nonisolated func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: (@Sendable (_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        [Self.book(url: source.bookSourceUrl + "/book", source: source)]
    }

    func discoverItems(page: Int, in source: BookSource) async -> [ModernParserBridge.DiscoverItem] {
        sections
    }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook] {
        discoverReturnsBooks ? [Self.book(url: source.bookSourceUrl + "/found", source: source)] : []
    }

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> OnlineBook {
        Self.book(url: url, source: source)
    }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] {
        [OnlineChapterRef(index: 0, title: "第一章", url: tocUrl + "/1")]
    }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String {
        "第一章的正文內容，足夠通過驗證。"
    }

    nonisolated private static func book(url: String, source: BookSource) -> OnlineBook {
        OnlineBook(
            name: "驗證用書", author: "作者", intro: "", coverUrl: "", bookUrl: url, tocUrl: url + "/toc",
            wordCount: "", lastChapter: "", kind: "", sourceId: source.id,
            sourceName: source.bookSourceName)
    }
}
