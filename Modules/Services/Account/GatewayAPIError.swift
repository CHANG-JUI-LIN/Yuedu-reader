import Foundation

enum GatewayAPIError: Error {
    /// No Gateway URL is baked into this build.
    case notConfigured
    /// The device could not reach the Gateway (DNS, TLS, timeout, offline).
    case transport(URLError)
    /// The Gateway answered with a structured error. `details` keeps the scalar fields of the
    /// wire object (`grpcCode`, `grpcStatus`, `pendingToken`, …); see `GatewayAPIClient`.
    case server(code: String, message: String, status: Int, details: [String: any Sendable])
    /// A 2xx response that did not match the contract.
    case invalidResponse

    var serverCode: String? {
        if case .server(let code, _, _, _) = self { return code }
        return nil
    }

    var details: [String: any Sendable] {
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

    /// The ID token itself was rejected (expired or revoked), so a refresh may fix it.
    /// Other 401s — `reauth-required`, a wrong password — are not helped by one, and
    /// resending a password only counts as another failed attempt.
    var isStaleToken: Bool {
        serverCode == "unauthenticated"
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
        case .server(let code, _, _, let details):
            // The Gateway's own text is English and technical (a zh-Hans deletion
            // showed "Apple access could not be revoked."); read the code instead.
            return Self.localizedMessage(code: code, upstream: details["upstream"] as? String)
        case .invalidResponse:
            return localized("中轉服務回應格式不正確")
        }
    }

    private static func localizedMessage(code: String, upstream: String?) -> String {
        switch code {
        case "invalid-credentials":
            return localized("登入資訊不正確，請再試一次")
        case "wrong-account":
            return localized("請用這個帳號已連結的 Apple 或 Google 帳號驗證")
        case "email-exists":
            return localized("這個電子郵件已被其他帳號使用")
        case "user-disabled":
            return localized("這個帳號已被停用")
        case "user-not-found":
            return localized("這個帳號已不存在")
        case "unauthenticated":
            return localized("登入狀態已失效，請重新登入")
        case "reauth-required":
            return localized("為了保護帳號安全，請重新登入後再試")
        case "provider-already-linked":
            return localized("這個帳號已經連結過此登入方式")
        case "credential-already-in-use":
            return localized("此登入方式屬於另一個帳號。你可以改用它登入那個帳號，或先在那個帳號解除連結。")
        case "cannot-unlink-last-provider":
            return localized("這是唯一的登入方式，解除後就無法再登入，請先連結另一種方式")
        case "rate-limited":
            return localized("嘗試次數過多，請稍後再試")
        case "upstream-unavailable":
            return localized("服務暫時無法使用，請稍後再試")
        case "apple-revoke-failed":
            return localized("無法撤銷 Apple 授權，帳號沒有被刪除，請稍後再試")
        case "cleanup-failed":
            return localized("帳號資料沒有刪除完成，帳號仍保留，請再試一次")
        case "invalid-argument" where upstream == "WEAK_PASSWORD":
            return localized("密碼至少需要 6 個字元")
        case "invalid-argument" where upstream?.hasPrefix("INVALID_EMAIL") == true:
            return localized("電子郵件格式不正確")
        default:
            return String(format: localized("伺服器無法完成這個請求（%@）"), code)
        }
    }
}
