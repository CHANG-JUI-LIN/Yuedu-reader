import Foundation
import Testing
@testable import yuedu_app

/// Unified library, Phase 0e: `search.firstResult` measures from submitting a search to the
/// first merged batch of that search, once per search, tagged with where it started.
///
/// Searches run without network: each source's results are stored in
/// `SearchResultCache.shared` first, and `BookSourceFetcher.searchStreaming` answers from
/// it. The span is a "⏱" line, which `DiagnosticLog` keeps only with verbose on, so each
/// test turns verbose on and restores it.
@MainActor
@Suite("search.firstResult span", .serialized)
struct SearchFirstResultSpanTests {
    @Test("a search records the span once, tagged with its origin and cache setting")
    func searchRecordsOnce() async throws {
        try await withSpanLogging {
            let source = makeSource("once")
            let mark = logMark()

            try await runSearch("三體", sources: [source], cached: [source])

            let added = spanLines(after: mark)
            #expect(added.count == 1)
            #expect(added.first?.contains("origin=searchTab") == true)
            #expect(added.first?.contains("sources=1") == true)
            #expect(added.first?.contains("cacheDays=1") == true)
            #expect(added.first?.contains("books=1") == true)
        }
    }

    @Test("each new search records its own span")
    func everySearchRecords() async throws {
        try await withSpanLogging {
            let source = makeSource("again")
            let mark = logMark()

            try await runSearch("三體", sources: [source], cached: [source])
            try await runSearch("三體", sources: [source], cached: [source])

            #expect(spanLines(after: mark).count == 2)
        }
    }

    @Test("a 換源 search is tagged as such")
    func changeSourceOrigin() async throws {
        try await withSpanLogging {
            let source = makeSource("change-source")
            let mark = logMark()

            try await runSearch("三體", sources: [source], cached: [source], origin: .changeSource)

            let added = spanLines(after: mark)
            #expect(added.count == 1)
            #expect(added.first?.contains("origin=changeSource") == true)
        }
    }

    @Test("a search cleared before anything merged records nothing")
    func clearedSearchRecordsNothing() async throws {
        try await withSpanLogging {
            let cleared = makeSource("cleared")
            let next = makeSource("after-clear")
            let mark = logMark()
            try await withCachedResults(query: "三體", for: [cleared, next]) {
                let aggregator = SearchAggregator()
                // Nothing can merge in between: the search task needs the main actor,
                // which this test holds until the clear.
                aggregator.search(query: "三體", sources: [cleared])
                aggregator.cancelAndClear()

                aggregator.search(query: "三體", sources: [next])
                try await waitUntil { !aggregator.isSearching }
                aggregator.cancelAndClear()
            }

            // Only the second search's span.
            #expect(spanLines(after: mark).count == 1)
        }
    }

    @Test("a paused and resumed search records nothing")
    func resumedSearchRecordsNothing() async throws {
        try await withSpanLogging {
            let source = makeSource("paused")
            let mark = logMark()
            try await withCachedResults(query: "三體", for: [source]) {
                let aggregator = SearchAggregator()
                aggregator.search(query: "三體", sources: [source])
                aggregator.pause()
                #expect(aggregator.isPaused)

                aggregator.resume()
                try await waitUntil { !aggregator.isSearching && !aggregator.results.isEmpty }
                aggregator.cancelAndClear()
            }

            #expect(spanLines(after: mark).isEmpty)
        }
    }

    // MARK: - Helpers

    private func withSpanLogging(_ body: () async throws -> Void) async throws {
        let log = DiagnosticLog.shared
        let savedVerbose = log.isVerboseEnabled
        log.isVerboseEnabled = true
        defer { log.isVerboseEnabled = savedVerbose }
        try await body()
    }

    /// The ids of every entry the diagnostic log holds now, for `spanLines(after:)`.
    private func logMark() -> Set<UUID> {
        Set(DiagnosticLog.shared.snapshot().map(\.id))
    }

    /// The span lines written after `mark` was taken: the entries whose id it does not hold.
    ///
    /// Neither position nor time can tell new lines from old here. The snapshot holds only
    /// the latest 6,000 entries, so counting slides; timestamps are stored to the second; and
    /// it is sorted by `sequence`, which restarts every launch, so this launch's lines sort
    /// among earlier launches' rather than after them.
    private func spanLines(after mark: Set<UUID>) -> [String] {
        DiagnosticLog.shared.snapshot()
            .filter { !mark.contains($0.id) && $0.message.contains("⏱ search.firstResult") }
            .map(\.message)
    }

    private func runSearch(
        _ query: String,
        sources: [BookSource],
        cached: [BookSource],
        origin: SearchOrigin = .searchTab
    ) async throws {
        try await withCachedResults(query: query, for: cached) {
            let aggregator = SearchAggregator()
            aggregator.search(query: query, sources: sources, origin: origin)
            try await waitUntil { !aggregator.isSearching }
            aggregator.cancelAndClear()
        }
    }

    /// Stores one matching book per source in the search cache for the duration of `body`.
    private func withCachedResults(
        query: String,
        for sources: [BookSource],
        _ body: () async throws -> Void
    ) async throws {
        let settings = GlobalSettings.shared
        let savedCacheDays = settings.searchCacheDays
        settings.searchCacheDays = 1
        let cache = SearchResultCache.shared
        for source in sources {
            cache.store(books: [book(query, in: source)], query: query, source: source, days: 1)
        }
        cache.waitForPendingWritesForTesting()
        defer {
            for source in sources {
                cache.clear(query: query, source: source)
            }
            settings.searchCacheDays = savedCacheDays
        }
        try await body()
    }

    private func makeSource(_ name: String) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "Phase 0 \(name)"
        source.bookSourceUrl = "https://phase0-span.test/\(name)"
        source.searchUrl = "https://phase0-span.test/\(name)/search?q={{key}}"
        source.ruleSearch.bookList = ".item"
        source.ruleSearch.name = ".title"
        source.ruleSearch.author = ".author"
        source.ruleSearch.bookUrl = "a@href"
        return source
    }

    private func book(_ name: String, in source: BookSource) -> OnlineBook {
        OnlineBook(
            name: name,
            author: "劉慈欣",
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

    private func waitUntil(
        timeout: TimeInterval = 10,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for the search")
    }
}
