import Foundation
import UIKit

/// How many sources a 書源檢查 probes at once, steered by the CPU the process actually spends.
///
/// MetricKit reports a cpu-exception once a process spends 90 s of CPU in 180 s: half a core
/// on average (Crashlytics 20727455, c0ec35f1, 77f93443, bdd4dca3). After the two pathological
/// stages were fixed, 1492 sources at 32 wide still spent 228 s in their busiest 180 s — many
/// ordinary table-of-contents parses, no single culprit — while a check of slow sites spends
/// almost nothing at the same width. A fixed width is wrong for one or the other, so the width
/// follows the measured CPU: wide while the sites are what the check waits on, narrow while
/// parsing is.
///
/// Measured on completions only — no timer — so the floor keeps at least that many sources in
/// flight to finish and report. Two measures:
/// - Over windows of `window` seconds, the width goes to what `targetCores` allows at the CPU
///   each source in flight spent: down when a window ran hot, up by at most half when it ran
///   cool. The next change waits a whole window, because the sources already in flight when
///   the width drops keep spending until they finish.
/// - At every completion, the CPU of the trailing `budgetWindow` — what MetricKit counts. A
///   single source can spend 8 s on one table of contents, so a window runs hot at any width;
///   at 0.4 of a core on average the measured run still had 180 s windows of 92.5 s. Once the
///   trailing CPU reaches `trailingGuardCPU`, the width drops to the floor at once and does
///   not rise until that CPU has rolled out.
struct BookSourceCheckPacing: Sendable {

    struct Sample: Sendable, Equatable {
        /// System uptime, seconds.
        var wall: TimeInterval
        /// The process's CPU time, user and system, seconds.
        var cpu: TimeInterval
    }

    struct Adjustment: Sendable, Equatable {
        var from: Int
        var to: Int
        /// The CPU the process spent over the window, in cores.
        var cores: Double
        /// How many sources were in flight over the window, on average.
        var meanInFlight: Double
        /// The CPU the process spent in the trailing `budgetWindow`, seconds.
        var trailingCPU: Double
        /// When the window began.
        var windowStart: TimeInterval
    }

    /// Below MetricKit's half core: a window is only acted on once it has run, and the rest
    /// of the app spends CPU too.
    static let targetCores = 0.4
    static let window: TimeInterval = 10
    /// MetricKit's span.
    static let budgetWindow: TimeInterval = 180
    /// MetricKit's 90 s, less what landed after the trailing 180 s crossed a level in the
    /// measured run — at worst 17 s, the sources already in flight finishing — and a margin.
    static let trailingGuardCPU: TimeInterval = 65

    let ceiling: Int
    let floor: Int
    private(set) var width: Int
    /// The narrowest the width has been, for the run's log line.
    private(set) var minWidth: Int

    private var windowStart: Sample
    private var lastEvent: TimeInterval
    /// Sources in flight integrated over the window's seconds.
    private var inFlightSeconds: Double = 0
    /// Completions back to the newest one at least `budgetWindow` old, which the trailing CPU
    /// is measured from; the run's start until the run is that old.
    private var history: [Sample]

    /// Starts at `ceiling`, so a check that waits on its sites runs at full width from its
    /// first source. A hot start is caught like any other burst: at 32 wide the measured run
    /// spent 1.83 cores in its first window, which the window rule cuts and the trailing
    /// budget counts.
    init(ceiling: Int, start: Sample) {
        self.ceiling = max(1, ceiling)
        floor = min(2, self.ceiling)
        width = self.ceiling
        minWidth = width
        windowStart = start
        lastEvent = start.wall
        history = [start]
    }

    /// A source finished at `sample`; `inFlight` sources had been in flight since the last
    /// completion. Returns the change of width, if there was one.
    mutating func sourceFinished(at sample: Sample, inFlight: Int) -> Adjustment? {
        inFlightSeconds += Double(inFlight) * max(0, sample.wall - lastEvent)
        lastEvent = sample.wall
        while history.count > 1, history[1].wall <= sample.wall - Self.budgetWindow {
            history.removeFirst()
        }
        let trailingCPU = sample.cpu - history[0].cpu
        history.append(sample)
        let overBudget = trailingCPU >= Self.trailingGuardCPU

        let elapsed = sample.wall - windowStart.wall
        let cores = elapsed > 0 ? (sample.cpu - windowStart.cpu) / elapsed : 0
        let meanInFlight = elapsed > 0 ? inFlightSeconds / elapsed : Double(inFlight)
        let next: Int
        if overBudget, width > floor {
            next = floor
        } else if elapsed >= Self.window {
            let allowed = cores > 0
                ? Int((Self.targetCores * meanInFlight / cores).rounded(.down))
                : ceiling
            if overBudget || cores > Self.targetCores {
                next = max(floor, min(width, allowed))
            } else {
                next = min(min(ceiling, max(width + 1, width * 3 / 2)), max(floor, allowed))
            }
        } else {
            return nil
        }

        let started = windowStart.wall
        windowStart = sample
        inFlightSeconds = 0
        guard next != width else { return nil }
        let adjustment = Adjustment(
            from: width, to: next, cores: cores, meanInFlight: meanInFlight,
            trailingCPU: trailingCPU, windowStart: started
        )
        width = next
        minWidth = min(minWidth, next)
        return adjustment
    }
}

/// Where a 書源檢查 reads the process's clock and CPU: live, or driven by a test.
struct BookSourceCheckCPUClock: Sendable {
    var sample: @Sendable () -> BookSourceCheckPacing.Sample

    static let live = BookSourceCheckCPUClock {
        BookSourceCheckPacing.Sample(wall: SourcePerfTrace.now, cpu: SourcePerfTrace.processCPU)
    }
}

/// When a 書源檢查 narrows to what `BookSourceCheckPacing` allows.
///
/// The CPU budget pacing keeps to is the one iOS enforces on a process that is not in front:
/// in the background a process that spends too much CPU is reported and can be killed, and a
/// hot or Low Power device throttles everything anyway. In the foreground the run goes at full
/// width — measured on 1,492 sources, 430 s instead of the 1,458 s it took paced throughout.
struct BookSourceCheckPacingCondition: Sendable {
    var isRequired: @MainActor @Sendable () -> Bool

    static let live = BookSourceCheckPacingCondition {
        let process = ProcessInfo.processInfo
        return process.thermalState == .serious
            || process.thermalState == .critical
            || process.isLowPowerModeEnabled
            || UIApplication.shared.applicationState == .background
    }

    /// Paced from the first source — the condition `BookSourceCheckCPUTests` measures pacing in.
    static let always = BookSourceCheckPacingCondition { true }
}
