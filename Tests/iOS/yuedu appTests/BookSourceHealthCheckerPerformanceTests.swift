import Foundation
import Testing
@testable import yuedu_app

@MainActor
struct BookSourceHealthCheckerPerformanceTests {
    // `nonisolated`: read from `.enabled(if:)`, which is a Sendable closure
    // evaluated outside the suite's actor.
    nonisolated private static let liveCorpusEnabled =
        ProcessInfo.processInfo.environment["RUN_HEALTH_CHECK_LIVE_TESTS"] == "1"
            || ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_HEALTH_CHECK_LIVE_TESTS"] == "1"

    @Test("large source packs coalesce UI publications without throttling network work")
    func largePackPublicationCadence() {
        #expect(BookSourceHealthChecker.publicationInterval(for: 100) == 0.25)
        #expect(BookSourceHealthChecker.publicationInterval(for: 500) == 0.5)
        #expect(BookSourceHealthChecker.publicationInterval(for: 3_000) == 1.0)
        #expect(BookSourceHealthChecker.effectiveConcurrency(configured: 16, sourceCount: 50) == 16)
        #expect(BookSourceHealthChecker.effectiveConcurrency(configured: 16, sourceCount: 3_000) == 32)
        #expect(AppConfig.webViewJSRenderWait == 1.0)
        #expect(AppConfig.webViewExplicitJSWait == 0.1)
    }

    @Test("book-source facade remains cross-source nonisolated")
    func fetcherFacadeIsNotAGlobalActor() {
        // This synchronous access is an intentional compile-time guard. Turning
        // BookSourceFetcher back into an actor would make every source share one
        // executor again and make this line require `await`.
        let _: BookSourceParsingPipeline = BookSourceFetcher.shared.pipeline
    }

    @Test("empty parsed content does not launch heuristic WebView recovery")
    func emptyContentDoesNotLaunchHeuristicWebViewRecovery() async {
        let content = await ChapterFetcher.shared.resolveContent(
            parsed: ChapterParsePayload(
                content: "", title: "Chapter", sourceMatched: true, isPay: false
            )
        )

        #expect(content.isEmpty)
    }

    @Test("three thousand fatal sources finish through the bounded scheduler")
    func threeThousandFatalSourcesFinish() async {
        let fetcher = HealthCheckTransportFailureFetcher()
        let checker = BookSourceHealthChecker(fetcher: fetcher)
        let sources = (0..<3_000).map { index -> BookSource in
            var source = BookSource(
                bookSourceUrl: "https://dead-\(index).example",
                bookSourceName: "dead \(index)"
            )
            source.searchUrl = "https://dead-\(index).example/search?q={{key}}"
            source.exploreUrl = "分類::https://dead-\(index).example/list"
            source.enabledExplore = true
            return source
        }

        checker.prepare(sources: sources)
        let startedAt = ContinuousClock.now
        await checker.runAll()
        let elapsed = ContinuousClock.now - startedAt
        print("validation synthetic 3000 fatal sources: \(elapsed)")

        #expect(await fetcher.calls.count == 3_000)
        #expect(checker.finishedCount == 3_000)
        #expect(elapsed < .seconds(30))
    }

    @Test(
        "real RULE corpus reports health-check throughput",
        .enabled(if: liveCorpusEnabled, "Set RUN_HEALTH_CHECK_LIVE_TESTS=1 for real-network timing"),
        .timeLimit(.minutes(60))
    )
    func realCorpusThroughput() async throws {
        let root = ProcessInfo.processInfo.environment["HEALTH_CHECK_CORPUS_PATH"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HEALTH_CHECK_CORPUS_PATH"]
            ?? "/Users/zhangruilin/Desktop/Test document/RULE"
        let urls = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root, isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension.lowercased() == "json" }

        var sources: [BookSource] = []
        for url in urls {
            var data = try Data(contentsOf: url)
            if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
            if let decoded = try? JSONDecoder().decode([BookSource].self, from: data) {
                sources.append(contentsOf: decoded)
            } else {
                sources.append(try JSONDecoder().decode(BookSource.self, from: data))
            }
        }
        #expect(!sources.isEmpty)

        let sharedFetcher = BookSourceFetcher.shared
        try? FileManager.default.removeItem(at: sharedFetcher.bookInfoCacheDir())
        try? FileManager.default.removeItem(at: sharedFetcher.tocCacheDir())
        let fetcher = TimedHealthCheckFetcher()
        let checker = BookSourceHealthChecker(fetcher: fetcher)
        WebViewFetcher.shared.resetPerformanceMetrics()
        checker.prepare(sources: sources)
        let startedAt = ContinuousClock.now
        await checker.runAll()
        let elapsed = ContinuousClock.now - startedAt
        let timing = await fetcher.snapshot()
        let webViewTiming = WebViewFetcher.shared.performanceSnapshot()
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        print(
            "HEALTH_CHECK_LIVE sources=\(sources.count) finished=\(checker.finishedCount) "
                + "elapsed=\(String(format: "%.3f", seconds))s maxActive=\(timing.maxActive) "
                + "calls=\(timing.callCounts) stageSeconds=\(timing.stageSeconds) "
                + "webViewPeak=\(webViewTiming.peakActiveCount) "
                + "webViewQueued=\(webViewTiming.queuedLeaseCount) "
                + "webViewQueueSeconds=\(String(format: "%.3f", webViewTiming.queuedLeaseSeconds))"
        )
        let slowest = checker.items
            .sorted { $0.responseTime > $1.responseTime }
            .prefix(20)
            .map { LiveTimingReport.SourceTime(name: $0.source.bookSourceName, milliseconds: $0.responseTime) }
        let report = LiveTimingReport(
            sourceCount: sources.count,
            finishedCount: checker.finishedCount,
            elapsedSeconds: seconds,
            maxActive: timing.maxActive,
            callCounts: timing.callCounts,
            stageSeconds: timing.stageSeconds,
            webViewPeakActive: webViewTiming.peakActiveCount,
            webViewQueuedLeaseCount: webViewTiming.queuedLeaseCount,
            webViewQueuedLeaseSeconds: webViewTiming.queuedLeaseSeconds,
            slowestSources: Array(slowest)
        )
        let reportPath = ProcessInfo.processInfo.environment["HEALTH_CHECK_REPORT_PATH"]
            ?? ProcessInfo.processInfo.environment["TEST_RUNNER_HEALTH_CHECK_REPORT_PATH"]
            ?? "/tmp/yuedu_health_check_real50_timing.json"
        let reportData = try JSONEncoder().encode(report)
        try reportData.write(to: URL(fileURLWithPath: reportPath), options: .atomic)

        #expect(checker.finishedCount == sources.count)
        #expect(timing.maxActive > 1)
    }

    @Test("transport failure aborts one source before discovery")
    func transportFailureIsFailFast() async {
        let fetcher = HealthCheckTransportFailureFetcher()
        let checker = BookSourceHealthChecker(fetcher: fetcher)
        var source = BookSource(bookSourceUrl: "https://unreachable.example", bookSourceName: "dead")
        source.searchUrl = "https://unreachable.example/search?q={{key}}"
        source.exploreUrl = "分類::https://unreachable.example/list"
        source.enabledExplore = true

        checker.prepare(sources: [source])
        await checker.runAll()

        #expect(await fetcher.calls == ["search"])
        #expect(checker.items[0].outcome(.search).status == .fail)
        #expect(checker.items[0].outcome(.discovery).status == .skipped)
        #expect(checker.items[0].outcome(.detail).status == .skipped)
        #expect(checker.items[0].failureCategory == .siteError)
    }

    @Test("bookshelf title is the primary source-specific search probe")
    func bookshelfTitleReplacesGenericValidationKeyword() async {
        let fetcher = HealthCheckKeywordCaptureFetcher()
        let checker = BookSourceHealthChecker(fetcher: fetcher)
        var source = BookSource(
            bookSourceUrl: "https://shelf-keyword.example",
            bookSourceName: "shelf keyword"
        )
        source.searchUrl = "https://shelf-keyword.example/search?q={{key}}"
        source.ruleSearch.checkKeyWord = "stale source keyword"
        checker.policy.checkDiscovery = false
        checker.policy.checkInfo = false

        checker.prepare(
            sources: [source],
            preferredSearchKeywords: [source.id: "Known Shelf Novel"]
        )
        await checker.runAll()

        #expect(await fetcher.queries == ["Known Shelf Novel"])
        #expect(checker.items[0].outcome(.search).status == .pass)
    }

    @Test("text source validation skips an explicitly typed audio result")
    func textSourceSelectsDeclaredPrimaryContent() async {
        let fetcher = HealthCheckMixedContentFetcher()
        let checker = BookSourceHealthChecker(fetcher: fetcher)
        var source = BookSource(
            bookSourceUrl: "https://mixed-content.example",
            bookSourceName: "mixed content"
        )
        source.bookSourceType = 0
        source.searchUrl = "https://mixed-content.example/search?q={{key}}"
        checker.policy.checkDiscovery = false

        checker.prepare(sources: [source])
        await checker.runAll()

        #expect(checker.items[0].searchBook?.name == "text result")
        #expect(checker.items[0].overallPass)
        #expect(await fetcher.detailURLs == ["https://mixed-content.example/text"])
        #expect(await fetcher.chapterReferers == ["https://mixed-content.example/text/toc"])
        let contentVariables = (await fetcher.contentRuntimeVariables).first ?? nil
        #expect(contentVariables?["detail.scope"] == "detail")
        #expect(contentVariables?["toc.scope"] == "toc")
        #expect(contentVariables?["chapter.scope"] == "chapter")
    }

    @Test("source validation rejects an upstream error page returned as chapter text")
    func transportErrorPageCannotPassContentValidation() async {
        let fetcher = HealthCheckMixedContentFetcher(
            chapterContent: """
            <!doctype html><html><head><title>Web server is down</title></head>
            <body><div>cloudflare</div><span>Error code 522</span>
            <footer>Visit cloudflare.com</footer></body></html>
            """
        )
        let checker = BookSourceHealthChecker(fetcher: fetcher)
        var source = BookSource(
            bookSourceUrl: "https://transport-error-content.example",
            bookSourceName: "transport error content"
        )
        source.bookSourceType = 0
        source.searchUrl = "https://transport-error-content.example/search?q={{key}}"
        checker.policy.checkDiscovery = false

        checker.prepare(sources: [source])
        await checker.runAll()

        #expect(checker.items[0].outcome(.search).status == .pass)
        #expect(checker.items[0].outcome(.detail).status == .pass)
        #expect(checker.items[0].outcome(.toc).status == .pass)
        #expect(checker.items[0].outcome(.content).status == .fail)
        #expect(checker.items[0].failureCategory == .siteError)
        #expect(!checker.items[0].overallPass)
    }

    @Test("validation candidate selection respects declared and unknown content types")
    func declaredContentSelectionContract() {
        var textSource = BookSource(
            bookSourceUrl: "https://selection.example/text",
            bookSourceName: "text"
        )
        textSource.bookSourceType = 0
        var audioSource = textSource
        audioSource.bookSourceType = 1

        func book(_ name: String, type: String?) -> OnlineBook {
            OnlineBook(
                name: name,
                author: "",
                intro: "",
                coverUrl: "",
                bookUrl: "https://selection.example/\(name)",
                tocUrl: "",
                wordCount: "",
                lastChapter: "",
                kind: "",
                sourceId: textSource.id,
                sourceName: textSource.bookSourceName,
                runtimeVariables: type.map { ["book.type": $0] }
            )
        }

        let audio = book("audio", type: "32")
        let text = book("text", type: "8")
        let manga = book("manga", type: "64")
        let unknown = book("unknown", type: nil)

        #expect(OnlineBookValidationSelector.preferredBook(
            from: [audio, text], for: textSource
        )?.name == "text")
        #expect(OnlineBookValidationSelector.preferredBook(
            from: [text, audio], for: audioSource
        )?.name == "audio")
        #expect(OnlineBookValidationSelector.preferredBook(
            from: [audio, unknown], for: textSource
        )?.name == "unknown")
        #expect(OnlineBookValidationSelector.preferredBook(
            from: [audio, manga], for: textSource
        ) == nil)
    }

    @Test("detail transport failure aborts before discovery")
    func detailFailureStopsBeforeDiscovery() async {
        let fetcher = HealthCheckDetailFailureFetcher()
        let checker = BookSourceHealthChecker(fetcher: fetcher)
        var source = BookSource(bookSourceUrl: "https://detail-failure.example", bookSourceName: "dead detail")
        source.searchUrl = "https://detail-failure.example/search?q={{key}}"
        source.exploreUrl = "分類::https://detail-failure.example/list"
        source.enabledExplore = true

        checker.prepare(sources: [source])
        await checker.runAll()

        #expect(await fetcher.calls == ["search", "detail"])
        #expect(checker.items[0].outcome(.search).status == .pass)
        #expect(checker.items[0].outcome(.detail).status == .fail)
        #expect(checker.items[0].outcome(.discovery).status == .skipped)
        #expect(checker.items[0].outcome(.toc).status == .skipped)
        #expect(checker.items[0].failureCategory == .siteError)
    }

    @Test("cancelled per-host waiter releases its validation worker immediately")
    func cancelledPerHostWaiterExitsQueue() async throws {
        let host = "cancel-\(UUID().uuidString)"
        let blocker = AsyncValidationBlocker()
        let first = Task {
            try await PerHostSemaphore.shared.withLock(host: host, maxConcurrent: 1) {
                await blocker.hold()
                return true
            }
        }
        await blocker.waitUntilHeld()

        let queued = Task {
            try await PerHostSemaphore.shared.withLock(host: host, maxConcurrent: 1) { true }
        }
        while await PerHostSemaphore.shared.queuedRequestCount(for: host) == 0 {
            await Task.yield()
        }
        queued.cancel()

        let deadline = ContinuousClock.now + .seconds(1)
        while await PerHostSemaphore.shared.queuedRequestCount(for: host) != 0,
              ContinuousClock.now < deadline {
            await Task.yield()
        }
        let queueDrained = await PerHostSemaphore.shared.queuedRequestCount(for: host) == 0
        #expect(queueDrained)

        await blocker.release()
        _ = try await first.value
        _ = try? await queued.value
    }

    @Test("cancelled WebView lease stops waiting without a pool release")
    func cancelledWebViewLeaseExitsQueue() async {
        let waiter = WebViewLeaseWait()
        let task = Task { @MainActor in try await waiter.value() }
        while !waiter.isWaiting { await Task.yield() }

        task.cancel()
        while waiter.isWaiting { await Task.yield() }

        do {
            _ = try await task.value
            Issue.record("cancelled WebView lease unexpectedly acquired a view")
        } catch is CancellationError {
            // Expected: cancellation resumes the queued continuation immediately.
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

private struct LiveTimingReport: Codable {
    struct SourceTime: Codable {
        let name: String
        let milliseconds: Int64
    }

    let sourceCount: Int
    let finishedCount: Int
    let elapsedSeconds: Double
    let maxActive: Int
    let callCounts: [String: Int]
    let stageSeconds: [String: Double]
    let webViewPeakActive: Int
    let webViewQueuedLeaseCount: Int
    let webViewQueuedLeaseSeconds: Double
    let slowestSources: [SourceTime]
}

private actor AsyncValidationBlocker {
    private var held = false
    private var holdContinuation: CheckedContinuation<Void, Never>?
    private var startContinuations: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        held = true
        for continuation in startContinuations { continuation.resume() }
        startContinuations.removeAll()
        await withCheckedContinuation { holdContinuation = $0 }
    }

    func waitUntilHeld() async {
        if held { return }
        await withCheckedContinuation { startContinuations.append($0) }
    }

    func release() {
        holdContinuation?.resume()
        holdContinuation = nil
    }
}

private actor HealthCheckTransportFailureFetcher: BookSourceHealthCheckFetching {
    private(set) var calls: [String] = []

    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        calls.append("search")
        throw URLError(.timedOut)
    }

    func discoverItems(
        page: Int,
        in source: BookSource
    ) async -> [ModernParserBridge.DiscoverItem] {
        calls.append("discoverItems")
        return [.init(title: "分類", url: "https://unreachable.example/list")]
    }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook] {
        calls.append("discoverBooks")
        return []
    }

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> OnlineBook {
        calls.append("detail")
        throw URLError(.timedOut)
    }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] {
        calls.append("toc")
        throw URLError(.timedOut)
    }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String {
        calls.append("content")
        throw URLError(.timedOut)
    }
}

private actor HealthCheckKeywordCaptureFetcher: BookSourceHealthCheckFetching {
    private(set) var queries: [String] = []

    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        queries.append(query)
        return [OnlineBook(
            name: query,
            author: "",
            intro: "",
            coverUrl: "",
            bookUrl: "https://shelf-keyword.example/book/1",
            tocUrl: "",
            wordCount: "",
            lastChapter: "",
            kind: "",
            sourceId: source.id,
            sourceName: source.bookSourceName
        )]
    }

    func discoverItems(
        page: Int,
        in source: BookSource
    ) async -> [ModernParserBridge.DiscoverItem] { [] }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook] { [] }

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> OnlineBook { throw URLError(.unsupportedURL) }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] { [] }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String { "" }
}

private actor HealthCheckMixedContentFetcher: BookSourceHealthCheckFetching {
    private let chapterContent: String
    private(set) var detailURLs: [String] = []
    private(set) var chapterReferers: [String?] = []
    private(set) var contentRuntimeVariables: [[String: String]?] = []

    init(chapterContent: String = "content") {
        self.chapterContent = chapterContent
    }

    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        [
            book(
                name: "audio result",
                url: "https://mixed-content.example/audio",
                type: "32",
                source: source
            ),
            book(
                name: "text result",
                url: "https://mixed-content.example/text",
                tocURL: "https://mixed-content.example/text/embedded-toc",
                type: "8",
                source: source
            ),
        ]
    }

    func discoverItems(
        page: Int,
        in source: BookSource
    ) async -> [ModernParserBridge.DiscoverItem] { [] }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook] { [] }

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> OnlineBook {
        detailURLs.append(url)
        return book(
            name: url.hasSuffix("/audio") ? "audio detail" : "text detail",
            url: url,
            tocURL: url + "/toc",
            type: url.hasSuffix("/audio") ? "32" : "8",
            source: source
        )
    }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] {
        guard tocUrl.contains("/text/") else { return [] }
        return [OnlineChapterRef(index: 0, title: "chapter", url: tocUrl + "/1")]
    }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String { chapterContent }

    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> BookInfoPackage {
        let info = try await fetchBookInfo(
            url: url,
            source: source,
            runtimeVariables: runtimeVariables
        )
        var variables = info.runtimeVariables ?? [:]
        variables["detail.scope"] = "detail"
        return BookInfoPackage(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            bookURL: info.bookUrl,
            name: info.name,
            author: info.author,
            intro: info.intro,
            coverUrl: info.coverUrl,
            tocUrl: info.tocUrl,
            wordCount: info.wordCount,
            lastChapter: info.lastChapter,
            kind: info.kind,
            runtimeVariables: variables,
            rawHTMLFilename: nil,
            savedAt: Date()
        )
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: (([OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool,
        runPreUpdateJs: Bool
    ) async throws -> TOCPackage {
        var chapters = try await fetchTOC(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables
        )
        chapters[0].runtimeVariables = ["chapter.scope": "chapter"]
        onFirstPageReady?(chapters)
        return TOCPackage(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            tocURL: tocUrl,
            runtimeVariables: ["toc.scope": "toc"],
            chapters: chapters,
            rawHTMLFilename: nil,
            savedAt: Date()
        )
    }

    func fetchChapterPackage(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> ChapterPackage {
        chapterReferers.append(chapterReferer)
        contentRuntimeVariables.append(ref.runtimeVariables)
        return ChapterPackage(
            bookId: bookId,
            chapterIndex: ref.index,
            sourceURL: ref.url,
            tocTitle: ref.title,
            canonicalTitle: nil,
            content: chapterContent,
            contentChecksum: "",
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
    }

    private func book(
        name: String,
        url: String,
        tocURL: String = "",
        type: String,
        source: BookSource
    ) -> OnlineBook {
        OnlineBook(
            name: name,
            author: "",
            intro: "",
            coverUrl: "",
            bookUrl: url,
            tocUrl: tocURL,
            wordCount: "",
            lastChapter: "",
            kind: "",
            sourceId: source.id,
            sourceName: source.bookSourceName,
            runtimeVariables: ["book.type": type]
        )
    }
}

private actor HealthCheckDetailFailureFetcher: BookSourceHealthCheckFetching {
    private(set) var calls: [String] = []

    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        calls.append("search")
        return [OnlineBook(
            name: "result",
            author: "author",
            intro: "",
            coverUrl: "",
            bookUrl: "https://detail-failure.example/book/1",
            tocUrl: "",
            wordCount: "",
            lastChapter: "",
            kind: "",
            sourceId: source.id,
            sourceName: source.bookSourceName
        )]
    }

    func discoverItems(
        page: Int,
        in source: BookSource
    ) async -> [ModernParserBridge.DiscoverItem] {
        calls.append("discoverItems")
        return [.init(title: "分類", url: "https://detail-failure.example/list")]
    }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook] {
        calls.append("discoverBooks")
        return []
    }

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> OnlineBook {
        calls.append("detail")
        throw URLError(.timedOut)
    }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] {
        calls.append("toc")
        return []
    }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String {
        calls.append("content")
        return ""
    }
}


private actor TimedHealthCheckFetcher: BookSourceHealthCheckFetching {
    struct Snapshot: Sendable {
        let maxActive: Int
        let callCounts: [String: Int]
        let stageSeconds: [String: Double]
    }

    private let base = BookSourceFetcher.shared
    private var active = 0
    private var maxActive = 0
    private var callCounts: [String: Int] = [:]
    private var stageSeconds: [String: Double] = [:]

    private func begin(_ stage: String) -> TimeInterval {
        active += 1
        maxActive = max(maxActive, active)
        callCounts[stage, default: 0] += 1
        return ProcessInfo.processInfo.systemUptime
    }

    private func end(_ stage: String, _ start: TimeInterval) {
        active -= 1
        stageSeconds[stage, default: 0] += ProcessInfo.processInfo.systemUptime - start
    }

    func snapshot() -> Snapshot {
        Snapshot(maxActive: maxActive, callCounts: callCounts, stageSeconds: stageSeconds)
    }

    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook] {
        let start = begin("search")
        defer { end("search", start) }
        return try await base.search(
            query: query,
            in: source,
            page: page,
            earlyFilter: earlyFilter,
            onHasMore: onHasMore,
            failureMode: failureMode
        )
    }

    func discoverItems(page: Int, in source: BookSource) async -> [ModernParserBridge.DiscoverItem] {
        let start = begin("discoverItems")
        defer { end("discoverItems", start) }
        return await base.discoverItems(page: page, in: source)
    }

    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook] {
        let start = begin("discoverBooks")
        defer { end("discoverBooks", start) }
        return try await base.discoverBooks(from: item, page: page, in: source)
    }

    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> OnlineBook {
        let start = begin("detail")
        defer { end("detail", start) }
        return try await base.fetchBookInfo(
            url: url,
            source: source,
            runtimeVariables: runtimeVariables
        )
    }

    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef] {
        let start = begin("toc")
        defer { end("toc", start) }
        return try await base.fetchTOC(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables
        )
    }

    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String {
        let start = begin("content")
        defer { end("content", start) }
        return try await base.fetchChapter(
            ref: ref,
            bookId: bookId,
            source: source,
            chapterReferer: chapterReferer
        )
    }
}
