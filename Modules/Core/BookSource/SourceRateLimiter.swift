import Foundation
import os

/// Per-source request throttle honoring Legado's `concurrentRate` (源并发率)
/// field, which sources declare to avoid tripping site rate limits / IP bans.
/// Legado's `ConcurrentRateLimiter` (legado-E, MD3 and upstream agree):
/// - "" / "0" → unlimited (the overwhelming majority of sources)
/// - "N"      → one request per N milliseconds ("非并发实际为1/毫秒")
/// - "N/M"    → at most N requests started per M milliseconds
///
/// Until 11-07 a bare "N" here meant N requests in flight at once, so a source declaring
/// `1000` (one a second — 29 of YCK1330's sources, 10 of 1329's, 12 of 1331's) was not
/// throttled at all, and `1` made every request of the source wait for the one before.
///
/// `run` acquires the source's budget, executes the operation WITHOUT holding
/// any lock (so one slow host never serializes other sources).
/// Requests of the same source queue on that source's own budget only. The window slides
/// (at most N starts in any M ms), where Legado's restarts when M ms have passed since its
/// first request: the same budget, without the burst of 2N across a window's edge.
enum SourceRateLimit {

    fileprivate struct Mode: Sendable, Equatable {
        let count: Int
        let milliseconds: Int
    }

    /// The rate `source.putConcurrent(rate)` set for a source key: Legado's
    /// `updateConcurrentRate`, which replaces the key's record for as long as the app runs.
    private static let updatedRates = OSAllocatedUnfairLock(initialState: [String: Mode]())

    fileprivate static func parse(_ rawRate: String) -> Mode? {
        let rate = rawRate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rate.isEmpty, rate != "0" else { return nil }
        if let slash = rate.firstIndex(of: "/") {
            let countPart = Int(rate[..<slash].trimmingCharacters(in: .whitespaces))
            let msPart = Int(rate[rate.index(after: slash)...].trimmingCharacters(in: .whitespaces))
            guard let count = countPart, let ms = msPart, count > 0, ms > 0 else { return nil }
            return Mode(count: count, milliseconds: ms)
        }
        guard let interval = Int(rate), interval > 0 else { return nil }
        return Mode(count: 1, milliseconds: interval)
    }

    /// Legado `BaseSource.putConcurrent(value)` → `ConcurrentRateLimiter.updateConcurrentRate`:
    /// `key`'s requests go at `rate` from now on. A rate that does not parse leaves the
    /// current one, as Legado's `NumberFormatException` branch keeps the record.
    static func updateRate(key: String, rate: String) {
        guard !key.isEmpty, let mode = parse(rate) else { return }
        updatedRates.withLock { $0[key] = mode }
    }

    /// Runs `operation` under the source's declared budget. Sources without a
    /// parseable `concurrentRate` run straight through with zero overhead.
    static func run<T>(
        source: BookSource,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await run(rate: source.concurrentRate, key: source.bookSourceUrl, operation)
    }

    static func run<T>(
        rate: String,
        key: String,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        // Legado's `fetchStart` checks the source's own rate first: a source without one is
        // never throttled, whatever `putConcurrent` stored for its key.
        guard let declared = parse(rate), !key.isEmpty else {
            return try await operation()
        }
        let mode = updatedRates.withLock { $0[key] } ?? declared
        await Ledger.shared.acquire(key: key, mode: mode)
        return try await operation()
    }

    /// Bookkeeping actor: request start timestamps per source key. Waits suspend inside the
    /// actor (sleep releases it), so acquires of different sources never block each other.
    private actor Ledger {
        static let shared = Ledger()

        private var windowStamps: [String: [Date]] = [:]

        func acquire(key: String, mode: Mode) async {
            let windowSeconds = Double(mode.milliseconds) / 1000
            while true {
                let now = Date()
                var stamps = (windowStamps[key] ?? []).filter {
                    now.timeIntervalSince($0) < windowSeconds
                }
                if stamps.count < mode.count || Task.isCancelled {
                    stamps.append(now)
                    windowStamps[key] = stamps
                    return
                }
                windowStamps[key] = stamps
                let waitSeconds = windowSeconds - now.timeIntervalSince(stamps[0])
                try? await Task.sleep(
                    nanoseconds: UInt64(Swift.max(0.01, waitSeconds) * 1_000_000_000)
                )
            }
        }
    }
}
