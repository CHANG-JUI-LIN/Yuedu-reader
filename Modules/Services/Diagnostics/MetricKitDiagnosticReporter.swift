import Foundation
import MetricKit
import os

/// Subscribes to MetricKit and routes **diagnostics** — crash, hang, CPU-exception,
/// disk-write-exception — to os_log + Crashlytics (as non-fatals with the call
/// stack attached). iOS delivers these to the app on the next launch after the
/// event, so a user hitting the exact "cpu_resource" / "diskwrites_resource"
/// reports we've been chasing no longer has to manually export an `.ips` from
/// Settings: it lands in Crashlytics automatically, and (with the dSYM-upload build
/// phase) symbolicated.
///
/// Register once at launch via `MetricKitDiagnosticReporter.shared.start()` —
/// currently from `RSSAppNotificationDelegate.application(_:didFinishLaunchingWithOptions:)`,
/// which is an odd home but is the app's only `UIApplicationDelegate` and therefore
/// the earliest reliable hook. The deployment target is iOS 17, well past the iOS 14
/// / 15 floors of every MetricKit diagnostic API used here, so no availability
/// checks are needed. No mutable state → safe as an `@unchecked Sendable` singleton.
///
/// Payloads also land in `DiagnosticLog` so 設定 → 診斷與回報 can show a crash or
/// hang to the person who hit it. Crashlytics is the developer's copy; that is the
/// user's.
final class MetricKitDiagnosticReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitDiagnosticReporter()

    private let log = Logger(subsystem: "com.yuedu.app", category: "MetricKit")

    func start() {
        MXMetricManager.shared.add(self)
        log.notice("⟐ MetricKit subscriber registered")
    }

    /// Crash and hang payloads never arrive in the Simulator — MetricKit only
    /// delivers on device. Without this the whole crash section of the diagnostics
    /// screen would be untestable until a real device crashed, so DEBUG builds can
    /// stage one.
    #if DEBUG
    func injectSampleDiagnosticForTesting() {
        DiagnosticLog.shared.record(
            severity: .fault,
            category: .crash,
            message: "crash: reason=SIMULATED signal=SIGSEGV excType=EXC_BAD_ACCESS",
            detail: "meta={\"simulated\":true}\ncallStack=<injected by injectSampleDiagnosticForTesting()>"
        )
    }
    #endif

    // MARK: - Metrics (daily aggregate). Cheap one-liners; the diagnostics below
    // are the valuable part.

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            log.notice("⟐ MXMetricPayload v\(payload.latestApplicationVersion, privacy: .public): \(payload.dictionaryRepresentation().count) metric group(s)")
        }
    }

    // MARK: - Diagnostics (crash / hang / cpu / disk) — the actionable signal.

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for d in payload.cpuExceptionDiagnostics ?? [] {
                report(
                    kind: "cpu-exception",
                    summary: "cpu=\(d.totalCPUTime) sampled=\(d.totalSampledTime)",
                    callStack: d.callStackTree, meta: d.metaData
                )
            }
            for d in payload.diskWriteExceptionDiagnostics ?? [] {
                report(
                    kind: "disk-write-exception",
                    summary: "writesCaused=\(d.totalWritesCaused)",
                    callStack: d.callStackTree, meta: d.metaData
                )
            }
            for d in payload.hangDiagnostics ?? [] {
                report(
                    kind: "hang",
                    summary: "hangDuration=\(d.hangDuration)",
                    callStack: d.callStackTree, meta: d.metaData
                )
            }
            for d in payload.crashDiagnostics ?? [] {
                let reason = d.terminationReason ?? "unknown"
                let signal = d.signal?.stringValue ?? "?"
                let excType = d.exceptionType?.stringValue ?? "?"
                report(
                    kind: "crash",
                    summary: "reason=\(reason) signal=\(signal) excType=\(excType)",
                    callStack: d.callStackTree, meta: d.metaData
                )
            }
        }
    }

    private func report(kind: String, summary: String, callStack: MXCallStackTree, meta: MXMetaData) {
        let stackJSON = String(data: callStack.jsonRepresentation(), encoding: .utf8) ?? "<unavailable>"
        let metaJSON = String(data: meta.jsonRepresentation(), encoding: .utf8) ?? "{}"

        // Full detail to the device log (Console / sysdiagnose).
        log.error("⟐ MetricKit \(kind, privacy: .public): \(summary, privacy: .public)\nmeta=\(metaJSON, privacy: .public)\ncallStack=\(stackJSON, privacy: .public)")

        // And to Crashlytics as a non-fatal so it surfaces in the dashboard with the
        // call stack attached. (Truncate the stack: Crashlytics value limits.)
        // The user-visible copy. `detail` carries the whole payload: the call stack is
        // the entire value of a crash report, and truncating it here would leave the
        // in-app report strictly worse than the dashboard's.
        DiagnosticLog.shared.record(
            severity: .fault,
            category: .crash,
            message: "\(kind): \(summary)",
            detail: "meta=\(metaJSON)\ncallStack=\(stackJSON)"
        )

        CrashContext.breadcrumb("MetricKit \(kind): \(summary)")
        CrashContext.recordNonFatal(
            domain: "MetricKitDiagnostic.\(kind)",
            message: "\(kind): \(summary)",
            extra: [
                "meta": String(metaJSON.prefix(900)),
                "callStackTree": String(stackJSON.prefix(7000)),
            ]
        )
    }
}
