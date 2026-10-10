import Foundation
import Testing
@testable import yuedu_app

/// Characterization tests (unified library, Phase 0a): they lock how search results are
/// keyed, merged and ranked today, before Phase 4 wraps `SearchAggregator`.
///
/// Assertions marked "Current behavior (audit §11.2)" lock a known quirk on purpose.
/// Phase 4 is expected to change those, and the test is then updated deliberately.
@Suite("Search keys (characterization)")
struct SearchKeyCharacterizationTests {
    @Test("keys fold case, full-width forms and spaces")
    func keysFoldCaseWidthAndSpaces() {
        #expect(SearchBook.nameKey("ＡＢＣ") == SearchBook.nameKey("abc"))
        #expect(SearchBook.nameKey(" 三 體 ") == SearchBook.nameKey("三體"))
        #expect(SearchBook.makeKey(name: "三體 ", author: " 劉慈欣") == SearchBook.makeKey(name: "三體", author: "劉慈欣"))
    }

    @Test("the name and the author stay separate parts of the key")
    func nameAndAuthorStaySeparate() {
        #expect(SearchBook.makeKey(name: "a", author: "bc") != SearchBook.makeKey(name: "ab", author: "c"))
    }

    @Test("punctuation is kept in the key")
    func punctuationIsKept() {
        // Current behavior (audit §11.2); Phase 4 is expected to change this.
        // The comment on `normalize` says it strips punctuation; it does not.
        #expect(SearchBook.nameKey("三體！") != SearchBook.nameKey("三體"))
    }

    @Test("Traditional and Simplified Chinese do not share a key")
    func traditionalAndSimplifiedDiffer() {
        // Current behavior (audit §11.2); Phase 4 is expected to change this.
        #expect(SearchBook.nameKey("三体") != SearchBook.nameKey("三體"))
    }
}

/// Drives a real `SearchAggregator` search without network: every source's results are
/// stored in `SearchResultCache.shared` first, and `BookSourceFetcher.searchStreaming`
/// answers from that cache before it would make a request.
///
/// Side effect: each search records a success in `SourceHealthStore.shared` for the fake
/// source ids. They never appear in a real source list.
@MainActor
@Suite("Search aggregator merging and ranking (characterization)", .serialized)
struct SearchAggregatorCharacterizationTests {
    @Test("the same title and author from two sources merge into one row")
    func sameBookFromTwoSourcesMerges() async throws {
        let a = makeSource("a")
        let b = makeSource("b")
        let results = try await search("三體", [
            (a, [book("三體", "劉慈欣", in: a)]),
            (b, [book("三體", "劉慈欣", in: b)]),
        ])

        #expect(results.map(\.name) == ["三體"])
        #expect(results.first?.origins.count == 2)
    }

    @Test("the first result to arrive fixes the merged row's author")
    func firstArrivalFixesTheAuthor() async throws {
        // Current behavior (audit §11.2); Phase 4 is expected to change this.
        // Both books come from one source in one batch, so their order is deterministic.
        let source = makeSource("first-author")
        let withoutAuthorFirst = try await search("三體", [
            (source, [book("三體", "", in: source, path: "1"), book("三體", "劉慈欣", in: source, path: "2")]),
        ])
        #expect(withoutAuthorFirst.count == 1)
        #expect(withoutAuthorFirst.first?.author == "")
        #expect(withoutAuthorFirst.first?.origins.count == 2)

        let other = makeSource("first-author-reversed")
        let withAuthorFirst = try await search("三體", [
            (other, [book("三體", "劉慈欣", in: other, path: "1"), book("三體", "", in: other, path: "2")]),
        ])
        #expect(withAuthorFirst.count == 1)
        #expect(withAuthorFirst.first?.author == "劉慈欣")
    }

    @Test("authors that contain one another merge; different authors stay apart")
    func authorContainmentMerges() async throws {
        let source = makeSource("authors")
        let results = try await search("球狀閃電", [
            (source, [
                book("球狀閃電", "劉慈欣", in: source, path: "1"),
                book("球狀閃電", "劉慈欣著", in: source, path: "2"),
                book("球狀閃電", "王晉康", in: source, path: "3"),
            ]),
        ])

        #expect(results.count == 2)
        let merged = try #require(results.first { $0.author == "劉慈欣" })
        #expect(merged.origins.count == 2)
        #expect(results.contains { $0.author == "王晉康" && $0.origins.count == 1 })
    }

    @Test("an exact title ranks first, then a prefix, then containment, then an author match")
    func rankingTiers() async throws {
        let source = makeSource("ranking")
        let results = try await search("三體", [
            (source, [
                book("地球往事三體", "", in: source, path: "contains"),
                book("黑暗森林", "三體作者", in: source, path: "author"),
                book("三體II", "", in: source, path: "prefix"),
                book("三體", "", in: source, path: "exact"),
            ]),
        ])

        #expect(results.map(\.name) == ["三體", "三體II", "地球往事三體", "黑暗森林"])
    }

    @Test("ties go to the shorter title, then to the row with more sources")
    func tieBreaks() async throws {
        let a = makeSource("ties-a")
        let b = makeSource("ties-b")
        let results = try await search("三體", [
            (a, [
                book("三體一", "", in: a),
                book("三體前傳", "", in: a),
                book("三體二", "", in: a),
            ]),
            (b, [book("三體二", "", in: b)]),
        ])

        // All three start with the query (same score). 三體前傳 is longer; of the two
        // three-character titles, 三體二 has two sources.
        #expect(results.map(\.name) == ["三體二", "三體一", "三體前傳"])
    }

    @Test("a book unrelated to the query is dropped; a title the query contains is kept")
    func relatedness() async throws {
        let source = makeSource("related")
        let results = try await search("三體全集", [
            (source, [
                book("球狀閃電", "劉慈欣", in: source, path: "unrelated"),
                book("三體", "劉慈欣", in: source, path: "contained"),
            ]),
        ])

        #expect(results.map(\.name) == ["三體"])
    }

    // MARK: - Helpers

    /// Stores each source's books in the search cache, runs one search over all the
    /// sources, waits for it to finish, and returns the published rows.
    private func search(
        _ query: String,
        _ batches: [(BookSource, [OnlineBook])]
    ) async throws -> [SearchBook] {
        let settings = GlobalSettings.shared
        let savedCacheDays = settings.searchCacheDays
        settings.searchCacheDays = 1
        let cache = SearchResultCache.shared
        for (source, books) in batches {
            cache.store(books: books, query: query, source: source, days: 1)
        }
        cache.waitForPendingWritesForTesting()

        let aggregator = SearchAggregator()
        defer {
            aggregator.cancelAndClear()
            for (source, _) in batches {
                cache.clear(query: query, source: source)
            }
            settings.searchCacheDays = savedCacheDays
        }

        aggregator.search(query: query, sources: batches.map(\.0))
        try await waitUntil { !aggregator.isSearching }
        #expect(aggregator.progress.completed == batches.count)
        return aggregator.results
    }

    private func makeSource(_ name: String) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "Phase 0 \(name)"
        source.bookSourceUrl = "https://phase0-search.test/\(name)"
        source.searchUrl = "https://phase0-search.test/\(name)/search?q={{key}}"
        source.ruleSearch.bookList = ".item"
        source.ruleSearch.name = ".title"
        source.ruleSearch.author = ".author"
        source.ruleSearch.bookUrl = "a@href"
        return source
    }

    private func book(_ name: String, _ author: String, in source: BookSource, path: String = "book") -> OnlineBook {
        OnlineBook(
            name: name,
            author: author,
            intro: "",
            coverUrl: "",
            bookUrl: "\(source.bookSourceUrl)/\(path)/\(name)",
            tocUrl: "\(source.bookSourceUrl)/\(path)/\(name)/toc",
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
        Issue.record("Timed out waiting for the search to finish")
    }
}
