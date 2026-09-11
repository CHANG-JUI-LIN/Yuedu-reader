import Foundation

/// Backend surface the app needs after sign-in: profile, avatar, subscription
/// and TestFlight. Two implementations exist — the existing Firebase SDK path
/// and the Gateway path — behind one protocol so no caller branches.
@MainActor
protocol AccountBackend: AnyObject {
    func fetchProfile(uid: String) async throws -> UserProfile?
    func upsertProfile(_ profile: UserProfile) async throws
    func uploadAvatar(data: Data) async throws -> URL
    /// Nil means the backend has no authoritative value (never "not Pro").
    /// Throws when the backend could not be reached.
    func refreshEntitlement(uid: String) async throws -> CachedSubscriptionEntitlement?
    func accountToken() async throws -> UUID
    func bind(signedTransaction: String) async throws -> CachedSubscriptionEntitlement
    func deleteSubscriptionAccountData() async throws
    func requestTestFlightAccess(email: String) async throws -> TestFlightAccessResult
    func deleteRemoteData(uid: String) async throws
}

enum AccountBackendError: Error {
    case notAuthenticated
    case unsupportedOnGateway
    case invalidResponse
}

@MainActor
final class AccountBackendRouter {
    static let shared = AccountBackendRouter()

    let firebase = FirebaseAccountBackend()
    let gateway = GatewayAccountBackend()

    /// Effective backend for the live session. The Gateway session store is the
    /// source of truth: profile/avatar/subscription calls only happen while
    /// signed in, and a Gateway session means those calls must not touch
    /// Google-hosted endpoints.
    var current: AccountBackend {
        GatewaySessionStore.shared.hasSession ? gateway : firebase
    }

    func backend(for route: AuthRoute) -> AccountBackend {
        route == .gateway ? gateway : firebase
    }
}
