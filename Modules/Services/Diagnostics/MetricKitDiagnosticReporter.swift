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
/// Register once at launch via `MetricKitDiagnosticReporter.shared.start()`.
/// Deployment target is iOS 18, so all MetricKit diagnostic APIs are available
/// unconditionally. No mutable state → safe as an `@unchecked Sendable` singleton.
final class MetricKitDiagnosticReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitDiagnosticReporter()

    private let log = Logger(subsystem: "com.yuedu.app", category: "MetricKit")

    func start() {
        MXMetricManager.shared.add(self)
        log.notice("⟐ MetricKit subscriber registered")
    }

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
