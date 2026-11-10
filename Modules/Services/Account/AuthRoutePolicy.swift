import FirebaseAuth
import Foundation

enum AuthRoute: String, Equatable {
    case direct
    case gateway
}

/// Why the initial route was chosen. Kept explicit so diagnostics can tell a
/// remembered success apart from a region guess or a live probe.
enum AuthRouteDecision: Equatable {
    case remembered(AuthRoute)
    case regionHint(AuthRoute)
    case probed(AuthRoute)
    case unavailableGatewayFallback
}

enum AuthRoutePolicy {
    /// Route selection never depends on Remote Config (which itself needs
    /// Firebase reachable). It uses only local state — the remembered last
    /// successful route and a regional hint — plus, when those do not already
    /// point at the Gateway, a short live probe of the direct Firebase host.
    ///
    /// The probe exists because a direct attempt from a blocked network does not
    /// fail fast: the Firebase Auth SDK sets no request timeout, so it waits out
    /// URLSession's 60 s default before the Gateway retry can start. That made the
    /// first sign-in in mainland China look broken while the second one (with the
    /// Gateway remembered) was instant. A remembered `.direct` is probed too: it is
    /// what a user who once signed in over a VPN or abroad carries into China.
    static func decide(
        gatewayConfigured: Bool,
        lastSuccessfulRoute: AuthRoute?,
        regionHintIsMainland: Bool,
        directReachable: () async -> Bool
    ) async -> (route: AuthRoute, decision: AuthRouteDecision) {
        // Without a relay entry point there is nothing to choose; a remembered
        // Gateway route from another build must never be preferred.
        guard gatewayConfigured else {
            return (.direct, .unavailableGatewayFallback)
        }
        if lastSuccessfulRoute == .gateway {
            return (.gateway, .remembered(.gateway))
        }
        if lastSuccessfulRoute == nil, regionHintIsMainland {
            return (.gateway, .regionHint(.gateway))
        }
        let route: AuthRoute = await directReachable() ? .direct : .gateway
        return (route, .probed(route))
    }

    /// Region is a hint only. Storefront / language are deliberately not used:
    /// a Chinese App Store account on a US network must still sign in.
    static func regionHintIsMainland(locale: Locale = .current, timeZone: TimeZone = .current) -> Bool {
        if locale.region?.identifier == "CN" { return true }
        return timeZone.identifier == "Asia/Shanghai" || timeZone.identifier == "Asia/Chongqing"
    }
}

/// Answers "does this network reach Firebase Auth directly right now?" with a
/// bounded round trip, so a blocked network costs seconds instead of the SDK's
/// 60 s timeout.
///
/// Guards a real, external failure: the Great Firewall blackholes or resets
/// `identitytoolkit.googleapis.com`, and the Firebase SDK exposes no timeout to
/// shorten. A false "unreachable" on a slow link only sends that sign-in through
/// the Gateway, which works everywhere. Delete this probe if the Gateway is
/// removed, or if the SDK ever gains a configurable request timeout.
enum DirectAuthReachability {
    static let probeURL = URL(string: "https://identitytoolkit.googleapis.com/")!
    static let timeout: TimeInterval = 3

    static func probe(session: URLSession = probeSession) async -> Bool {
        var request = URLRequest(url: probeURL)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        let started = Date()
        do {
            // Any HTTP answer (Google replies 404 here) proves the host is
            // reachable end to end, including TLS.
            let (_, response) = try await session.data(for: request)
            let reachable = response is HTTPURLResponse
            AppLogger.network("auth direct probe: \(reachable ? "reachable" : "no HTTP response") in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            return reachable
        } catch {
            AppLogger.network("auth direct probe failed after \(Int(Date().timeIntervalSince(started) * 1000)) ms", error: error)
            return false
        }
    }

    static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession.trusting(configuration)
    }()
}

enum AuthRouteFallbackPolicy {
    /// Operations whose initial route may resolve to the Gateway in a Release
    /// build. Email and Apple can: Apple's authorization sheet talks only to
    /// Apple (reachable from the mainland), and the resulting identity token is
    /// exchanged by the Gateway's `signInWithIdp` exactly as the SDK would.
    /// Google stays direct: its sign-in page (accounts.google.com) is itself
    /// blocked in the mainland, so a relay for the token exchange cannot help —
    /// the user never gets a token to exchange.
    static func isGatewayEligible(operation: AccountOperation) -> Bool {
        switch operation {
        case .signInWithEmail, .signUpWithEmail, .signInWithApple:
            return true
        case .signInWithGoogle, .link, .unlink, .deleteAccount, .bindPurchase,
             .sendPasswordReset:
            return false
        }
    }

    /// Only an idempotent sign-in may silently retry on the other route after a
    /// connectivity failure. Email sign-in and Apple sign-in qualify: repeating
    /// either lands on the same uid (Apple's `sub` maps to one account), so a
    /// request that did reach Firebase before the reply was lost costs nothing.
    /// Sign-up, linking, deletion and purchase binding have side effects;
    /// switching routes after an ambiguous failure could double-create an
    /// account or a binding, so they never auto-retry.
    static func allowsAutomaticRouteSwitch(operation: AccountOperation) -> Bool {
        operation == .signInWithEmail || operation == .signInWithApple
    }
}

/// Classifies an error for route decisions. Only transport-level failures may
/// trigger a switch; credential, permission and conflict answers from a
/// reachable backend never do — a route switch would just re-submit them.
enum AuthRouteErrorClassifier {
    static func isRouteFailure(_ error: Error) -> Bool {
        if let gatewayError = error as? GatewayAPIError {
            return gatewayError.isConnectivityFailure
        }
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain {
            return nsError.code == AuthErrorCode.networkError.rawValue
                || nsError.code == AuthErrorCode.webNetworkRequestFailed.rawValue
        }
        return nsError.domain == NSURLErrorDomain
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
