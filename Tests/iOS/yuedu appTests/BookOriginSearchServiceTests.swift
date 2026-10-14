import Foundation
import Testing
@testable import yuedu_app

/// Characterization tests (unified library, Phase 0a) for the 換源 / 封面搜索 fan-out.
///
/// Side effect: every answered search records a success in `SourceHealthStore.shared`
/// for the fake source ids. They never appear in a real source list.
@MainActor
@Suite("Book origin search (characterization)", .serialized)
struct BookOriginSearchServiceTests {
    @Test("only the same book is kept: same title, compatible author")
    func keepsOnlyTheSameBook() async {
        let source = makeSource("same-book")
        let fetcher = ScriptedOriginFetcher([
            source.bookSourceUrl: .success([
                book("三體", "劉慈欣", in: source, path: "match"),
                book("三體", "", in: source, path: "no-author"),
                book("三體II", "劉慈欣", in: source, path: "sequel"),
                book("三體", "王晉康", in: source, path: "other-author"),
            ]),
        ])

        let origins = await collect(title: "三體", author: "劉慈欣", sources: [source], fetcher: fetcher)

        #expect(Set(origins.map(\.bookUrl)) == [
            "\(source.bookSourceUrl)/match/三體",
            "\(source.bookSourceUrl)/no-author/三體",
        ])
    }

    @Test("a repeated source and URL is kept once, and the excluded origin is dropped")
    func deduplicatesAndExcludes() async {
        let source = makeSource("dedup")
        let repeated = book("三體", "劉慈欣", in: source, path: "repeated")
        let current = book("三體", "劉慈欣", in: source, path: "current")
        let fetcher = ScriptedOriginFetcher([
            source.bookSourceUrl: .success([repeated, repeated, current]),
        ])

        let origins = await collect(
            title: "三體", author: "劉慈欣", sources: [source], fetcher: fetcher,
            excludingOriginKey: ChangeSourceCache.originKey(sourceId: source.id, bookUrl: current.bookUrl)
        )

        #expect(origins.map(\.bookUrl) == [repeated.bookUrl])
    }

    @Test("the source filter decides which sources are queried")
    func sourceFilterSkipsSources() async {
        let kept = makeSource("filter-kept")
        let skipped = makeSource("filter-skipped")
        let fetcher = ScriptedOriginFetcher([
            kept.bookSourceUrl: .success([book("三體", "劉慈欣", in: kept)]),
            skipped.bookSourceUrl: .success([book("三體", "劉慈欣", in: skipped)]),
        ])

        let origins = await collect(
            title: "三體", author: "劉慈欣", sources: [kept, skipped], fetcher: fetcher,
            sourceFilter: { $0.id == kept.id }
        )

        #expect(origins.map(\.sourceId) == [kept.id])
        #expect(fetcher.queriedSourceURLs == [kept.bookSourceUrl])
    }

    @Test("once shouldStop is true, no further source is started")
    func shouldStopEndsTheFanOut() async {
        let sources = (1...3).map { makeSource("stop-\($0)") }
        var script: [String: Result<[OnlineBook], Error>] = [:]
        for source in sources {
            script[source.bookSourceUrl] = .success([book("三體", "劉慈欣", in: source)])
        }
        let fetcher = ScriptedOriginFetcher(script)
        var batches: [[BookOrigin]] = []

        // One source at a time, so the order of answers is the order of sources.
        await BookOriginSearchService.stream(
            title: "三體", author: "劉慈欣", sources: sources, concurrency: 1, fetcher: fetcher,
            shouldStop: { $0 >= 2 },
            onBatch: { batches.append($0) }
        )

        #expect(batches.map(\.count) == [1, 1])
        #expect(fetcher.queriedSourceURLs == sources.prefix(2).map(\.bookSourceUrl))
    }

    @Test("each source with matches is delivered as one batch")
    func oneBatchPerSource() async {
        let a = makeSource("batch-a")
        let b = makeSource("batch-b")
        let empty = makeSource("batch-empty")
        let fetcher = ScriptedOriginFetcher([
            a.bookSourceUrl: .success([
                book("三體", "劉慈欣", in: a, path: "1"),
                book("三體", "劉慈欣", in: a, path: "2"),
            ]),
            b.bookSourceUrl: .success([book("三體", "劉慈欣", in: b)]),
            empty.bookSourceUrl: .success([book("球狀閃電", "劉慈欣", in: empty)]),
        ])
        var batches: [[BookOrigin]] = []

        await BookOriginSearchService.stream(
            title: "三體", author: "劉慈欣", sources: [a, b, empty], concurrency: 1, fetcher: fetcher,
            onBatch: { batches.append($0) }
        )

        #expect(batches.map(\.count) == [2, 1])
    }

    @Test("a source that fails gives its slot to the next source, and only answers are counted")
    func failedSourceKeepsTheFanOutGoing() async {
        // Until Phase 3b a failed source's slot was dropped: with one slot, the fan-out ended
        // at the first failure and the remaining sources were never asked.
        let failing = makeSource("slot-failing")
        let answering = makeSource("slot-answering")
        let fetcher = ScriptedOriginFetcher([
            failing.bookSourceUrl: .failure(URLError(.badServerResponse)),
            answering.bookSourceUrl: .success([book("三體", "劉慈欣", in: answering)]),
        ])
        var answered = 0
        var origins: [BookOrigin] = []

        await BookOriginSearchService.stream(
            title: "三體", author: "劉慈欣", sources: [failing, answering], concurrency: 1, fetcher: fetcher,
            onSourceAnswered: { answered += 1 },
            onBatch: { origins.append(contentsOf: $0) }
        )

        #expect(fetcher.queriedSourceURLs == [failing.bookSourceUrl, answering.bookSourceUrl])
        #expect(origins.map(\.sourceId) == [answering.id])
        #expect(answered == 1)
    }

    @Test("a source that throws answers nil, the same as one that times out")
    func thrownErrorLooksLikeATimeout() async {
        // Current behavior: `searchSourceWithTimeout` discards the error with `try?`, so
        // 換源 cannot tell a failed source from a slow one (Phase 0 plan, follow-up 1).
        let source = makeSource("throws")
        let fetcher = ScriptedOriginFetcher([
            source.bookSourceUrl: .failure(URLError(.badServerResponse)),
        ])

        let books = await BookOriginSearchService.searchSourceWithTimeout(
            query: "三體", bookTitle: "三體", bookAuthor: "劉慈欣",
            source: source, bookSourceFetcher: fetcher, seconds: 5
        )

        #expect(books == nil)
    }

    @Test("a source slower than the timeout answers nil")
    func slowSourceTimesOut() async {
        let source = makeSource("slow")
        let fetcher = ScriptedOriginFetcher([:], waitsUntilCancelled: [source.bookSourceUrl])

        let books = await BookOriginSearchService.searchSourceWithTimeout(
            query: "三體", bookTitle: "三體", bookAuthor: "劉慈欣",
            source: source, bookSourceFetcher: fetcher, seconds: 1
        )

        #expect(books == nil)
    }

    // MARK: - Helpers

    private func collect(
        title: String,
        author: String,
        sources: [BookSource],
        fetcher: ScriptedOriginFetcher,
        excludingOriginKey: String? = nil,
        sourceFilter: ((BookSource) -> Bool)? = nil
    ) async -> [BookOrigin] {
        var origins: [BookOrigin] = []
        await BookOriginSearchService.stream(
            title: title, author: author, sources: sources, concurrency: 1, fetcher: fetcher,
            excludingOriginKey: excludingOriginKey,
            sourceFilter: sourceFilter,
            onBatch: { origins.append(contentsOf: $0) }
        )
        return origins
    }

    private func makeSource(_ name: String) -> BookSource {
        var source = BookSource()
        source.bookSourceName = "Phase 0 \(name)"
        source.bookSourceUrl = "https://phase0-origin.test/\(name)"
        source.searchUrl = "https://phase0-origin.test/\(name)/search?q={{key}}"
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
}

/// Answers each source from a script keyed by `bookSourceUrl`. A source listed in
/// `waitsUntilCancelled` never answers; its task ends when the caller cancels it.
private final class ScriptedOriginFetcher: BookSourceFetching, @unchecked Sendable {
    private let script: [String: Result<[OnlineBook], Error>]
    private let waitsUntilCancelled: Set<String>
    private let lock = NSLock()
    private var queried: [String] = []

    init(_ script: [String: Result<[OnlineBook], Error>], waitsUntilCancelled: Set<String> = []) {
        self.script = script
        self.waitsUntilCancelled = waitsUntilCancelled
    }

    var queriedSourceURLs: [String] {
        lock.withLock { queried }
    }

    func search(query: String, in source: BookSource) async throws -> [OnlineBook] {
        lock.withLock { queried.append(source.bookSourceUrl) }
        if waitsUntilCancelled.contains(source.bookSourceUrl) {
            // Not a timing assumption: this sleep only ends by cancellation, which the
            // service's own timeout triggers.
            try await Task.sleep(nanoseconds: 600 * 1_000_000_000)
        }
        return try script[source.bookSourceUrl]?.get() ?? []
    }

    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> BookInfoPackage {
        throw NSError(domain: "ScriptedOriginFetcher", code: 1)
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool
    ) async throws -> TOCPackage {
        throw NSError(domain: "ScriptedOriginFetcher", code: 2)
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
