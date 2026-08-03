import CloudKit
import Foundation
import os

private let subscriptionICloudLog = Logger(
    subsystem: "com.zhangruilin.yuedureader",
    category: "SubscriptionICloud"
)

/// Cross-device mirror of a verified Pro entitlement, kept in the user's private
/// CloudKit database.
///
/// This is the only entitlement path that survives an App Store account switch
/// for a purchase made without a Yuedu account. CloudKit is keyed by the *iCloud*
/// account (Settings → Apple ID → iCloud), which iOS keeps separate from the App
/// Store account (Settings → Apple ID → Media & Purchases); switching storefronts
/// to download the app leaves it untouched. `SubscriptionEntitlementCache` cannot
/// cover this case because it is keyed by Firebase UID, and a guest purchase has
/// no UID to key on.
///
/// It is also the only remote entitlement store reachable from mainland China:
/// Chinese iCloud runs on `*.icloud.com.cn`, while every Firebase endpoint is a
/// Google domain.
///
/// Isolation matches `ICloudSyncManager`: a plain class whose CloudKit calls are
/// completion handlers wrapped in continuations. All callers come from
/// `SubscriptionStore` on the main actor.
final class SubscriptionICloudMirror {
    static let shared = SubscriptionICloudMirror()

    /// The CloudKit record type. It must be deployed from the Development to the
    /// Production environment in the CloudKit console before a release build can
    /// write it — Production does not create schema on the fly.
    static let recordType = "ProEntitlement"

    private enum Field {
        static let isProActive = "isProActive"
        static let expiresAt = "expiresAt"
        static let productIds = "productIds"
        static let signedTransaction = "signedTransaction"
        static let updatedAt = "updatedAt"
    }

    /// One record per iCloud account *per StoreKit environment*. A fixed name
    /// keeps every access a direct fetch by ID, so the record type needs no
    /// queryable index.
    ///
    /// The environment suffix keeps TestFlight and App Store entitlements apart:
    /// the mirror lives in the user's iCloud account, which both builds share, so
    /// a single record would have let a free TestFlight purchase unlock the App
    /// Store build on the same Apple ID.
    private static var recordName: String {
        "pro_entitlement" + SubscriptionRuntimeEnvironment.storageSuffix
    }

    private let container: CKContainer
    private let database: CKDatabase
    /// Last value written, so repeated refreshes that re-read the same StoreKit
    /// state don't spend a CloudKit write every time.
    private var lastWritten: CachedSubscriptionEntitlement?

    private init(
        container: CKContainer = CKContainer(identifier: ICloudSyncManager.containerIdentifier)
    ) {
        self.container = container
        database = container.privateCloudDatabase
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: Self.recordName)
    }

    // MARK: - Read

    /// The mirrored entitlement, or nil when iCloud is unavailable, no mirror was
    /// ever written for this iCloud account, or the record could not be read.
    /// Every one of those means "nothing to say", never "not subscribed" — the
    /// caller must not revoke access on nil.
    func load() async -> CachedSubscriptionEntitlement? {
        guard SubscriptionRuntimeEnvironment.isResolved, await isAvailable() else { return nil }
        do {
            let record = try await fetchRecord(recordID)
            guard let entitlement = entitlement(from: record) else { return nil }
            subscriptionICloudLog.notice(
                "iCloud mirror read: isProActive \(entitlement.isProActive, privacy: .public) active \(entitlement.isActive(), privacy: .public)"
            )
            return entitlement
        } catch {
            if isRecordNotFound(error) {
                subscriptionICloudLog.notice("iCloud mirror absent for this iCloud account")
            } else {
                subscriptionICloudLog.error(
                    "iCloud mirror read failed: \(error.localizedDescription, privacy: .public)"
                )
            }
            return nil
        }
    }

    // MARK: - Write

    /// Mirrors a StoreKit-verified entitlement. `signedTransaction` is stored
    /// unused for now so a later build can verify Apple's signature (or have the
    /// backend re-verify it) without asking users to restore again.
    func store(
        _ entitlement: CachedSubscriptionEntitlement,
        productIDs: Set<String>,
        signedTransaction: String?
    ) async {
        guard SubscriptionRuntimeEnvironment.isResolved,
              lastWritten != entitlement,
              await isAvailable() else { return }
        // Fetch-then-modify, never a bare new record: `CKDatabase.save` defaults
        // to `.ifServerRecordUnchanged`, so a freshly constructed record carries
        // no change tag and fails with `serverRecordChanged` once a mirror exists.
        let record = (try? await fetchRecord(recordID)) ?? CKRecord(
            recordType: Self.recordType,
            recordID: recordID
        )
        record[Field.isProActive] = NSNumber(value: entitlement.isProActive)
        record[Field.expiresAt] = entitlement.expiresAt as NSDate?
        record[Field.productIds] = productIDs.sorted().joined(separator: ",") as NSString
        record[Field.signedTransaction] = signedTransaction as NSString?
        record[Field.updatedAt] = Date() as NSDate
        do {
            try await saveRecord(record)
            lastWritten = entitlement
            subscriptionICloudLog.notice(
                "iCloud mirror written: isProActive \(entitlement.isProActive, privacy: .public)"
            )
        } catch {
            subscriptionICloudLog.error(
                "iCloud mirror write failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Clears the mirror. Only for an entitlement Apple actually revoked — never
    /// for "this Apple Account has no transactions", which is what an account
    /// switch looks like.
    func clear() async {
        await store(
            CachedSubscriptionEntitlement(isProActive: false, expiresAt: nil),
            productIDs: [],
            signedTransaction: nil
        )
    }

    // MARK: - Diagnostics

    /// iCloud account state for the entitlement-drop diagnostic. Separates "the
    /// mirror could not help because iCloud is signed out" from "the mirror was
    /// reachable and still had nothing", which is the evidence for whether users
    /// switch only the App Store account or the whole Apple ID.
    func accountStatusDescription() async -> String {
        await withCheckedContinuation { continuation in
            container.accountStatus { status, _ in
                let text: String
                switch status {
                case .available: text = "available"
                case .noAccount: text = "noAccount"
                case .restricted: text = "restricted"
                case .couldNotDetermine: text = "couldNotDetermine"
                case .temporarilyUnavailable: text = "temporarilyUnavailable"
                @unknown default: text = "unknown"
                }
                continuation.resume(returning: text)
            }
        }
    }

    // MARK: - Private

    private func entitlement(from record: CKRecord) -> CachedSubscriptionEntitlement? {
        guard let isProActive = record[Field.isProActive] as? NSNumber else { return nil }
        return CachedSubscriptionEntitlement(
            isProActive: isProActive.boolValue,
            expiresAt: record[Field.expiresAt] as? Date
        )
    }

    private func isAvailable() async -> Bool {
        await withCheckedContinuation { continuation in
            container.accountStatus { status, _ in
                continuation.resume(returning: status == .available)
            }
        }
    }

    private func fetchRecord(_ recordID: CKRecord.ID) async throws -> CKRecord {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordID: recordID) { record, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let record {
                    continuation.resume(returning: record)
                } else {
                    continuation.resume(throwing: CKError(.unknownItem))
                }
            }
        }
    }

    private func saveRecord(_ record: CKRecord) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            database.save(record) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func isRecordNotFound(_ error: Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .unknownItem || ckError.code == .zoneNotFound
    }
}
