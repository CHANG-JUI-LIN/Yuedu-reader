import Foundation
import Testing
@testable import yuedu_app

/// Per-call cost of the lock-guarded caches every rule evaluation goes through: compiled
/// regexes, parsed JSOUP selectors, the cookie and login-header stores, and the LRU cache under
/// the first two. Recorded before and after the Swift 6 migration swapped their locks, so the
/// swap is measured rather than assumed. Gated: it only prints numbers.
@Suite("Rule cache lock performance", .serialized)
struct RuleCacheLockPerformanceTests {
    private static func environment(_ key: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return env[key] ?? env["TEST_RUNNER_" + key]
    }

    nonisolated private static let enabled = environment("RULE_CACHE_PERF") == "1"

    private static let patterns = (0..<32).map { "chapter-\($0)\\s+(\\d+)" }
    private static let selectors = (0..<32).map { "class.book-\($0)@tag.a.0@href" }
    private static let sourceURL = "https://rule-cache-perf.invalid/source"

    /// Median µs per call over `passes` passes of `iterations` calls.
    private static func microseconds(passes: Int = 5, iterations: Int, _ body: (Int) -> Void) -> Double {
        var samples: [Double] = []
        for _ in 0..<passes {
            let start = ProcessInfo.processInfo.systemUptime
            for index in 0..<iterations { body(index) }
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1_000_000 / Double(iterations))
        }
        return samples.sorted()[samples.count / 2]
    }

    /// Wall-clock ms for 8 concurrent workers each making `iterations` calls.
    private static func contendedMilliseconds(iterations: Int, _ body: @escaping @Sendable (Int) -> Void) async -> Double {
        let start = ProcessInfo.processInfo.systemUptime
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for index in 0..<iterations { body(index) }
                }
            }
        }
        return (ProcessInfo.processInfo.systemUptime - start) * 1000
    }

    @Test(.enabled(if: enabled, "Set RULE_CACHE_PERF=1"))
    func cacheHitCost() async {
        // Warm every cache so the loops below measure hits only.
        for pattern in Self.patterns { _ = RegexCache.shared.regex(for: pattern) }
        for selector in Self.selectors {
            _ = SelectorCache.shared.getOrParse(selector) { _ in SelectorCache.ParsedJsoupRule(steps: []) }
        }
        LoginManager.shared.storeLoginHeader(sourceUrl: Self.sourceURL, raw: "{\"X-Perf\":\"1\"}")
        let lru = LRUCache<String, Int>(capacity: 64)
        for index in 0..<64 { lru.put("k\(index)", value: index) }

        let regexUs = Self.microseconds(iterations: 50_000) { index in
            _ = RegexCache.shared.regex(for: Self.patterns[index & 31])
        }
        let selectorUs = Self.microseconds(iterations: 50_000) { index in
            _ = SelectorCache.shared.getOrParse(Self.selectors[index & 31]) { _ in SelectorCache.ParsedJsoupRule(steps: []) }
        }
        let lruUs = Self.microseconds(iterations: 100_000) { index in
            _ = lru.get("k\(index & 63)")
        }
        let headerUs = Self.microseconds(iterations: 100_000) { _ in
            _ = LoginManager.shared.getLoginHeader(sourceUrl: Self.sourceURL)
        }
        let revisionUs = Self.microseconds(iterations: 100_000) { _ in
            _ = LoginManager.shared.loginInfoRevision(sourceUrl: Self.sourceURL)
        }
        let cookieUs = Self.microseconds(iterations: 2_000) { _ in
            _ = CookieStore.shared.get(url: Self.sourceURL)
        }

        let patterns = Self.patterns
        let regexContended = await Self.contendedMilliseconds(iterations: 20_000) { index in
            _ = RegexCache.shared.regex(for: patterns[index & 31])
        }
        let sourceURL = Self.sourceURL
        let headerContended = await Self.contendedMilliseconds(iterations: 50_000) { _ in
            _ = LoginManager.shared.getLoginHeader(sourceUrl: sourceURL)
        }

        print(String(
            format: "RULE_CACHE_PERF regex=%.3fus selector=%.3fus lru=%.3fus loginHeader=%.3fus loginRevision=%.3fus cookie=%.2fus regex8x20k=%.1fms loginHeader8x50k=%.1fms",
            regexUs, selectorUs, lruUs, headerUs, revisionUs, cookieUs, regexContended, headerContended
        ))
        LoginManager.shared.removeLoginHeader(sourceUrl: Self.sourceURL)
    }
}
