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
/// runtime variables) before evaluating, so `withBridge` serializes callers
/// with a lock — same-source parses queue briefly, different sources never
/// block each other. Async operations (network `fetch`, runtime search) use
/// `bridgeForAsyncOperations` without the lock, relying on the JS engine's own
/// serial queue exactly as separate bridges did before.
///
/// Staleness: the cache key includes the source's `lastUpdateTime`, which the
/// store bumps on every edit/import — an updated source naturally maps to a
/// fresh session, no explicit invalidation hooks needed.
final class BookSourceSession {

    let source: BookSource
    private let bridge: ModernParserBridge
    private let lock = NSLock()

    private init(source: BookSource) {
        self.source = source
        // Cheap now: the bridge defers its JSContext until a rule actually runs JS,
        // so the `js.runtimeCreate` span lives on that lazy accessor instead. A
        // pure-CSS source should never emit one.
        self.bridge = ModernParserBridge(source: source)
    }

    /// Serialized bridge access for synchronous parse calls (the bridge sets
    /// per-call context before evaluating; two interleaved parses would bleed
    /// book/chapter state into each other).
    func withBridge<T>(_ body: (ModernParserBridge) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(bridge)
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
