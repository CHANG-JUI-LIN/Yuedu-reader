import Combine
import Foundation

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

    @Published var items: [BookSourceCheckItem] = []
    @Published var isRunning = false
    /// One-line summary of the actions applied after the last completed run (disabled / deleted).
    @Published var lastSummary: String?
    /// Last finished verdict per source id — drives the badges in the source list.
    @Published var healthById: [UUID: SourceValidationSummary] = [:]

    /// The user-chosen handling for bad/slow sources and the Legado check toggles,
    /// set before `runAll()`.
    var policy = BookSourceCheckPolicy()

    /// At most this many sources are probed at once, keeping timings meaningful.
    private static let maxConcurrent = 6

    private var cancelled = false
    private let fetcher = BookSourceFetcher.shared

    var finishedCount: Int { items.filter(\.isFinished).count }

    func prepare(sources: [BookSource]) {
        cancelled = false
        lastSummary = nil
        items = sources.map { BookSourceCheckItem(source: $0) }
    }

    func runAll() async {
        guard !items.isEmpty else { return }
        isRunning = true
        cancelled = false
        lastSummary = nil

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            let total = items.count
            while next < min(Self.maxConcurrent, total) {
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

        if !cancelled { applyPolicy() }
        isRunning = false
        cancelled = false
    }

    func cancel() {
        cancelled = true
        isRunning = false
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
        for id in toDisable { store.setEnabled(id: id, enabled: false) }
        let deleted = deleteIds.isEmpty ? 0 : store.delete(ids: deleteIds)

        var parts: [String] = []
        if !toDisable.isEmpty { parts.append("\(localized("已停用")) \(toDisable.count)") }
        if deleted > 0 { parts.append("\(localized("已刪除")) \(deleted)") }
        lastSummary = parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    // MARK: - Per-source five-stage run

    private func setStage(
        _ index: Int, _ stage: ValidationStage, _ status: StageStatus, _ summary: String = ""
    ) {
        guard items.indices.contains(index) else { return }
        items[index].stages[stage.rawValue] = StageOutcome(status: status, summary: summary)
    }

    /// Keep the *first* (earliest root-cause) failure category; later stages don't override it.
    private func recordFailure(at index: Int, _ category: FailureCategory) {
        guard items.indices.contains(index) else { return }
        if items[index].failureCategory == nil {
            items[index].failureCategory = category
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
        // Legado (CheckSourceService.checkSource): respondTime doubles as the adaptive
        // request timeout — measured elapsed time on success, timeout+elapsed on failure.
        let respondTime = items[index].overallPass
            ? elapsed
            : Int64(policy.timeoutSeconds) * 1000 + elapsed
        BookSourceStore.shared.setRespondTime(id: items[index].source.id, ms: respondTime)
    }

    private enum ProbeResult<T> {
        case success(T, String)
        case failure(FailureCategory, String)
    }

    private struct CheckTimeoutError: Error {}

    /// Whole-source timeout matching Legado `CheckSource.timeout` (default 180 s).
    private func withOverallTimeout<T>(
        seconds: Int, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CheckTimeoutError()
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
            try await withOverallTimeout(seconds: policy.timeoutSeconds) {
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

    private func runStages(at index: Int) async throws {
        guard items.indices.contains(index), !cancelled else { return }
        let source = items[index].source

        // Stage 1 — search track (搜索)
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
            case .failure(let category, let message):
                setStage(index, .search, .fail, message)
                recordFailure(at: index, category)
            }
        } else {
            setStage(index, .search, .skipped, "—")
        }

        // Stage 2 — discovery track (發現). Like Legado, sources without an explore URL
        // simply skip discovery — an empty explore URL is not a failure.
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
            case .failure(let category, let message):
                setStage(index, .discovery, .fail, message)
                recordFailure(at: index, category)
            }
        } else {
            setStage(index, .discovery, .skipped, "—")
        }

        // Stages 3–5 — detail / toc / content across every track that produced a book
        // (Legado checkBook). checkInfo gates the whole chain; checkCategory gates toc
        // and content; checkContent gates content only.
        guard items.indices.contains(index), !cancelled else { return }

        let books: [(track: String, book: OnlineBook)] = {
            var result: [(track: String, book: OnlineBook)] = []
            if let searchBook = items[index].searchBook {
                result.append((localized("搜索"), searchBook))
            }
            if let discoveryBook = items[index].discoveryBook {
                result.append((localized("發現"), discoveryBook))
            }
            return result
        }()

        guard !books.isEmpty else {
            // Both tracks failed (or were skipped): nothing left to chain-test.
            setStage(index, .detail, .skipped, "—")
            setStage(index, .toc, .skipped, "—")
            setStage(index, .content, .skipped, "—")
            return
        }

        guard policy.checkInfo else {
            // Legado: checkInfo=false returns from checkBook before anything runs.
            setStage(index, .detail, .skipped, "—")
            setStage(index, .toc, .skipped, "—")
            setStage(index, .content, .skipped, "—")
            return
        }

        // Stage 3 — detail, only when the book lacks a tocUrl (Legado skips the request).
        setStage(index, .detail, .running)
        var resolvedBooks: [(track: String, book: OnlineBook)] = []
        var detailFailures: [(FailureCategory, String)] = []
        var detailSuccesses: [String] = []
        for (track, book) in books {
            guard items.indices.contains(index), !cancelled else { return }
            let result = await probeDetail(book: book, source: source)
            switch result {
            case .success(let info, let message):
                resolvedBooks.append((track, info))
                detailSuccesses.append(message)
            case .failure(let category, let message):
                detailFailures.append((category, "\(track)\(message)"))
            }
        }
        guard items.indices.contains(index), !cancelled else { return }
        if detailFailures.isEmpty {
            setStage(index, .detail, .pass, detailSuccesses.joined(separator: "；"))
        } else {
            setStage(index, .detail, .fail, detailFailures.map(\.1).joined(separator: "；"))
            recordFailure(at: index, detailFailures[0].0)
        }

        // Stages 4–5 — toc then content. Legado skips both for file-type sources
        // and when checkCategory is off.
        let chainDisabled = !policy.checkCategory || source.bookSourceType == 3
        if chainDisabled {
            setStage(index, .toc, .skipped, "—")
            setStage(index, .content, .skipped, "—")
            return
        }

        // Stage 4 — chapter list (first two chapters, mirroring Legado's take(2)).
        setStage(index, .toc, .running)
        var tocChapters: [(track: String, chapter: OnlineChapterRef)] = []
        var tocFailures: [(FailureCategory, String)] = []
        var tocSuccesses: [String] = []
        for (track, book) in resolvedBooks {
            guard items.indices.contains(index), !cancelled else { return }
            let result = await probeTOC(book: book, source: source)
            switch result {
            case .success(let chapter, let message):
                tocChapters.append((track, chapter))
                tocSuccesses.append(message)
            case .failure(let category, let message):
                tocFailures.append((category, "\(track)\(message)"))
            }
        }
        guard items.indices.contains(index), !cancelled else { return }
        if tocFailures.isEmpty {
            setStage(index, .toc, .pass, tocSuccesses.joined(separator: "；"))
        } else {
            setStage(index, .toc, .fail, tocFailures.map(\.1).joined(separator: "；"))
            recordFailure(at: index, tocFailures[0].0)
        }

        // Stage 5 — first chapter body (Legado getContentAwait, needSave = false).
        guard policy.checkContent else {
            setStage(index, .content, .skipped, "—")
            return
        }
        setStage(index, .content, .running)
        var contentFailures: [(FailureCategory, String)] = []
        var contentSuccesses: [String] = []
        for (track, chapter) in tocChapters {
            guard items.indices.contains(index), !cancelled else { return }
            let result = await probeContent(chapter: chapter, source: source)
            switch result {
            case .success(let count, let message):
                contentSuccesses.append(message)
                _ = count
            case .failure(let category, let message):
                contentFailures.append((category, "\(track)\(message)"))
            }
        }
        guard items.indices.contains(index), !cancelled else { return }
        if contentFailures.isEmpty {
            setStage(index, .content, .pass, contentSuccesses.joined(separator: "；"))
        } else {
            setStage(index, .content, .fail, contentFailures.map(\.1).joined(separator: "；"))
            recordFailure(at: index, contentFailures[0].0)
        }
    }

    // MARK: - Stage probes

    private func probeSearch(keyword: String, source: BookSource) async -> ProbeResult<OnlineBook> {
        let url = source.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            return .failure(.ruleMissing, localized("搜索鏈接規則為空"))
        }
        do {
            let books = try await fetcher.search(query: keyword, in: source)
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
            let info = try await fetcher.fetchBookInfo(url: book.bookUrl, source: source)
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
            let chapters = try await fetcher.fetchTOC(tocUrl: book.tocUrl, source: source)
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
            let text = try await fetcher.fetchChapter(ref: chapter, bookId: UUID(), source: source)
            let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
            guard count > 0 else { return .failure(.contentEmpty, localized("正文失效")) }
            return .success(count, "\(localized("抓取")) \(count) \(localized("字"))")
        } catch {
            return .failure(.siteError, error.localizedDescription)
        }
    }
}
