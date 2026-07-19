import FirebaseAuth
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
        let result = try await Functions.functions(region: functionsRegion)
            .httpsCallable("bindSubscriptionPurchase")
            .call(["signedTransaction": jws])
        let entitlement = try entitlement(from: result.data)
        SubscriptionEntitlementCache.save(entitlement, uid: uid)
        return entitlement.isActive()
    }

    /// Returns nil only when Firebase is temporarily unavailable. The caller keeps
    /// the last value for the same signed-in UID instead of revoking valid access.
    func refreshEntitlement() async -> Bool? {
        guard let uid = Auth.auth().currentUser?.uid else { return false }
        do {
            let snapshot = try await Firestore.firestore()
                .collection("entitlements")
                .document(uid)
                .getDocument()
            let data = snapshot.data()
            let entitlement = CachedSubscriptionEntitlement(
                isProActive: data?["isProActive"] as? Bool == true,
                expiresAt: (data?["expiresAt"] as? Timestamp)?.dateValue()
            )
            SubscriptionEntitlementCache.save(entitlement, uid: uid)
            return entitlement.isActive()
        } catch {
            subscriptionAccountLog.error(
                "Account entitlement refresh failed: \(error.localizedDescription, privacy: .public)"
            )
            return SubscriptionEntitlementCache.load(uid: uid)?.isActive()
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
