import Foundation

/// Every re-request of a chapter, and why.
///
/// A single retry is normal — a cancelled fetch gets reissued, a flaky source gets a
/// second chance. What matters, and what nothing recorded before, is **which** reason
/// keeps firing and whether the same chapter is going round in circles. "無限加載中"
/// and "章節載入失敗" both looked like one bug for a long time precisely because the
/// retries behind them were invisible: the log showed the symptom, never the cause or
/// the repetition.
///
/// So this records the reason at each retry, and escalates to an anomaly once one
/// chapter has been retried past `escalationThreshold` — carrying the whole sequence
/// of reasons, which is the thing that identifies the loop. `fetchCancelled ×4` is a
/// cancellation storm; `fetchCancelled → cacheInconsistent → cacheInconsistent` is the
/// cache and the load state disagreeing. Those need different fixes and used to look
/// identical from the outside.
///
/// Thread-safe and callable from anywhere: the retry sites live on the main actor
/// (`ReaderView`), inside actors (`OnlineReadingPipeline`), and in detached download
/// tasks (`OfflineDownloadManager`).
enum ChapterRetryLog {

    /// Why a chapter is being requested again. One case per real retry site — if a new
    /// site appears, it gets its own case rather than reusing a near-enough one.
    enum Reason: String, Sendable {
        /// Our own in-flight request was cancelled while somebody was still waiting on
        /// the chapter. `ReaderView.reissueCancelledChapterFetch`.
        case fetchCancelled
        /// A shared in-flight task was torn down by whoever created it; this caller
        /// learned nothing and reruns its own request rather than inheriting the
        /// cancellation. `OnlineReadingPipeline`.
        case inheritedCancellation
        /// The user tapped 重試.
        case userTapped
        /// The chapter says `.ready` but nothing readable is on disk — the load state
        /// and the cache disagree. This is the one users worked around with
        /// "刷新一下就好了".
        case cacheInconsistent
        /// Download-time per-chapter retry with backoff. `OfflineDownloadManager`.
        case offlineDownload
        /// A preload finished against a pagination generation that no longer exists and
        /// has to be redone.
        case layoutSuperseded
        /// The scroll engine found a chapter still sitting on its placeholder.
        case scrollPlaceholderStuck
        /// Android identity was switched on, so the request is worth repeating.
        case androidIdentityEnabled
    }

    /// Retries of one chapter before it is treated as a loop rather than a hiccup.
    /// Three is deliberately low: the offline downloader's own budget is three attempts,
    /// so anything reaching this in the reader is already past what a transient failure
    /// should need.
    private static let escalationThreshold = 3
    /// Reasons kept per chapter for the report. Enough to see the pattern.
    private static let historyLimit = 8
    /// Chapters tracked at once. Bounded so a long download session cannot grow this
    /// without limit; the oldest tracked chapter is dropped first.
    private static let trackedChapterLimit = 64

    private struct Key: Hashable {
        let bookId: String
        let chapter: Int
    }

    private static let lock = NSLock()
    private static var history: [Key: [Reason]] = [:]
    /// Insertion order, for evicting the oldest tracked chapter.
    private static var order: [Key] = []
    /// Chapters already reported, so one stuck chapter produces one anomaly rather than
    /// one per retry after the threshold.
    private static var escalated: Set<Key> = []

    // MARK: - Recording

    /// Records one retry. `attempt` is passed when the caller keeps its own counter
    /// (the downloader does); otherwise this type's own count is used.
    static func record(
        _ reason: Reason,
        chapter: Int,
        bookId: String?,
        attempt: Int? = nil,
        detail: String? = nil
    ) {
        let key = Key(bookId: bookId ?? "-", chapter: chapter)

        let (count, reasons, shouldEscalate): (Int, [Reason], Bool) = lock.withLock {
            var entries = history[key] ?? []
            if entries.isEmpty {
                order.append(key)
                if order.count > trackedChapterLimit, let oldest = order.first {
                    order.removeFirst()
                    history.removeValue(forKey: oldest)
                    escalated.remove(oldest)
                }
            }
            entries.append(reason)
            if entries.count > historyLimit { entries.removeFirst(entries.count - historyLimit) }
            history[key] = entries

            let escalate = entries.count >= escalationThreshold && !escalated.contains(key)
            if escalate { escalated.insert(key) }
            return (entries.count, entries, escalate)
        }

        let attemptText = attempt.map(String.init) ?? String(count)
        var line = "⟲ chapter retry ch=\(chapter) reason=\(reason.rawValue) attempt=\(attemptText)"
        if let detail, !detail.isEmpty { line += " \(detail)" }
        AppLogger.render(line, level: .warning)

        guard shouldEscalate else { return }
        AppLogger.anomaly(
            localized("章節反覆重試"),
            category: .reader,
            detail: ([
                "chapter=\(chapter)",
                "book=\(bookId ?? "-")",
                "retries=\(count)",
                "reasons=\(reasons.map(\.rawValue).joined(separator: " → "))",
                detail,
            ].compactMap { $0 }).joined(separator: "\n")
        )
    }

    /// The chapter finally arrived. Clears its history so a later, unrelated retry does
    /// not inherit this run's count — otherwise a book read for long enough would
    /// eventually report every chapter as looping.
    static func noteSuccess(chapter: Int, bookId: String?) {
        let key = Key(bookId: bookId ?? "-", chapter: chapter)
        lock.withLock {
            guard history.removeValue(forKey: key) != nil else { return }
            order.removeAll { $0 == key }
            escalated.remove(key)
        }
    }

    /// Retries recorded for a chapter in this session, for tests and for callers that
    /// want to show it.
    static func retryCount(chapter: Int, bookId: String?) -> Int {
        lock.withLock { history[Key(bookId: bookId ?? "-", chapter: chapter)]?.count ?? 0 }
    }

    static func resetForTesting() {
        lock.withLock {
            history.removeAll()
            order.removeAll()
            escalated.removeAll()
        }
    }
}
