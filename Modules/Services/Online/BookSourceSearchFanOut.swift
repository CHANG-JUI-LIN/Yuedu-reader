import Foundation

/// How one book source answered one search request (Phase 4a). Three answers, as the audit
/// asks of every search participant (§11.3): books, a legitimate empty, or a failure; plus
/// Phase 0b's failure the fetcher reports as no results.
enum SearchSourceOutcome: Sendable, Equatable {
    case results
    case empty
    /// The fetch failed and the fetcher reported it as no results (Phase 0b).
    case failedAsEmpty
    case timedOut
    case failed

    /// Answered within its time, whatever it said.
    var answered: Bool {
        switch self {
        case .results, .empty, .failedAsEmpty: true
        case .timedOut, .failed: false
        }
    }
}

/// The fan-out a search over many book sources runs (Phase 4a, extracted from
/// `SearchAggregator`'s first search and 載入更多, which each had a copy): at most
/// `concurrency` sources at a time, each against its own timeout, a source that finishes
/// handing its slot to the next.
///
/// It fetches; it does not merge. The caller merges in `onBatch` / `onAnswer`, which run on
/// the main actor in the order the sources finish.
@MainActor
struct BookSourceSearchFanOut {
    var concurrency: Int
    /// Seconds per source.
    var timeout: UInt64
    /// Seconds per JS-driven source (`timeout(for:normal:aggregate:)`).
    var aggregateTimeout: UInt64
    var fetcher: BookSourceFetcher = .shared

    enum Request: Sendable {
        /// Page 1, streamed: books reach `onBatch` as the source's pages arrive.
        case firstPage(onBatch: @Sendable (BookSource, [OnlineBook]) async -> Void)
        /// A later page (search 9e: fetched by itself after page 1), fetched whole.
        case page(Int)
    }

    struct Answer: Sendable {
        var outcome: SearchSourceOutcome
        /// Books not already handed to `onBatch`.
        var books: [OnlineBook]
        /// The source's own `hasMoreRule` verdict for a later page; nil when unknown.
        var hasMore: Bool?
        var elapsedMs: Double
    }

    /// JS-runtime searchUrls (aggregators + jsLib-backed API sources) get the longer budget;
    /// plain `{{key}}`-template sources stay fail-fast.
    nonisolated static func timeout(for source: BookSource, normal: UInt64, aggregate: UInt64) -> UInt64 {
        source.shouldUseLegadoRuntimeFetch(for: source.searchUrl) ? aggregate : normal
    }

    /// Runs `request` over `sources`. Returns when every source has answered, when
    /// `onAnswer` returns false (the rest are cancelled), or when the calling task is
    /// cancelled; a source still running then is not answered, so a resumed search asks it
    /// again.
    func run(
        query: String,
        sources: [BookSource],
        request: Request,
        onAnswer: (BookSource, Answer) async -> Bool
    ) async {
        let width = min(concurrency, sources.count)
        guard width > 0 else { return }
        let normal = timeout
        let aggregate = aggregateTimeout
        let fetcher = fetcher
        await withTaskGroup(of: (Int, Answer).self) { group in
            var next = 0

            func enqueueNextSource() {
                guard next < sources.count else { return }
                let index = next
                let source = sources[index]
                next += 1
                let sourceTimeout = Self.timeout(for: source, normal: normal, aggregate: aggregate)
                group.addTask {
                    guard !Task.isCancelled else {
                        return (index, Answer(outcome: .failed, books: [], hasMore: nil, elapsedMs: 0))
                    }
                    switch request {
                    case .firstPage(let onBatch):
                        return (index, await Self.firstPage(query: query, source: source, timeout: sourceTimeout, fetcher: fetcher) { books in
                            await onBatch(source, books)
                        })
                    case .page(let page):
                        return (index, await Self.laterPage(query: query, source: source, page: page, timeout: sourceTimeout,
                                                           fetcher: fetcher))
                    }
                }
            }

            for _ in 0..<width {
                enqueueNextSource()
            }

            while let (index, answer) = await group.next() {
                // A pause or a newer search cancels the caller's task. Stop before answering,
                // so the source in flight stays unfinished.
                guard !Task.isCancelled else { break }
                guard await onAnswer(sources[index], answer) else {
                    group.cancelAll()
                    return
                }
                enqueueNextSource()
            }
        }
    }

    // MARK: - One source against its timeout

    /// Page 1, streamed. The search races a sleep; whichever finishes first wins.
    private nonisolated static func firstPage(
        query: String,
        source: BookSource,
        timeout: UInt64,
        fetcher: BookSourceFetcher,
        onBatch: @escaping @Sendable ([OnlineBook]) async -> Void
    ) async -> Answer {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            return try await withThrowingTaskGroup(of: BookSourceFetcher.SearchStreamingOutcome.self) { group in
                group.addTask {
                    try await fetcher.searchStreaming(query: query, in: source, onBatch: onBatch)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                    throw TimeoutError()
                }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
                let outcome: SearchSourceOutcome = result.failure != nil
                    ? .failedAsEmpty
                    : (result.books.isEmpty ? .empty : .results)
                return Answer(outcome: outcome, books: result.streamed ? [] : result.books, hasMore: nil, elapsedMs: elapsedMs)
            }
        } catch is TimeoutError {
            return Answer(outcome: .timedOut, books: [], hasMore: nil, elapsedMs: elapsed(since: startedAt))
        } catch {
            return Answer(outcome: .failed, books: [], hasMore: nil, elapsedMs: elapsed(since: startedAt))
        }
    }

    /// A later page: a plain (non-streaming) search with the same timeout.
    private nonisolated static func laterPage(
        query: String,
        source: BookSource,
        page: Int,
        timeout: UInt64,
        fetcher: BookSourceFetcher
    ) async -> Answer {
        let startedAt = ProcessInfo.processInfo.systemUptime
        do {
            return try await withThrowingTaskGroup(of: (books: [OnlineBook], hasMore: Bool?).self) { group in
                group.addTask {
                    try await fetcher.searchPage(query: query, in: source, page: page)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                    throw TimeoutError()
                }
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
                group.cancelAll()
                return Answer(outcome: result.books.isEmpty ? .empty : .results, books: result.books,
                              hasMore: result.hasMore, elapsedMs: elapsed(since: startedAt))
            }
        } catch is TimeoutError {
            return Answer(outcome: .timedOut, books: [], hasMore: nil, elapsedMs: elapsed(since: startedAt))
        } catch {
            return Answer(outcome: .failed, books: [], hasMore: nil, elapsedMs: elapsed(since: startedAt))
        }
    }

    private nonisolated static func elapsed(since start: TimeInterval) -> Double {
        (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    private struct TimeoutError: Error {}
}
