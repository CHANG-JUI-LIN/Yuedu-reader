import Foundation

// MARK: - Source Health Store
//
// Each book source's measured search round-trip, which 換源 sorts its candidates by
// (fastest first).
//
// It used to also skip sources: three timeouts or failures in a row put a source in a
// cooldown of 5 min, doubling to 60 min, and the aggregate search left it out meanwhile.
// Legado skips no source for having failed before (`SearchModel`, `ChangeBookSourceViewModel`),
// and readers saw a search reach only part of their sources — for a whole hour after a bad
// connection had timed many of them out. Records written then still carry the old
// `consecutiveFailures`/`cooldownUntil` keys; decoding ignores them.
@MainActor
final class SourceHealthStore {
    static let shared = SourceHealthStore()

    private struct Health: Codable {
        /// Exponential moving average of successful search round-trips, in
        /// milliseconds. Optional so records persisted by older builds decode.
        var averageResponseMs: Double?
    }

    private let defaultsKey = "yd_source_health_v1"

    private var map: [String: Health]
    private var needsPersist = false

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Health].self, from: data) {
            map = decoded
        } else {
            map = [:]
        }
    }

    /// A source answered. When the caller measured the round-trip, fold it into the
    /// source's response-time EMA (used to rank 換源 candidates by speed).
    func recordSuccess(_ id: UUID, responseMs: Double? = nil) {
        var health = map[id.uuidString] ?? Health()
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

    /// Coalesced write-back.
    ///
    /// Every `recordSuccess`/`recordFailure` used to JSON-encode the whole map and
    /// hand it to `UserDefaults` — on the main actor, once per book source. A search
    /// across a few thousand sources therefore did a few thousand full-map encodes
    /// and defaults writes while results were streaming in. The map is a cache of
    /// response times, so batching the write costs nothing: an entry lost to a kill
    /// just means one measurement is gone.
    private func persist() {
        needsPersist = true
    }

    /// Write-back. Called when a search run reaches a resting point (finished,
    /// paused, 載入更多 done) — never per source.
    func flush() {
        guard needsPersist else { return }
        needsPersist = false
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
