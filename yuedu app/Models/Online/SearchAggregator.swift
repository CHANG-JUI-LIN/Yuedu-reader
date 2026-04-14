import Combine
import Foundation
import SwiftUI

// MARK: - 書籍來源連結（單個書源提供的連結資訊）

struct BookOrigin: Identifiable {
    let id = UUID()
    let sourceId: UUID
    let sourceName: String
    let bookUrl: String
    let tocUrl: String
    let coverUrl: String
    let intro: String
    let lastChapter: String
    let wordCount: String
    let kind: String
    let runtimeVariables: [String: String]?
}

// MARK: - 聚合搜尋結果（合併同名書籍的多來源資訊）

class SearchBook: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let author: String
    @Published var origins: [BookOrigin]

    /// 去重用的標準化 key
    var deduplicationKey: String {
        Self.makeKey(name: name, author: author)
    }

    /// 產生去重 key：統一全形半形、去除空白
    static func makeKey(name: String, author: String) -> String {
        let n = normalize(name)
        let a = normalize(author)
        return "\(n)||||\(a)"
    }

    /// 標準化字串：去除空白/標點、統一全半形
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            ?? s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 主要封面 URL（取第一個非空的）
    var coverUrl: String {
        origins.first(where: { !$0.coverUrl.isEmpty })?.coverUrl ?? ""
    }

    /// 主要簡介（取最長的）
    var intro: String {
        origins.max(by: { $0.intro.count < $1.intro.count })?.intro ?? ""
    }

    /// 主要最新章節
    var lastChapter: String {
        origins.first(where: { !$0.lastChapter.isEmpty })?.lastChapter ?? ""
    }

    /// 主要分類
    var kind: String {
        origins.first(where: { !$0.kind.isEmpty })?.kind ?? ""
    }

    /// 列表用簡介：過濾「标签:」「#xxx」等標籤行、截斷過長內容，避免整屏標籤
    var displayIntro: String {
        let raw = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        let lines = raw.components(separatedBy: .newlines)
        var kept: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if t.hasPrefix("标签:") || t.hasPrefix("標籤:") { continue }
            if t.hasPrefix("#") && t.count < 30 { continue }
            kept.append(t)
        }
        let joined = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if joined.count <= 100 { return joined }
        let end = joined.index(joined.startIndex, offsetBy: 100)
        return String(joined[..<end]) + "…"
    }

    /// 顯示用書名：有書名用書名，否則用最新章節或簡介前 N 字，減少「未知書名」
    /// 會清理前綴的 ？、... 與無意義符號，避免顯示「？... 诡秘之主...」
    var displayName: String {
        let n = Self.cleanDisplayTitle(name.trimmingCharacters(in: .whitespacesAndNewlines))
        if !n.isEmpty && !Self.isOnlyListNumber(n) { return n }
        if !lastChapter.isEmpty { return Self.cleanDisplayTitle(lastChapter) }
        let introTrimmed = intro.trimmingCharacters(in: .whitespacesAndNewlines)
        if introTrimmed.count > 2 {
            let cleaned = Self.cleanDisplayTitle(introTrimmed)
            if !cleaned.isEmpty {
                let end = cleaned.index(cleaned.startIndex, offsetBy: min(30, cleaned.count))
                return String(cleaned[..<end])
            }
        }
        return name.isEmpty ? "未知書名" : n
    }

    /// 清理顯示用標題：去掉前綴的 ？、...、全形空格等
    private static func cleanDisplayTitle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            let before = t
            if t.hasPrefix("？") || t.hasPrefix("?") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines); continue }
            if t.hasPrefix("...") { t = String(t.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines); continue }
            if t.hasPrefix("..") { t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines); continue }
            if t.hasPrefix(".") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines); continue }
            if t.hasPrefix("　") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines); continue }
            if before == t { break }
        }
        return t
    }

    /// 是否為純列表序號（如 "1."、"2、"）
    private static func isOnlyListNumber(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        if let regex = try? NSRegularExpression(pattern: #"^\s*\d+[\.\、．]?\s*$"#),
           regex.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
        { return true }
        return false
    }

    init(name: String, author: String, origins: [BookOrigin] = []) {
        self.name = name
        self.author = author
        self.origins = origins
    }
}

// MARK: - 非同步信號量（限制併發數量）

actor AsyncSemaphore {
    private let limit: Int
    private var count: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if count < limit {
            count += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
        } else {
            count -= 1
        }
    }
}

// MARK: - 搜尋聚合引擎
//
// 核心設計：
// 1. TaskGroup + AsyncSemaphore 管理 maxConcurrency=30 的併發
// 2. 每個書源獨立綁定 15s 超時，逾時即 cancel 釋放資源
// 3. 任何 1 個書源回傳結果就立即 mergeItems + 重新排序 + 刷新 UI
// 4. 使用 @Published 搭配 SwiftUI 自動觸發畫面更新（串流機制）

@MainActor
class SearchAggregator: ObservableObject {
    @Published var results: [SearchBook] = []
    @Published var isSearching = false
    @Published var progress: SearchProgress = SearchProgress()

    /// 搜尋進度
    struct SearchProgress {
        var total: Int = 0
        var completed: Int = 0
        var failed: Int = 0
        var timedOut: Int = 0

        var fraction: Double {
            guard total > 0 else { return 0 }
            return Double(completed + failed + timedOut) / Double(total)
        }
    }

    /// 併發限制（最大同時請求數）- 降低可減少超時/失敗
    private let maxConcurrency = 12

    /// 每個書源的超時秒數 - 延長可減少超時失敗
    private let perSourceTimeout: UInt64 = 25

    /// 目前搜尋任務（用於取消）
    private var searchTask: Task<Void, Never>?

    /// 去重表：key → results 陣列索引
    private var deduplicationMap: [String: Int] = [:]

    // MARK: - 開始搜尋

    func search(query: String, sources: [BookSource]) {
        // 取消上一次搜尋
        searchTask?.cancel()

        // 重置狀態（書源已驗證，全部納入搜尋）
        results = []
        deduplicationMap = [:]
        progress = SearchProgress(total: sources.count)
        isSearching = true

        let semaphore = AsyncSemaphore(limit: maxConcurrency)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)

        searchTask = Task { [weak self] in
            await withTaskGroup(of: SearchBatchResult.self) { group in
                for source in sources {
                    group.addTask {
                        // 取得信號量 → 控制併發上限
                        await semaphore.acquire()
                        defer { Task { await semaphore.release() } }
                        // 每個書源獨立超時，逾時即 cancel
                        return await Self.searchSingleSource(
                            query: q, source: source, timeout: self?.perSourceTimeout ?? 25
                        )
                    }
                }

                // 串流處理：每收到一個結果就立即 merge + 排序 + 刷新 UI
                for await batchResult in group {
                    guard !Task.isCancelled, let self = self else { break }

                    switch batchResult {
                    case .success(let books):
                        self.mergeBatch(books, query: q)
                        self.progress.completed += 1
                    case .timeout:
                        self.progress.timedOut += 1
                    case .failed:
                        self.progress.failed += 1
                    }
                    // 每次有新結果都重新排序（SwiftUI @Published 自動觸發 UI 更新）
                    self.sortResults(query: q)
                }
            }

            self?.isSearching = false
        }
    }

    // MARK: - 取消搜尋

    func cancel() {
        searchTask?.cancel()
        isSearching = false
    }

    // MARK: - 帶超時的單源搜尋（靜態方法，無 actor 隔離問題）
    //
    // 用 withThrowingTaskGroup 實現超時：
    // - 任務 A：實際搜尋
    // - 任務 B：sleep(timeout) 後拋 TimeoutError
    // 誰先完成就回傳誰，另一個 cancelAll()

    private enum SearchBatchResult: Sendable {
        case success([OnlineBook])
        case timeout
        case failed
    }

    private static func searchSingleSource(
        query: String, source: BookSource, timeout: UInt64
    ) async -> SearchBatchResult {
        do {
            return try await withThrowingTaskGroup(of: [OnlineBook].self) { group in
                group.addTask {
                    try await BookSourceFetcher.shared.search(query: query, in: source)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                    throw SearchTimeoutError()
                }
                let result = try await group.next()!
                group.cancelAll()
                return .success(result)
            }
        } catch is CancellationError {
            return .failed
        } catch is SearchTimeoutError {
            return .timeout
        } catch {
            return .failed
        }
    }

    // MARK: - 合併一批結果（去重 + 聚合）
    //
    // 任何 1 個書源回傳結果就立即執行：
    // 1. 建立 BookOrigin
    // 2. 用 name+author 去重 key 查表
    // 3. 已存在 → 合併到 origins 陣列
    // 4. 不存在 → 新增 SearchBook

    private func mergeBatch(_ books: [OnlineBook], query: String) {
        let q = query.lowercased()
            .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            ?? query.lowercased()

        for book in books {
            // 過濾掉與搜索關鍵字完全無關的結果
            let normalizedName = book.name.lowercased()
                .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "")
                ?? book.name.lowercased()
            let normalizedAuthor = book.author.lowercased()
                .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "")
                ?? book.author.lowercased()

            let isRelated = !q.isEmpty && (
                normalizedName.contains(q) ||
                normalizedAuthor.contains(q) ||
                q.contains(normalizedName)
            )
            guard isRelated else { continue }

            let origin = BookOrigin(
                sourceId: book.sourceId,
                sourceName: book.sourceName,
                bookUrl: book.bookUrl,
                tocUrl: book.tocUrl,
                coverUrl: book.coverUrl,
                intro: book.intro,
                lastChapter: book.lastChapter,
                wordCount: book.wordCount,
                kind: book.kind,
                runtimeVariables: book.runtimeVariables
            )

            let key = SearchBook.makeKey(name: book.name, author: book.author)

            if let existingIndex = deduplicationMap[key],
                existingIndex < results.count
            {
                // 同名同作者 → 合併到已有結果的來源陣列
                withAnimation(.easeInOut(duration: 0.25)) {
                    results[existingIndex].origins.append(origin)
                }
            } else {
                // 新書 → 建立新的 SearchBook
                let searchBook = SearchBook(
                    name: book.name,
                    author: book.author,
                    origins: [origin]
                )
                withAnimation(.easeInOut(duration: 0.25)) {
                    deduplicationMap[key] = results.count
                    results.append(searchBook)
                }
            }
        }
    }

    // MARK: - 三層排序

    private func sortResults(query: String) {
        let q =
            query.lowercased()
            .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            ?? query.lowercased()

        withAnimation(.easeInOut(duration: 0.3)) {
            results.sort { a, b in
                let aScore = matchScore(name: a.name, query: q)
                let bScore = matchScore(name: b.name, query: q)

                if aScore != bScore { return aScore > bScore }

                // 同分時：書名越短越精確（如「斗罗大陆」優於「斗罗大陆,普通魂师...」）
                if a.name.count != b.name.count { return a.name.count < b.name.count }

                return a.origins.count > b.origins.count
            }

            rebuildDeduplicationMap()
        }
    }

    /// 匹配分數：3 = 書名完全等於關鍵字，2 = 書名以關鍵字開頭，1 = 書名包含關鍵字，0 = 不匹配
    /// 簡體書源搜簡體，同名排最前；要搜繁體請導入繁體書源
    private func matchScore(name: String, query: String) -> Int {
        let normalized =
            name.lowercased()
            .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            ?? name.lowercased()

        guard !query.isEmpty else { return 0 }

        if normalized == query { return 3 }
        if normalized.hasPrefix(query) { return 2 }
        if normalized.contains(query) { return 1 }
        if query.contains(normalized) && !normalized.isEmpty { return 1 }
        return 0
    }

    /// 重建去重表（排序後索引會改變）
    private func rebuildDeduplicationMap() {
        deduplicationMap.removeAll(keepingCapacity: true)
        for (index, book) in results.enumerated() {
            deduplicationMap[book.deduplicationKey] = index
        }
    }
}

// MARK: - 超時錯誤
private struct SearchTimeoutError: Error {}
