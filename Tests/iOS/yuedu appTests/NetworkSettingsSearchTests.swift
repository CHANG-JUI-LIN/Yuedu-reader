import Foundation
import Testing
@testable import yuedu_app

@Suite("Network settings search", .serialized)
struct NetworkSettingsSearchTests {
    @Test("issue 32 source pack decodes into searchable sources")
    func issue32SourcePackDecodes() throws {
        let path = "/Users/zhangruilin/Desktop/Test document/RULE/a8adf570-e115-4b99-87e3-ccaf298ae361.json"
        guard FileManager.default.fileExists(atPath: path) else { return }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let sources = try JSONDecoder().decode([BookSource].self, from: data)

        #expect(sources.count == 459)
        #expect(sources.contains { !$0.searchUrl.isEmpty && !$0.ruleSearch.bookList.isEmpty })
    }

    @Test("large 11780 source pack decodes into enabled searchable sources")
    func large11780SourcePackDecodes() throws {
        let path = "/Users/zhangruilin/Desktop/Test document/RULE/11780_51b655a48db62802c20dcb56a8802d4d.json"
        guard FileManager.default.fileExists(atPath: path) else { return }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
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

    @Test("large source packs get a safety auto pause when unset")
    func largeSourcePackSafetyAutoPause() {
        #expect(NetworkSearchSettings.effectiveAutoPauseCount(
            configured: 0,
            sourceCount: NetworkSearchSettings.largeSourcePackThreshold - 1
        ) == 0)
        #expect(NetworkSearchSettings.effectiveAutoPauseCount(
            configured: 0,
            sourceCount: NetworkSearchSettings.largeSourcePackThreshold
        ) == NetworkSearchSettings.largeSourcePackAutoPauseCount)
        #expect(NetworkSearchSettings.effectiveAutoPauseCount(
            configured: 3,
            sourceCount: 1607
        ) == 3)
    }

    @Test("runtime template search sources get aggregate timeout budget")
    func runtimeTemplateSearchSourcesGetAggregateTimeoutBudget() {
        var runtimeSource = makeSource(name: "Runtime", url: "https://example.com/source")
        runtimeSource.jsLib = "const CONFIG = { api: { baseUrl: 'https://api.example.com' } };"
        runtimeSource.searchUrl = "{{CONFIG.api.baseUrl}}/search.php?keyword={{key}}&page={{page}}"

        var fastSource = makeSource(name: "Fast", url: "https://example.com/fast")
        fastSource.jsLib = "function noop() { return ''; }"
        fastSource.searchUrl = "https://example.com/search?q={{key}}&page={{page}}"

        #expect(SearchAggregator.searchTimeout(for: runtimeSource, normal: 12, aggregate: 30) == 30)
        #expect(SearchAggregator.searchTimeout(for: fastSource, normal: 12, aggregate: 30) == 12)
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
}

private final class CountingBookSourceFetcher: BookSourceFetching {
    private let lock = NSLock()
    private var calls = 0

    var searchCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "CountingBookSourceFetcher", code: 1)
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?
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
        lock.lock()
        calls += 1
        lock.unlock()
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
