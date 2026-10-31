import Foundation

/// Staged performance markers for the online-book pipeline. Emits `⏱ stage 123ms`
/// lines through AppLogger (os_log-backed, visible in Release Console) so slow
/// opens can be attributed to a stage instead of guessed at:
///
///   detail.network / detail.parse
///   toc.network / toc.parse / toc.nextPage
///   chapter.network / chapter.parse
///   search.rules / detail.rules / toc.rules / toc.nextRules / chapter.rules  (one page through
///     a source's rules; `cpu=` is the parsing thread's own time)
///   webNovel.content  (the content heuristic for a source with no content rule; `cpu=` too)
///   toc.nextPageChain  (how many next pages a table of contents walked)
///   sourceCheck.run / sourceCheck.toc / sourceCheck.content  (書源檢查: the whole run with the
///     process's CPU seconds, and each source's table-of-contents and content probes)
///   sourceCheck.width  (the check's width changing with the CPU it spent over the window)
///   js.runtimeCreate
///   coreText.firstPage / coreText.fullLayout
///   coreText.scroll.loadChapter / coreText.scroll.slice / coreText.scroll.placeholderSlice
///   coreText.document.buildChapter  (per-phase totals; sub-phases below are nested in it)
///   coreText.document.htmlParse / cssCollect / cssParse / astBuild / cssMatch
///   commentBubble.recognize / commentBubble.draw  (one 段評 bubble's SVG parse / raster)
///   cjk.typography.prepare  (the legacy engine's CJK pass over a chapter; the browser
///     engine's runs per paragraph and is a YueduCoreText Points of Interest interval)
///   reader.open.transition / reader.open.contentGate / reader.open.contentHold
///   reader.open.deferredPreload
///   reader.page.neighbour / willTransition / didFinish / display  (a paged-mode turn's
///     main-thread steps; logged only past 50ms, named by `MainThreadMonitor` at any length)
///   wait.jsQueue / wait.blockingResult / wait.regex / wait.reviewSummary  (a blocking wait
///     on the main thread only — `mainThreadWait`)
///   search.presentation.runtimeMarkers / kindInference / coverURL / introSanitize / mainMerge
///   search.presentation.coverURL.rejected
///   search.listPublish / search.listPublish.summary
///   search.firstResult  (submit to the first merged batch; tagged origin / sources / cacheDays)
///   search.iOS17.nativeTableApply
///   home.sync / home.groups / home.rowContent  (the 探索 home's main-thread parts: building its
///     rows, its sections, a section's cards)
///   module.entries  (a module list's items made into entries, off the main actor; wall clock:
///     lists landing together wait on ICU's transliterator lock in `WorkMatchKey`, so it reads
///     more than the work)
///   home.row  (a row's load, wall clock across its await: it includes time spent waiting for a
///     busy main thread, so it is not main-thread work even when its line says `main`)
///
/// Only spans at or above their reporting threshold are logged, so hot paths
/// (per-chapter title rules etc.) don't flood the Console.
enum SourcePerfTrace {

    /// Start stamp for the manual `record(since:)` form, so call sites that cannot wrap their
    /// work in a closure don't each spell out the clock.
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// CPU time the calling thread has used. Wall time under a 32-wide 書源檢查 is mostly
    /// waiting for a core, so the spans that attribute a run's CPU also say how much of their
    /// time was their own thread's (`cpuStart()` / `record(since: CPUStart)`). Synchronous
    /// work only: an `await` can resume on another thread.
    static var threadCPU: TimeInterval {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }

    /// CPU time the whole process has used, user and system: what MetricKit's cpu-exception
    /// counts against its budget of 90 s in 180 s.
    static var processCPU: TimeInterval {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> TimeInterval {
            TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    struct CPUStart {
        let wall: TimeInterval
        let cpu: TimeInterval
    }

    static func cpuStart() -> CPUStart {
        CPUStart(wall: now, cpu: threadCPU)
    }

    /// `record(since:)` for a `cpuStart()` span: the line also carries `cpu=`, this thread's
    /// CPU time over the span.
    static func record(
        _ stage: String,
        _ detail: String = "",
        since start: CPUStart,
        thresholdMs: Double = 1
    ) {
        let cpuMs = (threadCPU - start.cpu) * 1000
        record(
            stage,
            "cpu=\(String(format: "%.0f", cpuMs))ms\(detail.isEmpty ? "" : " \(detail)")",
            since: start.wall,
            thresholdMs: thresholdMs
        )
    }

    /// Measure a synchronous span.
    @discardableResult
    static func span<T>(
        _ stage: String,
        _ detail: @autoclosure () -> String = "",
        thresholdMs: Double = 1,
        measuresCPU: Bool = false,
        _ body: () throws -> T
    ) rethrows -> T {
        let t0 = ProcessInfo.processInfo.systemUptime
        let cpu0 = measuresCPU ? threadCPU : 0
        // A synchronous span on the main thread is, while it runs, what the main thread is
        // doing: `MainThreadMonitor` names it when the main thread stops answering.
        let onMain = Thread.isMainThread
        if onMain { MainThreadActivity.push(stage) }
        defer {
            if onMain { MainThreadActivity.pop() }
            if measuresCPU {
                record(stage, detail(), since: CPUStart(wall: t0, cpu: cpu0), thresholdMs: thresholdMs)
            } else {
                record(stage, detail(), since: t0, thresholdMs: thresholdMs)
            }
        }
        return try body()
    }

    /// A blocking wait (`wait.*`), measured only when the main thread is the one waiting.
    /// Off the main thread these waits are the design — a JS queue, a regex worker — and
    /// timing them would only add log lines; on the main thread one is a stall, and a wait
    /// that runs out its timeout lasts a round number of seconds, the shape the reader's
    /// recurring "no instrumented span" stalls have (Crashlytics 6f607251, install 26DCAAAC).
    @discardableResult
    static func mainThreadWait<T>(
        _ stage: String,
        _ detail: @autoclosure () -> String = "",
        _ body: () throws -> T
    ) rethrows -> T {
        guard Thread.isMainThread else { return try body() }
        return try span(stage, detail(), thresholdMs: 5, body)
    }

    /// Measure an async span. Runs in the caller's isolation, so `body` stays in the
    /// caller's region and is never sent to another executor.
    @discardableResult
    static func spanAsync<T>(
        _ stage: String,
        _ detail: @autoclosure () -> String = "",
        thresholdMs: Double = 1,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let t0 = ProcessInfo.processInfo.systemUptime
        // An async span suspends rather than blocking whichever thread records it, so it is
        // never a main-thread stall and leaves no breadcrumb.
        defer { record(stage, detail(), since: t0, thresholdMs: thresholdMs, mainThreadStallBreadcrumb: false) }
        return try await body()
    }

    /// Manual form for call sites that already track their own start time.
    static func record(
        _ stage: String,
        _ detail: String = "",
        since t0: TimeInterval,
        thresholdMs: Double = 1,
        mainThreadStallBreadcrumb: Bool = true
    ) {
        let ms = (ProcessInfo.processInfo.systemUptime - t0) * 1000
        guard ms >= thresholdMs else { return }
        let line = "⏱ \(stage) \(String(format: "%.0f", ms))ms\(detail.isEmpty ? "" : " \(detail)")"
        AppLogger.parse(line)
        // Long enough to be felt on the main thread: also into the Crashlytics log, so the
        // next hang, watchdog or crash report from this session carries it.
        if mainThreadStallBreadcrumb, ms >= mainThreadBreadcrumbMs, Thread.isMainThread {
            CrashContext.breadcrumb("main \(line)")
        }
    }

    /// A main-thread span this long is a visible stall.
    static let mainThreadBreadcrumbMs: Double = 100
}
