import Foundation
import os

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
/// Concurrency: the bridge lives on the session's `SourceScriptHost`, so everything that
/// touches it runs there, one job at a time; different sources never block each other.
/// Parse calls also mutate bridge-level context (book/chapter bridges, runtime variables)
/// that later calls in the same flow read back, so they first queue for the source's turn
/// (`parse`, `withTurn`) — ordered by the caller's task priority, because a 段評 source's
/// content rule holds the turn for the whole of its own network round trips: ~2s per
/// chapter on 光遇番茄, measured 2026-10-06. A fetch (`fetch`, runtime search, discover)
/// takes no turn: its script halves run on the host between parses and its network runs
/// off it, as it ran beside parses before.
///
/// Staleness: the cache key includes the source's `lastUpdateTime`, which the
/// store bumps on every edit/import — an updated source naturally maps to a
/// fresh session, no explicit invalidation hooks needed.
final class BookSourceSession: Sendable {

    let source: BookSource
    let host: SourceScriptHost<ModernParserBridge>
    /// The source's `@js:` header rule as its engine last resolved it, readable without the
    /// host (`BookSource.parsedHeaders`, `resolvedHeaders()`).
    let headerSnapshot = SourceHeaderSnapshot()
    private let gate = SourceTurnGate()

    /// `requestSession` carries a test's URLProtocol; production sessions come from
    /// `session(for:)` with the bridge's default.
    init(source: BookSource, requestSession: URLSession = LegadoJSBridge.requestSession) {
        self.source = source
        // Cheap now: the bridge defers its JSContext until a rule actually runs JS,
        // so the `js.runtimeCreate` span lives on that lazy accessor instead. A
        // pure-CSS source should never emit one.
        self.host = SourceScriptHost(
            ModernParserBridge(source: source, requestSession: requestSession, headerSnapshot: headerSnapshot),
            label: source.bookSourceName
        )
    }

    // MARK: - The source's turn
    //
    // Waiters are served highest task priority first, FIFO within a priority. With a plain
    // lock the chapter the reader is waiting on took its turn behind every queued prefetch:
    // after a jump the reader prefetches four neighbours, each holding the bridge ~2s on a
    // 段評 source, so a second jump could wait ~8s before its own fetch even started, and a
    // chapter opened right after launch sat behind the shelf's table-of-contents refreshes.
    // The priority is the one the task already carries (`ChapterFetchPriority.taskPriority`,
    // the shelf refresh's `.utility`).
    //
    // Nothing is preempted or cancelled here — a jump that cancelled its siblings was the
    // main manufacturer of spurious 章節載入失敗 (see `ChapterFetchManager.fetchChapter`).
    // Only a task that was cancelled anyway leaves the queue instead of still running its
    // parse (`parse(_:)`); a holder always finishes.

    /// Runs `body` on the host in the source's turn, queued by the calling task's priority,
    /// and throws `CancellationError` without running it if the task is cancelled before its
    /// turn — a closed reader's queued prefetches must not each still take the bridge for
    /// their full parse.
    func parse<T: Sendable>(_ body: sending (ModernParserBridge) throws -> T) async throws -> T {
        try await gate.acquireUnlessCancelled(priority: Task.currentPriority)
        defer { gate.release() }
        return try await host.run(body)
    }

    /// `parse` for the parsing pipeline's calls, which run once their turn comes even when the
    /// task was cancelled while waiting: a parse already under way upstream is finished, as it
    /// always was.
    func withTurn<T: Sendable>(_ body: sending (ModernParserBridge) throws -> T) async rethrows -> T {
        await gate.acquire(priority: Task.currentPriority)
        defer { gate.release() }
        return try await host.run(body)
    }

    /// `withTurn` for a caller on its own thread (not a task), which it blocks until `body`
    /// has run. Never call it from Swift concurrency: a waiting cooperative thread is one
    /// fewer for the very hop to the host this waits on.
    func withBridge<T: Sendable>(
        priority: TaskPriority = Task.currentPriority,
        _ body: @escaping @Sendable (ModernParserBridge) -> T
    ) -> T {
        gate.acquireBlocking(priority: priority)
        defer { gate.release() }
        let result = OSAllocatedUnfairLock<T?>(initialState: nil)
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: priority) { [host] in
            let value = await host.run(body)
            result.withLock { $0 = value }
            done.signal()
        }
        done.wait()
        // The task stored the value before signalling.
        return result.withLock { $0 }!
    }

    /// Callers currently waiting for the source's turn (tests watch the queue form).
    var queuedCallers: Int { gate.queuedCallers }

    /// A rule URL fetched with the source's runtime: script halves on the host, no turn.
    func fetch(ruleUrl: String, key: String? = nil, page: Int? = nil) async throws -> (String, String) {
        try await host.fetch(ruleUrl: ruleUrl, key: key, page: page)
    }

    // MARK: - Header rule

    /// The `@js:` header rule's result for a caller that cannot wait — a SwiftUI body, a
    /// cover cell on the main thread. Before the first resolution this is `[:]` and starts
    /// one on the host; afterwards it is what the engine last resolved, which a resolution
    /// for a new login state replaces.
    ///
    /// Never waits on the host: a script there may be parked on a verification page that only
    /// the main thread can show (TestFlight AGT4StkW1MHoKzDbZNJd4So, 「69书吧人机验证卡死」).
    func headerSnapshotStartingResolution() -> [String: String] {
        let (headers, startsResolution) = headerSnapshot.readClaimingResolution()
        if startsResolution {
            Task(priority: .utility) { [self] in
                _ = await resolveHeadersOnHost()
                headerSnapshot.finishResolution()
            }
        }
        return headers ?? [:]
    }

    /// The `@js:` header rule's result for a request about to be sent: what the engine last
    /// resolved, or — before any resolution — resolved now on the host. A request never goes
    /// out without the rule's headers because nothing had resolved them yet: 书山聚合 puts
    /// its required token there and answers `{"error":"访问被拒绝"}` without it.
    func resolvedHeaders() async -> [String: String] {
        if let headers = headerSnapshot.headers { return headers }
        return await resolveHeadersOnHost()
    }

    private func resolveHeadersOnHost() async -> [String: String] {
        // The engine publishes what it resolves into `headerSnapshot` itself.
        let headers = await host.run { $0.resolvedSourceHeaders() }
        AppLogger.parse("⟐ header.js resolved", context: [
            "source": source.bookSourceName,
            "keys": headers.keys.sorted().joined(separator: ",")
        ])
        return headers
    }

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

/// One source's resolved header rule, shared between its engine (which writes every
/// resolution) and callers off its host (which read it without waiting).
final class SourceHeaderSnapshot: Sendable {
    private struct State: Sendable {
        var headers: [String: String]?
        var resolving = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var headers: [String: String]? { state.withLock { $0.headers } }

    func store(_ headers: [String: String]) {
        state.withLock { $0.headers = headers }
    }

    /// The current value, and whether the caller should start the first resolution — true
    /// once, while nothing has resolved and no resolution is under way.
    func readClaimingResolution() -> (headers: [String: String]?, startsResolution: Bool) {
        state.withLock { state in
            guard state.headers == nil, !state.resolving else { return (state.headers, false) }
            state.resolving = true
            return (nil, true)
        }
    }

    func finishResolution() {
        state.withLock { $0.resolving = false }
    }
}

/// Whose turn it is on one source, and who waits for it: highest task priority first, FIFO
/// within a priority. A release hands the turn straight to the next waiter.
final class SourceTurnGate: Sendable {
    private enum Wake: Sendable {
        case task(CheckedContinuation<Void, Never>)
        case cancellableTask(CheckedContinuation<Void, any Error>)
        case thread(DispatchSemaphore)
    }

    private struct Waiter: Sendable {
        let ticket: UInt64
        let priority: UInt8
        let wake: Wake
    }

    private struct State: Sendable {
        var held = false
        var waiting: [Waiter] = []
        var nextTicket: UInt64 = 0

        mutating func takeTicket() -> UInt64 {
            defer { nextTicket += 1 }
            return nextTicket
        }
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Suspends until the turn is the caller's.
    func acquire(priority: TaskPriority) async {
        let ticket = state.withLock { $0.takeTicket() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted = state.withLock { state -> Bool in
                if !state.held {
                    state.held = true
                    return true
                }
                state.waiting.append(Waiter(ticket: ticket, priority: priority.rawValue, wake: .task(continuation)))
                return false
            }
            if granted { continuation.resume() }
        }
    }

    /// Blocks the calling thread until the turn is its own.
    func acquireBlocking(priority: TaskPriority) {
        let semaphore = DispatchSemaphore(value: 0)
        let granted = state.withLock { state -> Bool in
            if !state.held {
                state.held = true
                return true
            }
            state.waiting.append(Waiter(
                ticket: state.takeTicket(), priority: priority.rawValue, wake: .thread(semaphore)
            ))
            return false
        }
        if !granted { semaphore.wait() }
    }

    func release() {
        let next = state.withLock { state -> Wake? in
            guard let index = state.waiting.indices.max(by: { lhs, rhs in
                let a = state.waiting[lhs], b = state.waiting[rhs]
                return a.priority != b.priority ? a.priority < b.priority : a.ticket > b.ticket
            }) else {
                state.held = false
                return nil
            }
            // Still held: the turn passes to this waiter without a gap another caller could take.
            return state.waiting.remove(at: index).wake
        }
        switch next {
        case .task(let continuation)?: continuation.resume()
        case .cancellableTask(let continuation)?: continuation.resume()
        case .thread(let semaphore)?: semaphore.signal()
        case nil: break
        }
    }

    var queuedCallers: Int { state.withLock { $0.waiting.count } }

    /// `acquire`, except that a task cancelled before its turn — already, or while waiting —
    /// leaves the queue at once and throws `CancellationError`, owning nothing.
    func acquireUnlessCancelled(priority: TaskPriority) async throws {
        let ticket = state.withLock { $0.takeTicket() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Outcome { case granted, queued, cancelled }
                // Checked under the lock, so a cancellation handler that runs later finds this
                // waiter queued, and one that ran earlier has already set `isCancelled`.
                let outcome = state.withLock { state -> Outcome in
                    if Task.isCancelled { return .cancelled }
                    if !state.held {
                        state.held = true
                        return .granted
                    }
                    state.waiting.append(Waiter(
                        ticket: ticket, priority: priority.rawValue, wake: .cancellableTask(continuation)
                    ))
                    return .queued
                }
                switch outcome {
                case .granted: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .queued: break
                }
            }
        } onCancel: {
            // Only a waiter still queued leaves; one `release` already handed the turn to owns it.
            let wake = state.withLock { state -> Wake? in
                guard let index = state.waiting.firstIndex(where: { $0.ticket == ticket }) else { return nil }
                return state.waiting.remove(at: index).wake
            }
            if case .cancellableTask(let continuation)? = wake {
                continuation.resume(throwing: CancellationError())
            }
        }
    }
}
