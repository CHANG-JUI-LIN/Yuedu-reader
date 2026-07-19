import Foundation

/// One reusable parsing session per book source (Legado-style lifecycle).
///
/// The expensive part of a parse is not rule extraction — it's standing up a
/// `ModernParserBridge`: a fresh JSContext, a dozen shim scripts, and (worst)
/// re-evaluating the source's `jsLib` on first JS use. The old pipeline built a
/// new bridge for EVERY call, so one 詳情頁 visit paid it for the info parse,
/// the TOC parse, and again for every additional TOC page; every chapter fetch
/// paid it once more. A session keeps ONE bridge per source and shares it
/// across detail → TOC → next pages → chapters.
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
        let t0 = ProcessInfo.processInfo.systemUptime
        self.bridge = ModernParserBridge(source: source)
        SourcePerfTrace.record(
            "js.runtimeCreate", source.bookSourceName, since: t0
        )
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

    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: BookSourceSession] = [:]
    private static let cacheLimit = 8

    static func session(for source: BookSource) -> BookSourceSession {
        let key = "\(source.bookSourceUrl)#\(source.lastUpdateTime)"
        cacheLock.lock()
        if let existing = cache[key] {
            cacheLock.unlock()
            return existing
        }
        cacheLock.unlock()

        // Construction is heavy (JSContext + shims) — never hold the global
        // lock through it, or a 30-source search fan-out serializes on init.
        let session = BookSourceSession(source: source)

        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let raced = cache[key] {
            // Another thread built the same source's session first; use theirs
            // so every caller converges on one bridge.
            return raced
        }
        if cache.count >= cacheLimit {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = session
        return session
    }
}
