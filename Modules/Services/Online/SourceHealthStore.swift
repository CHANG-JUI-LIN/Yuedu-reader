import Foundation

// MARK: - Source Health Store
//
// Tracks per-book-source search reliability so the aggregator can temporarily
// skip sources that keep timing out (or hard-failing). A source's consecutive
// timeout/failure count drives an exponential cooldown; any successful search
// resets it.
//
// Why: large imported source packs (e.g. a 459-source 合集) contain many dead or
// unreachable hosts. Without cooldown every search re-attempts them, and each one
// holds a concurrency slot until the per-source timeout — making search feel
// minutes-slow even though good results stream in early. Skipping known-bad
// sources keeps repeat searches fast; cooldowns expire so a recovered source is
// retried automatically.
//
// Scope: only the multi-source aggregate search (`SearchAggregator`) skips
// cooldown sources. A single explicitly-selected source is always attempted.
@MainActor
final class SourceHealthStore {
    static let shared = SourceHealthStore()

    private struct Health: Codable {
        var consecutiveFailures: Int = 0
        var cooldownUntil: Date?
        /// Exponential moving average of successful search round-trips, in
        /// milliseconds. Optional so records persisted by older builds decode.
        var averageResponseMs: Double?
    }

    /// Consecutive timeouts/failures before a source enters cooldown.
    private let failureThreshold = 3
    /// Base cooldown once the threshold is crossed; doubles per extra failure.
    private let baseCooldown: TimeInterval = 5 * 60
    /// Upper bound on a single cooldown window.
    private let maxCooldown: TimeInterval = 60 * 60
    private let defaultsKey = "yd_source_health_v1"

    private var map: [String: Health]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Health].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    /// Whether a source is currently cooling down and should be skipped.
    func isInCooldown(_ id: UUID, now: Date = Date()) -> Bool {
        guard let until = map[id.uuidString]?.cooldownUntil else { return false }
        return until > now
    }

    /// Split sources into ones to search now and ones to skip (in cooldown).
    func partition(
        _ sources: [BookSource], now: Date = Date()
    ) -> (active: [BookSource], skipped: [BookSource]) {
        var active: [BookSource] = []
        var skipped: [BookSource] = []
        for source in sources {
            if isInCooldown(source.id, now: now) {
                skipped.append(source)
            } else {
                active.append(source)
            }
        }
        return (active, skipped)
    }

    /// A source returned without timing out → it is reachable; clear any strikes.
    /// When the caller measured the round-trip, fold it into the source's
    /// response-time EMA (used to rank 換源 candidates by speed).
    func recordSuccess(_ id: UUID, responseMs: Double? = nil) {
        var health = map[id.uuidString] ?? Health()
        health.consecutiveFailures = 0
        health.cooldownUntil = nil
        if let responseMs, responseMs > 0 {
            if let avg = health.averageResponseMs {
                health.averageResponseMs = avg * 0.7 + responseMs * 0.3
            } else {
                health.averageResponseMs = responseMs
            }
        }
        // Nothing worth persisting → drop the record entirely (old behavior).
        if health.averageResponseMs == nil {
            map[id.uuidString] = nil
        } else {
            map[id.uuidString] = health
        }
        persist()
    }

    /// Ranking key for "fastest first" ordering (換源 candidate list): measured
    /// sources sort by their EMA; unmeasured ones sort after any measured one.
    func responseSortKey(_ id: UUID) -> Double {
        map[id.uuidString]?.averageResponseMs ?? Double.greatestFiniteMagnitude
    }

    /// A source timed out or hard-failed → add a strike and, past the threshold,
    /// (re)start an exponentially growing cooldown.
    func recordFailure(_ id: UUID, now: Date = Date()) {
        var health = map[id.uuidString] ?? Health()
        health.consecutiveFailures += 1
        if health.consecutiveFailures >= failureThreshold {
            let over = Double(health.consecutiveFailures - failureThreshold)  // 0, 1, 2, …
            let duration = min(maxCooldown, baseCooldown * pow(2, over))
            health.cooldownUntil = now.addingTimeInterval(duration)
        }
        map[id.uuidString] = health
        persist()
    }

    /// Clears all cooldowns/strikes (e.g. a user-initiated "retry all").
    func reset() {
        guard !map.isEmpty else { return }
        map.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
