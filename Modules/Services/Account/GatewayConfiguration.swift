import Foundation

/// Resolves the Gateway entry point from the app bundle. The value is injected
/// at build time (`GATEWAY_BASE_URL` build setting → `GatewayBaseURL` plist key)
/// so the shipped binary can point at a controlled HTTPS host without a
/// Remote Config round trip.
enum GatewayConfiguration {
    static let infoPlistKey = "GatewayBaseURL"

    static var baseURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("$(") else { return nil }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host else {
            return nil
        }
        if scheme == "https" { return url }
        // Plain HTTP is only accepted for loopback development hosts; it never
        // relaxes ATS or permits arbitrary third-party endpoints.
        if scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(host) {
            return url
        }
        return nil
    }

    static var isConfigured: Bool {
        baseURL != nil
    }
}
