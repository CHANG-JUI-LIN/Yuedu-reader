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
}

// MARK: - Four-stage validation model

/// The four independent probes run against every source, in run order.
enum ValidationStage: Int, CaseIterable, Identifiable {
    case connectivity = 0
    case booklist
    case detail
    case content

    var id: Int { rawValue }

    /// Short label under the stage dot in a result row.
    var title: String {
        switch self {
        case .connectivity: return localized("連通")
        case .booklist:     return localized("分類")
        case .detail:       return localized("詳情")
        case .content:      return localized("正文")
        }
    }

    /// Full stage name shown on the prepare page.
    var longTitle: String {
        switch self {
        case .connectivity: return localized("網絡連通性")
        case .booklist:     return localized("發現分類")
        case .detail:       return localized("書籍詳情")
        case .content:      return localized("正文內容")
        }
    }

    var explanation: String {
        switch self {
        case .connectivity: return localized("檢測是否能訪問書源主域名")
        case .booklist:     return localized("解析發現頁第一個分類的書單")
        case .detail:       return localized("解析書單第一本書的詳情頁")
        case .content:      return localized("獲取第一章正文內容")
        }
    }

    var symbol: String {
        switch self {
        case .connectivity: return "antenna.radiowaves.left.and.right"
        case .booklist:     return "safari"
        case .detail:       return "book"
        case .content:      return "text.alignleft"
        }
    }
}

enum StageStatus: Equatable { case pending, running, pass, fail, skipped }

/// Why a source failed — `.emptyRule` means the site responded but a rule parsed out
/// empty (書單/目錄/正文為空), `.other` covers network, timeout and runtime errors.
enum FailureCategory: Equatable { case emptyRule, other }

struct StageOutcome: Equatable {
    var status: StageStatus = .pending
    var summary: String = ""
}

/// Overall verdict per source, shown as the badge in the source list.
enum SourceHealth: Equatable {
    case passed        // all four stages passed → 驗證通過
    case fetchError    // stage 1–3 failed → 抓取異常
    case contentError  // only stage 4 failed → 正文異常
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

    func outcome(_ stage: ValidationStage) -> StageOutcome { stages[stage.rawValue] }

    var isFinished: Bool { !stages.contains { $0.status == .pending || $0.status == .running } }
    var overallPass: Bool { stages.allSatisfy { $0.status == .pass } }

    var health: SourceHealth? {
        guard isFinished else { return nil }
        if overallPass { return .passed }
        if outcome(.content).status == .fail,
           outcome(.connectivity).status == .pass,
           outcome(.booklist).status == .pass,
           outcome(.detail).status == .pass {
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

    /// The user-chosen handling for bad/slow sources, set before `runAll()`.
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

    // MARK: - Per-source four-stage run

    private func setStage(
        _ index: Int, _ stage: ValidationStage, _ status: StageStatus, _ summary: String = ""
    ) {
        guard items.indices.contains(index) else { return }
        items[index].stages[stage.rawValue] = StageOutcome(status: status, summary: summary)
    }

    private func skipRemaining(after stage: ValidationStage, at index: Int) {
        guard items.indices.contains(index) else { return }
        for s in ValidationStage.allCases where s.rawValue > stage.rawValue {
            items[index].stages[s.rawValue] = StageOutcome(status: .skipped, summary: "—")
        }
    }

    private func finishItem(at index: Int, startedAt t0: CFAbsoluteTime) {
        guard items.indices.contains(index) else { return }
        items[index].responseTime = Int64((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        if let health = items[index].health {
            healthById[items[index].source.id] = SourceValidationSummary(
                health: health, responseMs: items[index].responseTime
            )
        }
    }

    private enum ProbeResult<T> {
        case success(T, String)
        case failure(FailureCategory, String)
    }

    private func checkItem(at index: Int) async {
        guard items.indices.contains(index), !cancelled else { return }
        let source = items[index].source
        let t0 = CFAbsoluteTimeGetCurrent()

        // Stage 1 — connectivity
        setStage(index, .connectivity, .running)
        let conn = await probeConnectivity(source)
        guard items.indices.contains(index), !cancelled else { return }
        setStage(index, .connectivity, conn.ok ? .pass : .fail, conn.message)
        if !conn.ok {
            items[index].failureCategory = .other
            skipRemaining(after: .connectivity, at: index)
            finishItem(at: index, startedAt: t0)
            return
        }

        // Stage 2 — first booklist (discover first, falling back to search)
        setStage(index, .booklist, .running)
        let listResult = await probeBooklist(source)
        guard items.indices.contains(index), !cancelled else { return }
        let book: OnlineBook
        switch listResult {
        case .failure(let category, let message):
            setStage(index, .booklist, .fail, message)
            items[index].failureCategory = category
            skipRemaining(after: .booklist, at: index)
            finishItem(at: index, startedAt: t0)
            return
        case .success(let found, let message):
            setStage(index, .booklist, .pass, message)
            book = found
        }

        // Stage 3 — book detail
        setStage(index, .detail, .running)
        let detailResult = await probeDetail(book: book, source: source)
        guard items.indices.contains(index), !cancelled else { return }
        let info: OnlineBook
        switch detailResult {
        case .failure(let category, let message):
            setStage(index, .detail, .fail, message)
            items[index].failureCategory = category
            skipRemaining(after: .detail, at: index)
            finishItem(at: index, startedAt: t0)
            return
        case .success(let fetched, let message):
            setStage(index, .detail, .pass, message)
            info = fetched
        }

        // Stage 4 — first chapter body
        setStage(index, .content, .running)
        let contentResult = await probeContent(book: book, info: info, source: source)
        guard items.indices.contains(index), !cancelled else { return }
        switch contentResult {
        case .failure(let category, let message):
            setStage(index, .content, .fail, message)
            items[index].failureCategory = category
        case .success(_, let message):
            setStage(index, .content, .pass, message)
            items[index].failureCategory = nil
        }
        finishItem(at: index, startedAt: t0)
    }

    // MARK: - Stage probes

    private func probeConnectivity(_ source: BookSource) async -> (ok: Bool, message: String) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let urlString = source.bookSourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, let url = safeURL(string: urlString) else {
            return (false, localized("無效的 URL"))
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 15
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard response is HTTPURLResponse else {
                return (false, localized("非 HTTP 響應"))
            }
            // Any HTTP status counts as reachable — plenty of sites reject HEAD yet serve pages.
            let ms = Int64((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            return (true, "\(ms)ms")
        } catch {
            return (false, error.localizedDescription)
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

    private func probeBooklist(_ source: BookSource) async -> ProbeResult<OnlineBook> {
        let hasDiscover = source.enabledExplore
            && !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSearch = !source.searchUrl.isEmpty

        var lastFailure: ProbeResult<OnlineBook> = .failure(.emptyRule, localized("發現頁無內容"))

        if hasDiscover {
            let sections = contentSections(await fetcher.discoverItems(page: 1, in: source))
            for section in sections.prefix(3) {
                guard !cancelled else { return lastFailure }
                do {
                    let books = try await fetcher.discoverBooks(from: section, page: 1, in: source)
                    if let book = books.first(where: {
                        !$0.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }) {
                        let title = section.title ?? localized("發現")
                        return .success(book, "「\(title)」\(books.count) \(localized("本"))")
                    }
                    lastFailure = .failure(.emptyRule, localized("書單為空"))
                } catch {
                    lastFailure = .failure(.other, error.localizedDescription)
                }
            }
            if !hasSearch { return lastFailure }
        }

        guard hasSearch else { return lastFailure }
        do {
            let books = try await fetcher.search(query: "我的", in: source)
            guard let book = books.first(where: {
                !$0.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                return .failure(.emptyRule, localized("搜索無結果"))
            }
            return .success(book, "\(localized("搜索")) \(books.count) \(localized("本"))")
        } catch {
            return .failure(.other, error.localizedDescription)
        }
    }

    private func probeDetail(book: OnlineBook, source: BookSource) async -> ProbeResult<OnlineBook> {
        do {
            let info = try await fetcher.fetchBookInfo(url: book.bookUrl, source: source)
            let name = info.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return .failure(.emptyRule, localized("詳情為空")) }
            return .success(info, "《\(name)》")
        } catch {
            return .failure(.other, error.localizedDescription)
        }
    }

    private func probeContent(
        book: OnlineBook, info: OnlineBook, source: BookSource
    ) async -> ProbeResult<Int> {
        let tocUrl: String = {
            let fromInfo = info.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fromInfo.isEmpty { return fromInfo }
            let fromBook = book.tocUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            return fromBook.isEmpty ? book.bookUrl : fromBook
        }()
        do {
            let chapters = try await fetcher.fetchTOC(tocUrl: tocUrl, source: source)
            guard let first = chapters.first(where: {
                !$0.shouldRenderAsVolumeSeparator && $0.hasLoadableContentURL
            }) else {
                return .failure(.emptyRule, localized("目錄為空"))
            }
            let text = try await fetcher.fetchChapter(ref: first, bookId: UUID(), source: source)
            let count = text.trimmingCharacters(in: .whitespacesAndNewlines).count
            guard count > 0 else { return .failure(.emptyRule, localized("正文為空")) }
            return .success(count, "\(localized("抓取")) \(count) \(localized("字"))")
        } catch {
            return .failure(.other, error.localizedDescription)
        }
    }
}
