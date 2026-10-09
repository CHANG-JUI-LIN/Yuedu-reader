import Foundation
import os
import FirebaseCore
import FirebaseCrashlytics

/// Thin, thread-safe wrapper over Crashlytics **and `DiagnosticLog`** for
/// breadcrumbs, persistent context
/// keys, and non-fatals — so a crash report (or a MetricKit diagnostic, see
/// `MetricKitDiagnosticReporter`) says *what the app was doing*, not just an
/// anonymous stack. Crashlytics' own API is thread-safe, so these are safe to call
/// from any actor/queue. Compiled into the main app target only (`Modules/` is not
/// shared with the extensions, which don't link Crashlytics).
enum CrashContext {
    private static let log = Logger(subsystem: "com.yuedu.app", category: "CrashContext")

    /// Crashlytics may only be touched after `FirebaseApp.configure()` (in the app delegate's
    /// `didFinishLaunching`). `App.init` and the stores it creates run before that, and since
    /// long main-thread spans became breadcrumbs they can call in here that early. Those lines
    /// still reach os_log and the diagnostic log; only the Crashlytics copy is skipped.
    private static var crashlyticsReady: Bool { FirebaseApp.app() != nil }

    /// A random id for this install, kept across launches. It is the Crashlytics user id, so
    /// every hang, crash and MetricKit report of one install can be listed together, and it
    /// travels with a diagnostic report the user sends (`DiagnosticReportUploader`) — one
    /// report number leads to everything else that install has reported. Not derived from
    /// anything about the person or the device.
    static var installID: String {
        let key = "yd_diagnostics_install_id"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    /// Call once Firebase is configured.
    static func identifyInstall() {
        guard crashlyticsReady else { return }
        Crashlytics.crashlytics().setUserID(installID)
    }

    /// A timestamped breadcrumb that shows up in the next crash/non-fatal report's
    /// log tab. Use for user actions and subsystem milestones.
    static func breadcrumb(_ message: String) {
        if crashlyticsReady { Crashlytics.crashlytics().log(message) }
        log.debug("🍞 \(message, privacy: .public)")
        DiagnosticLog.shared.record(severity: .info, category: .general, message: "🍞 \(message)")
    }

    /// A persistent key/value attached to every subsequent report (overwrites the
    /// previous value for the same key). Use for "current state" (open book,
    /// reader mode, syncing…).
    static func setKey(_ key: String, _ value: String) {
        guard crashlyticsReady else { return }
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    static func setKey(_ key: String, _ value: Int) {
        guard crashlyticsReady else { return }
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    static func setKey(_ key: String, _ value: Bool) {
        guard crashlyticsReady else { return }
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    /// Record a non-fatal error so it surfaces in Crashlytics without crashing the
    /// app. `extra` becomes additional info on the report.
    static func recordNonFatal(
        domain: String,
        code: Int = 0,
        message: String,
        extra: [String: String] = [:]
    ) {
        var info: [String: Any] = [NSLocalizedDescriptionKey: message]
        for (key, value) in extra { info[key] = value }
        if crashlyticsReady {
            Crashlytics.crashlytics().record(error: NSError(domain: domain, code: code, userInfo: info))
        }
        log.error("⚠️ non-fatal [\(domain, privacy: .public)] \(message, privacy: .public)")
        DiagnosticLog.shared.record(
            severity: .error,
            category: .general,
            message: "⚠️ non-fatal [\(domain)] \(message)",
            detail: extra.isEmpty ? nil : extra.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")
        )
    }

    /// Records a MetricKit diagnostic as an exception whose stack is the diagnostic's own
    /// heaviest path. Frames whose binary is loaded in this process go as addresses, which
    /// Crashlytics' backend symbolicates against the uploaded dSYM; the rest go as text.
    /// `extra` becomes custom keys, which Crashlytics snapshots into the report.
    static func recordMetricKitDiagnostic(
        kind: String,
        reason: String,
        frames: [MetricKitCallStack.Frame],
        extra: [String: String]
    ) {
        guard crashlyticsReady else { return }
        let crashlytics = Crashlytics.crashlytics()
        for (key, value) in extra { crashlytics.setCustomValue(value, forKey: "mk_\(key)") }
        let model = ExceptionModel(name: "MetricKit.\(kind)", reason: reason)
        model.stackTrace = frames.map { frame in
            if let address = frame.loadedAddress {
                return StackFrame(address: address)
            }
            return StackFrame(symbol: frame.readable, file: frame.binaryName ?? frame.binaryUUID, line: 0)
        }
        crashlytics.record(exceptionModel: model)
        log.error("⚠️ MetricKit \(kind, privacy: .public) recorded: \(reason, privacy: .public)")
    }

    /// Records an issue whose "stack" is the app's own activity names (innermost first), so
    /// Crashlytics groups it by what the app was doing — e.g. a main-thread stall during
    /// `library.shelf.save` is one issue, during `library.chapters.read` another.
    static func recordActivityIssue(name: String, reason: String, activities: [String]) {
        guard crashlyticsReady else { return }
        let model = ExceptionModel(name: name, reason: reason)
        let frames = activities.isEmpty ? ["(no instrumented span)"] : Array(activities.reversed())
        model.stackTrace = frames.map { StackFrame(symbol: $0, file: "activity", line: 0) }
        Crashlytics.crashlytics().record(exceptionModel: model)
        log.error("⚠️ \(name, privacy: .public): \(reason, privacy: .public)")
    }
}
