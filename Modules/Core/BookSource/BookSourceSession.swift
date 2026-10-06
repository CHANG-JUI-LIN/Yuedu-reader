import Foundation

/// One reusable parsing session per book source (Legado-style lifecycle).
///
/// For a source whose rules contain JS, the expensive part of a parse is not rule
/// extraction — it's standing up the runtime: a fresh JSContext, a dozen shim
/// scripts, and (worst) evaluating the source's `jsLib`. The old pipeline built a
/// new bridge for EVERY call, so one 詳情頁 visit paid it for the info parse,
/// the TOC parse, and again for every additional TOC page; every chapter fetch
/// paid it once more. A session keeps ONE bridge per source and shares it
/// across detail → TOC → next pages → chapters.
///
/// The bridge itself now defers that runtime until a rule actually evaluates JS
/// (`ModernParserBridge.jsEngine`), so a pure CSS/XPath source costs nothing here.
///
/// Concurrency: parse calls mutate bridge-level context (book/chapter bridges,
/// runtime variables) before evaluating, so `withBridge` serializes callers —
/// same-source parses queue, different sources never block each other. The queue
/// is ordered by the caller's task priority (see `withBridge`), because a 段評
/// source's content rule holds the bridge for the whole of its own network round
/// trips: ~2s per chapter on 光遇番茄, measured 2026-10-06. Async operations
/// (network `fetch`, runtime search) use `bridgeForAsyncOperations` without the
/// lock, relying on the JS engine's own serial queue exactly as separate bridges
/// did before.
///
/// Staleness: the cache key includes the source's `lastUpdateTime`, which the
/// store bumps on every edit/import — an updated source naturally maps to a
/// fresh session, no explicit invalidation hooks needed.
final class BookSourceSession {

    let source: BookSource
    private let bridge: ModernParserBridge

    private init(source: BookSource) {
        self.source = source
        // Cheap now: the bridge defers its JSContext until a rule actually runs JS,
        // so the `js.runtimeCreate` span lives on that lazy accessor instead. A
        // pure-CSS source should never emit one.
        self.bridge = ModernParserBridge(source: source)
    }

    // MARK: - Serialized bridge access
    //
    // Waiters are served highest task priority first, FIFO within a priority. With a plain
    // lock the chapter the reader is waiting on took its turn behind every queued prefetch:
    // after a jump the reader prefetches four neighbours, each holding the bridge ~2s on a
    // 段評 source, so a second jump could wait ~8s before its own fetch even started, and a
    // chapter opened right after launch sat behind the shelf's table-of-contents refreshes.
    // The priority is the one the task already carries (`ChapterFetchPriority.taskPriority`,
    // the shelf refresh's `.utility`), read where the caller is still on its task or, on the
    // source-script thread, from the QoS `SourceScriptThread` enforced from it.
    //
    // Nothing is preempted or cancelled here — a jump that cancelled its siblings was the
    // main manufacturer of spurious 章節載入失敗 (see `ChapterFetchManager.fetchChapter`).
    // Only a task that was cancelled anyway leaves the queue instead of still running its
    // parse (`parse(_:)`); a holder always finishes.
    private let gate = NSCondition()
    private var bridgeInUse = false
    private var waiting: [Waiter] = []
    private var nextTicket: UInt64 = 0

    private struct Waiter {
        let ticket: UInt64
        let priority: UInt8
    }

    /// Set under `gate`; flipped by the task's cancellation handler while it waits for the bridge.
    final class WaitCancellation {
        fileprivate var isCancelled = false
    }

    /// Serialized bridge access for synchronous parse calls (the bridge sets
    /// per-call context before evaluating; two interleaved parses would bleed
    /// book/chapter state into each other). Queued by `priority`, highest first.
    func withBridge<T>(
        priority: TaskPriority = Task.currentPriority,
        _ body: (ModernParserBridge) throws -> T
    ) rethrows -> T {
        _ = acquireBridge(priority: priority.rawValue, cancellation: nil)
        defer { releaseBridge() }
        return try body(bridge)
    }

    /// `withBridge` for async callers: runs `body` on the source-script thread, queued by the
    /// calling task's priority, and throws `CancellationError` without running it if the task is
    /// cancelled before its turn — a closed reader's queued prefetches must not each still take
    /// the bridge for their full parse.
    func parse<T>(_ body: @escaping (ModernParserBridge) throws -> T) async throws -> T {
        let priority = Task.currentPriority
        let cancellation = WaitCancellation()
        return try await withTaskCancellationHandler {
            try await SourceScriptThread.run {
                guard self.acquireBridge(priority: priority.rawValue, cancellation: cancellation) else {
                    throw CancellationError()
                }
                defer { self.releaseBridge() }
                return try body(self.bridge)
            }
        } onCancel: {
            self.gate.lock()
            cancellation.isCancelled = true
            self.gate.broadcast()
            self.gate.unlock()
        }
    }

    /// Blocks until the bridge is free and no waiter outranks the caller. Returns false only
    /// when `cancellation` was flipped first; the caller then owns nothing.
    private func acquireBridge(priority: UInt8, cancellation: WaitCancellation?) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        let ticket = nextTicket
        nextTicket += 1
        waiting.append(Waiter(ticket: ticket, priority: priority))
        while true {
            if cancellation?.isCancelled == true {
                waiting.removeAll { $0.ticket == ticket }
                gate.broadcast()
                return false
            }
            let outranked = waiting.contains {
                $0.priority > priority || ($0.priority == priority && $0.ticket < ticket)
            }
            if !bridgeInUse, !outranked {
                waiting.removeAll { $0.ticket == ticket }
                bridgeInUse = true
                return true
            }
            gate.wait()
        }
    }

    /// Callers currently waiting for the bridge (tests watch the queue form).
    var queuedCallers: Int {
        gate.lock()
        defer { gate.unlock() }
        return waiting.count
    }

    private func releaseBridge() {
        gate.lock()
        bridgeInUse = false
        gate.broadcast()
        gate.unlock()
    }

    /// Bridge access for async operations (`fetch(ruleUrl:)`, runtime search…)
    /// that cannot hold a lock across suspension points. Execution-level safety
    /// comes from the JS engine's serial queue, matching the pre-session
    /// behavior of those call sites.
    var bridgeForAsyncOperations: ModernParserBridge { bridge }

    // MARK: - Per-source cache

    private struct CacheEntry {
        let session: BookSourceSession
        var lastUsed: UInt64
    }

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: CacheEntry] = [:]
    private nonisolated(unsafe) static var accessClock: UInt64 = 0

    /// Sessions kept alive. Bounded because a session can own a JSContext, but wide
    /// enough to cover a fan-out's working set: source validation runs 6 sources at a
    /// time and each walks five stages, so at the old limit of 8 the cache was over
    /// capacity almost immediately.
    private static let cacheLimit = 32

    static func session(for source: BookSource) -> BookSourceSession {
        let key = "\(source.bookSourceUrl)#\(source.lastUpdateTime)"
        cacheLock.lock()
        if let existing = cache[key] {
            accessClock += 1
            cache[key]?.lastUsed = accessClock
            cacheLock.unlock()
            return existing.session
        }
        cacheLock.unlock()

        // Construction is heavy (rule data +, on first JS use, a JSContext and its
        // shims) — never hold the global lock through it, or a 30-source search
        // fan-out serializes on init.
        let session = BookSourceSession(source: source)

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let raced = cache[key] {
            // Another thread built the same source's session first; use theirs
            // so every caller converges on one bridge.
            return raced.session
        }
        // Evict the single least-recently-used entry. This used to `removeAll()`,
        // which is pathological under fan-out: crossing the limit threw away every
        // live session, so sources being actively parsed rebuilt their bridge
        // mid-run and the cache never reached a steady state.
        while cache.count >= cacheLimit {
            guard let oldest = cache.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key
            else { break }
            cache.removeValue(forKey: oldest)
        }
        accessClock += 1
        cache[key] = CacheEntry(session: session, lastUsed: accessClock)
        return session
    }
}
