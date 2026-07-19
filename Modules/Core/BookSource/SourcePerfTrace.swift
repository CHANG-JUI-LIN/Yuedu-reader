import Foundation

/// Staged performance markers for the online-book pipeline. Emits `⏱ stage 123ms`
/// lines through AppLogger (os_log-backed, visible in Release Console) so slow
/// opens can be attributed to a stage instead of guessed at:
///
///   detail.network / detail.parse
///   toc.network / toc.parse / toc.nextPage
///   chapter.network / chapter.parse
///   js.runtimeCreate
///   coreText.firstPage / coreText.fullLayout
///
/// Only spans at or above their reporting threshold are logged, so hot paths
/// (per-chapter title rules etc.) don't flood the Console.
enum SourcePerfTrace {

    /// Measure a synchronous span.
    @discardableResult
    static func span<T>(
        _ stage: String,
        _ detail: @autoclosure () -> String = "",
        thresholdMs: Double = 1,
        _ body: () throws -> T
    ) rethrows -> T {
        let t0 = ProcessInfo.processInfo.systemUptime
        defer { record(stage, detail(), since: t0, thresholdMs: thresholdMs) }
        return try body()
    }

    /// Measure an async span.
    @discardableResult
    static func spanAsync<T>(
        _ stage: String,
        _ detail: @autoclosure () -> String = "",
        thresholdMs: Double = 1,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let t0 = ProcessInfo.processInfo.systemUptime
        defer { record(stage, detail(), since: t0, thresholdMs: thresholdMs) }
        return try await body()
    }

    /// Manual form for call sites that already track their own start time.
    static func record(
        _ stage: String,
        _ detail: String = "",
        since t0: TimeInterval,
        thresholdMs: Double = 1
    ) {
        let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        guard ms >= thresholdMs else { return }
        AppLogger.parse(
            "⏱ \(stage) \(String(format: "%.0f", ms))ms\(detail.isEmpty ? "" : " \(detail)")"
        )
    }
}
