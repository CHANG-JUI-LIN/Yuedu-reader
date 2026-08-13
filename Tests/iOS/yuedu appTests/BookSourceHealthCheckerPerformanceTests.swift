import Foundation
import Testing
@testable import yuedu_app

@MainActor
struct BookSourceHealthCheckerPerformanceTests {
    private static let liveCorpusEnabled =
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
        checker.prepare(sources: sources)
        let startedAt = ContinuousClock.now
        await checker.runAll()
        let elapsed = ContinuousClock.now - startedAt
        let timing = await fetcher.snapshot()
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000
        print(
            "HEALTH_CHECK_LIVE sources=\(sources.count) finished=\(checker.finishedCount) "
                + "elapsed=\(String(format: "%.3f", seconds))s maxActive=\(timing.maxActive) "
                + "calls=\(timing.callCounts) stageSeconds=\(timing.stageSeconds)"
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
