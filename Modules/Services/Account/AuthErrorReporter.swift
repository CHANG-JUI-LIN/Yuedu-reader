import FirebaseAuth
import Foundation
import os

/// Firebase's `internalError` surfaces only the unhelpful "An internal error has
/// occurred…" string; the real reason (e.g. a provider not enabled in the console)
/// lives inside the NSError userInfo. This digs it out for display + logging.
enum AuthErrorReporter {
    private static let logger = Logger(subsystem: "com.zhangruilin.yuedureader", category: "Auth")

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        logger.error("sign-in failed: domain=\(ns.domain, privacy: .public) code=\(ns.code) userInfo=\(ns.userInfo, privacy: .public)")

        if let server = serverMessage(from: ns) {
            if server.contains("CONFIGURATION_NOT_FOUND") || server.contains("OPERATION_NOT_ALLOWED") {
                return localized("此登入方式尚未在 Firebase 啟用，請在 Console 開啟對應的登入提供者")
            }
            return server
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           !underlying.localizedDescription.isEmpty {
            return "\(ns.localizedDescription)\n[\(underlying.domain) \(underlying.code)] \(underlying.localizedDescription)"
        }
        return ns.localizedDescription
    }

    /// Pulls the server-side message out of Firebase's deserialized response payload.
    private static func serverMessage(from error: NSError) -> String? {
        guard let response = error.userInfo["FIRAuthErrorUserInfoDeserializedResponseKey"] else {
            return nil
        }
        if let dict = response as? [String: Any] {
            if let errorDict = dict["error"] as? [String: Any], let message = errorDict["message"] as? String {
                return message
            }
            if let message = dict["message"] as? String {
                return message
            }
        }
        return String(describing: response)
    }
}
