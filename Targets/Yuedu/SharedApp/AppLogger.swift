import Foundation
import os.log

// MARK: - Structured Logging Module
//
// Replaces silent failures scattered across the codebase.
// Release builds use os_log, viewable in Console.app without affecting the UI.
// Debug builds additionally output to stderr for developer visibility.
//
// Every call also lands in `DiagnosticLog`, which keeps a bounded copy on disk for
// 設定 → 診斷與回報. That is why the single funnel at the bottom of this file
// matters: it is the one place all ~330 call sites pass through, so the device-
// readable log needed no changes at any of them.

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.yuedu.app"

    // MARK: - Categories

    private static let networkLog = Logger(subsystem: subsystem, category: "network")
    private static let parseLog   = Logger(subsystem: subsystem, category: "parse")
    private static let renderLog  = Logger(subsystem: subsystem, category: "render")
    private static let cacheLog   = Logger(subsystem: subsystem, category: "cache")
    private static let securityLog = Logger(subsystem: subsystem, category: "security")
    private static let generalLog = Logger(subsystem: subsystem, category: "general")
    private static let syncLog    = Logger(subsystem: subsystem, category: "sync")

    // MARK: - Public API
    //
    // `level` is optional so the existing call sites keep working unchanged. Pass it
    // in new code — the inferred value is a best-effort reading of the message (see
    // `resolvedSeverity`), and an explicit level is always better.

    static func network(_ message: String, error: Error? = nil, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: networkLog, level: .error, message: message, error: error, context: context,
            category: .network, severity: level, defaultSeverity: .notice)
    }

    static func parse(_ message: String, error: Error? = nil, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: parseLog, level: .error, message: message, error: error, context: context,
            category: .parse, severity: level, defaultSeverity: .notice)
    }

    static func render(_ message: String, error: Error? = nil, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: renderLog, level: .error, message: message, error: error, context: context,
            category: .reader, severity: level, defaultSeverity: .notice)
    }

    static func cache(_ message: String, error: Error? = nil, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: cacheLog, level: .error, message: message, error: error, context: context,
            category: .cache, severity: level, defaultSeverity: .notice)
    }

    /// iCloud / Firestore / WebDAV. These subsystems used to hold their own
    /// `Logger` instances with three different subsystem strings between them, which
    /// meant none of their output reached the in-app log.
    static func sync(_ message: String, error: Error? = nil, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: syncLog, level: .error, message: message, error: error, context: context,
            category: .sync, severity: level, defaultSeverity: .notice)
    }

    static func security(_ message: String, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: securityLog, level: .fault, message: message, error: nil, context: context,
            category: .security, severity: level, defaultSeverity: .fault)
    }

    static func info(_ message: String, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: generalLog, level: .info, message: message, error: nil, context: context,
            category: .general, severity: level, defaultSeverity: .info)
    }

    static func error(_ message: String, error: Error? = nil, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: generalLog, level: .error, message: message, error: error, context: context,
            category: .general, severity: level, defaultSeverity: .error)
    }

    /// An invariant the code guarantees did not hold.
    ///
    /// Separate from `error` on purpose: an error is something that went wrong out
    /// there — a request failed, a file was missing. An anomaly is the app doing
    /// something it promised it would not, which is the only class of event the
    /// diagnostics screen asks the user to report. Keep the bar there; a chatty
    /// anomaly is worse than no anomaly, because it teaches people to ignore the
    /// banner.
    ///
    /// `detail` carries whatever makes the report actionable — a position trail, the
    /// two values that disagreed — and is shown when the row is expanded.
    static func anomaly(
        _ message: String,
        category: DiagnosticCategory = .general,
        detail: String? = nil,
        context: [String: Any] = [:]
    ) {
        log(logger: generalLog, level: .fault, message: message, error: nil, context: context,
            category: category, severity: .anomaly, defaultSeverity: .anomaly, detail: detail)
    }

    // MARK: - Severity inference

    /// How a line's severity is decided when the caller did not say.
    ///
    /// ⚠️ **Documented heuristic.** The six category functions (`render`, `parse`,
    /// `cache`, `network`, …) name a *subsystem*, not a severity — but every one of
    /// them has always logged at `.error`. Taken literally that makes ~300 call sites
    /// "errors", including every `[FlipTrace]` breadcrumb describing a normal page
    /// turn, which would leave the diagnostics screen's severity filter meaningless.
    ///
    /// So severity is read from two structural signals plus the house marker
    /// convention, in order:
    ///
    /// 1. A `⏱` prefix, or a `[SomethingTrace]` / `[SomethingDebug]` / `[Something-DIAG]`
    ///    tag — these families are step-by-step narration by construction, and matching
    ///    on the suffix keeps the next one somebody adds classified without a code
    ///    change. `[ANNOT-DIAG]` earned its place the hard way: it was 2656 of the 6000
    ///    entries in a real exported log, 44% of the budget, crowding out the anomalies
    ///    the export existed to carry.
    /// 2. **The caller passed an `Error`.** That is the caller stating that something
    ///    failed, and it is the one signal here that is not a naming convention.
    /// 3. A `⟐` structured-probe marker → `.notice`.
    /// 4. Otherwise the function's own level: `security` is a fault, `error` is an
    ///    error, and a bare subsystem line with no `Error` attached is a `.notice`.
    ///
    /// **The real fix is an explicit `level:` at each call site**, which every one of
    /// these functions now accepts. **Delete this, and the `severity == nil` branch
    /// that calls it, once the call sites carry their own level.**
    private static let noticePrefix = "⟐"
    private static let timingPrefix = "⏱"
    private static let traceTagSuffixes = ["trace]", "debug]", "diag]"]

    /// Exposed for tests; not meant to be called directly.
    static func resolvedSeverity(
        message: String,
        default fallback: DiagnosticSeverity,
        carriesError: Bool = false
    ) -> DiagnosticSeverity {
        let text = body(of: message)

        if text.hasPrefix(timingPrefix) { return .trace }
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            let tag = text[text.startIndex...close].lowercased()
            if traceTagSuffixes.contains(where: { tag.hasSuffix($0) }) { return .trace }
        }

        if carriesError { return max(fallback, .error) }
        if text.hasPrefix(noticePrefix) { return max(fallback, .notice) }
        return fallback
    }

    /// TTS spans several files that all log through `render`/`error`, so the category
    /// is read off the message's own prefix rather than asking 160-odd call sites to
    /// move to a new function. Same bargain as above, and it goes away the same way.
    private static let ttsPrefix = "[TTS]"

    /// The category a message belongs to, which is the calling function's category
    /// unless the message tags itself as something more specific.
    static func resolvedCategory(message: String, declared: DiagnosticCategory) -> DiagnosticCategory {
        body(of: message).hasPrefix(ttsPrefix) ? .tts : declared
    }

    /// The message with any leading spaces skipped, as a view rather than a copy.
    ///
    /// `trimmingCharacters` would allocate a second `String` for every log line, and
    /// this runs on the reader's page-turn path where `AppLogger.render` is called
    /// several times per turn. A `Substring` borrows the original's storage.
    private static func body(of message: String) -> Substring {
        var index = message.startIndex
        while index < message.endIndex, message[index] == " " || message[index] == "\t" {
            index = message.index(after: index)
        }
        return message[index...]
    }

    // MARK: - Private

    /// `true` for the two functions whose names are severities rather than
    /// subsystems. Only these keep `.error`/`.fault` with no `Error` attached.
    private static func log(
        logger: Logger,
        level: OSLogType,
        message: String,
        error: Error?,
        context: [String: Any],
        category: DiagnosticCategory,
        severity: DiagnosticSeverity?,
        defaultSeverity: DiagnosticSeverity,
        detail: String? = nil
    ) {
        var parts = [message]
        if let error {
            parts.append("error=\(error.localizedDescription)")
        }
        if !context.isEmpty {
            let ctxStr = context.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
            parts.append("[\(ctxStr)]")
        }
        let fullMessage = parts.joined(separator: " | ")

        switch level {
        case .fault:
            logger.fault("\(fullMessage, privacy: .public)")
        case .error:
            logger.error("\(fullMessage, privacy: .public)")
        case .info:
            logger.info("\(fullMessage, privacy: .public)")
        default:
            logger.debug("\(fullMessage, privacy: .public)")
        }

        DiagnosticLog.shared.record(
            severity: severity ?? resolvedSeverity(
                message: message, default: defaultSeverity, carriesError: error != nil
            ),
            category: resolvedCategory(message: message, declared: category),
            message: fullMessage,
            detail: detail
        )

        #if DEBUG
        let prefix: String
        switch level {
        case .fault:  prefix = "[SECURITY]"
        case .error:  prefix = "[ERROR]"
        case .info:   prefix = "[INFO]"
        default:      prefix = "[DEBUG]"
        }
        print("\(prefix) \(fullMessage)")
        #endif
    }
}
