import Foundation

/// Immutable, bounded data derived from one search origin before SwiftUI renders it.
///
/// `BookOrigin.intro` is controlled by imported source rules and can contain an
/// entire HTML document. Keep that unbounded payload out of `View.body`: rows read
/// this snapshot instead of normalizing the raw metadata again on every redraw.
struct SearchOriginPresentation: Sendable {
    let contentKind: OnlineBookContentKind
    let displayIntro: String
    let introCharacterCount: Int
    let lastChapterTitleCandidate: String
    let introTitleCandidate: String
}

struct PreparedSearchOrigin: Sendable {
    let origin: BookOrigin
    let presentation: SearchOriginPresentation
}

struct PreparedSearchResult: Sendable {
    let book: OnlineBook
    let preparedOrigin: PreparedSearchOrigin
}

/// Stable stack-frame boundaries for watchdog `.ips` reports.
///
/// `os_signpost`/os_log data is useful in Console and sysdiagnose, but it is not
/// guaranteed to be embedded in a normal `.ips` crash report. These deliberately
/// non-inlined functions give symbolicated samples unambiguous stage names instead:
/// `inferContentKind` versus `sanitizeIntroForSearchRow`.
enum SearchResultIPSDiagnostics {
    @inline(never)
    static func snapshotRuntimeModeMarkers(forSourceURL sourceURL: String?) -> [String] {
        OnlineBookContentInference.sourceRuntimeModeMarkers(forSourceURL: sourceURL)
    }

    @inline(never)
    static func inferContentKind(
        _ book: OnlineBook,
        sourceType: Int?,
        modeMarkers: [String]
    ) -> OnlineBookContentKind {
        OnlineBookContentInference.infer(
            sourceType: sourceType,
            runtimeVariables: book.runtimeVariables,
            urls: [book.bookUrl, book.tocUrl],
            metadataText: [book.kind, book.intro, book.lastChapter, book.sourceName]
                + modeMarkers
        )
    }

    @inline(never)
    static func inferContentKind(
        _ origin: BookOrigin,
        sourceType: Int?,
        modeMarkers: [String]
    ) -> OnlineBookContentKind {
        OnlineBookContentInference.infer(
            sourceType: sourceType,
            runtimeVariables: origin.runtimeVariables,
            urls: [origin.bookUrl, origin.tocUrl],
            metadataText: [origin.kind, origin.intro, origin.lastChapter, origin.sourceName]
                + modeMarkers
        )
    }

    @inline(never)
    static func sanitizeIntroForSearchRow(_ rawIntro: String) -> String {
        let raw = ReaderHTMLUtilities.displayText(
            fromHTMLFragment: rawIntro,
            preservingLineBreaks: false
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        let lines = raw.components(separatedBy: .newlines)
        var kept: [String] = []
        for line in lines {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if text.hasPrefix("标签:") || text.hasPrefix("標籤:") { continue }
            if text.hasPrefix("#") && text.count < 30 { continue }
            kept.append(text)
        }

        let joined = kept.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.count <= 100 { return joined }
        let end = joined.index(joined.startIndex, offsetBy: 100)
        return String(joined[..<end]) + "…"
    }

    /// Named frame for future watchdog reports. Build 44 showed the unbounded
    /// equivalent executing inside `AggregatedResultRow.body` on MainActor.
    @inline(never)
    static func normalizeCoverURL(
        _ rawCoverURL: String,
        baseURL: String?
    ) -> String {
        SearchResultCoverURLPolicy.normalizedString(
            rawCoverURL,
            baseURL: baseURL
        )
    }
}

enum SearchResultPresentationBuilder {
    private struct SourceSnapshot: Sendable {
        let url: String?
        let name: String
        let type: Int?
    }

    /// Swift 6.3 approachable concurrency lets a plain nonisolated async function
    /// stay on its caller's actor. A cancellation-linked detached worker is used
    /// deliberately so unbounded metadata work cannot drift back onto MainActor.
    @inline(never)
    static func prepareBatch(
        _ books: [OnlineBook],
        source: BookSource?
    ) async -> [PreparedSearchResult] {
        guard !books.isEmpty else { return [] }

        let snapshot = SourceSnapshot(
            url: source?.bookSourceUrl,
            name: source?.bookSourceName ?? "unknown",
            type: source?.bookSourceType
        )
        let worker = Task.detached(priority: .userInitiated) {
            prepareBatchSynchronously(books, source: snapshot)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    @inline(never)
    private static func prepareBatchSynchronously(
        _ books: [OnlineBook],
        source: SourceSnapshot
    ) -> [PreparedSearchResult] {
        assert(
            !Thread.isMainThread,
            "Search-result presentation must never execute on the main thread"
        )
        let detail = "\(books.count) books source=\(source.name)"
        let modeMarkers = SourcePerfTrace.span(
            "search.presentation.runtimeMarkers",
            detail,
            thresholdMs: 1
        ) {
            SearchResultIPSDiagnostics.snapshotRuntimeModeMarkers(
                forSourceURL: source.url
            )
        }
        let kinds = SourcePerfTrace.span(
            "search.presentation.kindInference",
            detail,
            thresholdMs: 4
        ) {
            var values: [OnlineBookContentKind] = []
            values.reserveCapacity(books.count)
            for book in books {
                guard !Task.isCancelled else { break }
                values.append(autoreleasepool {
                    SearchResultIPSDiagnostics.inferContentKind(
                        book,
                        sourceType: source.type,
                        modeMarkers: modeMarkers
                    )
                })
            }
            return values
        }
        let booksWithKinds = Array(books.prefix(kinds.count))
        let origins = SourcePerfTrace.span(
            "search.presentation.coverURL",
            detail,
            thresholdMs: 4
        ) {
            booksWithKinds.map { book in
                autoreleasepool {
                    Self.makeOrigin(book, sourceBaseURL: source.url)
                }
            }
        }
        let rejectedCoverCount = zip(booksWithKinds, origins).reduce(into: 0) {
            count, pair in
            if !pair.0.coverUrl.isEmpty && pair.1.coverUrl.isEmpty {
                count += 1
            }
        }
        if rejectedCoverCount > 0 {
            AppLogger.parse(
                "⏱ search.presentation.coverURL.rejected "
                    + "count=\(rejectedCoverCount) source=\(source.name.prefix(80))"
            )
        }
        let presentations = SourcePerfTrace.span(
            "search.presentation.introSanitize",
            detail,
            thresholdMs: 4
        ) {
            var values: [SearchOriginPresentation] = []
            values.reserveCapacity(origins.count)
            for (origin, kind) in zip(origins, kinds) {
                guard !Task.isCancelled else { break }
                values.append(autoreleasepool {
                    Self.makePresentation(origin, kind)
                })
            }
            return values
        }

        return zip(booksWithKinds, zip(origins, presentations)).map { element in
            let (book, prepared) = element
            return PreparedSearchResult(
                book: book,
                preparedOrigin: PreparedSearchOrigin(
                    origin: prepared.0,
                    presentation: prepared.1
                )
            )
        }
    }

    /// Compatibility path for direct `SearchBook(origins:)` construction in tests
    /// and non-search callers. Production search batches use `prepareBatch` above.
    static func prepareOrigins(
        _ origins: [BookOrigin],
        sourceStore: BookSourceStore
    ) -> [PreparedSearchOrigin] {
        origins.map { origin in
            let source = sourceStore.sources.first { $0.id == origin.sourceId }
            let kind = SearchResultIPSDiagnostics.inferContentKind(
                origin,
                sourceType: source?.bookSourceType,
                modeMarkers: SearchResultIPSDiagnostics
                    .snapshotRuntimeModeMarkers(forSourceURL: source?.bookSourceUrl)
            )
            return PreparedSearchOrigin(
                origin: origin,
                presentation: makePresentation(origin, kind)
            )
        }
    }

    private static func makeOrigin(
        _ book: OnlineBook,
        sourceBaseURL: String?
    ) -> BookOrigin {
        BookOrigin(
            sourceId: book.sourceId,
            sourceName: book.sourceName,
            bookUrl: book.bookUrl,
            tocUrl: book.tocUrl,
            coverUrl: SearchResultIPSDiagnostics.normalizeCoverURL(
                book.coverUrl,
                baseURL: sourceBaseURL
            ),
            intro: book.intro,
            lastChapter: book.lastChapter,
            wordCount: book.wordCount,
            kind: book.kind,
            runtimeVariables: book.runtimeVariables
        )
    }

    private static func makePresentation(
        _ origin: BookOrigin,
        _ contentKind: OnlineBookContentKind
    ) -> SearchOriginPresentation {
        SearchOriginPresentation(
            contentKind: contentKind,
            displayIntro: SearchResultIPSDiagnostics.sanitizeIntroForSearchRow(origin.intro),
            introCharacterCount: origin.intro.count,
            lastChapterTitleCandidate: cleanDisplayTitle(origin.lastChapter),
            introTitleCandidate: introTitleCandidate(origin.intro)
        )
    }

    static func cleanDisplayTitle(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            let before = text
            if text.hasPrefix("？") || text.hasPrefix("?") {
                text = String(text.dropFirst())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if text.hasPrefix("...") {
                text = String(text.dropFirst(3))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if text.hasPrefix("..") {
                text = String(text.dropFirst(2))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if text.hasPrefix(".") || text.hasPrefix("　") {
                text = String(text.dropFirst())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if before == text { break }
        }
        return text
    }

    static func isOnlyListNumber(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        guard let regex = try? NSRegularExpression(pattern: #"^\s*\d+[\.\、．]?\s*$"#) else {
            return false
        }
        return regex.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
    }

    private static func introTitleCandidate(_ rawIntro: String) -> String {
        let trimmed = rawIntro.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2 else { return "" }
        let cleaned = cleanDisplayTitle(trimmed)
        guard !cleaned.isEmpty else { return "" }
        let end = cleaned.index(cleaned.startIndex, offsetBy: min(30, cleaned.count))
        return String(cleaned[..<end])
    }
}
