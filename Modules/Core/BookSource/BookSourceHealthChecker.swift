import Combine
import Foundation
import os

protocol BookSourceHealthCheckFetching: Sendable {
    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: (@Sendable (_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook]
    /// `search` with a failure kept apart from an empty page (`BookSourceFetcher.searchOutcome`).
    func searchOutcome(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: (@Sendable (_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode,
        usesCache: Bool
    ) async throws -> BookSourceSearchOutcome
    func discoverItems(page: Int, in source: BookSource) async throws -> [ModernParserBridge.DiscoverItem]
    /// The source's explore kinds as Legado's checker reads them (`BookSource.exploreKinds()`):
    /// whether or not 發現 is switched on for the source.
    func exploreKinds(in source: BookSource) async throws -> [ModernParserBridge.DiscoverItem]
    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook]
    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?
    ) async throws -> OnlineBook
    func fetchTOC(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?
    ) async throws -> [OnlineChapterRef]
    func fetchChapter(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> String
    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?,
        usesCache: Bool
    ) async throws -> BookInfoPackage
    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: ((_ chapters: [OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool,
        runPreUpdateJs: Bool,
        writesCache: Bool
    ) async throws -> TOCPackage
    /// `detailPage`: the detail page the probe just read, which a TOC at the book's own URL is
    /// read from (Legado's `tocHtml`).
    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: ((_ chapters: [OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool,
        runPreUpdateJs: Bool,
        writesCache: Bool,
        detailPage: BookDetailPage?
    ) async throws -> TOCPackage
    func fetchChapterPackage(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> ChapterPackage
}

extension BookSourceFetcher: BookSourceHealthCheckFetching {}

extension BookSourceHealthCheckFetching {
    /// A fetcher with no 發現 switch of its own: its kinds are the source's.
    func exploreKinds(in source: BookSource) async throws -> [ModernParserBridge.DiscoverItem] {
        try await discoverItems(page: 1, in: source)
    }

    /// A fetcher that reports no failures: its books, or an empty page.
    func searchOutcome(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: (@Sendable (_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode,
        usesCache: Bool
    ) async throws -> BookSourceSearchOutcome {
        BookSourceSearchOutcome(books: try await search(
            query: query, in: source, page: page,
            earlyFilter: earlyFilter, onHasMore: onHasMore, failureMode: failureMode
        ))
    }

    func fetchBookInfoPackage(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        knownBook: OnlineBook?,
        usesCache: Bool
    ) async throws -> BookInfoPackage {
        let book = try await fetchBookInfo(
            url: url,
            source: source,
            runtimeVariables: runtimeVariables,
            knownBook: knownBook
        )
        return BookInfoPackage(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            bookURL: book.bookUrl,
            name: book.name,
            author: book.author,
            intro: book.intro,
            coverUrl: book.coverUrl,
            tocUrl: book.tocUrl,
            wordCount: book.wordCount,
            lastChapter: book.lastChapter,
            kind: book.kind,
            runtimeVariables: book.runtimeVariables,
            rawHTMLFilename: nil,
            savedAt: Date()
        )
    }

    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: ((_ chapters: [OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool,
        runPreUpdateJs: Bool,
        writesCache: Bool
    ) async throws -> TOCPackage {
        let chapters = try await fetchTOC(
            tocUrl: tocUrl,
            source: source,
            runtimeVariables: runtimeVariables
        )
        onFirstPageReady?(chapters)
        return TOCPackage(
            sourceId: source.id,
            sourceName: source.bookSourceName,
            tocURL: tocUrl,
            runtimeVariables: runtimeVariables,
            chapters: chapters,
            rawHTMLFilename: nil,
            savedAt: Date()
        )
    }

    /// A fetcher that reads every TOC from the site.
    func fetchTOCPackage(
        tocUrl: String,
        source: BookSource,
        runtimeVariables: [String: String]?,
        onFirstPageReady: ((_ chapters: [OnlineChapterRef]) -> Void)?,
        forceRefresh: Bool,
        runPreUpdateJs: Bool,
        writesCache: Bool,
        detailPage: BookDetailPage?
    ) async throws -> TOCPackage {
        try await fetchTOCPackage(
            tocUrl: tocUrl, source: source, runtimeVariables: runtimeVariables,
            onFirstPageReady: onFirstPageReady, forceRefresh: forceRefresh,
            runPreUpdateJs: runPreUpdateJs, writesCache: writesCache
        )
    }

    func fetchChapterPackage(
        ref: OnlineChapterRef,
        bookId: UUID,
        source: BookSource,
        chapterReferer: String?
    ) async throws -> ChapterPackage {
        let content = try await fetchChapter(
            ref: ref,
            bookId: bookId,
            source: source,
            chapterReferer: chapterReferer
        )
        return ChapterPackage(
            bookId: bookId,
            chapterIndex: ref.index,
            sourceURL: ref.url,
            tocTitle: ref.title,
            canonicalTitle: nil,
            content: content,
            contentChecksum: "",
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
    }
}

/// What to do with sources that fail / are too slow, chosen by the user before a run.
struct BookSourceCheckPolicy: Equatable {
    enum BadAction: String, CaseIterable, Identifiable {
        case markOnly   // leave the source as-is, just report
        case disable    // turn the source off
        case delete     // remove the source entirely

        var id: String { rawValue }
        var title: String {
            switch self {
            case .markOnly: return localized("僅標記")
            case .disable:  return localized("停用")
            case .delete:   return localized("刪除")
            }
        }
    }

    var badAction: BadAction = .markOnly
    var disableSlow: Bool = false
    var slowThresholdMs: Int = 8000

    /// Preset "too slow" thresholds (ms) offered in the pre-check options.
    static let slowOptionsMs = [3000, 5000, 8000, 10000]

    // MARK: - Legado CheckSource toggles (all default on, matching Legado)

    /// 檢查搜索（搜索鏈接 + 搜索結果）
    var checkSearch = true
    /// 檢查發現（發現頁第一個分類）
    var checkDiscovery = true
    /// 檢查詳情（實際請求並解析詳情頁）——同時控制目錄/正文檢查
    var checkInfo = true
    /// 檢查目錄（前兩章；關閉時正文也不再檢查，與 Legado 一致）
    var checkCategory = true
    /// 檢查正文（第一章）
    var checkContent = true
    /// Legado `CheckSource.keyword` 的默認測試關鍵字；書源可用 `ruleSearch.checkKeyWord` 覆寫
    var keyword = "我的"
    /// Legado `CheckSource.timeout` —— 單書源整體檢查超時（秒）
    var timeoutSeconds = 180
    /// Legado-E `CheckSource.checkDomain`, off by default as there: connect to the source's
    /// host first and stop at 域名失效 when that fails within two seconds.
    var checkDomain = false
    /// Legado `CheckSource.wSourceComment`, on by default as there: a failed source's comment
    /// starts with `// Error: <reason>`.
    var writesErrorComment = true

    /// Preset overall timeouts (s) offered in the pre-check options.
    static let timeoutOptionsSeconds = [60, 120, 180, 300]
}

// MARK: - Five-item validation model (aligned with Legado CheckSourceService)

/// The five probes run against every source, in run order. Unlike the previous
/// four-stage model there is no separate connectivity HEAD probe: reachability is
/// judged implicitly by the real search/discovery requests, exactly like Legado.
enum ValidationStage: Int, CaseIterable, Identifiable {
    case search = 0
    case discovery
    case detail
    case toc
    case content

    var id: Int { rawValue }

    /// Short label under the stage dot in a result row.
    var title: String {
        switch self {
        case .search:    return localized("搜索")
        case .discovery: return localized("發現")
        case .detail:    return localized("詳情")
        case .toc:       return localized("目錄")
        case .content:   return localized("正文")
        }
    }

    /// Full stage name shown on the prepare page.
    var longTitle: String {
        switch self {
        case .search:    return localized("搜索書籍")
        case .discovery: return localized("發現分類")
        case .detail:    return localized("詳情頁")
        case .toc:       return localized("章節目錄")
        case .content:   return localized("正文內容")
        }
    }

    var explanation: String {
        switch self {
        case .search:    return localized("用測試關鍵字搜索並解析結果")
        case .discovery: return localized("解析發現頁第一個分類的書單")
        case .detail:    return localized("獲取並解析書籍詳情")
        case .toc:       return localized("解析第一本書的章節目錄（前兩章）")
        case .content:   return localized("獲取第一章正文內容")
        }
    }

    var symbol: String {
        switch self {
        case .search:    return "magnifyingglass"
        case .discovery: return "safari"
        case .detail:    return "book"
        case .toc:       return "list.bullet.rectangle"
        case .content:   return "text.alignleft"
        }
    }
}

enum StageStatus: Equatable { case pending, running, pass, fail, skipped }

/// Why a source failed, mirroring the invalid group names Legado writes onto the source:
/// 搜索失效 / 發現失效 / 目錄失效 / 正文失效 / 校驗超時 / js失效 / 網站失效.
enum FailureCategory: Equatable {
    /// 目錄地址為空 — the rule a stage needs produced nothing. (搜索鏈接規則為空 and
    /// 發現規則為空 skip their stage instead: Legado does not count them as invalid.)
    case ruleMissing
    /// 搜索失效 — search ran but produced no book
    case searchFailed
    /// 發現失效 — discovery ran but produced no book
    case discoveryFailed
    /// 目錄失效 — TOC parsed out empty
    case tocEmpty
    /// 正文失效 — chapter body parsed out empty
    case contentEmpty
    /// 校驗超時 — the whole per-source run exceeded the configured timeout
    case timeout
    /// js失效 — a JS exception escaped the rule pipeline
    case jsError
    /// 網站失效 — network / timeout / runtime error
    case siteError
    /// 域名失效 — 檢查域名 could not connect to the source's host (Legado-E `checkDomain`)
    case domainUnreachable

    var title: String {
        switch self {
        case .ruleMissing:    return localized("規則缺失")
        case .searchFailed:   return localized("搜索失效")
        case .discoveryFailed: return localized("發現失效")
        case .tocEmpty:       return localized("目錄失效")
        case .contentEmpty:   return localized("正文失效")
        case .timeout:        return localized("校驗超時")
        case .jsError:        return localized("js失效")
        case .siteError:      return localized("網站失效")
        case .domainUnreachable: return localized("域名失效")
        }
    }

    /// Filter bucket used by the results list.
    enum Bucket { case ruleMissing, parseFailed, environment }

    var bucket: Bucket {
        switch self {
        case .ruleMissing: return .ruleMissing
        case .searchFailed, .discoveryFailed, .tocEmpty, .contentEmpty: return .parseFailed
        case .timeout, .jsError, .siteError, .domainUnreachable: return .environment
        }
    }

    /// Legado aborts the current source when a transport/runtime exception escapes
    /// a probe. Only ordinary empty parse results continue to the other track.
    var stopsCurrentSource: Bool {
        switch self {
        case .timeout, .jsError, .siteError, .domainUnreachable: return true
        case .ruleMissing, .searchFailed, .discoveryFailed, .tocEmpty, .contentEmpty:
            return false
        }
    }
}

struct StageOutcome: Equatable {
    var status: StageStatus = .pending
    var summary: String = ""
}

/// Overall verdict per source, shown as the badge in the source list.
enum SourceHealth: Equatable {
    case passed        // all stages passed → 驗證通過
    case fetchError    // any stage except content failed → 抓取異常
    case contentError  // only content failed → 正文異常
}

/// Persisted per-source outcome so the source list can badge rows after a run,
/// even once the results sheet is closed.
struct SourceValidationSummary: Equatable {
    var health: SourceHealth
    var responseMs: Int64
}

/// Legacy single-state view of an item, kept so old call sites keep compiling.
enum CheckStatus: Equatable { case pending, testing, pass, fail }

struct BookSourceCheckItem: Identifiable {
    let id = UUID()
    let source: BookSource
    var stages: [StageOutcome] = ValidationStage.allCases.map { _ in StageOutcome() }
    var responseTime: Int64 = 0
    var failureCategory: FailureCategory? = nil

    /// Per-track candidates from the search / discovery probes. `nil` when the
    /// track failed or was skipped; detail/toc/content run against whichever
    /// tracks have a book, and any track failure fails the stage (Legado keeps
    /// track-level groups, so one broken track marks the whole source).
    var searchBook: OnlineBook? = nil
    var discoveryBook: OnlineBook? = nil

    /// What each track failed with, for the groups Legado names per track (搜索目录失效…).
    var trackFailures: [ValidationTrack: FailureCategory] = [:]
    /// The failure that ended the check, if one did (校验超时, js失效, 网站失效, 域名失效).
    var abortCategory: FailureCategory? = nil
    /// The first failure's reason, for the `// Error:` comment.
    var failureMessage: String? = nil
    /// Tracks whose rule is empty (搜索链接规则为空, 发现规则为空) — and those whose rule is set,
    /// whose tag a check clears.
    var emptyRuleTracks: Set<ValidationTrack> = []
    var presentRuleTracks: Set<ValidationTrack> = []

    func outcome(_ stage: ValidationStage) -> StageOutcome { stages[stage.rawValue] }

    var isFinished: Bool { !stages.contains { $0.status == .pending || $0.status == .running } }
    var overallPass: Bool { stages.allSatisfy { $0.status == .pass || $0.status == .skipped } }

    var health: SourceHealth? {
        guard isFinished else { return nil }
        if overallPass { return .passed }
        let failed = stages.filter { $0.status == .fail }
        // 正文異常 only when every other stage passed
        if failed.count == 1, outcome(.content).status == .fail {
            return .contentError
        }
        return .fetchError
    }

    /// Legacy overall status mapping.
    var status: CheckStatus {
        if stages.contains(where: { $0.status == .running }) { return .testing }
        guard isFinished else { return .pending }
        return overallPass ? .pass : .fail
    }
}

@MainActor
final class BookSourceHealthChecker: ObservableObject {
    /// Shared so a run keeps going after the user leaves the book-source screen (background check).
    static let shared = BookSourceHealthChecker(background: BookSourceCheckBackgroundTask.shared)

    /// Deliberately NOT `@Published`. A run mutates this array on every stage
    /// transition — five stages, two transitions each, now up to 16 sources in
    /// flight — and publishing each one re-diffed the whole results list. Change
    /// notifications go through `requestItemsPublication`, which coalesces them on
    /// the same bounded cadence the search results list uses.
    private(set) var items: [BookSourceCheckItem] = []

    private var publicationGate = SearchResultPublicationGate(minimumInterval: 0.25)
    private var publicationTask: Task<Void, Never>?

    @Published var isRunning = false
    /// One-line summary of the actions applied after the last completed run (disabled / deleted).
    @Published var lastSummary: String?
    /// Last finished verdict per source id — drives the badges in the source list.
    /// Mutated once per finished source but published through the same coalesced
    /// `objectWillChange` path as `items`. `@Published` here used to bypass that
    /// gate and force up to one full 3,000-row SwiftUI diff per completed source.
    private(set) var healthById: [UUID: SourceValidationSummary] = [:]

    /// The user-chosen handling for bad/slow sources and the Legado check toggles,
    /// set before `runAll()`.
    var policy = BookSourceCheckPolicy()

    /// The most sources probed at once; `BookSourceCheckPacing` narrows from it while the
    /// process spends more CPU than MetricKit allows. Follows the user's 網路設定 → 並發數,
    /// the same knob the search fan-out uses — Legado likewise drives both its
    /// search and its 校验书源 from one `threadCount`. This used to be hard-wired to
    /// 6 with no way to raise it, which is most of why validating a large source
    /// list felt slower here than there.
    private var maxConcurrent: Int {
        Self.effectiveConcurrency(
            configured: GlobalSettings.shared.searchConcurrency,
            sourceCount: items.count
        )
    }

    private var cancelled = false
    enum StopReason: Equatable {
        /// 停止.
        case user
        /// iOS ended the app's background time (`BookSourceCheckBackgroundTask`).
        case backgroundTimeExpired
    }
    /// Why the last run ended before its end; nil while running and for a run that finished.
    /// Read at the publication `cancel()` forces.
    private(set) var stopReason: StopReason?
    /// The run `items` belongs to. `prepare` starts a new one; work of an earlier run that is
    /// still draining after 停止 (a script blocked on its request, a stage between awaits) carries
    /// its own in `checkRun` and lands nothing — it used to write its stages into the next run's
    /// rows, and its loop, seeing `cancelled` reset, started sources over the new list.
    private var runGeneration = 0
    @TaskLocal private static var checkRun: Int = 0
    /// The task-group run of the current `runAll`, cancelled by `cancel()`.
    private var runTask: Task<Void, Never>?
    /// Measured response times awaiting a single batched write — `applyPolicy` at the end of a
    /// run, `flushRespondTimes` when it is cancelled.
    private var pendingRespondTimes: [UUID: Int64] = [:]
    /// The groups and comment of finished sources (`BookSourceCheckMarks`), written with the
    /// respond times.
    private var pendingMarks: [UUID: BookSourceCheckMarks] = [:]
    /// When finished sources were last written mid-run. Legado saves each source as it
    /// finishes; here one save rewrites the whole library, so finished sources land together
    /// at most this often, and a run that ends early — 停止, the app killed in the background —
    /// keeps what it had found.
    private var lastResultsFlush: TimeInterval = 0
    static let resultsFlushInterval: TimeInterval = 30
    private let fetcher: any BookSourceHealthCheckFetching
    /// Where measured response times and the post-run 停用／刪除 policy land.
    private let store: BookSourceStore
    /// What `BookSourceCheckPacing` measures a run's CPU with.
    private let cpuClock: BookSourceCheckCPUClock
    /// When the run narrows to what `BookSourceCheckPacing` allows.
    private let pacingCondition: BookSourceCheckPacingCondition
    /// Keeps a run going once the app leaves the foreground; nil for checkers made in tests.
    private let background: BookSourceCheckBackgroundTask?

    init(
        fetcher: any BookSourceHealthCheckFetching = BookSourceFetcher.shared,
        store: BookSourceStore = .shared,
        cpuClock: BookSourceCheckCPUClock = .live,
        pacingCondition: BookSourceCheckPacingCondition = .live,
        background: BookSourceCheckBackgroundTask? = nil
    ) {
        self.fetcher = fetcher
        self.store = store
        self.cpuClock = cpuClock
        self.pacingCondition = pacingCondition
        self.background = background
    }

    private(set) var finishedCount = 0
    /// Running tallies kept in step with `items`, so the result sheet never filters the
    /// whole run to count or list failures — it used to, five times per render, once per
    /// publication, over every item of a 50,000-source run.
    private(set) var passedCount = 0
    /// Finished, failed items by index, in completion order.
    private(set) var failedIndices: [Int] = []
    private(set) var failedIndicesByBucket: [FailureCategory.Bucket: [Int]] = [:]
    /// Bumped on every coalesced publication; lists key their row refresh off it.
    private(set) var publicationVersion = 0
    /// Sent right after each coalesced publication, with the new state already in place
    /// (`objectWillChange` fires *before* `@Published` changes land, so it cannot be read
    /// from synchronously).
    let didPublish = PassthroughSubject<Void, Never>()

    static func publicationInterval(for sourceCount: Int) -> TimeInterval {
        if sourceCount >= 2_000 { return 1.0 }
        if sourceCount >= 500 { return 0.5 }
        return 0.25
    }

    /// Current Legado validates with a default `threadCount` of 32. Keep the
    /// user's normal network setting for ordinary runs, but do not make packs of
    /// 1,000+ sources use our older 16-wide default for hours. Thirty-two also
    /// matches `BookSourceSession`'s bounded active-session cache.
    static func effectiveConcurrency(configured: Int, sourceCount: Int) -> Int {
        let configured = NetworkSearchSettings.clampedConcurrency(configured)
        return sourceCount >= 1_000 ? max(32, configured) : configured
    }

    func prepare(sources: [BookSource]) {
        // Legado refuses a second run while one is going (`CheckSourceService`); so does this
        // checker — replacing `items` under a live run would hand its tasks the new list.
        guard !isRunning else { return }
        cancelled = false
        stopReason = nil
        lastSummary = nil
        runGeneration += 1
        lastResultsFlush = 0
        // Results of a run that ended are written by then; nothing of one may reach this run.
        pendingRespondTimes.removeAll(keepingCapacity: true)
        pendingMarks.removeAll(keepingCapacity: true)
        items = sources.map { BookSourceCheckItem(source: $0) }
        finishedCount = 0
        passedCount = 0
        failedIndices = []
        failedIndicesByBucket = [:]
        publicationTask?.cancel()
        publicationTask = nil
        publicationGate = SearchResultPublicationGate(
            minimumInterval: Self.publicationInterval(for: sources.count)
        )
        requestItemsPublication(force: true)
    }

    func runAll() async {
        guard !items.isEmpty, !isRunning else { return }
        isRunning = true
        cancelled = false
        stopReason = nil
        lastSummary = nil
        let generation = runGeneration
        background?.runStarted(total: items.count) { [weak self] in
            // iOS is about to suspend the app: end the run as 停止 does, keeping what it found.
            // A source still in flight would otherwise be frozen mid-check and, on return,
            // fail its timeout — a 校验超时 written onto a source that was never slow.
            self?.cancel(reason: .backgroundTimeExpired)
        }
        let run = Task { @MainActor in
            await Self.$checkRun.withValue(generation) {
                await self.runGroup()
            }
        }
        runTask = run
        await run.value
        // A newer run owns the state now; this one only drained.
        guard generation == runGeneration else { return }
        runTask = nil

        if cancelled {
            flushRespondTimes()
        } else {
            applyPolicy()
        }
        background?.runEnded()
        isRunning = false
        cancelled = false
        // The run is over: land the final state immediately rather than waiting out
        // the cadence.
        requestItemsPublication(force: true)
    }

    /// True while `index` is a row of the run this task belongs to and that run was not stopped.
    /// After 停止 the results so far are written at once; a source still draining then — a
    /// request that errors out as the app is suspended, a script parked on its user — must not
    /// add a 网站失效 or 校验超时 that the next write would put onto the source.
    private func isLive(_ index: Int) -> Bool {
        Self.checkRun == runGeneration && !cancelled && items.indices.contains(index)
    }

    private func runGroup() async {
        let total = items.count
        let startedAt = ProcessInfo.processInfo.systemUptime
        // The process's CPU over the run: MetricKit's cpu-exception is a budget of 90 s in
        // 180 s for the whole process, and large runs met it (Crashlytics c0ec35f1, 20727455).
        let cpuAtStart = SourcePerfTrace.processCPU
        var pacing = BookSourceCheckPacing(ceiling: maxConcurrent, start: cpuClock.sample())
        // Pacing follows the CPU at every completion, but its width is used only while
        // `pacingCondition` holds — the device hot, Low Power Mode, or the app in the background
        // — and the run goes at full width otherwise.
        var paced = pacingCondition.isRequired()
        var pacedFinishes = 0
        defer {
            SourcePerfTrace.record(
                "sourceCheck.run",
                "sources=\(total) finished=\(finishedCount) concurrency=\(pacing.ceiling) "
                    + "minWidth=\(pacing.minWidth) pacedFinishes=\(pacedFinishes) "
                    + "cpu=\(String(format: "%.1f", SourcePerfTrace.processCPU - cpuAtStart))s",
                since: startedAt,
                thresholdMs: 0
            )
        }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            var inFlight = 0
            while inFlight < (paced ? pacing.width : pacing.ceiling), next < total {
                let index = next
                group.addTask { [weak self] in await self?.checkItem(at: index) }
                next += 1
                inFlight += 1
            }
            while await group.next() != nil {
                if let change = pacing.sourceFinished(at: cpuClock.sample(), inFlight: inFlight) {
                    SourcePerfTrace.record(
                        "sourceCheck.width",
                        "\(change.from)→\(change.to) cores=\(String(format: "%.2f", change.cores)) "
                            + "inFlight=\(String(format: "%.1f", change.meanInFlight)) "
                            + "trailing=\(String(format: "%.1f", change.trailingCPU))s",
                        since: change.windowStart,
                        thresholdMs: 0
                    )
                }
                inFlight -= 1
                let wasPaced = paced
                paced = pacingCondition.isRequired()
                if paced { pacedFinishes += 1 }
                if paced != wasPaced {
                    SourcePerfTrace.record(
                        "sourceCheck.paced",
                        "\(paced) width=\(paced ? pacing.width : pacing.ceiling)",
                        since: SourcePerfTrace.now,
                        thresholdMs: 0
                    )
                }
                guard !cancelled, !Task.isCancelled, Self.checkRun == runGeneration else {
                    continue
                }
                while inFlight < (paced ? pacing.width : pacing.ceiling), next < total {
                    let index = next
                    group.addTask { [weak self] in await self?.checkItem(at: index) }
                    next += 1
                    inFlight += 1
                }
            }
        }
    }

    func cancel(reason: StopReason = .user) {
        guard isRunning else { return }
        cancelled = true
        stopReason = reason
        isRunning = false
        settleUnfinishedRows()
        // Requests in flight end with the task; a script blocked inside one drains on its own
        // and lands nothing (`isLive`).
        runTask?.cancel()
        runTask = nil
        // Keep the measurements taken before the user stopped.
        flushRespondTimes()
        background?.runEnded()
        requestItemsPublication(force: true)
    }

    /// The sources in flight when the run stopped write nothing more (`isLive`), so their
    /// running stages go back to not started rather than spinning on a stopped run.
    private func settleUnfinishedRows() {
        for index in items.indices
        where items[index].stages.contains(where: { $0.status == .running }) {
            for stage in ValidationStage.allCases
            where items[index].stages[stage.rawValue].status == .running {
                items[index].stages[stage.rawValue] = StageOutcome()
            }
        }
    }

    /// True when a *passing* source's total time exceeds the configured "too slow" threshold.
    func isSlow(_ item: BookSourceCheckItem) -> Bool {
        item.overallPass && item.responseTime > Int64(policy.slowThresholdMs)
    }

    // MARK: - Apply Actions

    /// After a full run, disable/delete bad sources and disable slow ones per the chosen policy,
    /// landing them together with the measured respond times in one store write.
    private func applyPolicy() {
        var disableIds: Set<UUID> = []
        var deleteIds: Set<UUID> = []

        for item in items {
            if item.isFinished, !item.overallPass {
                switch policy.badAction {
                case .markOnly: break
                case .disable:  disableIds.insert(item.source.id)
                case .delete:   deleteIds.insert(item.source.id)
                }
            } else if policy.disableSlow, isSlow(item) {
                disableIds.insert(item.source.id)
            }
        }

        let toDisable = disableIds.subtracting(deleteIds)
        let deleted = store.applyCheckOutcome(
            respondTimes: pendingRespondTimes,
            marks: pendingMarks,
            disable: toDisable,
            delete: deleteIds
        )
        pendingRespondTimes.removeAll(keepingCapacity: true)
        pendingMarks.removeAll(keepingCapacity: true)

        var parts: [String] = []
        if !toDisable.isEmpty { parts.append(String(format: localized("已停用 %d"), toDisable.count)) }
        if deleted > 0 { parts.append(String(format: localized("已刪除 %d"), deleted)) }
        lastSummary = parts.isEmpty ? nil : parts.joined(separator: localized("，"))
    }

    // MARK: - Per-source five-stage run

    /// Coalesced `objectWillChange` for `items`, mirroring
    /// `SearchAggregator.requestResultsPublication`: publish at most every
    /// `minimumInterval`, with one trailing update so the final state always lands.
    private func requestItemsPublication(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        switch publicationGate.request(now: now, force: force) {
        case .publishNow:
            publicationTask?.cancel()
            publicationTask = nil
            publicationGate.didPublish(at: now)
            publicationVersion += 1
            objectWillChange.send()
            didPublish.send()

        case .schedule(let delay):
            guard publicationTask == nil else { return }
            publicationTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.publicationTask = nil
                self.requestItemsPublication()
            }

        case .suppress:
            break
        }
    }

    private func setStage(
        _ index: Int, _ stage: ValidationStage, _ status: StageStatus, _ summary: String = ""
    ) {
        guard isLive(index) else { return }
        items[index].stages[stage.rawValue] = StageOutcome(status: status, summary: summary)
        requestItemsPublication()
    }

    /// Keep the *first* (earliest root-cause) failure category; later stages don't override it.
    /// - Parameter track: the track the failure belongs to, for Legado's per-track groups.
    private func recordFailure(
        at index: Int,
        _ category: FailureCategory,
        message: String,
        track: ValidationTrack? = nil
    ) {
        guard isLive(index) else { return }
        if let track, items[index].trackFailures[track] == nil {
            items[index].trackFailures[track] = category
        }
        if category.stopsCurrentSource, items[index].abortCategory == nil {
            items[index].abortCategory = category
            // Legado's comment holds the exception that ended the check.
            items[index].failureMessage = message
        }
        if items[index].failureMessage == nil {
            items[index].failureMessage = message
        }
        if items[index].failureCategory == nil {
            items[index].failureCategory = category
            requestItemsPublication()
        }
    }

    private func finishItem(at index: Int, startedAt t0: CFAbsoluteTime) {
        guard isLive(index) else { return }
        let elapsed = Int64((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        items[index].responseTime = elapsed
        if let health = items[index].health {
            healthById[items[index].source.id] = SourceValidationSummary(
                health: health, responseMs: elapsed
            )
        }
        // Legado/MD3 persist respondTime as outcome metadata: measured elapsed time
        // on success, configured timeout + elapsed time on failure.
        // Accumulated, not persisted here: writing per source re-encoded the whole
        // source library to disk once per finished source (see `setRespondTimes`).
        // Flushed when the run ends or is cancelled.
        pendingRespondTimes[items[index].source.id] = items[index].overallPass
            ? elapsed
            : Int64(policy.timeoutSeconds) * 1000 + elapsed
        pendingMarks[items[index].source.id] = Self.checkMarks(for: items[index], policy: policy)
        finishedCount += 1
        if items[index].isFinished {
            if items[index].overallPass {
                passedCount += 1
            } else {
                failedIndices.append(index)
                if let bucket = items[index].failureCategory?.bucket {
                    failedIndicesByBucket[bucket, default: []].append(index)
                }
            }
        }
        background?.progress(finished: finishedCount)
        let now = ProcessInfo.processInfo.systemUptime
        if lastResultsFlush == 0 { lastResultsFlush = now }
        if now - lastResultsFlush >= Self.resultsFlushInterval {
            flushRespondTimes()
        }
        requestItemsPublication()
    }

    /// Writes the finished sources' respond times and marks. Named for its first job.
    func flushRespondTimes() {
        lastResultsFlush = ProcessInfo.processInfo.systemUptime
        guard !pendingRespondTimes.isEmpty || !pendingMarks.isEmpty else { return }
        store.recordCheckResults(respondTimes: pendingRespondTimes, marks: pendingMarks)
        pendingRespondTimes.removeAll(keepingCapacity: true)
        pendingMarks.removeAll(keepingCapacity: true)
    }

    /// The groups and comment Legado's `CheckSourceService` leaves on a source after this check.
    static func checkMarks(
        for item: BookSourceCheckItem,
        policy: BookSourceCheckPolicy
    ) -> BookSourceCheckMarks {
        typealias Group = BookSourceCheckMarks.Group
        var marks = BookSourceCheckMarks(writesComment: policy.writesErrorComment)
        for track in [ValidationTrack.search, .discovery] {
            let tag = track == .search ? Group.searchURLEmpty : Group.exploreRuleEmpty
            if item.emptyRuleTracks.contains(track) {
                marks.addGroups.append(tag)
            } else if item.presentRuleTracks.contains(track) {
                marks.removeGroups.append(tag)
            }
            switch item.trackFailures[track] {
            case .searchFailed?: marks.addGroups.append(Group.searchFailed)
            case .discoveryFailed?: marks.addGroups.append(Group.discoveryFailed)
            case .tocEmpty?, .ruleMissing?: marks.addGroups.append(Group.tocFailed(track))
            case .contentEmpty?: marks.addGroups.append(Group.contentFailed(track))
            // A failure that ends the check is named once, for the source, below.
            case .timeout?, .jsError?, .siteError?, .domainUnreachable?, nil: break
            }
        }
        switch item.abortCategory {
        case .timeout?: marks.addGroups.append(Group.timeout)
        case .jsError?: marks.addGroups.append(Group.jsError)
        case .siteError?: marks.addGroups.append(Group.siteError)
        case .domainUnreachable?: marks.addGroups.append(Group.domainUnreachable)
        default: break
        }
        if !item.overallPass {
            // Legado's comment holds the exception that ended the check, or — for a check that
            // ran to its end — the invalid groups it found (`getInvalidGroupNames`).
            let invalid = marks.addGroups.filter(BookSourceCheckMarks.isInvalidGroup)
            marks.errorReason = item.abortCategory == nil && !invalid.isEmpty
                ? invalid.joined(separator: ", ")
                : item.failureMessage ?? item.failureCategory?.title
                    ?? item.stages.first { $0.status == .fail }?.summary ?? ""
        }
        return marks
    }

    private enum ProbeResult<T> {
        case success(T, String)
        case failure(FailureCategory, String)
    }

    private struct CheckTimeoutError: Error, Sendable {}

    /// Whole-source timeout matching Legado / MD3 / Sigma `CheckSource.timeout`.
    /// Individual HTTP, WebView and JS operations retain their own lower-level
    /// bounds. `respondTime` is output metadata used for display/sorting; upstream
    /// Legado does not feed it back as a per-stage timeout.
    private func withTimeout<T: Sendable, E: Error & Sendable>(
        seconds: TimeInterval,
        throwing error: E,
        onTimeout: @escaping @Sendable () -> Void = {},
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                // Before the throw: leaving the group waits for `operation`, and cancellation
                // does not reach a script parked on the user (see `checkItem`).
                onTimeout()
                throw error
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func checkItem(at index: Int) async {
        guard isLive(index), !cancelled else { return }
        let t0 = CFAbsoluteTimeGetCurrent()

        // A script parked on `java.startBrowserAwait` (or a captcha) waits for the user with no
        // deadline and no cancellation, so the timeout ends the source's waits itself: the
        // script raises the dismissal and the check can finish (LegadoUserWaitRegistry).
        let userWaits = BookSourceSession.session(for: items[index].source).userWaits
        let timedOutOnUser = OSAllocatedUnfairLock(initialState: false)
        do {
            try await withTimeout(
                seconds: TimeInterval(policy.timeoutSeconds),
                throwing: CheckTimeoutError(),
                onTimeout: {
                    if userWaits.isWaiting { timedOutOnUser.withLock { $0 = true } }
                    userWaits.cancelAll()
                }
            ) {
                try await self.runStages(at: index)
            }
        } catch is CheckTimeoutError {
            markTimedOut(at: index, waitingForUser: timedOutOnUser.withLock { $0 })
        } catch is CancellationError {
            return  // user cancelled; leave partial results as-is
        } catch {
            guard isLive(index), !cancelled else { return }
            recordFailure(at: index, .siteError, message: error.localizedDescription)
        }
        finishItem(at: index, startedAt: t0)
    }

    /// - Parameter waitingForUser: the source was waiting on a page or captcha for the user
    ///   when time ran out — a step the run cannot take, not a slow site.
    private func markTimedOut(at index: Int, waitingForUser: Bool = false) {
        guard isLive(index) else { return }
        for stage in ValidationStage.allCases {
            switch items[index].outcome(stage).status {
            case .running:
                items[index].stages[stage.rawValue] = StageOutcome(
                    status: .fail,
                    summary: waitingForUser ? localized("需要使用者操作") : localized("校驗超時")
                )
            case .pending:
                items[index].stages[stage.rawValue] = StageOutcome(status: .skipped, summary: "—")
            default:
                break
            }
        }
        recordFailure(
            at: index,
            .timeout,
            message: localized("校驗超時")
        )
    }

    private func skipPendingStages(at index: Int) {
        guard isLive(index) else { return }
        for stage in ValidationStage.allCases
        where items[index].outcome(stage).status == .pending {
            items[index].stages[stage.rawValue] = StageOutcome(status: .skipped, summary: "—")
        }
        requestItemsPublication()
    }

    /// A check that ends before its search (檢查域名): the failure shows on the first dot.
    private func failBeforeSearch(at index: Int, _ category: FailureCategory, _ message: String) {
        guard isLive(index) else { return }
        setStage(index, .search, .fail, message)
        recordFailure(at: index, category, message: message)
        skipPendingStages(at: index)
    }

    private func runStages(at index: Int) async throws {
        guard isLive(index), !cancelled else { return }
        let source = items[index].source

        if policy.checkDomain {
            switch await BookSourceDomainProbe.check(source.bookSourceUrl) {
            case .reachable:
                break
            case .notHTTP:
                // Legado-E throws "源地址不是http链接": the check fails, with no group.
                failBeforeSearch(at: index, .ruleMissing, localized("源地址不是 http 連結"))
                return
            case .unreachable:
                failBeforeSearch(at: index, .domainUnreachable, localized("源地址不可訪問"))
                return
            }
            guard isLive(index), !cancelled else { return }
        }

        // Legado validates one track completely before starting the other:
        // search -> checkBook, then discovery -> checkBook. Besides matching its
        // observable order, this prevents an unnecessary discovery request when
        // detail / TOC / content already exposed a fatal transport/runtime error.
        if policy.checkSearch,
           source.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Legado tags such a source 搜索链接规则为空 and goes on to discovery. The tag is not
            // one of its invalid groups (`BookSource.getInvalidGroupNames` keeps groups holding
            // 失效, and 校验超时), so a discovery-only source passes on its discovery track.
            setStage(index, .search, .skipped, localized("搜索鏈接規則為空"))
            items[index].emptyRuleTracks.insert(.search)
        } else if policy.checkSearch {
            items[index].presentRuleTracks.insert(.search)
            setStage(index, .search, .running)
            // Legado `BookSource.getCheckKeyword(CheckSource.keyword)`: the source's own
            // `checkKeyWord`, else the run's keyword. A title from the bookshelf used to come
            // first, which made a source pass here on a word Legado never searches.
            let testWord = source.checkKeyword(default: policy.keyword)
            let result = await probeSearch(keyword: testWord, source: source)
            guard isLive(index), !cancelled else { return }
            switch result {
            case .success(let book, let message):
                setStage(index, .search, .pass, message)
                items[index].searchBook = book
                guard await runBookTrack(
                    at: index,
                    track: .search,
                    book: book,
                    source: source
                ) else {
                    skipPendingStages(at: index)
                    return
                }
            case .failure(let category, let message):
                setStage(index, .search, .fail, message)
                recordFailure(at: index, category, message: message, track: .search)
                if category.stopsCurrentSource {
                    skipPendingStages(at: index)
                    return
                }
            }
        } else {
            setStage(index, .search, .skipped, "—")
        }

        // Sources without an explore URL simply skip discovery — an empty explore
        // URL is not a failure. Legado checks discovery whenever the URL is set, whether or not
        // the discover page is switched on (`enabledExplore` only hides it from 发现).
        let hasExplore = !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if policy.checkDiscovery, hasExplore {
            setStage(index, .discovery, .running)
            let result = await probeDiscovery(source)
            guard isLive(index), !cancelled else { return }
            switch result {
            case nil:
                // 发现规则为空: like 搜索链接规则为空, a tag Legado does not count as invalid.
                setStage(index, .discovery, .skipped, localized("發現規則為空"))
                items[index].emptyRuleTracks.insert(.discovery)
            case .success(let book, let message):
                setStage(index, .discovery, .pass, message)
                items[index].presentRuleTracks.insert(.discovery)
                items[index].discoveryBook = book
                guard await runBookTrack(
                    at: index,
                    track: .discovery,
                    book: book,
                    source: source
                ) else {
                    skipPendingStages(at: index)
                    return
                }
            case .failure(let category, let message):
                setStage(index, .discovery, .fail, message)
                // Legado clears 发现规则为空 once a kind has a URL, before it fetches; a failing
                // explore script still yields one (its `ERROR:` kind).
                items[index].presentRuleTracks.insert(.discovery)
                recordFailure(at: index, category, message: message, track: .discovery)
                if category.stopsCurrentSource {
                    skipPendingStages(at: index)
                    return
                }
            }
        } else {
            setStage(index, .discovery, .skipped, "—")
        }

        // If neither track produced a book, or a check toggle omitted the shared
        // checkBook chain, close any untouched dots as skipped.
        skipPendingStages(at: index)
    }

    /// Runs Legado's `checkBook` chain for one search/discovery result. Returns
    /// `false` only when an exception category should abort the whole source.
    private func runBookTrack(
        at index: Int,
        track: ValidationTrack,
        book: OnlineBook,
        source: BookSource
    ) async -> Bool {
        guard isLive(index), !cancelled else { return false }
        guard policy.checkInfo else { return true }

        let detail = await runTrackStage(at: index, stage: .detail, track: track) {
            await self.probeDetail(book: book, source: source)
        }
        let resolvedBook: OnlineBook
        switch detail {
        case .success(let book):
            resolvedBook = book
        case .failure(let category):
            return !category.stopsCurrentSource
        }

        guard policy.checkCategory, source.bookSourceType != 3 else {
            markStageSkippedIfPending(at: index, .toc)
            markStageSkippedIfPending(at: index, .content)
            return true
        }

        let toc = await runTrackStage(at: index, stage: .toc, track: track) {
            await self.probeTOC(book: resolvedBook, source: source)
        }
        let chapter: ValidatedChapter
        switch toc {
        case .success(let value):
            chapter = value
        case .failure(let category):
            return !category.stopsCurrentSource
        }

        guard policy.checkContent else {
            markStageSkippedIfPending(at: index, .content)
            return true
        }

        let content = await runTrackStage(at: index, stage: .content, track: track) {
            await self.probeContent(chapter: chapter, source: source)
        }
        switch content {
        case .success:
            return true
        case .failure(let category):
            return !category.stopsCurrentSource
        }
    }

    private enum TrackStageResult<T> {
        case success(T)
        case failure(FailureCategory)
    }

    /// Merges one track's result into the shared five-dot UI without letting a
    /// later successful track erase an earlier failure.
    private func runTrackStage<T>(
        at index: Int,
        stage: ValidationStage,
        track: ValidationTrack,
        operation: () async -> ProbeResult<T>
    ) async -> TrackStageResult<T> {
        let label = track == .search ? localized("搜索") : localized("發現")
        guard isLive(index), !cancelled else {
            return .failure(.siteError)
        }
        let previous = items[index].outcome(stage)
        setStage(index, stage, .running, previous.summary)
        let result = await operation()
        guard isLive(index), !cancelled else {
            return .failure(.siteError)
        }

        switch result {
        case .success(let value, let message):
            mergeTrackStage(
                at: index,
                stage: stage,
                previous: previous,
                status: .pass,
                summary: "\(label)\(message)"
            )
            return .success(value)
        case .failure(let category, let message):
            mergeTrackStage(
                at: index,
                stage: stage,
                previous: previous,
                status: .fail,
                summary: "\(label)\(message)"
            )
            recordFailure(at: index, category, message: message, track: track)
            return .failure(category)
        }
    }

    private func mergeTrackStage(
        at index: Int,
        stage: ValidationStage,
        previous: StageOutcome,
        status: StageStatus,
        summary: String
    ) {
        let finalStatus: StageStatus = previous.status == .fail || status == .fail ? .fail : status
        let oldSummary = previous.summary == "—" ? "" : previous.summary
        let combined = oldSummary.isEmpty ? summary : "\(oldSummary)；\(summary)"
        setStage(index, stage, finalStatus, combined)
    }

    private func markStageSkippedIfPending(at index: Int, _ stage: ValidationStage) {
        guard isLive(index), items[index].outcome(stage).status == .pending else {
            return
        }
        setStage(index, stage, .skipped, "—")
    }

    // MARK: - Stage probes

    /// Runs only for a source with a search URL (`runStages` skips the stage otherwise).
    private func probeSearch(keyword: String, source: BookSource) async -> ProbeResult<OnlineBook> {
        do {
            // The outcome, not just its books: a failed request or rule is the source's cause
            // (HTTP 403, a script exception), which "搜索失效" — no books — used to hide.
            let outcome = try await fetcher.searchOutcome(
                query: keyword,
                in: source,
                page: 1,
                earlyFilter: nil,
                onHasMore: nil,
                failureMode: .propagateTransportError,
                usesCache: false
            )
            switch outcome {
            case .failed(.script(let message)):
                return .failure(.jsError, message)
            case .failed(.http(let code)):
                // Legado reads the body of any status (`newCallStrResponse` checks none), so an
                // error page that lists no books is 搜索失效 and the check goes on to discovery.
                return .failure(.searchFailed, "HTTP \(code)")
            case .failed(let failure):
                return .failure(.siteError, failure.logReason)
            case .empty, .results:
                break
            }
            let books = outcome.books
            guard let book = OnlineBookValidationSelector.firstBook(in: books) else {
                return .failure(.searchFailed, localized("搜索失效"))
            }
            return .success(book, String(format: localized("「%1$@」%2$d 本"), keyword, books.count))
        } catch let ModernParserBridgeError.scriptError(message) {
            return .failure(.jsError, message)
        } catch FetchError.httpError(let code) {
            return .failure(.searchFailed, "HTTP \(code)")
        } catch {
            return .failure(.siteError, error.localizedDescription)
        }
    }

    /// Legado's `exploreKinds().firstOrNull { !it.url.isNullOrBlank() }`: the first kind with
    /// a URL, of any type. One kind is passed over that Legado takes: a `java.startBrowser`
    /// URL opens a page for the reader, which a check running over hundreds of sources must
    /// not do — Legado's opens it in front of the user.
    private func checkedSection(
        _ sections: [ModernParserBridge.DiscoverItem]
    ) -> ModernParserBridge.DiscoverItem? {
        sections.first { item in
            let url = (item.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !url.isEmpty && !url.contains("java.startBrowser")
        }
    }

    /// Legado probes only the *first* discover section. `exploreKinds` reads the exploreUrl
    /// rule (no request unless its script makes one); the single network request is
    /// `discoverBooks` — same one-request cost as Legado's `exploreBookAwait`. `nil` when no
    /// section has a URL (Legado's 发现规则为空).
    private func probeDiscovery(_ source: BookSource) async -> ProbeResult<OnlineBook>? {
        do {
            guard let section = checkedSection(try await fetcher.exploreKinds(in: source)) else {
                return nil
            }
            let books = try await fetcher.discoverBooks(from: section, page: 1, in: source)
            guard let book = OnlineBookValidationSelector.firstBook(in: books) else {
                return .failure(.discoveryFailed, localized("發現失效"))
            }
            let title = section.title ?? localized("發現")
            return .success(book, String(format: localized("「%1$@」%2$d 本"), title, books.count))
        } catch let error as ModernParserBridge.ExploreScriptError {
            return .failure(.jsError, error.message)
        } catch let ModernParserBridgeError.scriptError(message) {
            return .failure(.jsError, message)
        } catch {
            return .failure(.siteError, error.localizedDescription)
        }
    }

    private struct ValidatedChapter {
        let ref: OnlineChapterRef
        let tocURL: String
    }

    /// Legado `checkBook` reads the detail page only for a book without a TOC URL — one from a
    /// search that landed on the book's own page already has it — and fails no book on what
    /// the page held: `getBookInfoAwait` fills what the rules read and keeps the rest.
    private func probeDetail(book: OnlineBook, source: BookSource) async -> ProbeResult<OnlineBook> {
        if !book.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success(book, localized("已含目錄地址"))
        }
        do {
            // `book` is the search/discover result this probe ran against — hand it over so a
            // detail rule that omits a field (the majority omit the title) keeps what the search
            // stage already found, exactly as legado's `analyzeBookInfo` does.
            let package = try await fetcher.fetchBookInfoPackage(
                url: book.bookUrl,
                source: source,
                runtimeVariables: book.runtimeVariables,
                knownBook: book,
                // The site's answer, not a stored one — and not a shelf book either (`probeTOC`).
                usesCache: false
            )
            var info = package.onlineBook
            let name = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if info.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                info.tocUrl = book.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? book.bookUrl
                    : book.tocUrl
            }
            var mergedVariables = book.runtimeVariables ?? [:]
            for (key, value) in package.runtimeVariables ?? [:] {
                mergedVariables[key] = value
            }
            info.runtimeVariables = mergedVariables.isEmpty ? nil : mergedVariables
            return .success(info, name.isEmpty ? localized("詳情") : "《\(name)》")
        } catch let ModernParserBridgeError.scriptError(message) {
            return .failure(.jsError, message)
        } catch {
            return .failure(.siteError, error.localizedDescription)
        }
    }

    /// Legado `checkBook`: the TOC without the volumes that are only headings (`isVolume`
    /// with no URL of their own: Legado gives those their title as one), the first two of the
    /// rest, and the first one's content read up to the second's URL (`nextChapterUrl`).
    ///
    /// The content stage reads chapters through the reader's own path, which opens no volume
    /// heading at all (`shouldRenderAsVolumeSeparator`, a superset of Legado's filter), so every
    /// heading is passed over: Legado would fetch a volume's own page, one this app never shows.
    private func probeTOC(book: OnlineBook, source: BookSource) async -> ProbeResult<ValidatedChapter> {
        let tocURL = book.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tocURL.isEmpty else {
            return .failure(.ruleMissing, localized("目錄地址為空"))
        }
        let startedAt = SourcePerfTrace.now
        var chapterCount = 0
        defer {
            SourcePerfTrace.record(
                "sourceCheck.toc", "chapters=\(chapterCount) \(source.bookSourceName)",
                since: startedAt, thresholdMs: 0
            )
        }
        do {
            let package = try await fetcher.fetchTOCPackage(
                tocUrl: tocURL,
                source: source,
                runtimeVariables: book.runtimeVariables,
                onFirstPageReady: nil,
                forceRefresh: true,
                // Legado's checker calls `getChapterListAwait` with `runPerJs = false` (legado-E,
                // MD3 `BookSourceCheckRepository` agree): `preUpdateJs` is the shelf's refresh
                // hook, not part of reading a TOC.
                runPreUpdateJs: false,
                // The book under test is a search or discovery result, not a shelf book: nothing
                // reads its TOC back, and a run covers thousands of sources (`probeContent`
                // likewise clears the chapter it fetched).
                writesCache: false,
                // Legado's checker reads the TOC through the same `getChapterListAwait`, so a
                // book whose TOC is its own page is not fetched a second time.
                detailPage: book.detailPage
            )
            chapterCount = package.chapters.count
            guard !package.chapters.isEmpty else {
                return .failure(.tocEmpty, localized("目錄失效"))
            }
            let checked = package.chapters
                .filter { !$0.shouldRenderAsVolumeSeparator }
                .prefix(2)
                .map { chapter -> OnlineChapterRef in
                    // Legado's `BookChapterList`: a chapter without a URL is read at the TOC page.
                    var chapter = chapter
                    if !chapter.hasLoadableContentURL { chapter.url = package.tocURL }
                    return chapter
                }
            // Legado's `toc.first()` on a TOC of headings alone throws, and the check ends there
            // as 网站失效 (not `TocEmptyException`, which is an empty list).
            guard var first = checked.first else {
                return .failure(.siteError, localized("目錄只有分卷標題"))
            }
            var mergedVariables = book.runtimeVariables ?? [:]
            for (key, value) in package.runtimeVariables ?? [:] {
                mergedVariables[key] = value
            }
            for (key, value) in first.runtimeVariables ?? [:] {
                mergedVariables[key] = value
            }
            mergedVariables[BookSourceFetcher.nextChapterRuntimeVariableKey] =
                checked.count > 1 ? checked[1].url : first.url
            first.runtimeVariables = mergedVariables
            return .success(
                ValidatedChapter(ref: first, tocURL: package.tocURL),
                String(format: localized("共 %d 章"), package.chapters.count)
            )
        } catch let ModernParserBridgeError.scriptError(message) {
            return .failure(.jsError, message)
        } catch {
            return .failure(.siteError, error.localizedDescription)
        }
    }

    private func probeContent(
        chapter: ValidatedChapter, source: BookSource
    ) async -> ProbeResult<Int> {
        let bookID = UUID()
        let startedAt = SourcePerfTrace.now
        var characters = 0
        defer {
            BookSourceFetcher.shared.clearAllChapterCache(bookId: bookID)
            SourcePerfTrace.record(
                "sourceCheck.content", "chars=\(characters) \(source.bookSourceName)",
                since: startedAt, thresholdMs: 0
            )
        }
        do {
            let package = try await fetcher.fetchChapterPackage(
                ref: chapter.ref,
                bookId: bookID,
                source: source,
                chapterReferer: chapter.tocURL
            )
            let text = package.content
            let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
            characters = count
            guard count > 0 else { return .failure(.contentEmpty, localized("正文失效")) }
            // Text that reads like several chapters passes, as in Legado's `CheckSourceService`,
            // which checks content for being non-empty alone. The reader still logs it
            // (`ChapterFetchManager.isSuspiciousChapterContent`); failing the check on it marked
            // sources Legado reads as broken.
            //
            // One check is the reader's own, made inside `fetchChapterPackage` for every route:
            // a body that is a source API's error envelope or a proxy's error page fails there
            // (`ChapterFetcher.validateResolvedContent`), because the reader shows the reader
            // that error instead of the text. Legado passes such a body as content.
            return .success(count, String(format: localized("抓取 %d 字"), count))
        } catch FetchError.emptyContent {
            // Legado's `ContentEmptyException`: 正文失效, and the check goes on.
            return .failure(.contentEmpty, localized("正文失效"))
        } catch let ModernParserBridgeError.scriptError(message) {
            return .failure(.jsError, message)
        } catch {
            return .failure(.siteError, error.localizedDescription)
        }
    }
}
