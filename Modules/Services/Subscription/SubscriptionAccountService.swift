import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import Foundation
import StoreKit
import os

private let subscriptionAccountLog = Logger(
    subsystem: "com.zhangruilin.yuedureader",
    category: "SubscriptionAccount"
)

@MainActor
final class SubscriptionAccountService {
    static let shared = SubscriptionAccountService()

    private let functionsRegion = "asia-east1"

    private init() {}

    var isAuthenticated: Bool {
        Auth.auth().currentUser != nil
    }

    /// The last entitlement this device saw the backend verify for the signed-in
    /// UID, readable synchronously and without a network round-trip. Returns nil
    /// when signed out, before Firebase is configured, or when this UID was never
    /// verified here. An expired subscription reads as `false` through
    /// `isActive()`, so this cannot keep a lapsed monthly plan alive offline.
    func cachedEntitlement() -> Bool? {
        guard FirebaseApp.app() != nil, let uid = Auth.auth().currentUser?.uid else { return nil }
        return SubscriptionEntitlementCache.load(uid: uid)?.isActive()
    }

    /// Whether a failed `bind` is worth retrying later. Anything that isn't a
    /// Cloud Functions status — a URLSession failure, a decoding error — is
    /// treated as temporary, since those are the shapes an unreachable backend
    /// takes.
    nonisolated func isRetryable(_ error: Error) -> Bool {
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
        let result = try await Functions.functions(region: functionsRegion)
            .httpsCallable("getSubscriptionAccountToken")
            .call()
        guard let payload = result.data as? [String: Any],
              let rawToken = payload["token"] as? String,
              let token = UUID(uuidString: rawToken) else {
            throw SubscriptionAccountError.invalidServerResponse
        }
        return token
    }

    func bind(transaction: StoreKit.VerificationResult<StoreKit.Transaction>) async throws -> Bool {
        guard let uid = Auth.auth().currentUser?.uid else {
            throw SubscriptionAccountError.authenticationRequired
        }
        let jws: String = transaction.jwsRepresentation
        do {
            let result = try await Functions.functions(region: functionsRegion)
                .httpsCallable("bindSubscriptionPurchase")
                .call(["signedTransaction": jws])
            let entitlement = try entitlement(from: result.data)
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
    /// entitlement document for this UID, or Firebase is unreachable and this
    /// device never cached a verified value. The caller keeps the last value for
    /// the same signed-in UID instead of revoking valid access.
    func refreshEntitlement() async -> Bool? {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        do {
            // `.server`, not the default source: the default attempts the server
            // and silently falls back to Firestore's own offline cache, so an
            // unreachable backend answered with either a missing document (read
            // below as "never verified") or a stale pre-purchase document whose
            // `false` would overwrite the verified keychain value. Both looked
            // like a successful read, so the catch branch that consults the
            // keychain was never reached. Requiring the server makes an applied
            // value provably authoritative and routes an unreachable Firebase
            // into that catch branch.
            let snapshot = try await Firestore.firestore()
                .collection("entitlements")
                .document(uid)
                .getDocument(source: .server)
            guard SubscriptionEntitlementRefreshPolicy.shouldApplyServerValue(
                documentExists: snapshot.exists
            ), let data = snapshot.data() else {
                // Missing document means "never verified on this backend" (e.g. a
                // purchase made while signed out, bound only later on sign-in), not
                // "no entitlement". Applying its absent value as false would revoke
                // previously verified access once Firebase becomes reachable — the
                // real China + VPN case behind "opening the tunnel drops Pro".
                subscriptionAccountLog.notice(
                    "No entitlement document for uid; keeping cached value"
                )
                return nil
            }
            let entitlement = CachedSubscriptionEntitlement(
                isProActive: data["isProActive"] as? Bool == true,
                expiresAt: (data["expiresAt"] as? Timestamp)?.dateValue()
            )
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
        guard let uid = Auth.auth().currentUser?.uid else { return }
        _ = try await Functions.functions(region: functionsRegion)
            .httpsCallable("deleteSubscriptionAccountData")
            .call()
        SubscriptionEntitlementCache.delete(uid: uid)
    }

    private func entitlement(from value: Any) throws -> CachedSubscriptionEntitlement {
        guard let payload = value as? [String: Any],
              let isProActive = payload["isProActive"] as? Bool else {
            throw SubscriptionAccountError.invalidServerResponse
        }
        let expiresAt: Date?
        if let milliseconds = payload["expiresAtMilliseconds"] as? NSNumber {
            expiresAt = Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
        } else {
            expiresAt = nil
        }
        return CachedSubscriptionEntitlement(isProActive: isProActive, expiresAt: expiresAt)
    }
}

enum SubscriptionAccountError: Error {
    case authenticationRequired
    case invalidServerResponse
}
