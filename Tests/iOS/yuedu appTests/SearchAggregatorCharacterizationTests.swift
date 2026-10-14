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
        #expect(SearchBook.makeKey(name: "ＡＢＣ", author: "") == SearchBook.makeKey(name: "abc", author: ""))
        #expect(SearchBook.makeKey(name: " 三 體 ", author: "") == SearchBook.makeKey(name: "三體", author: ""))
        #expect(SearchBook.makeKey(name: "三體 ", author: " 劉慈欣") == SearchBook.makeKey(name: "三體", author: "劉慈欣"))
    }

    @Test("the name and the author stay separate parts of the key")
    func nameAndAuthorStaySeparate() {
        #expect(SearchBook.makeKey(name: "a", author: "bc") != SearchBook.makeKey(name: "ab", author: "c"))
    }

    @Test("punctuation is kept in the key")
    func punctuationIsKept() {
        // The off-shelf records' key (`OffShelfReadRecords`): stored data, so it stays. 搜索
        // (4c-1) and 換源 (4d) compare titles by `WorkMatchKey` instead, which folds
        // punctuation and Traditional / Simplified (`ChangeSourceMatchTests`). The comment
        // on `normalize` says it strips punctuation; it does not.
        #expect(SearchBook.makeKey(name: "三體！", author: "") != SearchBook.makeKey(name: "三體", author: ""))
        #expect(SearchBook.makeKey(name: "三体", author: "") != SearchBook.makeKey(name: "三體", author: ""))
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

    @Test("a result without an author is its own row, whichever arrives first")
    func noAuthorIsItsOwnRow() async throws {
        // Changed on purpose in unified search 4c-1 (maintainer's decision 1, design §7.2):
        // the first arrival used to fix the merged row's author, so a no-author result
        // that came first took every 劉慈欣 copy under an empty author. A title merges only
        // when both sides name compatible authors.
        // Both books come from one source in one batch, so their order is deterministic.
        let source = makeSource("first-author")
        let withoutAuthorFirst = try await search("三體", [
            (source, [book("三體", "", in: source, path: "1"), book("三體", "劉慈欣", in: source, path: "2")]),
        ])
        #expect(withoutAuthorFirst.count == 2)
        #expect(Set(withoutAuthorFirst.map(\.author)) == ["", "劉慈欣"])
        #expect(withoutAuthorFirst.allSatisfy { $0.origins.count == 1 })

        let other = makeSource("first-author-reversed")
        let withAuthorFirst = try await search("三體", [
            (other, [book("三體", "劉慈欣", in: other, path: "1"), book("三體", "", in: other, path: "2")]),
        ])
        #expect(withAuthorFirst.count == 2)
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
        // Authors named, so the two 三體二 merge under the work rule (4c-1).
        let results = try await search("三體", [
            (a, [
                book("三體一", "劉慈欣", in: a),
                book("三體前傳", "劉慈欣", in: a),
                book("三體二", "劉慈欣", in: a),
            ]),
            (b, [book("三體二", "劉慈欣", in: b)]),
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

    // MARK: - Work rule (unified search 4c-1)

    @Test("搜索 merges by the work key: Traditional, Simplified and punctuation fold together")
    func workKeyFolds() async throws {
        let a = makeSource("work-a")
        let b = makeSource("work-b")
        let c = makeSource("work-c")
        let results = try await search("三體", [
            (a, [book("三體", "劉慈欣", in: a)]),
            (b, [book("三体", "刘慈欣", in: b)]),
            (c, [book("三體！", "劉慈欣", in: c)]),
        ])
        #expect(results.count == 1)
        #expect(results.first?.origins.count == 3)
    }

    @Test("a Simplified query finds and ranks a Traditional title exactly")
    func simplifiedQueryFindsTraditional() async throws {
        let source = makeSource("work-query")
        let results = try await search("三体", [
            (source, [book("三體II", "劉慈欣", in: source, path: "2"), book("三體", "劉慈欣", in: source, path: "1")]),
        ])
        #expect(results.map(\.name) == ["三體", "三體II"])
    }

    @Test("the same title and author in another kind stays apart")
    func contentKindKeepsApart() async throws {
        let text = makeSource("work-text")
        let audio = makeSource("work-audio", type: 1)
        let results = try await search("三體", [
            (text, [book("三體", "劉慈欣", in: text)]),
            (audio, [book("三體", "劉慈欣", in: audio)]),
        ])
        #expect(results.count == 2)
    }

    @Test("換源 folds titles like 搜索 (4d), and an empty author still merges")
    func changeSourceFoldsTitles() async throws {
        let a = makeSource("change-a")
        let b = makeSource("change-b")
        let c = makeSource("change-c")
        let folded = try await search("三體", [
            (a, [book("三體", "劉慈欣", in: a)]),
            (b, [book("三体", "刘慈欣", in: b)]),
            (c, [book("三體！", "", in: c)]),
        ], origin: .changeSource)
        #expect(folded.count == 1)
        #expect(folded.first?.origins.count == 3)

        let d = makeSource("change-d")
        let noAuthor = try await search("三體", [
            (d, [book("三體", "", in: d, path: "1"), book("三體", "劉慈欣", in: d, path: "2")]),
        ], origin: .changeSource)
        #expect(noAuthor.count == 1)
        #expect(noAuthor.first?.origins.count == 2)

        let e = makeSource("change-e")
        let otherAuthor = try await search("三體", [
            (e, [book("三體", "劉慈欣", in: e, path: "1"), book("三体", "王晉康", in: e, path: "2"),
                 book("三體II", "劉慈欣", in: e, path: "3")]),
        ], origin: .changeSource)
        #expect(otherAuthor.count == 3, "a different author and a sequel stay apart")
        #expect(Set(otherAuthor.map(\.name)) == ["三體", "三体", "三體II"])
    }

    // MARK: - Helpers

    /// Stores each source's books in the search cache, runs one search over all the
    /// sources, waits for it to finish, and returns the published rows.
    private func search(
        _ query: String,
        _ batches: [(BookSource, [OnlineBook])],
        origin: SearchOrigin = .searchTab
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

        aggregator.search(query: query, sources: batches.map(\.0), origin: origin)
        try await waitUntil { !aggregator.isSearching }
        #expect(aggregator.progress.completed == batches.count)
        return aggregator.results
    }

    private func makeSource(_ name: String, type: Int = 0) -> BookSource {
        var source = BookSource()
        source.bookSourceType = type
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
