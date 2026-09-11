import Foundation

enum GatewayAPIError: Error {
    /// No Gateway URL is baked into this build.
    case notConfigured
    /// The device could not reach the Gateway (DNS, TLS, timeout, offline).
    case transport(URLError)
    /// The Gateway answered with a structured error.
    case server(code: String, message: String, status: Int, details: [String: Any])
    /// A 2xx response that did not match the contract.
    case invalidResponse

    var serverCode: String? {
        if case .server(let code, _, _, _) = self { return code }
        return nil
    }

    var details: [String: Any] {
        if case .server(_, _, _, let details) = self { return details }
        return [:]
    }

    /// Transport-level failure: retryable later, but never evidence that the
    /// session or the account is invalid.
    var isConnectivityFailure: Bool {
        if case .transport = self { return true }
        if case .server(let code, _, _, _) = self, code == "upstream-unavailable" { return true }
        return false
    }

    /// The server has definitively rejected the session or the account.
    var isSessionInvalid: Bool {
        guard case .server(let code, _, _, _) = self else { return false }
        return code == "unauthenticated" || code == "user-disabled" || code == "user-not-found"
    }

    /// The operation needs a fresh credential before it can proceed.
    var requiresRecentAuth: Bool {
        serverCode == "reauth-required"
    }

    var isRateLimited: Bool {
        serverCode == "rate-limited"
    }

    var grpcCode: Int? {
        details["grpcCode"] as? Int
    }

    var grpcStatus: String? {
        details["grpcStatus"] as? String
    }
}

extension GatewayAPIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return localized("此版本未設定中轉服務")
        case .transport:
            return localized("目前無法連線中轉服務，請檢查網路後再試")
        case .server(_, let message, _, _):
            return message
        case .invalidResponse:
            return localized("中轉服務回應格式不正確")
        }
    }
}
