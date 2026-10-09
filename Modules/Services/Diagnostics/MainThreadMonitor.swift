import Foundation
import os

/// What the main thread is doing right now, as named by the synchronous `SourcePerfTrace`
/// spans it is inside (innermost last). Lock-protected so the monitor thread can read it.
enum MainThreadActivity {
    private static let stack = OSAllocatedUnfairLock(initialState: [String]())

    static func push(_ name: String) { stack.withLock { $0.append(name) } }
    static func pop() { stack.withLock { _ = $0.popLast() } }
    static func snapshot() -> [String] { stack.withLock { $0 } }
}

/// Notices when the main thread stops answering, and records how long and during what.
///
/// MetricKit reports hangs with a call stack, but only those it decides to report, a while
/// later, and without the app's own view of what it was doing. This fills the gap:
///
/// - Every `interval` a monitor thread asks the main thread to answer. When an answer is
///   overdue past `stallThreshold`, a stall has begun: the open main-thread spans
///   (`MainThreadActivity`) and the scene phase are captured, and a marker file says so.
/// - When the main thread answers, the stall is recorded with its duration — to the
///   diagnostic log, to the Crashlytics log from `breadcrumbThreshold`, and as a Crashlytics
///   issue grouped by activity from `reportThreshold`.
/// - When the app is killed during a stall (the scene-update watchdog after 10 s, or a user
///   force-quitting a frozen app) nothing answers and the marker stays. The next launch finds
///   it and reports "died during a main-thread stall" with what was running — the case no
///   other source covers, because a watchdog kill is not a crash Crashlytics sees.
///
/// Suspension is not a stall: the monitor thread notices its own tick arriving late (the
/// whole process was frozen) and discards the outstanding question.
final class MainThreadMonitor: @unchecked Sendable {
    static let shared = MainThreadMonitor()

    private let interval: TimeInterval = 0.1
    private let stallThreshold: TimeInterval = 0.25
    private let breadcrumbThreshold: TimeInterval = 0.5
    private let reportThreshold: TimeInterval = 2
    /// A tick this late means the process itself was suspended.
    private let suspensionGap: TimeInterval = 1
    /// How long it keeps watching after the app leaves the foreground: the scene-update
    /// watchdog judges the transition within 10 s. After that it stops asking, so hours of
    /// background listening do not wake the main thread ten times a second.
    private let backgroundWatchWindow: TimeInterval = 15
    /// A run that died less than this into a stall is not reported as an issue (a swipe
    /// away during a short pause); it is still written to the diagnostic log.
    private let diedReportThreshold: Double = 1

    private struct State {
        var started = false
        var lastTick: TimeInterval = 0
        var pingSentAt: TimeInterval?
        var openStall: OpenStall?
        var phase = "launch"
        /// Set when the scene reaches the background; nil while in the foreground.
        var backgroundSince: TimeInterval?
    }

    private struct OpenStall: Codable {
        var startedAt: TimeInterval
        var activitiesAtStart: [String]
        var activitiesLatest: [String]
        var phase: String
        var lastMeasuredSeconds: Double
        var build: String
        var wallClock: Date
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let log = Logger(subsystem: "com.yuedu.app", category: "MainThreadMonitor")
    private let markerURL: URL

    init(markerURL: URL = StorageLocations.diagnostics.appendingPathComponent("main-thread-stall.json")) {
        self.markerURL = markerURL
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static var build: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    /// Reports a stall the previous run died in, then starts watching. Call once, early.
    func start() {
        let alreadyStarted = state.withLock { state -> Bool in
            defer { state.started = true }
            return state.started
        }
        guard !alreadyStarted else { return }
        reportStallFromPreviousRun()
        let thread = Thread { [weak self] in self?.run() }
        thread.name = "com.yuedu.main-thread-monitor"
        // Not `.utility`: the stalls worth catching happen under heavy CPU load (68% in the
        // field watchdog reports), and a starved monitor tick looks like a suspension and
        // throws the stall away.
        thread.qualityOfService = .userInteractive
        thread.start()
        log.notice("⟐ main-thread monitor started")
    }

    /// The scene phase as the app sees it, carried into every stall record: a stall on the
    /// way into the background is the one the watchdog kills for.
    func notePhase(_ phase: String) {
        let now = Self.now
        state.withLock { state in
            state.phase = phase
            if phase == "background" {
                if state.backgroundSince == nil { state.backgroundSince = now }
            } else {
                state.backgroundSince = nil
            }
        }
    }

    // MARK: - Monitor thread

    private func run() {
        while true {
            // A sampling tick on a dedicated thread, not a wait for state to settle. Past the
            // background window it only checks once a second whether the app came back.
            let idle = state.withLock { state in
                state.pingSentAt == nil
                    && state.backgroundSince.map { Self.now - $0 > backgroundWatchWindow } == true
            }
            Thread.sleep(forTimeInterval: idle ? 1 : interval)
            tick()
        }
    }

    private func tick() {
        let now = Self.now
        enum Action { case none, discard, ping, open(OpenStall), update(OpenStall) }
        let action: Action = state.withLock { state in
            let gap = now - state.lastTick
            state.lastTick = now
            if gap > suspensionGap {
                // The process was frozen; whatever was outstanding says nothing about main.
                let hadStall = state.openStall != nil
                state.pingSentAt = nil
                state.openStall = nil
                return hadStall ? .discard : .none
            }
            guard let sent = state.pingSentAt else {
                if let since = state.backgroundSince, now - since > backgroundWatchWindow {
                    return .none
                }
                state.pingSentAt = now
                return .ping
            }
            let waited = now - sent
            guard waited >= stallThreshold else { return .none }
            if var open = state.openStall {
                // Refresh the marker about once a second so a kill leaves a current figure.
                guard waited - open.lastMeasuredSeconds >= 1 else { return .none }
                open.lastMeasuredSeconds = waited
                open.activitiesLatest = MainThreadActivity.snapshot()
                state.openStall = open
                return .update(open)
            }
            let activities = MainThreadActivity.snapshot()
            let open = OpenStall(
                startedAt: sent, activitiesAtStart: activities, activitiesLatest: activities,
                phase: state.phase, lastMeasuredSeconds: waited, build: Self.build, wallClock: Date()
            )
            state.openStall = open
            return .open(open)
        }
        switch action {
        case .none:
            break
        case .discard:
            // Its marker would otherwise outlive it and be reported next launch as a death.
            removeMarker()
        case .ping:
            DispatchQueue.main.async { [weak self] in self?.mainAnswered() }
        case .open(let stall), .update(let stall):
            writeMarker(stall)
        }
    }

    // MARK: - Main thread

    private func mainAnswered() {
        let now = Self.now
        let finished: (OpenStall, Double)? = state.withLock { state in
            defer {
                state.pingSentAt = nil
                state.openStall = nil
            }
            guard let open = state.openStall, let sent = state.pingSentAt else { return nil }
            return (open, now - sent)
        }
        guard let (stall, seconds) = finished else { return }
        removeMarker()
        record(stall, seconds: seconds)
    }

    private func record(_ stall: OpenStall, seconds: Double) {
        let ms = Int(seconds * 1000)
        let during = Self.describe(stall)
        let message = "main thread blocked \(ms) ms · \(during)"
        log.error("⟐ \(message, privacy: .public)")
        DiagnosticLog.shared.record(
            severity: seconds >= reportThreshold ? .error : .warning,
            category: .general,
            message: "⟐ \(message)"
        )
        if seconds >= breadcrumbThreshold {
            CrashContext.breadcrumb(message)
        }
        if seconds >= reportThreshold {
            CrashContext.recordActivityIssue(
                name: "MainThreadStall",
                reason: "\(ms) ms \(during)",
                activities: stall.activitiesAtStart
            )
        }
    }

    private static func describe(_ stall: OpenStall) -> String {
        let start = stall.activitiesAtStart.isEmpty ? "no instrumented span" : stall.activitiesAtStart.joined(separator: " > ")
        var text = "during \(start) · phase \(stall.phase)"
        if stall.activitiesLatest != stall.activitiesAtStart {
            let latest = stall.activitiesLatest.isEmpty ? "none" : stall.activitiesLatest.joined(separator: " > ")
            text += " · later \(latest)"
        }
        return text
    }

    // MARK: - Marker

    private func writeMarker(_ stall: OpenStall) {
        do {
            let data = try JSONEncoder().encode(stall)
            try data.write(to: markerURL, options: .atomic)
        } catch {
            log.error("stall marker not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeMarker() {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: markerURL)
        } catch {
            log.error("stall marker not removed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reportStallFromPreviousRun() {
        guard FileManager.default.fileExists(atPath: markerURL.path) else { return }
        defer { removeMarker() }
        let stall: OpenStall
        do {
            stall = try JSONDecoder().decode(OpenStall.self, from: Data(contentsOf: markerURL))
        } catch {
            log.error("stall marker unreadable: \(error.localizedDescription, privacy: .public)")
            return
        }
        let seconds = String(format: "%.1f", stall.lastMeasuredSeconds)
        let message = "previous run died while the main thread was blocked ≥\(seconds) s · \(Self.describe(stall)) · build \(stall.build) · at \(stall.wallClock)"
        log.error("⟐ \(message, privacy: .public)")
        DiagnosticLog.shared.record(severity: .fault, category: .crash, message: "⟐ \(message)")
        CrashContext.breadcrumb(message)
        guard stall.lastMeasuredSeconds >= diedReportThreshold else { return }
        CrashContext.recordActivityIssue(
            name: "DiedDuringMainThreadStall",
            reason: "≥\(seconds) s \(Self.describe(stall)) build \(stall.build)",
            activities: stall.activitiesLatest.isEmpty ? stall.activitiesAtStart : stall.activitiesLatest
        )
    }
}
