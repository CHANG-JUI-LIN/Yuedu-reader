import Foundation
import os.log

// MARK: - Structured Logging Module
//
// Replaces silent failures scattered across the codebase.
// Release builds use os_log, viewable in Console.app without affecting the UI.
// Debug builds additionally output to stderr for developer visibility.

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.yuedu.app"

    // MARK: - Categories

    private static let networkLog = Logger(subsystem: subsystem, category: "network")
    private static let parseLog   = Logger(subsystem: subsystem, category: "parse")
    private static let renderLog  = Logger(subsystem: subsystem, category: "render")
    private static let cacheLog   = Logger(subsystem: subsystem, category: "cache")
    private static let securityLog = Logger(subsystem: subsystem, category: "security")
    private static let generalLog = Logger(subsystem: subsystem, category: "general")

    // MARK: - Public API

    static func network(_ message: String, error: Error? = nil, context: [String: Any] = [:]) {
        log(logger: networkLog, level: .error, message: message, error: error, context: context)
    }

    static func parse(_ message: String, error: Error? = nil, context: [String: Any] = [:]) {
        log(logger: parseLog, level: .error, message: message, error: error, context: context)
    }

    static func render(_ message: String, error: Error? = nil, context: [String: Any] = [:]) {
        log(logger: renderLog, level: .error, message: message, error: error, context: context)
    }

    static func cache(_ message: String, error: Error? = nil, context: [String: Any] = [:]) {
        log(logger: cacheLog, level: .error, message: message, error: error, context: context)
    }

    static func security(_ message: String, context: [String: Any] = [:]) {
        log(logger: securityLog, level: .fault, message: message, error: nil, context: context)
    }

    static func info(_ message: String, context: [String: Any] = [:]) {
        log(logger: generalLog, level: .info, message: message, error: nil, context: context)
    }

    static func error(_ message: String, error: Error? = nil, context: [String: Any] = [:]) {
        log(logger: generalLog, level: .error, message: message, error: error, context: context)
    }

    // MARK: - Private

    private static func log(
        logger: Logger,
        level: OSLogType,
        message: String,
        error: Error?,
        context: [String: Any]
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
