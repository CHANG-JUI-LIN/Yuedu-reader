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
            category: .network, severity: level)
    }

    static func parse(_ message: String, error: Error? = nil, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: parseLog, level: .error, message: message, error: error, context: context,
            category: .parse, severity: level)
    }

    static func render(_ message: String, error: Error? = nil, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: renderLog, level: .error, message: message, error: error, context: context,
            category: .reader, severity: level)
    }

    static func cache(_ message: String, error: Error? = nil, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: cacheLog, level: .error, message: message, error: error, context: context,
            category: .cache, severity: level)
    }

    /// iCloud / Firestore / WebDAV. These subsystems used to hold their own
    /// `Logger` instances with three different subsystem strings between them, which
    /// meant none of their output reached the in-app log.
    static func sync(_ message: String, error: Error? = nil, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: syncLog, level: .error, message: message, error: error, context: context,
            category: .sync, severity: level)
    }

    static func security(_ message: String, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: securityLog, level: .fault, message: message, error: nil, context: context,
            category: .security, severity: level)
    }

    static func info(_ message: String, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: generalLog, level: .info, message: message, error: nil, context: context,
            category: .general, severity: level)
    }

    static func error(_ message: String, error: Error? = nil, context: [String: Any] = [:], level: DiagnosticSeverity? = nil) {
        log(logger: generalLog, level: .error, message: message, error: error, context: context,
            category: .general, severity: level)
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
            category: category, severity: .anomaly, detail: detail)
    }

    // MARK: - Severity inference

    /// Markers this codebase already uses as de-facto level tags.
    ///
    /// ⚠️ **This is a documented heuristic, not a guess.** `AppLogger.render` alone
    /// has ~150 call sites and every one of them is implicitly `.error`, but most
    /// carry `[FlipTrace]` breadcrumbs describing normal page turns. Without this
    /// mapping the diagnostics screen's "anomalies" count would equal "all reader
    /// logs" and the report banner would mean nothing.
    ///
    /// **The real fix is an explicit `level:` at each call site** (~50 of them carry
    /// these prefixes). This encodes the existing convention so that work can happen
    /// gradually instead of as a prerequisite.
    ///
    /// **Delete this — and the `severity == nil` branch that uses it — once those
    /// call sites pass `level:` explicitly.**
    private static let tracePrefixes = ["[FlipTrace]", "[ProgressTrace]", "⏱"]
    private static let noticePrefix = "⟐"

    /// TTS spans several files that all log through `render`/`error`, so the
    /// category is read off the message's own prefix rather than asking 160-odd call
    /// sites to move to a new function. Same bargain as `tracePrefixes` above, and
    /// it goes away the same way.
    private static let ttsPrefix = "[TTS]"

    /// The category a message belongs to, which is the calling function's category
    /// unless the message tags itself as something more specific.
    static func resolvedCategory(message: String, declared: DiagnosticCategory) -> DiagnosticCategory {
        body(of: message).hasPrefix(ttsPrefix) ? .tts : declared
    }

    /// Exposed for tests; not meant to be called directly.
    static func resolvedSeverity(message: String, implied: OSLogType) -> DiagnosticSeverity {
        let text = body(of: message)
        if tracePrefixes.contains(where: { text.hasPrefix($0) }) { return .trace }
        if text.hasPrefix(noticePrefix) { return .notice }

        switch implied {
        case .fault: return .fault
        case .error: return .error
        case .info:  return .info
        default:     return .trace
        }
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

    private static func log(
        logger: Logger,
        level: OSLogType,
        message: String,
        error: Error?,
        context: [String: Any],
        category: DiagnosticCategory,
        severity: DiagnosticSeverity?,
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
            severity: severity ?? resolvedSeverity(message: message, implied: level),
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
