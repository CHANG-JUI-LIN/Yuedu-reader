import Foundation
import os
import Testing
@testable import yuedu_app

@Suite("Network settings search", .serialized)
struct NetworkSettingsSearchTests {
    private static let issue32PackPath = "/Users/zhangruilin/Desktop/Test document/RULE/a8adf570-e115-4b99-87e3-ccaf298ae361.json"
    private static let large11780PackPath = "/Users/zhangruilin/Desktop/Test document/RULE/11780_51b655a48db62802c20dcb56a8802d4d.json"

    @Test(
        "issue 32 source pack decodes into searchable sources",
        .enabled(if: FileManager.default.fileExists(atPath: issue32PackPath), "Needs the issue 32 source pack at \(issue32PackPath)")
    )
    func issue32SourcePackDecodes() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.issue32PackPath))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)

        #expect(sources.count == 459)
        #expect(sources.contains { !$0.searchUrl.isEmpty && !$0.ruleSearch.bookList.isEmpty })
    }

    @Test(
        "large 11780 source pack decodes into enabled searchable sources",
        .enabled(if: FileManager.default.fileExists(atPath: large11780PackPath), "Needs the 11780 source pack at \(large11780PackPath)")
    )
    func large11780SourcePackDecodes() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.large11780PackPath))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)

        #expect(sources.count == 1607)
        #expect(sources.filter(\.enabled).count == 1607)
        #expect(sources.contains { !$0.searchUrl.isEmpty && !$0.ruleSearch.bookList.isEmpty })
    }

    @Test("search cache reuses fresh results and remaps to current source identity")
    func searchCacheReusesFreshResults() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = SearchResultCache(directory: directory)
        var source = makeSource(name: "Original", url: "https://example.com/source")
        let oldSourceId = source.id
        let book = makeOnlineBook(name: "Issue32", source: source)

        cache.store(
            books: [book],
            query: "Issue32",
            source: source,
            days: 5,
            now: Date(timeIntervalSince1970: 1_000)
        )
        cache.waitForPendingWritesForTesting()

        source.id = UUID()
        source.bookSourceName = "Current"
        let cached = try #require(cache.freshBooks(
            query: "Issue32",
            source: source,
            days: 5,
            now: Date(timeIntervalSince1970: 1_000 + 60)
        ))

        #expect(cached.count == 1)
        #expect(cached[0].name == "Issue32")
        #expect(cached[0].sourceId == source.id)
        #expect(cached[0].sourceId != oldSourceId)
        #expect(cached[0].sourceName == "Current")
        #expect(cache.freshBooks(query: "Issue32", source: source, days: 0) == nil)
        #expect(cache.freshBooks(
            query: "Issue32",
            source: source,
            days: 5,
            now: Date(timeIntervalSince1970: 1_000 + 6 * 86_400)
        ) == nil)
    }

    @Test("auto pause policy follows exact and fuzzy thresholds")
    func autoPausePolicyThresholds() {
        let disabled = SearchAutoPausePolicy(count: 0)
        #expect(!disabled.shouldPause(exactCount: 100, fuzzyCount: 100))

        let policy = SearchAutoPausePolicy(count: 2)
        #expect(!policy.shouldPause(exactCount: 1, fuzzyCount: 9))
        #expect(policy.shouldPause(exactCount: 2, fuzzyCount: 0))
        #expect(policy.shouldPause(exactCount: 0, fuzzyCount: 10))
    }

    @Test("auto pause 0 never pauses, however many sources there are (feedback #16)")
    func zeroAutoPauseNeverPauses() {
        // Until 2026-10-18 a hidden override turned 0 into 10 once 300+ sources were enabled.
        let policy = SearchAutoPausePolicy(count: 0)
        #expect(!policy.isEnabled)
        #expect(!policy.shouldPause(exactCount: 10, fuzzyCount: 50))
        #expect(!policy.shouldPause(exactCount: 1559, fuzzyCount: 1559))
    }

    @Test("runtime template search sources get aggregate timeout budget")
    func runtimeTemplateSearchSourcesGetAggregateTimeoutBudget() {
        var runtimeSource = makeSource(name: "Runtime", url: "https://example.com/source")
        runtimeSource.jsLib = "const CONFIG = { api: { baseUrl: 'https://api.example.com' } };"
        runtimeSource.searchUrl = "{{CONFIG.api.baseUrl}}/search.php?keyword={{key}}&page={{page}}"

        var fastSource = makeSource(name: "Fast", url: "https://example.com/fast")
        fastSource.jsLib = "function noop() { return ''; }"
        fastSource.searchUrl = "https://example.com/search?q={{key}}&page={{page}}"

        #expect(BookSourceSearchFanOut.timeout(for: runtimeSource, normal: 12, aggregate: 30) == 30)
        #expect(BookSourceSearchFanOut.timeout(for: fastSource, normal: 12, aggregate: 30) == 12)
    }

    @MainActor
    @Test("change source search auto pauses after configured exact result count")
    func changeSourceAutoPauses() async throws {
        let previousConcurrency = GlobalSettings.shared.searchConcurrency
        let previousAutoPauseCount = GlobalSettings.shared.searchAutoPauseCount
        defer {
            GlobalSettings.shared.searchConcurrency = previousConcurrency
            GlobalSettings.shared.searchAutoPauseCount = previousAutoPauseCount
        }
        GlobalSettings.shared.searchConcurrency = 1
        GlobalSettings.shared.searchAutoPauseCount = 1

        let sourceA = makeSource(name: "A", url: "https://example.com/a")
        let sourceB = makeSource(name: "B", url: "https://example.com/b")
        let fetcher = CountingBookSourceFetcher()
        let viewModel = ReaderViewModel(
            chapterFetcher: NoopChapterFetcher(),
            bookCoordinator: NoopOnlineBookCoordinator(),
            bookSourceFetcher: fetcher
        )
        var book = ReadingBook(title: "Issue32", author: "Author", contentFilename: "")
        book.isOnline = true
        book.bookInfoURL = "https://example.com/current"

        viewModel.loadOtherOrigins(
            book: book,
            currentSourceId: sourceA.id,
            enabledSources: [sourceA, sourceB],
            store: BookStore(),
            forceRefresh: true
        )

        try await waitUntil {
            !viewModel.changeSourceLoading
        }

        #expect(viewModel.changeSourceOrigins.count == 1)
        #expect(fetcher.searchCallCount == 1)
    }

    @MainActor
    @Test("change source with auto pause 0 searches all 500 sources and caches the list as complete")
    func changeSourceZeroAutoPauseSearchesEverySource() async throws {
        let previousConcurrency = GlobalSettings.shared.searchConcurrency
        let previousAutoPauseCount = GlobalSettings.shared.searchAutoPauseCount
        let previousCacheDays = GlobalSettings.shared.searchCacheDays
        var book = ReadingBook(title: "Feedback16", author: "Author", contentFilename: "")
        book.isOnline = true
        book.bookInfoURL = "https://example.com/current"
        let bookId = book.id
        defer {
            GlobalSettings.shared.searchConcurrency = previousConcurrency
            GlobalSettings.shared.searchAutoPauseCount = previousAutoPauseCount
            GlobalSettings.shared.searchCacheDays = previousCacheDays
            ChangeSourceCache.shared.clear(for: bookId)
        }
        GlobalSettings.shared.searchConcurrency = 30
        GlobalSettings.shared.searchAutoPauseCount = 0
        GlobalSettings.shared.searchCacheDays = 5

        let sources = (0..<500).map { makeSource(name: "S\($0)", url: "https://feedback16-\($0).test") }
        let fetcher = CountingBookSourceFetcher()
        let viewModel = ReaderViewModel(
            chapterFetcher: NoopChapterFetcher(),
            bookCoordinator: NoopOnlineBookCoordinator(),
            bookSourceFetcher: fetcher
        )

        viewModel.loadOtherOrigins(
            book: book,
            currentSourceId: UUID(),
            enabledSources: sources,
            store: BookStore(),
            forceRefresh: true
        )
        try await waitUntil(timeout: 60) { !viewModel.changeSourceLoading }

        #expect(fetcher.searchCallCount == 500)
        #expect(viewModel.changeSourceOrigins.count == 500)
        let entry = try #require(ChangeSourceCache.shared.entry(for: bookId))
        #expect(entry.isComplete == true)
        #expect(entry.origins.count == 500)
        #expect(ChangeSourceCache.shared.freshEntry(for: bookId, days: 5)?.origins.count == 500)
    }

    @MainActor
    @Test("a change source search cut short by auto pause is not cached as the complete list")
    func pausedChangeSourceIsNotCachedAsComplete() async throws {
        let previousConcurrency = GlobalSettings.shared.searchConcurrency
        let previousAutoPauseCount = GlobalSettings.shared.searchAutoPauseCount
        let previousCacheDays = GlobalSettings.shared.searchCacheDays
        var book = ReadingBook(title: "Feedback16Paused", author: "Author", contentFilename: "")
        book.isOnline = true
        book.bookInfoURL = "https://example.com/current"
        let bookId = book.id
        defer {
            GlobalSettings.shared.searchConcurrency = previousConcurrency
            GlobalSettings.shared.searchAutoPauseCount = previousAutoPauseCount
            GlobalSettings.shared.searchCacheDays = previousCacheDays
            ChangeSourceCache.shared.clear(for: bookId)
        }
        GlobalSettings.shared.searchConcurrency = 1
        GlobalSettings.shared.searchAutoPauseCount = 1
        GlobalSettings.shared.searchCacheDays = 5

        let sources = (0..<3).map { makeSource(name: "P\($0)", url: "https://feedback16-paused-\($0).test") }
        let fetcher = CountingBookSourceFetcher()
        let viewModel = ReaderViewModel(
            chapterFetcher: NoopChapterFetcher(),
            bookCoordinator: NoopOnlineBookCoordinator(),
            bookSourceFetcher: fetcher
        )

        viewModel.loadOtherOrigins(
            book: book,
            currentSourceId: UUID(),
            enabledSources: sources,
            store: BookStore(),
            forceRefresh: true
        )
        try await waitUntil { !viewModel.changeSourceLoading }

        #expect(viewModel.changeSourceOrigins.count == 1)
        let entry = try #require(ChangeSourceCache.shared.entry(for: bookId))
        #expect(entry.isComplete == false)
        // Reopening the sheet searches again instead of serving one result as everything.
        #expect(ChangeSourceCache.shared.freshEntry(for: bookId, days: 5) == nil)
    }

    @Test("a cache entry written before isComplete existed is not served as fresh")
    func legacyCacheEntryIsNotFresh() throws {
        let bookId = UUID()
        defer { ChangeSourceCache.shared.clear(for: bookId) }
        let origin = BookOrigin(
            sourceId: UUID(), sourceName: "Legacy", bookUrl: "https://legacy.test/book",
            tocUrl: "", coverUrl: "", intro: "", lastChapter: "", wordCount: "", kind: "",
            runtimeVariables: nil
        )
        ChangeSourceCache.shared.store(origins: [origin], for: bookId)
        #expect(ChangeSourceCache.shared.freshEntry(for: bookId, days: 5) != nil)
        // The same entry as builds before 2026-10-18 wrote it: no isComplete key.
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let url = caches.appendingPathComponent("ChangeSourceCache/\(bookId.uuidString).json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "isComplete")
        try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
        #expect(ChangeSourceCache.shared.entry(for: bookId) != nil)
        #expect(ChangeSourceCache.shared.freshEntry(for: bookId, days: 5) == nil)
    }

    @MainActor
    @Test("stopping source search also cancels background TOC warm-up")
    func stoppingSearchCancelsTOCWarmup() async throws {
        let previousLoadTOC = GlobalSettings.shared.changeSourceLoadToc
        let previousCacheDays = GlobalSettings.shared.searchCacheDays
        let previousSources = BookSourceStore.shared.sources
        var book = ReadingBook(title: "Warm", author: "Author", contentFilename: "")
        book.isOnline = true
        let bookId = book.id
        defer {
            GlobalSettings.shared.changeSourceLoadToc = previousLoadTOC
            GlobalSettings.shared.searchCacheDays = previousCacheDays
            BookSourceStore.shared.sources = previousSources
            ChangeSourceCache.shared.clear(for: bookId)
        }

        GlobalSettings.shared.changeSourceLoadToc = true
        GlobalSettings.shared.searchCacheDays = 1
        let source = makeSource(name: "Warm", url: "https://example.com/warm")
        BookSourceStore.shared.sources = [source]
        let origin = BookOrigin(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            bookUrl: "https://example.com/warm/book",
            tocUrl: "https://example.com/warm/toc",
            coverUrl: "",
            intro: "",
            lastChapter: "",
            wordCount: "",
            kind: "",
            runtimeVariables: nil
        )
        ChangeSourceCache.shared.store(origins: [origin], for: bookId)

        let fetcher = CancellableTOCFetcher()
        let viewModel = ReaderViewModel(
            chapterFetcher: NoopChapterFetcher(),
            bookCoordinator: NoopOnlineBookCoordinator(),
            bookSourceFetcher: fetcher
        )
        viewModel.loadOtherOrigins(
            book: book,
            currentSourceId: UUID(),
            enabledSources: [source],
            store: BookStore()
        )
        try await waitUntilAsync { await fetcher.didStartTOCRequest }

        viewModel.stopChangeSourceSearch()

        try await waitUntilAsync { await fetcher.didCancelTOCRequest }
        #expect(await fetcher.didCancelTOCRequest)
    }

    private func makeSource(name: String, url: String) -> BookSource {
        var source = BookSource()
        source.bookSourceName = name
        source.bookSourceUrl = url
        source.searchUrl = "/search?q={{key}}"
        source.ruleSearch.bookList = ".item"
        source.ruleSearch.name = ".title"
        source.ruleSearch.author = ".author"
        source.ruleSearch.bookUrl = "a@href"
        return source
    }

    private func makeOnlineBook(name: String, source: BookSource) -> OnlineBook {
        OnlineBook(
            name: name,
            author: "Author",
            intro: "",
            coverUrl: "",
            bookUrl: "\(source.bookSourceUrl)/book",
            tocUrl: "\(source.bookSourceUrl)/toc",
            wordCount: "",
            lastChapter: "",
            kind: "",
            sourceId: source.id,
            sourceName: source.bookSourceName
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchResultCacheTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for condition")
    }

    private func waitUntilAsync(
        timeout: TimeInterval = 2,
        condition: @escaping () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for async condition")
    }
}

private actor CancellableTOCFetcher: BookSourceFetching {
    private(set) var didStartTOCRequest = false
    private(set) var didCancelTOCRequest = false

    nonisolated func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "CancellableTOCFetcher", code: 1)
    }

    nonisolated func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool
    ) async throws -> TOCPackage {
        await markTOCStarted()
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            if Task.isCancelled || error is CancellationError {
                await markTOCCancelled()
            }
            throw error
        }
        throw NSError(domain: "CancellableTOCFetcher", code: 2)
    }

    private func markTOCStarted() {
        didStartTOCRequest = true
    }

    private func markTOCCancelled() {
        didCancelTOCRequest = true
    }

    nonisolated func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> Bool {
        false
    }

    nonisolated func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    nonisolated func clearAllChapterCache(bookId: UUID) {}
    nonisolated func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        []
    }

    nonisolated func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> ChapterPackage? {
        nil
    }

    nonisolated func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> String? {
        nil
    }
}

private final class CountingBookSourceFetcher: BookSourceFetching {
    private let calls = OSAllocatedUnfairLock(initialState: 0)

    var searchCallCount: Int { calls.withLock { $0 } }

    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "CountingBookSourceFetcher", code: 1)
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool
    ) async throws -> TOCPackage {
        throw NSError(domain: "CountingBookSourceFetcher", code: 2)
    }

    func isChapterCached(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> Bool {
        false
    }

    func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    func clearAllChapterCache(bookId: UUID) {}

    func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        calls.withLock { $0 += 1 }
        return [
            OnlineBook(
                name: query,
                author: "Author",
                intro: "",
                coverUrl: "",
                bookUrl: "\(source.bookSourceUrl)/book",
                tocUrl: "\(source.bookSourceUrl)/toc",
                wordCount: "",
                lastChapter: "",
                kind: "",
                sourceId: source.id,
                sourceName: source.bookSourceName
            )
        ]
    }

    func loadChapterPackageSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> ChapterPackage? {
        nil
    }

    func loadNormalizedChapterHTMLSync(
        bookId: UUID,
        chapterIndex: Int,
        expectedSourceURL: String?,
        expectedTOCTitle: String?
    ) -> String? {
        nil
    }
}

private struct NoopChapterFetcher: ChapterFetching {
    func isChapterCached(book: ReadingBook, chapterIndex: Int) async -> Bool { false }

    func fetchChapter(
        book: ReadingBook,
        chapterIndex: Int,
        priority: ChapterFetchPriority,
        store: BookStore?
    ) async throws -> ChapterPackage {
        throw NSError(domain: "NoopChapterFetcher", code: 1)
    }

    func cancelChapter(bookId: UUID, chapterIndex: Int) async {}
    func cancelAll(for bookId: UUID) async {}
}

private final class NoopOnlineBookCoordinator: OnlineBookCoordinating {
    func downloadBook(_ book: ReadingBook, store: BookStore?) {}
    func downloadBook(
        _ book: ReadingBook,
        store: BookStore?,
        startChapterIndex: Int,
        chapterCount: Int?
    ) {}
    func pauseDownload(book: ReadingBook, store: BookStore?) {}
    func prefetchAround(book: ReadingBook, center: Int, store: BookStore?) async {}
}
