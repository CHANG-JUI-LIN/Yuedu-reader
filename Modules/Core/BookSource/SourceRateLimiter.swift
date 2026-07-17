import Foundation

/// Per-source request throttle honoring Legado's `concurrentRate` (源并发率)
/// field, which sources declare to avoid tripping site rate limits / IP bans:
/// - "" / "0" → unlimited (the overwhelming majority of sources)
/// - "N"      → at most N requests in flight for the source at once
/// - "N/M"    → at most N requests *started* per M milliseconds (sliding window)
///
/// `run` acquires the source's budget, executes the operation WITHOUT holding
/// any lock (so one slow host never serializes other sources), then releases.
/// Requests of the same source queue on that source's own budget only.
enum SourceRateLimit {

    fileprivate enum Mode: Sendable {
        case concurrent(max: Int)
        case window(count: Int, milliseconds: Int)
    }

    fileprivate static func parse(_ rawRate: String) -> Mode? {
        let rate = rawRate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rate.isEmpty, rate != "0" else { return nil }
        if let slash = rate.firstIndex(of: "/") {
            let countPart = Int(rate[..<slash].trimmingCharacters(in: .whitespaces))
            let msPart = Int(rate[rate.index(after: slash)...].trimmingCharacters(in: .whitespaces))
            guard let count = countPart, let ms = msPart, count > 0, ms > 0 else { return nil }
            return .window(count: count, milliseconds: ms)
        }
        guard let maxInFlight = Int(rate), maxInFlight > 0 else { return nil }
        return .concurrent(max: maxInFlight)
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
        guard let mode = parse(rate), !key.isEmpty else {
            return try await operation()
        }
        await Ledger.shared.acquire(key: key, mode: mode)
        defer {
            // Release must not block the caller; only the concurrency form
            // keeps in-flight state that needs decrementing.
            if case .concurrent = mode {
                Task { await Ledger.shared.release(key: key) }
            }
        }
        return try await operation()
    }

    /// Bookkeeping actor: in-flight counts (concurrency form) and request start
    /// timestamps (window form) per source key. Waits suspend inside the actor
    /// (sleep releases it), so acquires of different sources never block each other.
    private actor Ledger {
        static let shared = Ledger()

        private var inFlight: [String: Int] = [:]
        private var windowStamps: [String: [Date]] = [:]

        func acquire(key: String, mode: Mode) async {
            switch mode {
            case .concurrent(let maxInFlight):
                while (inFlight[key] ?? 0) >= maxInFlight {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    if Task.isCancelled { break }
                }
                inFlight[key, default: 0] += 1
            case .window(let count, let milliseconds):
                let windowSeconds = Double(milliseconds) / 1000
                while true {
                    let now = Date()
                    var stamps = (windowStamps[key] ?? []).filter {
                        now.timeIntervalSince($0) < windowSeconds
                    }
                    if stamps.count < count || Task.isCancelled {
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

        func release(key: String) {
            let next = (inFlight[key] ?? 1) - 1
            if next <= 0 {
                inFlight[key] = nil
            } else {
                inFlight[key] = next
            }
        }
    }
}
