import Foundation

/// The single cross-source "find this exact book in every enabled source" fan-out.
///
/// 換源 and 封面搜索 ask the same question of the same sources — Legado runs both
/// through `WebBook.searchBookAwait` for the same reason — so the search lives
/// here and each screen only decides what to do with the origins it receives.
/// A second copy of this loop is how the two would drift apart on matching,
/// dedup, timeout and health accounting.
///
/// Results stream per source rather than arriving as one array: a shelf with 400+
/// sources takes minutes to exhaust, and both screens fill in as matches arrive.
@MainActor
enum BookOriginSearchService {

    /// Runs the fan-out until every source has answered, `shouldStop` reports that
    /// enough matches are in (搜索自動暫停), or the surrounding task is cancelled.
    ///
    /// - Parameters:
    ///   - title: the book's title; also the search query, as Legado does.
    ///   - author: used for same-book matching only.
    ///   - concurrency: active sources at a time (網路設定 → 搜索並發數).
    ///   - excludingOriginKey: an origin to hide — 換源 excludes the one in use.
    ///   - sourceFilter: decides whether a source is worth querying at all;
    ///     封面搜索 skips sources whose search rule has no cover field.
    ///   - shouldStop: given the running match count, returns true to stop early.
    ///   - onBatch: one source's matches, already deduped, on the main actor.
    static func stream(
        title: String,
        author: String,
        sources: [BookSource],
        concurrency: Int,
        fetcher: BookSourceFetching,
        excludingOriginKey: String? = nil,
        sourceFilter: ((BookSource) -> Bool)? = nil,
        shouldStop: (Int) -> Bool = { _ in false },
        onBatch: ([BookOrigin]) -> Void
    ) async {
        let queried = sourceFilter.map { filter in sources.filter(filter) } ?? sources
        guard !queried.isEmpty else { return }

        var seenOriginKeys = Set<String>()
        var emittedCount = 0

        await withTaskGroup(of: [OnlineBook]?.self) { group in
            var nextSourceIndex = 0
            let activeLimit = min(max(concurrency, 1), queried.count)

            func enqueueNextSource() {
                guard nextSourceIndex < queried.count else { return }
                let source = queried[nextSourceIndex]
                nextSourceIndex += 1
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    return await searchSourceWithTimeout(
                        query: title,
                        bookTitle: title,
                        bookAuthor: author,
                        source: source,
                        bookSourceFetcher: fetcher
                    )
                }
            }

            for _ in 0..<activeLimit {
                enqueueNextSource()
            }

            while let list = await group.next() {
                if Task.isCancelled { break }
                guard let list else { continue }
                var shouldPause = false
                // Collect the whole source's matches and hand them over once:
                // per-book callbacks re-published (and re-diffed) the caller's
                // list for every single origin.
                var batchOrigins: [BookOrigin] = []
                for ob in list {
                    guard SearchBook.isLikelySameBook(
                        name: title, author: author,
                        name: ob.name, author: ob.author
                    ) else { continue }
                    // Dedup only the same source + URL. Aggregation channels from
                    // different sources may share a URL but remain distinct rules.
                    let originKey = ChangeSourceCache.originKey(
                        sourceId: ob.sourceId, bookUrl: ob.bookUrl)
                    if !originKey.isEmpty {
                        if originKey == excludingOriginKey { continue }
                        guard seenOriginKeys.insert(originKey).inserted else { continue }
                    }
                    batchOrigins.append(
                        BookOrigin(
                            sourceId: ob.sourceId,
                            sourceName: ob.sourceName,
                            bookUrl: ob.bookUrl,
                            tocUrl: ob.tocUrl,
                            coverUrl: ob.coverUrl,
                            intro: ob.intro,
                            lastChapter: ob.lastChapter,
                            wordCount: ob.wordCount,
                            kind: ob.kind,
                            runtimeVariables: ob.runtimeVariables
                        )
                    )
                    if shouldStop(emittedCount + batchOrigins.count) {
                        shouldPause = true
                        break
                    }
                }
                if !batchOrigins.isEmpty {
                    emittedCount += batchOrigins.count
                    onBatch(batchOrigins)
                }
                if shouldPause {
                    group.cancelAll()
                    break
                }
                enqueueNextSource()
            }
        }
    }

    /// One source's search, abandoned after `seconds`. A source that never answers
    /// must not hold an active slot for the whole session.
    nonisolated static func searchSourceWithTimeout(
        query: String,
        bookTitle: String,
        bookAuthor: String,
        source: BookSource,
        bookSourceFetcher: BookSourceFetching,
        seconds: UInt64 = 20
    ) async -> [OnlineBook]? {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let books: [OnlineBook]? = await withTaskGroup(of: [OnlineBook]?.self) { group in
            group.addTask {
                // Early filter (Legado BookList idea): reject non-matching items
                // right after their name/author rules run, so the remaining field
                // rules (cover/intro/kind/wordCount/lastChapter/bookUrl) are never
                // evaluated — both callers only keep exact same-book candidates.
                try? await bookSourceFetcher.search(
                    query: query,
                    in: source,
                    earlyFilter: { name, author in
                        SearchBook.isLikelySameBook(
                            name: bookTitle, author: bookAuthor,
                            name: name, author: author
                        )
                    }
                )
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        if books != nil {
            // Feed the response-time EMA so the 換源 list can rank fast sources first.
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
            let sourceId = source.id
            await MainActor.run {
                SourceHealthStore.shared.recordSuccess(sourceId, responseMs: elapsedMs)
            }
        }
        return books
    }
}
