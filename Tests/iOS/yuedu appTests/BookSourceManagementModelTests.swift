import Combine
import Foundation
import Testing
@testable import yuedu_app

/// 書源管理's derived state: pages, the page-scoped selection, header counts and rows.
@Suite(.serialized)
@MainActor
struct BookSourceManagementModelTests {
    @Test("全選 on 抓取異常 selects that page only, and switching pages clears the selection")
    func selectAllIsScopedToThePage() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let model = harness.model

        #expect(model.counts == BookSourceManagementModel.Counts(
            total: 6, enabled: 6, discover: 0, fetchError: 2, contentError: 1))

        model.filter = .fetchError
        #expect(model.pageCount == 2)
        model.toggleSelectAll()
        // Before: 全選 took the whole (search-filtered) library, so 刪除 on this page
        // deleted every source.
        #expect(model.selectedIDs == [harness.fetchA.id, harness.fetchB.id])
        #expect(model.pageSelectedCount == 2)
        #expect(model.isPageFullySelected)

        model.filter = .all
        #expect(model.selectedIDs.isEmpty)
        #expect(model.pageCount == 6)
        #expect(model.pageSelectedCount == 0)

        model.toggleSelection(harness.okA.id)
        model.filter = .contentError
        #expect(model.selectedIDs.isEmpty)
        model.invertSelection()
        #expect(model.selectedIDs == [harness.contentA.id])

        model.toggleSelectAll()
        #expect(model.selectedIDs.isEmpty)
    }

    @Test("searching narrows the count without dropping the selection")
    func searchKeepsTheSelection() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let model = harness.model

        model.toggleSelection(harness.okA.id)
        model.toggleSelection(harness.fetchA.id)
        model.searchText = harness.okA.bookSourceName.uppercased()
        #expect(model.pageCount == 1)
        #expect(model.pageSelectedCount == 1)
        #expect(model.selectedIDs.count == 2)

        model.searchText = ""
        #expect(model.pageCount == 6)
        #expect(model.pageSelectedCount == 2)
    }

    @Test("a new verdict that moves a source off the page drops it from the selection")
    func verdictMovesSourceOffThePage() async throws {
        let harness = try await Harness()
        defer { harness.remove() }
        let model = harness.model

        model.filter = .fetchError
        model.toggleSelection(harness.fetchA.id)
        #expect(model.selectedIDs == [harness.fetchA.id])

        await harness.fetcher.setFetchFailures([harness.fetchB.bookSourceUrl])
        await harness.runValidation()

        #expect(model.counts.fetchError == 1)
        #expect(model.pageCount == 1)
        #expect(model.selectedIDs.isEmpty)
    }

    @Test("grouped rows: pin groups, first-appearance groups, collapsed members, flat search")
    func groupedRows() async throws {
        let settings = GlobalSettings.shared
        let previousGrouped = settings.bookSourceListGrouped
        settings.bookSourceListGrouped = true
        defer { settings.bookSourceListGrouped = previousGrouped }

        let a = Self.source("甲", group: "小說")
        let b = Self.source("乙", group: "")
        let c = Self.source("丙", group: " 小說 ")
        let d = Self.source("丁", group: "漫畫")
        let e = Self.source("戊", group: "小說")
        let f = Self.source("己", group: "漫畫")
        let harness = try await Harness(sources: [a, b, c, d, e, f], validates: false)
        defer { harness.remove() }
        harness.store.pinToTop(id: e.id)
        harness.store.pinToBottom(id: f.id)
        await Self.mainQueueTurn()
        let model = harness.model

        typealias Item = BookSourceManagementModel.Item
        #expect(model.items == [
            .header,
            .group(BookSourceRowGroup.topPinnedID), .source(e.id),
            .group("小說"), .source(a.id), .source(c.id),
            .group(BookSourceRowGroup.defaultGroupID), .source(b.id),
            .group("漫畫"), .source(d.id),
            .group(BookSourceRowGroup.bottomPinnedID), .source(f.id),
        ])
        #expect(model.group("小說")?.sourceIDs == [a.id, c.id])
        #expect(model.group(BookSourceRowGroup.defaultGroupID)?.name == model.defaultGroupName)

        model.toggleExpansion("小說")
        #expect(!model.items.contains(.source(a.id)))
        #expect(model.items.contains(.group("小說")))

        model.searchText = "丙"
        #expect(model.items == [.header, .source(c.id)])
    }

    @Test("library edits land in one rebuild after the edit has finished")
    func libraryEditsRebuildOnce() async throws {
        let harness = try await Harness(validates: false)
        defer { harness.remove() }
        let model = harness.model
        let versionBefore = model.contentVersion

        harness.store.toggle(id: harness.okA.id)
        // `objectWillChange` fires before the store's write lands; the model waits for it.
        #expect(model.counts.enabled == 6)
        await Self.mainQueueTurn()
        #expect(model.counts.enabled == 5)
        #expect(model.source(for: harness.okA.id)?.enabled == false)
        #expect(model.contentVersion > versionBefore)

        model.toggleSelection(harness.okB.id)
        harness.store.delete(id: harness.okB.id)
        await Self.mainQueueTurn()
        #expect(model.selectedIDs.isEmpty)
        #expect(model.counts.total == 5)
    }

    // MARK: - Harness

    static func source(_ name: String, group: String = "") -> BookSource {
        var source = BookSource(bookSourceUrl: "https://\(UUID().uuidString).example", bookSourceName: name)
        source.bookSourceGroup = group
        source.searchUrl = source.bookSourceUrl + "/search?q={{key}}"
        return source
    }

    /// Lets the main queue drain up to this point — the model rebuilds on the turn after
    /// a library edit.
    static func mainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    final class Harness {
        let okA = BookSourceManagementModelTests.source("甲書源")
        let okB = BookSourceManagementModelTests.source("乙書源")
        let okC = BookSourceManagementModelTests.source("丙書源")
        let fetchA = BookSourceManagementModelTests.source("丁書源")
        let fetchB = BookSourceManagementModelTests.source("戊書源")
        let contentA = BookSourceManagementModelTests.source("己書源")

        let directory: URL
        let defaultsSuite: String
        let store: BookSourceStore
        let fetcher: ScriptedHealthFetcher
        let checker: BookSourceHealthChecker
        let model: BookSourceManagementModel

        init(sources: [BookSource]? = nil, validates: Bool = true) async throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("BookSourceManagementModel-\(UUID().uuidString)")
            defaultsSuite = "BookSourceManagementModelTests.\(UUID().uuidString)"
            store = BookSourceStore(directory: directory)
            store.replaceSourcesFromSync(sources ?? [okA, okB, fetchA, fetchB, contentA, okC])
            fetcher = ScriptedHealthFetcher(
                fetchFailures: [fetchA.bookSourceUrl, fetchB.bookSourceUrl],
                contentFailures: [contentA.bookSourceUrl]
            )
            checker = BookSourceHealthChecker(fetcher: fetcher, store: store)
            checker.policy.checkDiscovery = false
            let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
            model = BookSourceManagementModel(
                store: store,
                healthChecker: checker,
                expansion: BookSourceGroupExpansionStore(defaults: defaults)
            )
            if validates { await runValidation() }
        }

        func runValidation() async {
            checker.prepare(sources: store.sources)
            await checker.runAll()
            // The run ends by writing respond times back to the store.
            await BookSourceManagementModelTests.mainQueueTurn()
        }

        func remove() {
            store.waitForQueuedWrites()
            try? FileManager.default.removeItem(at: directory)
            UserDefaults().removePersistentDomain(forName: defaultsSuite)
        }
    }
}

/// Passes every stage except the ones scripted to fail: a transport failure on search
/// (抓取異常) or an empty chapter (正文異常).
actor ScriptedHealthFetcher: BookSourceHealthCheckFetching {
    private var fetchFailures: Set<String>
    private let contentFailures: Set<String>

    init(fetchFailures: Set<String>, contentFailures: Set<String>) {
        self.fetchFailures = fetchFailures
        self.contentFailures = contentFailures
    }

    func setFetchFailures(_ urls: Set<String>) {
        fetchFailures = urls
    }

    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: (@Sendable (_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        if fetchFailures.contains(source.bookSourceUrl) { throw URLError(.timedOut) }
        return [book(url: source.bookSourceUrl + "/book", toc: "", source: source)]
    }

    func discoverItems(page: Int, in source: BookSource) async -> [ModernParserBridge.DiscoverItem] { [] }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook] { [] }

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> OnlineBook {
        book(url: url, toc: url + "/toc", source: source)
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
        contentFailures.contains(source.bookSourceUrl) ? "" : "第一章的正文內容，足夠通過驗證。"
    }

    private func book(url: String, toc: String, source: BookSource) -> OnlineBook {
        OnlineBook(
            name: "驗證用書", author: "作者", intro: "", coverUrl: "", bookUrl: url, tocUrl: toc,
            wordCount: "", lastChapter: "", kind: "", sourceId: source.id,
            sourceName: source.bookSourceName)
    }
}
