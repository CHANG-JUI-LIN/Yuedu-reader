import Foundation
import Testing
@testable import yuedu_app

/// Unified search, Phase 4a: the book-source fan-out `SearchAggregator` runs for its first
/// search and for 載入更多. Sources answer from `SearchResultCache` (stored first), so
/// nothing reaches the network.
@MainActor
@Suite("Book source search fan-out", .serialized)
struct BookSourceSearchFanOutTests {
    private let fanOut = BookSourceSearchFanOut(concurrency: 2, timeout: 5, aggregateTimeout: 5)

    @Test("every source answers once, with its books, past the concurrency width")
    func everySourceAnswers() async throws {
        let first = makeSource("book"), second = makeSource("second"), third = makeSource("third")
        try await withCache([first, second, third]) {
            let streamed = BatchLog()
            var answers: [String: BookSourceSearchFanOut.Answer] = [:]
            await fanOut.run(query: "三體", sources: [first, second, third], request: .firstPage { source, books in
                await streamed.add(source.bookSourceName, books.count)
            }) { source, answer in
                answers[source.bookSourceName] = answer
                return true
            }

            #expect(Set(answers.keys) == ["book", "second", "third"])
            #expect(answers.values.allSatisfy { $0.outcome == .results })
            let delivered = await streamed.total(for: "book") + (answers["book"]?.books.count ?? 0)
            #expect(delivered == 1, "a book reaches the caller once, streamed or in the answer")
        }
    }

    @Test("onAnswer returning false stops the fan-out; the sources not answered are left unanswered")
    func stopsWhenAsked() async throws {
        let sources = (0..<4).map { makeSource("stop-\($0)") }
        try await withCache(sources) {
            var answered: [String] = []
            await BookSourceSearchFanOut(concurrency: 1, timeout: 5, aggregateTimeout: 5)
                .run(query: "三體", sources: sources, request: .firstPage { _, _ in }) { source, _ in
                    answered.append(source.bookSourceName)
                    return false
                }
            #expect(answered == ["stop-0"], "one slot: the first source answers, and nothing after it starts")
        }
    }

    @Test("an outcome says whether the source answered within its time")
    func answeredMeansInTime() {
        #expect(SearchSourceOutcome.results.answered)
        #expect(SearchSourceOutcome.empty.answered)
        #expect(SearchSourceOutcome.failedAsEmpty.answered)
        #expect(!SearchSourceOutcome.timedOut.answered)
        #expect(!SearchSourceOutcome.failed.answered)
    }

    @Test("a JS-driven source gets the aggregate budget")
    func timeoutBudget() {
        var plain = makeSource("plain")
        plain.searchUrl = "https://fanout.test/plain/search?q={{key}}"
        #expect(BookSourceSearchFanOut.timeout(for: plain, normal: 12, aggregate: 30) == 12)
    }

    // MARK: - Helpers

    /// Each source answers 三體 from the cache. (An empty answer cannot be cached: the cache
    /// keeps only results.)
    private func withCache(_ sources: [BookSource], _ body: () async throws -> Void) async throws {
        let settings = GlobalSettings.shared
        let savedCacheDays = settings.searchCacheDays
        settings.searchCacheDays = 1
        let cache = SearchResultCache.shared
        for source in sources {
            cache.store(books: [book("三體", in: source)], query: "三體", source: source, days: 1)
        }
        cache.waitForPendingWritesForTesting()
        defer {
            for source in sources { cache.clear(query: "三體", source: source) }
            settings.searchCacheDays = savedCacheDays
        }
        try await body()
    }

    private func makeSource(_ name: String) -> BookSource {
        var source = BookSource()
        source.bookSourceName = name
        source.bookSourceUrl = "https://fanout.test/\(name)"
        source.searchUrl = "https://fanout.test/\(name)/search?q={{key}}"
        source.ruleSearch.bookList = ".item"
        source.ruleSearch.name = ".title"
        source.ruleSearch.author = ".author"
        source.ruleSearch.bookUrl = "a@href"
        return source
    }

    private func book(_ name: String, in source: BookSource) -> OnlineBook {
        OnlineBook(name: name, author: "劉慈欣", intro: "", coverUrl: "", bookUrl: "\(source.bookSourceUrl)/book",
                   tocUrl: "\(source.bookSourceUrl)/toc", wordCount: "", lastChapter: "", kind: "",
                   sourceId: source.id, sourceName: source.bookSourceName)
    }
}

private actor BatchLog {
    private var counts: [String: Int] = [:]
    func add(_ name: String, _ count: Int) { counts[name, default: 0] += count }
    func total(for name: String) -> Int { counts[name] ?? 0 }
}
