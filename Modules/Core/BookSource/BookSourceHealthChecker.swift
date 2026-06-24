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

@MainActor
final class BookSourceHealthChecker: ObservableObject {
    /// Shared so a run keeps going after the user leaves the book-source screen (background check).
    static let shared = BookSourceHealthChecker()

    @Published var items: [BookSourceCheckItem] = []
    @Published var isRunning = false
    /// One-line summary of the actions applied after the last completed run (disabled / deleted).
    @Published var lastSummary: String?

    /// The user-chosen handling for bad/slow sources, set before `runAll()`.
    var policy = BookSourceCheckPolicy()

    /// At most this many sources are probed at once. Unbounded concurrency made every source
    /// contend for the network, inflating response times and making "too slow" detection useless;
    /// a small window keeps timings meaningful and is gentler on the sites.
    private static let maxConcurrent = 6

    private var cancelled = false
    private let fetcher = BookSourceFetcher.shared

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

    /// True when a *passing* source's response time exceeds the configured "too slow" threshold.
    func isSlow(_ item: BookSourceCheckItem) -> Bool {
        item.status == .pass && item.responseTime > Int64(policy.slowThresholdMs)
    }

    // MARK: - Apply Actions

    /// After a full run, disable/delete bad sources and disable slow ones per the chosen policy.
    private func applyPolicy() {
        let store = BookSourceStore.shared
        var disableIds: Set<UUID> = []
        var deleteIds: Set<UUID> = []

        for item in items {
            if item.status == .fail {
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

    // MARK: - Single Source Check

    private func checkItem(at index: Int) async {
        guard items.indices.contains(index), !cancelled else { return }
        items[index].status = .testing
        items[index].detail = nil

        let source = items[index].source
        let t0 = CFAbsoluteTimeGetCurrent()

        let result = await probe(source: source)
        let elapsed = Int64((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        guard items.indices.contains(index), !cancelled else { return }
        items[index].status = result.pass ? .pass : .fail
        items[index].responseTime = elapsed
        items[index].detail = result.message
    }

    /// A source is "good" when a reader can actually reach a book through it — via the
    /// discover page *or* via search. Either path is enough; we only fail when neither
    /// works. Discover is tried first (it's the Explore tab the user sees), but a
    /// discover failure no longer condemns the source: plenty of sources have a quirky
    /// or login-gated discover page yet search and read perfectly.
    private func probe(source: BookSource) async -> (pass: Bool, message: String) {
        let hasDiscover = source.enabledExplore
            && !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasSearch = !source.searchUrl.isEmpty

        if hasDiscover {
            let discover = await checkDiscover(source: source)
            if discover.pass || cancelled { return discover }
            // Discover didn't work — fall back to search before giving up.
            guard hasSearch else { return discover }
            return await checkSearch(source: source)
        }

        if hasSearch {
            return await checkSearch(source: source)
        }

        // No discover and no search — minimal connectivity check.
        return await checkConnectivity(url: source.bookSourceUrl)
    }

    // MARK: - Discover Checking

    /// Discover entries usable as actual *content* — excludes `select` filter dropdowns
    /// and `java.startBrowser(...)` login actions. The live Explore page skips these too
    /// (see `DiscoverViewModel.mapItem`); without this, an aggregator whose first entry is
    /// a login link gets wrongly failed even though its real categories work fine.
    private func contentSections(
        _ sections: [ModernParserBridge.DiscoverItem]
    ) -> [ModernParserBridge.DiscoverItem] {
        sections.filter { item in
            guard (item.type ?? "") != "select" else { return false }
            let url = (item.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !url.isEmpty && !url.contains("java.startBrowser")
        }
    }

    /// Fetch discover categories → first usable section → get books → fetch a book's
    /// detail. A single broken category doesn't fail the source: we try the first few
    /// content sections and pass as soon as one of them responds.
    private func checkDiscover(source: BookSource) async -> (pass: Bool, message: String) {
        let sections = await fetcher.discoverItems(page: 1, in: source)
        guard !cancelled else { return (false, localized("已取消")) }

        let usable = contentSections(sections)
        guard !usable.isEmpty else {
            return (false, localized("發現頁無內容"))
        }

        var lastError = localized("發現頁無內容")
        for section in usable.prefix(3) {
            guard !cancelled else { return (false, localized("已取消")) }

            let books: [OnlineBook]
            do {
                books = try await fetcher.discoverBooks(from: section, page: 1, in: source)
            } catch {
                lastError = "\(localized("發現頁請求失敗")): \(error.localizedDescription)"
                continue
            }

            // Section responded but is empty (e.g. a personal shelf when not logged in).
            // The endpoint works, so the source is reachable — count it as a pass.
            guard let firstBook = books.first(where: {
                !$0.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                return (true, "\(section.title ?? localized("發現")) \(localized("無可讀取書籍"))")
            }

            // Verify a book opens; a flaky detail page just moves us to the next section.
            do {
                let bookInfo = try await fetcher.fetchBookInfo(url: firstBook.bookUrl, source: source)
                guard !cancelled else { return (false, localized("已取消")) }
                let name = bookInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
                return (true, name.isEmpty
                    ? "\(firstBook.name) — \(localized("詳情為空"))"
                    : "《\(name)》\(bookInfo.author)")
            } catch {
                lastError = "\(firstBook.name): \(error.localizedDescription)"
                continue
            }
        }

        return (false, lastError)
    }

    // MARK: - Search Checking

    private func checkSearch(source: BookSource) async -> (pass: Bool, message: String) {
        do {
            let books = try await fetcher.search(query: "的", in: source)
            guard !cancelled else { return (false, localized("已取消")) }
            if books.isEmpty {
                return (false, localized("搜索無結果"))
            }
            let names = books.prefix(3).map { "《\($0.name)》" }.joined(separator: "、")
            return (true, "\(books.count) \(localized("個結果"))（\(names)）")
        } catch {
            return (false, "\(localized("搜索失敗")): \(error.localizedDescription)")
        }
    }

    // MARK: - Fallback Connectivity

    private func checkConnectivity(url: String) async -> (pass: Bool, message: String) {
        guard !url.isEmpty else {
            return (false, localized("書源地址為空"))
        }
        guard let parsed = safeURL(string: url) else {
            return (false, localized("無效的 URL"))
        }
        do {
            var req = URLRequest(url: parsed)
            req.httpMethod = "HEAD"
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                return (false, localized("非 HTTP 響應"))
            }
            if (200..<400).contains(http.statusCode) {
                return (true, "HTTP \(http.statusCode)")
            }
            return (false, "HTTP \(http.statusCode)")
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

// MARK: - Health Check Item

struct BookSourceCheckItem: Identifiable {
    let id = UUID()
    let source: BookSource
    var status: CheckStatus = .pending
    var responseTime: Int64 = 0
    var detail: String?

    var overallPass: Bool { status == .pass }
}

enum CheckStatus: Equatable {
    case pending
    case testing
    case pass
    case fail
}
