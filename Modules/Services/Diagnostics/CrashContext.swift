import Foundation
import os
import FirebaseCrashlytics

/// Thin, thread-safe wrapper over Crashlytics for breadcrumbs, persistent context
/// keys, and non-fatals — so a crash report (or a MetricKit diagnostic, see
/// `MetricKitDiagnosticReporter`) says *what the app was doing*, not just an
/// anonymous stack. Crashlytics' own API is thread-safe, so these are safe to call
/// from any actor/queue. Compiled into the main app target only (`Modules/` is not
/// shared with the extensions, which don't link Crashlytics).
enum CrashContext {
    private static let log = Logger(subsystem: "com.yuedu.app", category: "CrashContext")

    /// A timestamped breadcrumb that shows up in the next crash/non-fatal report's
    /// log tab. Use for user actions and subsystem milestones.
    static func breadcrumb(_ message: String) {
        Crashlytics.crashlytics().log(message)
        log.debug("🍞 \(message, privacy: .public)")
    }

    /// A persistent key/value attached to every subsequent report (overwrites the
    /// previous value for the same key). Use for "current state" (open book,
    /// reader mode, syncing…).
    static func setKey(_ key: String, _ value: String) {
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    static func setKey(_ key: String, _ value: Int) {
        Crashlytics.crashlytics().setCustomValue(value, forKey: key)
    }

    static func setKey(_ key: String, _ value: Bool) {
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
        Crashlytics.crashlytics().record(error: NSError(domain: domain, code: code, userInfo: info))
        log.error("⚠️ non-fatal [\(domain, privacy: .public)] \(message, privacy: .public)")
    }
}
