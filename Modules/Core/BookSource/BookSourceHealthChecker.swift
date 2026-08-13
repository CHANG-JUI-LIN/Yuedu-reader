import Combine
import Foundation

protocol BookSourceHealthCheckFetching: Sendable {
    func search(
        query: String,
        in source: BookSource,
        page: Int,
        earlyFilter: ((_ name: String, _ author: String) -> Bool)?,
        onHasMore: ((Bool?) -> Void)?,
        failureMode: BookSourceSearchFailureMode
    ) async throws -> [OnlineBook]
    func discoverItems(page: Int, in source: BookSource) async -> [ModernParserBridge.DiscoverItem]
    func discoverBooks(
        from item: ModernParserBridge.DiscoverItem,
        page: Int,
        in source: BookSource
    ) async throws -> [OnlineBook]
    func fetchBookInfo(
        url: String,
        source: BookSource,
        runtimeVariables: [String: String]?
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
}

extension BookSourceFetcher: BookSourceHealthCheckFetching {}

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
    /// 檢查詳情（僅當結果缺少目錄地址時請求）——Legado 中它同時控制目錄/正文檢查
    var checkInfo = true
    /// 檢查目錄（前兩章；關閉時正文也不再檢查，與 Legado 一致）
    var checkCategory = true
    /// 檢查正文（第一章）
    var checkContent = true
    /// Legado `CheckSource.keyword` 的默認測試關鍵字；書源可用 `ruleSearch.checkKeyWord` 覆寫
    var keyword = "我的"
    /// Legado `CheckSource.timeout` —— 單書源整體檢查超時（秒）
    var timeoutSeconds = 180

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
        case .detail:    return localized("書籍詳情")
        case .toc:       return localized("章節目錄")
        case .content:   return localized("正文內容")
        }
    }

    var explanation: String {
        switch self {
        case .search:    return localized("用測試關鍵字搜索並解析結果")
        case .discovery: return localized("解析發現頁第一個分類的書單")
        case .detail:    return localized("僅當結果缺少目錄地址時獲取書籍詳情")
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

/// Why a source failed, mirroring the group names Legado writes onto the source:
/// 搜索鏈接規則為空 / 發現規則為空 / 搜索失效 / 發現失效 / 目錄失效 / 正文失效 /
/// 校驗超時 / js失效 / 網站失效.
enum FailureCategory: Equatable {
    /// 搜索鏈接規則為空 or 發現規則為空 — site responded but the rule is missing
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
        }
    }

    /// Filter bucket used by the results list.
    enum Bucket { case ruleMissing, parseFailed, environment }

    var bucket: Bucket {
        switch self {
        case .ruleMissing: return .ruleMissing
        case .searchFailed, .discoveryFailed, .tocEmpty, .contentEmpty: return .parseFailed
        case .timeout, .jsError, .siteError: return .environment
        }
    }

    /// Legado aborts the current source when a transport/runtime exception escapes
    /// a probe. Only ordinary empty parse results continue to the other track.
    var stopsCurrentSource: Bool {
        switch self {
        case .timeout, .jsError, .siteError: return true
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
    static let shared = BookSourceHealthChecker()

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

    /// How many sources are probed at once. Follows the user's 網路設定 → 並發數,
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
    /// Measured response times awaiting a single batched write — see `flushRespondTimes`.
    private var pendingRespondTimes: [UUID: Int64] = [:]
    private let fetcher: any BookSourceHealthCheckFetching

    init(fetcher: any BookSourceHealthCheckFetching = BookSourceFetcher.shared) {
        self.fetcher = fetcher
    }

    private(set) var finishedCount = 0

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
        cancelled = false
        lastSummary = nil
        items = sources.map { BookSourceCheckItem(source: $0) }
        finishedCount = 0
        publicationTask?.cancel()
        publicationTask = nil
        publicationGate = SearchResultPublicationGate(
            minimumInterval: Self.publicationInterval(for: sources.count)
        )
        requestItemsPublication(force: true)
    }

    func runAll() async {
        guard !items.isEmpty else { return }
        isRunning = true
        cancelled = false
        lastSummary = nil

        let concurrency = maxConcurrent
        let total = items.count
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            SourcePerfTrace.record(
                "sourceCheck.run",
                "sources=\(total) finished=\(finishedCount) concurrency=\(concurrency)",
                since: startedAt,
                thresholdMs: 0
            )
        }
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(concurrency, total) {
                let index = next
                group.addTask { [weak self] in await self?.checkItem(at: index) }
                next += 1
            }
            while await group.next() != nil {
                guard !cancelled, next < total else { continue }
                let index = next
                group.addTask { [weak self] in await self?.checkItem(at: index) }
                next += 1
            }
        }

        flushRespondTimes()
        if !cancelled { applyPolicy() }
        isRunning = false
        cancelled = false
        // The run is over: land the final state immediately rather than waiting out
        // the cadence.
        requestItemsPublication(force: true)
    }

    func cancel() {
        cancelled = true
        isRunning = false
        // Keep the measurements taken before the user stopped.
        flushRespondTimes()
    }

    /// True when a *passing* source's total time exceeds the configured "too slow" threshold.
    func isSlow(_ item: BookSourceCheckItem) -> Bool {
        item.overallPass && item.responseTime > Int64(policy.slowThresholdMs)
    }

    // MARK: - Apply Actions

    /// After a full run, disable/delete bad sources and disable slow ones per the chosen policy.
    private func applyPolicy() {
        let store = BookSourceStore.shared
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
        store.setEnabled(ids: toDisable, enabled: false)
        let deleted = deleteIds.isEmpty ? 0 : store.delete(ids: deleteIds)

        var parts: [String] = []
        if !toDisable.isEmpty { parts.append("\(localized("已停用")) \(toDisable.count)") }
        if deleted > 0 { parts.append("\(localized("已刪除")) \(deleted)") }
        lastSummary = parts.isEmpty ? nil : parts.joined(separator: "，")
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
            objectWillChange.send()

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
        guard items.indices.contains(index) else { return }
        items[index].stages[stage.rawValue] = StageOutcome(status: status, summary: summary)
        requestItemsPublication()
    }

    /// Keep the *first* (earliest root-cause) failure category; later stages don't override it.
    private func recordFailure(at index: Int, _ category: FailureCategory) {
        guard items.indices.contains(index) else { return }
        if items[index].failureCategory == nil {
            items[index].failureCategory = category
            requestItemsPublication()
        }
    }

    private func finishItem(at index: Int, startedAt t0: CFAbsoluteTime) {
        guard items.indices.contains(index) else { return }
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
        finishedCount += 1
        requestItemsPublication()
    }

    private func flushRespondTimes() {
        guard !pendingRespondTimes.isEmpty else { return }
        BookSourceStore.shared.setRespondTimes(pendingRespondTimes)
        pendingRespondTimes.removeAll(keepingCapacity: true)
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
    private func withTimeout<T, E: Error & Sendable>(
        seconds: TimeInterval,
        throwing error: E,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw error
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func checkItem(at index: Int) async {
        guard items.indices.contains(index), !cancelled else { return }
        let t0 = CFAbsoluteTimeGetCurrent()

        do {
            try await withTimeout(
                seconds: TimeInterval(policy.timeoutSeconds),
                throwing: CheckTimeoutError()
            ) {
                try await self.runStages(at: index)
            }
        } catch is CheckTimeoutError {
            markTimedOut(at: index)
        } catch is CancellationError {
            return  // user cancelled; leave partial results as-is
        } catch {
            guard items.indices.contains(index), !cancelled else { return }
            recordFailure(at: index, .siteError)
        }
        finishItem(at: index, startedAt: t0)
    }

    private func markTimedOut(at index: Int) {
        guard items.indices.contains(index) else { return }
        for stage in ValidationStage.allCases {
            switch items[index].outcome(stage).status {
            case .running:
                items[index].stages[stage.rawValue] = StageOutcome(
                    status: .fail, summary: localized("校驗超時")
                )
            case .pending:
                items[index].stages[stage.rawValue] = StageOutcome(status: .skipped, summary: "—")
            default:
                break
            }
        }
        recordFailure(at: index, .timeout)
    }

    private func skipPendingStages(at index: Int) {
        guard items.indices.contains(index) else { return }
        for stage in ValidationStage.allCases
        where items[index].outcome(stage).status == .pending {
            items[index].stages[stage.rawValue] = StageOutcome(status: .skipped, summary: "—")
        }
        requestItemsPublication()
    }

    private func runStages(at index: Int) async throws {
        guard items.indices.contains(index), !cancelled else { return }
        let source = items[index].source

        // Legado validates one track completely before starting the other:
        // search -> checkBook, then discovery -> checkBook. Besides matching its
        // observable order, this prevents an unnecessary discovery request when
        // detail / TOC / content already exposed a fatal transport/runtime error.
        if policy.checkSearch {
            setStage(index, .search, .running)
            let keyword = source.ruleSearch.checkKeyWord
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let testWord = keyword.isEmpty ? policy.keyword : keyword
            let result = await probeSearch(keyword: testWord, source: source)
            guard items.indices.contains(index), !cancelled else { return }
            switch result {
            case .success(let book, let message):
                setStage(index, .search, .pass, message)
                items[index].searchBook = book
                guard await runBookTrack(
                    at: index,
                    track: localized("搜索"),
                    book: book,
                    source: source
                ) else {
                    skipPendingStages(at: index)
                    return
                }
            case .failure(let category, let message):
                setStage(index, .search, .fail, message)
                recordFailure(at: index, category)
                if category.stopsCurrentSource {
                    skipPendingStages(at: index)
                    return
                }
            }
        } else {
            setStage(index, .search, .skipped, "—")
        }

        // Sources without an explore URL simply skip discovery — an empty explore
        // URL is not a failure.
        let hasExplore = source.enabledExplore
            && !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if policy.checkDiscovery, hasExplore {
            setStage(index, .discovery, .running)
            let result = await probeDiscovery(source)
            guard items.indices.contains(index), !cancelled else { return }
            switch result {
            case .success(let book, let message):
                setStage(index, .discovery, .pass, message)
                items[index].discoveryBook = book
                guard await runBookTrack(
                    at: index,
                    track: localized("發現"),
                    book: book,
                    source: source
                ) else {
                    skipPendingStages(at: index)
                    return
                }
            case .failure(let category, let message):
                setStage(index, .discovery, .fail, message)
                recordFailure(at: index, category)
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
        track: String,
        book: OnlineBook,
        source: BookSource
    ) async -> Bool {
        guard items.indices.contains(index), !cancelled else { return false }
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
        let chapter: OnlineChapterRef
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
        track: String,
        operation: () async -> ProbeResult<T>
    ) async -> TrackStageResult<T> {
        guard items.indices.contains(index), !cancelled else {
            return .failure(.siteError)
        }
        let previous = items[index].outcome(stage)
        setStage(index, stage, .running, previous.summary)
        let result = await operation()
        guard items.indices.contains(index), !cancelled else {
            return .failure(.siteError)
        }

        switch result {
        case .success(let value, let message):
            mergeTrackStage(
                at: index,
                stage: stage,
                previous: previous,
                status: .pass,
                summary: "\(track)\(message)"
            )
            return .success(value)
        case .failure(let category, let message):
            mergeTrackStage(
                at: index,
                stage: stage,
                previous: previous,
                status: .fail,
                summary: "\(track)\(message)"
            )
            recordFailure(at: index, category)
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
        guard items.indices.contains(index), items[index].outcome(stage).status == .pending else {
            return
        }
        setStage(index, stage, .skipped, "—")
    }

    // MARK: - Stage probes

    private func probeSearch(keyword: String, source: BookSource) async -> ProbeResult<OnlineBook> {
        let url = source.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            return .failure(.ruleMissing, localized("搜索鏈接規則為空"))
        }
        do {
            let books = try await fetcher.search(
                query: keyword,
                in: source,
                page: 1,
                earlyFilter: nil,
                onHasMore: nil,
                failureMode: .propagateTransportError
            )
            guard let book = books.first(where: {
                !$0.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                return .failure(.searchFailed, localized("搜索失效"))
            }
            return .success(book, "「\(keyword)」\(books.count) \(localized("本"))")
        } catch {
            return .failure(.siteError, error.localizedDescription)
        }
    }

    /// Discover entries usable as actual *content* — excludes `select` filter dropdowns
    /// and `java.startBrowser(...)` login actions, mirroring the live Explore page.
    private func contentSections(
        _ sections: [ModernParserBridge.DiscoverItem]
    ) -> [ModernParserBridge.DiscoverItem] {
        sections.filter { item in
            guard (item.type ?? "") != "select" else { return false }
            let url = (item.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !url.isEmpty && !url.contains("java.startBrowser")
        }
    }

    /// Legado probes only the *first* discover section (`exploreKinds().firstOrNull`).
    /// `discoverItems` parses the exploreUrl rule locally (no request); the single
    /// network request is `discoverBooks` — same one-request cost as Legado's
    /// `exploreBookAwait`.
    private func probeDiscovery(_ source: BookSource) async -> ProbeResult<OnlineBook> {
        do {
            let sections = contentSections(await fetcher.discoverItems(page: 1, in: source))
            guard let section = sections.first else {
                return .failure(.ruleMissing, localized("發現規則為空"))
            }
            let books = try await fetcher.discoverBooks(from: section, page: 1, in: source)
            guard let book = books.first(where: {
                !$0.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                return .failure(.discoveryFailed, localized("發現失效"))
            }
            let title = section.title ?? localized("發現")
            return .success(book, "「\(title)」\(books.count) \(localized("本"))")
        } catch {
            return .failure(.siteError, error.localizedDescription)
        }
    }

    private func probeDetail(book: OnlineBook, source: BookSource) async -> ProbeResult<OnlineBook> {
        let tocUrl = book.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tocUrl.isEmpty else {
            return .success(book, localized("詳情已含目錄地址"))
        }
        do {
            let info = try await fetcher.fetchBookInfo(
                url: book.bookUrl,
                source: source,
                runtimeVariables: book.runtimeVariables
            )
            let name = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .failure(.ruleMissing, localized("詳情為空")) }
            return .success(info, "《\(name)》")
        } catch {
            return .failure(.siteError, error.localizedDescription)
        }
    }

    /// Returns the first loadable (non-volume-separator) chapter of the TOC.
    private func probeTOC(book: OnlineBook, source: BookSource) async -> ProbeResult<OnlineChapterRef> {
        do {
            let chapters = try await fetcher.fetchTOC(
                tocUrl: book.tocUrl,
                source: source,
                runtimeVariables: book.runtimeVariables
            )
            guard let first = chapters.first(where: {
                !$0.shouldRenderAsVolumeSeparator && $0.hasLoadableContentURL
            }) else {
                return .failure(.tocEmpty, localized("目錄失效"))
            }
            return .success(first, "\(localized("章節")) \(chapters.count) \(localized("章"))")
        } catch {
            return .failure(.siteError, error.localizedDescription)
        }
    }

    private func probeContent(
        chapter: OnlineChapterRef, source: BookSource
    ) async -> ProbeResult<Int> {
        do {
            let text = try await fetcher.fetchChapter(
                ref: chapter,
                bookId: UUID(),
                source: source,
                chapterReferer: nil
            )
            let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
            guard count > 0 else { return .failure(.contentEmpty, localized("正文失效")) }
            return .success(count, "\(localized("抓取")) \(count) \(localized("字"))")
        } catch {
            return .failure(.siteError, error.localizedDescription)
        }
    }
}
