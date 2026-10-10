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
///   coreText.scroll.loadChapter / coreText.scroll.slice / coreText.scroll.placeholderSlice
///   coreText.document.buildChapter  (per-phase totals; sub-phases below are nested in it)
///   coreText.document.htmlParse / cssCollect / cssParse / astBuild / cssMatch
///   cjk.typography.prepare  (the legacy engine's CJK pass over a chapter; the browser
///     engine's runs per paragraph and is a YueduCoreText Points of Interest interval)
///   reader.open.transition / reader.open.contentGate / reader.open.contentHold
///   reader.open.deferredPreload
///   search.presentation.runtimeMarkers / kindInference / coverURL / introSanitize / mainMerge
///   search.presentation.coverURL.rejected
///   search.listPublish / search.listPublish.summary
///   search.firstResult  (submit to the first merged batch; tagged origin / sources / cacheDays)
///   search.iOS17.nativeTableApply
///
/// Only spans at or above their reporting threshold are logged, so hot paths
/// (per-chapter title rules etc.) don't flood the Console.
enum SourcePerfTrace {

    /// Start stamp for the manual `record(since:)` form, so call sites that cannot wrap their
    /// work in a closure don't each spell out the clock.
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Measure a synchronous span.
    @discardableResult
    static func span<T>(
        _ stage: String,
        _ detail: @autoclosure () -> String = "",
        thresholdMs: Double = 1,
        _ body: () throws -> T
    ) rethrows -> T {
        let t0 = ProcessInfo.processInfo.systemUptime
        // A synchronous span on the main thread is, while it runs, what the main thread is
        // doing: `MainThreadMonitor` names it when the main thread stops answering.
        let onMain = Thread.isMainThread
        if onMain { MainThreadActivity.push(stage) }
        defer {
            if onMain { MainThreadActivity.pop() }
            record(stage, detail(), since: t0, thresholdMs: thresholdMs)
        }
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
        let line = "⏱ \(stage) \(String(format: "%.0f", ms))ms\(detail.isEmpty ? "" : " \(detail)")"
        AppLogger.parse(line)
        // Long enough to be felt on the main thread: also into the Crashlytics log, so the
        // next hang, watchdog or crash report from this session carries it.
        if ms >= mainThreadBreadcrumbMs, Thread.isMainThread {
            CrashContext.breadcrumb("main \(line)")
        }
    }

    /// A main-thread span this long is a visible stall.
    static let mainThreadBreadcrumbMs: Double = 100
}
