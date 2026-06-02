import Combine
import Foundation
import SwiftUI

// MARK: - Book Origin (link info provided by a single book source)

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

// MARK: - Aggregated Search Results (merge info from multiple sources for the same book)

class SearchBook: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let author: String
    @Published var origins: [BookOrigin]

    /// Normalized key for deduplication
    var deduplicationKey: String {
        Self.makeKey(name: name, author: author)
    }

    /// Generate dedup key: normalize fullwidth/halfwidth, strip whitespace
    static func makeKey(name: String, author: String) -> String {
        let n = normalize(name)
        let a = normalize(author)
        return "\(n)||||\(a)"
    }

    /// Name-only normalized key. Used to bucket candidates that share a title so
    /// their authors can then be compared for compatibility (`isLikelySameBook`),
    /// instead of requiring an exact name+author match to merge sources.
    static func nameKey(_ name: String) -> String {
        normalize(name)
    }

    /// Normalize string: strip whitespace/punctuation, convert fullwidth to halfwidth
    private static func normalize(_ s: String) -> String {
        s.lowercased()
            .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            ?? s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Heuristic "same book" test used for 換源 (source switching).
    ///
    /// Names must match — equal after normalization, or one strongly contains the
    /// other (subtitle / volume-suffix variations across sources). Authors are a
    /// *soft* filter: they only exclude a candidate when BOTH sides report a
    /// non-empty author AND those authors are incompatible. This keeps alternative
    /// sources discoverable even when a source omits the author (very common) or
    /// formats the title slightly differently — the previous exact `(name, author)`
    /// key match returned an empty list in those cases.
    static func isLikelySameBook(
        name lhsName: String, author lhsAuthor: String,
        name rhsName: String, author rhsAuthor: String
    ) -> Bool {
        let n1 = normalize(lhsName)
        let n2 = normalize(rhsName)
        guard !n1.isEmpty, !n2.isEmpty else { return false }
        guard fieldsCompatible(n1, n2) else { return false }

        let a1 = normalize(lhsAuthor)
        let a2 = normalize(rhsAuthor)
        if a1.isEmpty || a2.isEmpty { return true }
        return fieldsCompatible(a1, a2)
    }

    /// Two already-normalized fields are compatible when equal, or when one
    /// contains the other (guarding against trivial 1-character substrings).
    private static func fieldsCompatible(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.count >= 2 && b.contains(a) { return true }
        if b.count >= 2 && a.contains(b) { return true }
        return false
    }

    /// Primary cover URL (first non-empty one)
    var coverUrl: String {
        origins.first(where: { !$0.coverUrl.isEmpty })?.coverUrl ?? ""
    }

    /// Primary intro (longest one)
    var intro: String {
        origins.max(by: { $0.intro.count < $1.intro.count })?.intro ?? ""
    }

    /// Primary latest chapter
    var lastChapter: String {
        origins.first(where: { !$0.lastChapter.isEmpty })?.lastChapter ?? ""
    }

    /// Primary category
    var kind: String {
        origins.first(where: { !$0.kind.isEmpty })?.kind ?? ""
    }

    /// Intro for list display: filter out tag lines (e.g. "标签 (tags):", "#xxx") and truncate
    /// overly long content to avoid flooding the screen with tags.
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

    /// Display name: prefer the book name, otherwise use the latest chapter or the first N
    /// characters of the intro to reduce "unknown title" results.
    /// Cleans leading ?, ..., and meaningless symbols (e.g. "?... 诡秘之主 (Book Title)...").
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

    /// Clean display title: strip leading ?, ..., fullwidth spaces, etc.
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

    /// Whether the string is a pure list number (e.g. "1.", "2、")
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

// MARK: - Async Semaphore (limits concurrency)

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

// MARK: - Search Aggregation Engine
//
// Core design:
// 1. TaskGroup + AsyncSemaphore manages concurrency with maxConcurrency=30
// 2. Each book source independently bound to a 15s timeout; timed-out tasks are cancelled to free resources
// 3. As soon as any single source returns results, immediately mergeItems + re-sort + refresh UI
// 4. Uses @Published with SwiftUI to automatically trigger view updates (streaming mechanism)

@MainActor
class SearchAggregator: ObservableObject {
    @Published var results: [SearchBook] = []
    @Published var isSearching = false
    @Published var progress: SearchProgress = SearchProgress()

    /// Search progress
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

    /// Concurrency limit (max simultaneous requests) — lower reduces timeouts/failures
    private let maxConcurrency = 12

    /// Timeout seconds per book source — increasing reduces timeout failures
    private let perSourceTimeout: UInt64 = 25

    /// Current search task (used for cancellation)
    private var searchTask: Task<Void, Never>?

    /// Dedup table: name key → indices of `results` sharing that title. Within a
    /// bucket, candidates merge only when their authors are compatible.
    private var deduplicationMap: [String: [Int]] = [:]

    // MARK: - Start Search

    func search(query: String, sources: [BookSource]) {
        // Cancel previous search
        searchTask?.cancel()

        // Reset state (sources are validated, all included in search)
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
                        // Acquire semaphore → cap concurrency
                        await semaphore.acquire()
                        defer { Task { await semaphore.release() } }
                        // Each source has its own timeout; cancel on expiry
                        return await Self.searchSingleSource(
                            query: q, source: source, timeout: self?.perSourceTimeout ?? 25
                        )
                    }
                }

                // Streaming: on each result, immediately merge + sort + refresh UI
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
                    // Re-sort every time new results arrive (SwiftUI @Published auto-triggers UI update)
                    self.sortResults(query: q)
                }
            }

            self?.isSearching = false
        }
    }

    // MARK: - Cancel Search

    func cancel() {
        searchTask?.cancel()
        isSearching = false
    }

    // MARK: - Single-source search with timeout (static method, no actor isolation issues)
    //
    // Uses withThrowingTaskGroup for timeout:
    // - Task A: actual search
    // - Task B: sleep(timeout) then throw TimeoutError
    // Whichever completes first is returned; the other is cancelAll()

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
                guard let result = try await group.next() else {
                    throw CancellationError()
                }
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

    // MARK: - Merge a batch of results (dedup + aggregate)
    //
    // Executed immediately whenever any single source returns results:
    // 1. Build BookOrigin
    // 2. Check dedup table by name+author key
    // 3. Already exists → merge into origins array
    // 4. Does not exist → create new SearchBook

    private func mergeBatch(_ books: [OnlineBook], query: String) {
        let q = query.lowercased()
            .applyingTransform(.fullwidthToHalfwidth, reverse: false)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            ?? query.lowercased()

        for book in books {
            // Filter out results completely unrelated to the search keyword
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

            // Bucket by title, then merge into the first same-title result whose
            // author is compatible (equal, or one side empty). Same title with a
            // clearly different author stays a separate book.
            let nameKey = SearchBook.nameKey(book.name)
            let existingIndex = deduplicationMap[nameKey]?.first { idx in
                idx < results.count
                    && SearchBook.isLikelySameBook(
                        name: book.name, author: book.author,
                        name: results[idx].name, author: results[idx].author)
            }

            if let existingIndex {
                // Compatible match → merge into existing result's origin array
                withAnimation(.easeInOut(duration: 0.25)) {
                    results[existingIndex].origins.append(origin)
                }
            } else {
                // New book → create new SearchBook
                let searchBook = SearchBook(
                    name: book.name,
                    author: book.author,
                    origins: [origin]
                )
                withAnimation(.easeInOut(duration: 0.25)) {
                    deduplicationMap[nameKey, default: []].append(results.count)
                    results.append(searchBook)
                }
            }
        }
    }

    // MARK: - Three-tier Sorting

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

                // Tie-breaker: shorter name is more precise
                // (e.g. a short precise name beats a long one with extra description)
                if a.name.count != b.name.count { return a.name.count < b.name.count }

                return a.origins.count > b.origins.count
            }

            rebuildDeduplicationMap()
        }
    }

    /// Match score: 3 = name exactly equals keyword, 2 = name starts with keyword,
    /// 1 = name contains keyword, 0 = no match.
    /// Simplified-Chinese sources search simplified Chinese; for traditional Chinese
    /// search, import traditional-Chinese sources.
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

    /// Rebuild dedup table (indices change after sorting)
    private func rebuildDeduplicationMap() {
        deduplicationMap.removeAll(keepingCapacity: true)
        for (index, book) in results.enumerated() {
            deduplicationMap[SearchBook.nameKey(book.name), default: []].append(index)
        }
    }
}

// MARK: - Timeout Error
private struct SearchTimeoutError: Error {}
