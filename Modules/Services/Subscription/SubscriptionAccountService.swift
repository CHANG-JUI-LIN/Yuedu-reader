import FirebaseCore
import FirebaseFunctions
import Foundation
import StoreKit
import os

private let subscriptionAccountLog = Logger(
    subsystem: "com.zhangruilin.yuedureader",
    category: "SubscriptionAccount"
)

/// Account-side subscription operations, routed through whichever
/// `AccountBackend` the live session uses. The entitlement document shape and
/// environment separation are preserved on both routes.
@MainActor
final class SubscriptionAccountService {
    static let shared = SubscriptionAccountService()

    private init() {}

    var isAuthenticated: Bool {
        FirebaseAuthManager.shared.isAuthenticated
    }

    private var backend: AccountBackend {
        AccountBackendRouter.shared.current
    }

    /// The last entitlement this device saw the backend verify for the signed-in
    /// UID, readable synchronously and without a network round-trip. Returns nil
    /// when signed out, before Firebase is configured, or when this UID was never
    /// verified here. An expired subscription reads as `false` through
    /// `isActive()`, so this cannot keep a lapsed monthly plan alive offline.
    func cachedEntitlement() -> Bool? {
        guard FirebaseApp.app() != nil, let uid = FirebaseAuthManager.shared.uid else { return nil }
        return SubscriptionEntitlementCache.load(uid: uid)?.isActive()
    }

    /// Products behind the cached entitlement, or `nil` when this device has
    /// never seen the backend name them. Used to tell a lifetime purchase from a
    /// subscription without a round-trip; `nil` must stay "unknown".
    func cachedEntitlementProductIDs() -> [String]? {
        guard FirebaseApp.app() != nil, let uid = FirebaseAuthManager.shared.uid else { return nil }
        return SubscriptionEntitlementCache.load(uid: uid)?.productIDs
    }

    /// Whether a failed `bind` is worth retrying later. Transport failures — a
    /// URLSession error, an unreachable backend, a 5xx — are temporary. A
    /// structured rejection (conflict, permission, invalid payload) is not.
    nonisolated func isRetryable(_ error: Error) -> Bool {
        if let gatewayError = error as? GatewayAPIError {
            switch gatewayError.serverCode {
            case "invalid-argument", "permission-denied", "conflict", "unsupported-media-type", "payload-too-large":
                return false
            default:
                return true
            }
        }
        let nsError = error as NSError
        return SubscriptionBindRetryPolicy.shouldRetry(
            isFunctionsError: nsError.domain == FunctionsErrorDomain,
            code: nsError.code
        )
    }

    func accountToken() async throws -> UUID {
        guard isAuthenticated else {
            throw SubscriptionAccountError.authenticationRequired
        }
        return try await backend.accountToken()
    }

    func bind(transaction: StoreKit.VerificationResult<StoreKit.Transaction>) async throws -> Bool {
        guard let uid = FirebaseAuthManager.shared.uid else {
            throw SubscriptionAccountError.authenticationRequired
        }
        do {
            let entitlement = try await backend.bind(signedTransaction: transaction.jwsRepresentation)
            SubscriptionEntitlementCache.save(entitlement, uid: uid)
            return entitlement.isActive()
        } catch {
            subscriptionAccountLog.error(
                "bindSubscriptionPurchase failed for uid \(uid, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
    }

    /// Returns nil when nothing authoritative is available: the backend has no
    /// entitlement document for this UID, or it is unreachable and this device
    /// never cached a verified value. The caller keeps the last value for the
    /// same signed-in UID instead of revoking valid access.
    func refreshEntitlement() async -> Bool? {
        guard let uid = FirebaseAuthManager.shared.uid else { return false }
        // Without a resolved environment there is no correct field to read:
        // defaulting to `isProActive` would hand the App Store entitlement to a
        // TestFlight build. Nothing to say beats saying the wrong thing.
        guard SubscriptionRuntimeEnvironment.isResolved else { return nil }
        do {
            guard let entitlement = try await backend.refreshEntitlement(uid: uid) else {
                // No document means "never verified on this backend" (e.g. a
                // purchase made while signed out, bound only later on sign-in),
                // not "no entitlement". Applying its absent value as false would
                // revoke previously verified access.
                subscriptionAccountLog.notice(
                    "No entitlement document for uid; keeping cached value"
                )
                return nil
            }
            SubscriptionEntitlementCache.save(entitlement, uid: uid)
            subscriptionAccountLog.notice(
                "Entitlement document: uid \(uid, privacy: .public) isProActive \(entitlement.isProActive, privacy: .public)"
            )
            return entitlement.isActive()
        } catch {
            let cached = SubscriptionEntitlementCache.load(uid: uid)?.isActive()
            subscriptionAccountLog.error(
                "Account entitlement refresh failed: \(error.localizedDescription, privacy: .public); keychain cache \(String(describing: cached), privacy: .public)"
            )
            return cached
        }
    }

    func deleteAccountData() async throws {
        guard let uid = FirebaseAuthManager.shared.uid else { return }
        try await backend.deleteSubscriptionAccountData()
        SubscriptionEntitlementCache.delete(uid: uid)
    }
}

enum SubscriptionAccountError: Error {
    case authenticationRequired
    case invalidServerResponse
}
