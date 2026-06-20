import Combine
import Foundation

@MainActor
final class BookSourceHealthChecker: ObservableObject {
    @Published var items: [BookSourceCheckItem] = []
    @Published var isRunning = false

    private var cancelled = false
    private let fetcher = BookSourceFetcher.shared

    func prepare(sources: [BookSource]) {
        cancelled = false
        items = sources.map { BookSourceCheckItem(source: $0) }
    }

    func runAll() async {
        guard !items.isEmpty else { return }
        isRunning = true
        cancelled = false
        defer {
            isRunning = false
            cancelled = false
        }
        await withTaskGroup(of: Void.self) { group in
            for index in items.indices {
                group.addTask { [weak self] in
                    await self?.checkItem(at: index)
                }
            }
        }
    }

    func cancel() {
        cancelled = true
        isRunning = false
    }

    // MARK: - Single Source Check

    private func checkItem(at index: Int) async {
        guard items.indices.contains(index), !cancelled else { return }
        items[index].status = .testing
        items[index].detail = nil

        let source = items[index].source
        let t0 = CFAbsoluteTimeGetCurrent()

        // Phase 1: try discover first
        if source.enabledExplore,
           !source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            let result = await checkDiscover(source: source)
            let elapsed = Int64((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            guard items.indices.contains(index), !cancelled else { return }
            items[index].status = result.pass ? .pass : .fail
            items[index].responseTime = elapsed
            items[index].detail = result.message
            return
        }

        // Phase 2: fall back to search
        if !source.searchUrl.isEmpty {
            let result = await checkSearch(source: source)
            let elapsed = Int64((CFAbsoluteTimeGetCurrent() - t0) * 1000)
            guard items.indices.contains(index), !cancelled else { return }
            items[index].status = result.pass ? .pass : .fail
            items[index].responseTime = elapsed
            items[index].detail = result.message
            return
        }

        // No discover and no search — minimal connectivity check
        let result = await checkConnectivity(url: source.bookSourceUrl)
        let elapsed = Int64((CFAbsoluteTimeGetCurrent() - t0) * 1000)
        guard items.indices.contains(index), !cancelled else { return }
        items[index].status = result.pass ? .pass : .fail
        items[index].responseTime = elapsed
        items[index].detail = result.message
    }

    // MARK: - Discover Checking

    /// Fetch discover categories → pick first → get books → fetch a book's detail.
    private func checkDiscover(source: BookSource) async -> (pass: Bool, message: String) {
        // 1. get discover sections
        let sections = await fetcher.discoverItems(page: 1, in: source)
        guard !cancelled else { return (false, localized("已取消")) }

        // Find first section that has a url
        guard let firstSection = sections.first(where: { ($0.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }),
              let sectionUrl = firstSection.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sectionUrl.isEmpty
        else {
            // Discover page returned no usable section
            return (false, localized("發現頁無內容"))
        }

        // 2. get books from that section
        let books: [OnlineBook]
        do {
            books = try await fetcher.discoverBooks(from: firstSection, page: 1, in: source)
        } catch {
            return (false, "\(localized("發現頁請求失敗")): \(error.localizedDescription)")
        }
        guard !cancelled else { return (false, localized("已取消")) }

        guard let firstBook = books.first(where: { $0.bookUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }),
              !firstBook.bookUrl.isEmpty
        else {
            // Section returned no books with a retrievable url
            return (true, "\(firstSection.title ?? localized("發現")) \(localized("無可讀取書籍"))")
        }

        // 3. fetch book detail
        do {
            let bookInfo = try await fetcher.fetchBookInfo(url: firstBook.bookUrl, source: source)
            guard !cancelled else { return (false, localized("已取消")) }
            let name = bookInfo.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                return (true, "\(firstBook.name) — \(localized("詳情為空"))")
            }
            return (true, "《\(name)》\(bookInfo.author)")
        } catch {
            return (false, "\(firstBook.name): \(error.localizedDescription)")
        }
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
