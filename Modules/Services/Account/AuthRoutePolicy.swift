import Foundation

/// Where account traffic goes. Persisted in UserDefaults and exposed in
/// Settings so the route is testable and switchable without a rebuild.
enum AuthRouteMode: String, CaseIterable, Identifiable {
    case automatic
    case direct
    case gateway

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .automatic: return "自動"
        case .direct: return "直連 Firebase"
        case .gateway: return "中轉服務"
        }
    }
}

enum AuthRoute: String, Equatable {
    case direct
    case gateway
}

/// Why the initial route was chosen. Kept explicit so diagnostics can tell a
/// remembered success apart from a region guess.
enum AuthRouteDecision: Equatable {
    case remembered(AuthRoute)
    case regionHint(AuthRoute)
    case mode(AuthRoute)
    case unavailableGatewayFallback
}

enum AuthRoutePolicy {
    /// Route selection never depends on Remote Config (which itself needs
    /// Firebase reachable). It uses only local state: the persisted mode, the
    /// remembered last successful route, and a regional hint that is treated as
    /// a hint — never as proof of reachability.
    static func decide(
        mode: AuthRouteMode,
        gatewayConfigured: Bool,
        lastSuccessfulRoute: AuthRoute?,
        regionHintIsMainland: Bool
    ) -> (route: AuthRoute, decision: AuthRouteDecision) {
        switch mode {
        case .direct:
            return (.direct, .mode(.direct))
        case .gateway:
            guard gatewayConfigured else {
                return (.direct, .unavailableGatewayFallback)
            }
            return (.gateway, .mode(.gateway))
        case .automatic:
            if let lastSuccessfulRoute {
                // A remembered Gateway route is only usable when this build has
                // an entry point at all; otherwise fall back to direct so a
                // release binary can never prefer an undeployed relay.
                if lastSuccessfulRoute == .gateway, !gatewayConfigured {
                    return (.direct, .unavailableGatewayFallback)
                }
                return (lastSuccessfulRoute, .remembered(lastSuccessfulRoute))
            }
            guard gatewayConfigured else {
                return (.direct, .unavailableGatewayFallback)
            }
            return regionHintIsMainland ? (.gateway, .regionHint(.gateway)) : (.direct, .regionHint(.direct))
        }
    }

    /// Region is a hint only. Storefront / language are deliberately not used:
    /// a Chinese App Store account on a US network must still sign in.
    static func regionHintIsMainland(locale: Locale = .current, timeZone: TimeZone = .current) -> Bool {
        if locale.region?.identifier == "CN" { return true }
        return timeZone.identifier == "Asia/Shanghai" || timeZone.identifier == "Asia/Chongqing"
    }
}

enum AuthRouteFallbackPolicy {
    /// Only idempotent sign-in may silently retry on the other route after a
    /// connectivity failure. Sign-up, linking, deletion and purchase binding
    /// have side effects; switching routes after an ambiguous failure could
    /// double-create an account or a binding, so they never auto-retry.
    static func allowsAutomaticRouteSwitch(operation: AccountOperation) -> Bool {
        switch operation {
        case .signInWithEmail, .signInWithApple, .signInWithGoogle:
            return true
        case .signUpWithEmail, .link, .unlink, .deleteAccount, .bindPurchase, .sendPasswordReset:
            return false
        }
    }
}

enum AccountOperation: Equatable {
    case signInWithEmail
    case signUpWithEmail
    case signInWithApple
    case signInWithGoogle
    case link
    case unlink
    case deleteAccount
    case bindPurchase
    case sendPasswordReset
}
