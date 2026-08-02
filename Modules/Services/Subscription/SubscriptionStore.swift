import Combine
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import Foundation
import StoreKit
import SwiftUI
import UIKit
import os

enum SubscriptionProductReloadPolicy {
    static func shouldReload(
        loadedProductCount: Int,
        expectedProductCount: Int,
        loadedStorefrontID: String?,
        currentStorefrontID: String?
    ) -> Bool {
        guard loadedProductCount >= expectedProductCount else { return true }
        guard let currentStorefrontID else { return false }
        return loadedStorefrontID != currentStorefrontID
    }
}

/// Single source of truth for the `Yuedu Pro` subscription.
///
/// Wraps StoreKit 2: loads the monthly/lifetime products, drives purchase and
/// restore, listens for transaction updates in the background, and combines
/// Apple Account entitlements with a verified Firebase account entitlement.
@MainActor
final class SubscriptionStore: ObservableObject {
    static let shared = SubscriptionStore()

    private static let subscriptionLog = Logger(
        subsystem: "com.zhangruilin.yuedureader",
        category: "Subscription"
    )

    /// Compile-time build kind; DEBUG (Xcode-launched) builds accept sandbox
    /// transactions so development testing keeps working, Release builds
    /// (TestFlight/App Store) filter them unless explicitly enabled.
    private static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// The product identifiers configured in App Store Connect and the local
    /// `.storekit` file. Order here is the display order on the paywall.
    enum ProProduct: String, CaseIterable {
        case lifetime = "com.zhangruilin.yuedureader.pro.lifetime"
        case monthly = "com.zhangruilin.yuedureader.pro.monthly"
    }

    // MARK: - Published state

    /// Loaded `Product` values, ordered to match `ProProduct.allCases`.
    @Published private(set) var products: [Product] = []
    /// Product IDs the user currently owns an active entitlement for.
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var storeKitIsProActive: Bool = false
    @Published private(set) var accountIsProActive: Bool = false
    /// Mirrored into the iCloud account, which survives an App Store account
    /// switch. See `SubscriptionICloudMirror`.
    @Published private(set) var iCloudIsProActive: Bool = false
    /// `true` while any Pro entitlement is active. Everything gates on this.
    @Published private(set) var isProActive: Bool = false
    @Published private(set) var isLoadingProducts: Bool = false
    @Published private(set) var isPurchasing: Bool = false
    @Published private(set) var isRestoring: Bool = false
    @Published private(set) var isRedeemingOfferCode: Bool = false
    /// Human-readable last error for surfacing in the paywall; nil when clear.
    @Published var lastErrorMessage: String?

    /// Debug-only entitlement override so gating can be exercised in the
    /// simulator without a StoreKit transaction. No effect in Release builds.
    @Published var debugForceProActive: Bool = false {
        didSet { recomputeEntitlement() }
    }

    // MARK: - Private

    private var updatesListenerTask: Task<Void, Never>?
    private var storefrontUpdatesListenerTask: Task<Void, Never>?
    private var loadedStorefrontID: String?
    private var productLoadGeneration = 0
    private let accountService = SubscriptionAccountService.shared
    private let iCloudMirror = SubscriptionICloudMirror.shared
    /// Throttle for the fire-and-forget drop diagnostic: one report per
    /// process per 5 minutes, so a repeatedly-failing device cannot flood
    /// the diagnostics collection.
    private var lastDropReportDate: Date?
    /// Persisted across launches: `true` once this device ever held a Pro
    /// entitlement. Cold-start drops (app relaunched while the entitlement is
    /// already false — the common "退出重進就掉了" report pattern) only report
    /// when this flag is set, so devices that never had Pro stay silent.
    private var hadProEver: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hadProEverKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hadProEverKey) }
    }
    private static let hadProEverKey = "subscription_had_pro_ever"
    /// Revoked transaction count from the last `currentEntitlements` read, so
    /// the drop diagnostic can distinguish "no transactions at all" from
    /// "transactions were revoked".
    private var lastRevokedCount = 0
    /// Products whose binding the backend rejected for a reason no retry can fix
    /// (already owned by another account, payload rejected). Kept per process so
    /// the deferred-binding retry doesn't re-run — and re-surface its error — on
    /// every foreground. A temporary failure deliberately stays out of this set.
    private var permanentBindFailureProductIDs: Set<String> = []

    private init() {
        // Start listening for transactions BEFORE any purchase so we never miss
        // an update delivered while the app was backgrounded or during a
        // purchase interrupted by an Ask-to-Buy / SCA prompt.
        updatesListenerTask = listenForTransactions()
        storefrontUpdatesListenerTask = listenForStorefrontChanges()
        Task {
            seedAccountEntitlementFromCache()
            await refreshEntitlements()
            await refreshICloudEntitlement()
        }
    }

    deinit {
        updatesListenerTask?.cancel()
        storefrontUpdatesListenerTask?.cancel()
    }

    // MARK: - Feature gating

    /// The single entitlement gate. Coarse in v1: all features map to Pro.
    func hasAccess(_ feature: PremiumFeature) -> Bool {
        isProActive
    }

    // MARK: - Product loading

    func loadProducts() async {
        let storefront = await Storefront.current
        await loadProducts(forStorefrontID: storefront?.id, forceReload: false)
    }

    private func loadProducts(forStorefrontID storefrontID: String?, forceReload: Bool) async {
        guard forceReload || SubscriptionProductReloadPolicy.shouldReload(
            loadedProductCount: products.count,
            expectedProductCount: ProProduct.allCases.count,
            loadedStorefrontID: loadedStorefrontID,
            currentStorefrontID: storefrontID
        ) else { return }

        productLoadGeneration += 1
        let generation = productLoadGeneration
        if let storefrontID, loadedStorefrontID != storefrontID {
            // A cached Product keeps its original localized price. Hide stale
            // prices while StoreKit fetches products for the new storefront.
            products = []
        }
        isLoadingProducts = true
        lastErrorMessage = nil
        defer {
            if generation == productLoadGeneration {
                isLoadingProducts = false
            }
        }
        do {
            let ids = ProProduct.allCases.map(\.rawValue)
            let loaded = try await Product.products(for: ids)
            guard generation == productLoadGeneration else { return }
            // Preserve the ProProduct.allCases display order.
            products = ProProduct.allCases.compactMap { pp in
                loaded.first { $0.id == pp.rawValue }
            }
            loadedStorefrontID = storefrontID
            if products.count != ProProduct.allCases.count {
                lastErrorMessage = localized("無法載入訂閱項目，請稍後再試")
            }
        } catch {
            guard generation == productLoadGeneration else { return }
            lastErrorMessage = localized("無法載入訂閱項目，請稍後再試")
        }
    }

    func product(for pro: ProProduct) -> Product? {
        products.first { $0.id == pro.rawValue }
    }

    // MARK: - Purchase / restore

    /// Returns `true` on a completed, verified purchase.
    @discardableResult
    func purchaseAsGuest(_ product: Product) async -> Bool {
        await purchase(product, accountToken: nil)
    }

    @discardableResult
    func purchaseForSignedInAccount(_ product: Product) async -> Bool {
        guard accountService.isAuthenticated else {
            lastErrorMessage = localized("請先登入後再綁定會員")
            return false
        }
        // Minting the token needs Cloud Functions, which is precisely what is
        // unreachable from mainland China without a VPN. Refusing the purchase
        // there helps nobody: Apple's side works, and the entitlement still
        // reaches the reader through StoreKit and the iCloud mirror. So buy
        // first and link later — `bindPendingPurchaseIfNeeded()` finishes the
        // binding on a foreground once Firebase answers again.
        let token = try? await accountService.accountToken()
        let purchased = await purchase(product, accountToken: token)
        if purchased, token == nil {
            lastErrorMessage = localized("購買成功，帳號服務暫時無法連線，恢復連線後會自動綁定")
        }
        return purchased
    }

    @discardableResult
    private func purchase(_ product: Product, accountToken: UUID?) async -> Bool {
        guard !isPurchasing else { return false }
        isPurchasing = true
        lastErrorMessage = nil
        defer { isPurchasing = false }
        do {
            let result: Product.PurchaseResult
            if let accountToken {
                result = try await product.purchase(options: [.appAccountToken(accountToken)])
            } else {
                result = try await product.purchase()
            }
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                if accountToken != nil {
                    do {
                        accountIsProActive = try await accountService.bind(transaction: verification)
                    } catch {
                        // The Apple purchase is already valid. Keep StoreKit access and
                        // explain that cross-Apple-Account binding still needs retrying.
                        if !accountService.isRetryable(error) {
                            permanentBindFailureProductIDs.insert(transaction.productID)
                        }
                        lastErrorMessage = localized("購買成功，但未能綁定帳號，請稍後使用恢復購買重試")
                    }
                }
                await transaction.finish()
                await refreshEntitlements()
                return isProActive
            case .userCancelled:
                return false
            case .pending:
                // Ask-to-Buy / SCA: entitlement arrives later via the listener.
                lastErrorMessage = localized("購買待確認，完成後將自動解鎖")
                return false
            @unknown default:
                return false
            }
        } catch {
            lastErrorMessage = localized("購買失敗，請稍後再試")
            return false
        }
    }

    /// Presents Apple's offer-code sheet, then synchronizes any entitlement
    /// created by the redemption with StoreKit and the signed-in Yuedu account.
    func redeemOfferCode(in scene: UIWindowScene?) async {
        switch SubscriptionOfferCodeRedemptionPolicy.action(
            isRedeeming: isRedeemingOfferCode,
            hasWindowScene: scene != nil
        ) {
        case .ignore:
            return
        case .reportUnavailable:
            lastErrorMessage = localized("目前無法開啟優惠碼兌換，請稍後再試")
            return
        case .present:
            break
        }

        guard let scene else { return }
        isRedeemingOfferCode = true
        lastErrorMessage = nil
        defer { isRedeemingOfferCode = false }

        do {
            try await AppStore.presentOfferCodeRedeemSheet(in: scene)
            await refreshEntitlements()
            if accountService.isAuthenticated {
                await bindCurrentStoreKitEntitlementsToAccount()
            }
        } catch {
            lastErrorMessage = localized("目前無法開啟優惠碼兌換，請稍後再試")
        }
    }

    /// Restores by syncing with the App Store, then re-reading entitlements.
    func restore() async {
        guard !isRestoring else { return }
        isRestoring = true
        lastErrorMessage = nil
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
        } catch {
            // A failed sync is non-fatal — currentEntitlements may still resolve.
        }
        await refreshEntitlements()
        // The iCloud mirror is a restorable grant too: a guest purchase made on
        // the previous App Store account lives only there. Reading it before the
        // verdict below keeps restore from reporting nothing to restore.
        await refreshICloudEntitlement()
        if accountService.isAuthenticated {
            await bindCurrentStoreKitEntitlementsToAccount()
        }
        if !isProActive {
            lastErrorMessage = localized("沒有找到可恢復的訂閱")
        }
    }

    // MARK: - Entitlement resolution

    /// Recomputes the entitlement from `Transaction.currentEntitlements`.
    func refreshEntitlements() async {
        var owned: Set<String> = []
        var revokedCount = 0
        var signedTransaction: String?
        var latestExpiry: Date?
        var hasUnexpiringProduct = false
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            guard SubscriptionEntitlementFilter.shouldAccept(
                environment: transaction.environment,
                isDebugBuild: Self.isDebugBuild
            ) else { continue }
            if transaction.revocationDate == nil {
                owned.insert(transaction.productID)
                if ProProduct(rawValue: transaction.productID) != nil {
                    signedTransaction = result.jwsRepresentation
                    if let expiration = transaction.expirationDate {
                        latestExpiry = max(latestExpiry ?? expiration, expiration)
                    } else {
                        // Lifetime: outlives any dated entitlement, so the mirror
                        // must not carry an expiry at all.
                        hasUnexpiringProduct = true
                    }
                }
            } else {
                revokedCount += 1
            }
        }
        purchasedProductIDs = owned
        lastRevokedCount = revokedCount
        Self.subscriptionLog.notice(
            "StoreKit currentEntitlements: owned \(owned.sorted().joined(separator: ","), privacy: .public) revoked \(revokedCount)"
        )
        recomputeEntitlement()
        await mirrorToICloud(
            owned: owned,
            revokedCount: revokedCount,
            expiresAt: hasUnexpiringProduct ? nil : latestExpiry,
            signedTransaction: signedTransaction
        )
    }

    /// Call only after Firebase has been configured (app active/auth callbacks).
    func refreshAllEntitlements() async {
        seedAccountEntitlementFromCache()
        await refreshEntitlements()
        await refreshICloudEntitlement()
        if let accountEntitlement = await accountService.refreshEntitlement() {
            accountIsProActive = accountEntitlement
        }
        recomputeEntitlement()
        await bindPendingPurchaseIfNeeded()
    }

    /// Reads the iCloud mirror. Like the keychain seed, a missing or unreadable
    /// mirror means "nothing to say" and leaves access alone; only a mirror the
    /// app itself cleared after an Apple revocation reports `false`.
    private func refreshICloudEntitlement() async {
        guard let entitlement = await iCloudMirror.load() else { return }
        let isActive = entitlement.isActive()
        guard isActive != iCloudIsProActive else { return }
        iCloudIsProActive = isActive
        recomputeEntitlement()
    }

    /// Writes the StoreKit entitlement into the iCloud mirror so it outlives an
    /// App Store account switch. An empty entitlement set deliberately writes
    /// nothing — see `SubscriptionICloudMirrorPolicy`, that state is exactly what
    /// a switched account looks like.
    ///
    /// A backend `false` never reaches here: a guest purchase is real in iCloud
    /// while `entitlements/{uid}` legitimately has nothing, so only Apple's own
    /// revocation may clear the mirror.
    private func mirrorToICloud(
        owned: Set<String>,
        revokedCount: Int,
        expiresAt: Date?,
        signedTransaction: String?
    ) async {
        switch SubscriptionICloudMirrorPolicy.action(
            ownedCount: owned.count,
            revokedCount: revokedCount
        ) {
        case .store:
            await iCloudMirror.store(
                CachedSubscriptionEntitlement(isProActive: true, expiresAt: expiresAt),
                productIDs: owned,
                signedTransaction: signedTransaction
            )
            if !iCloudIsProActive {
                iCloudIsProActive = true
                recomputeEntitlement()
            }
        case .revoke:
            await iCloudMirror.clear()
            if iCloudIsProActive {
                iCloudIsProActive = false
                recomputeEntitlement()
            }
        case .leaveAlone:
            break
        }
    }

    /// Restores the last backend-verified account entitlement before any network
    /// work. `accountIsProActive` otherwise starts at `false` on every cold launch
    /// and can only rise from a live Firebase response, so a device that cannot
    /// reach Firebase — mainland China without a VPN, where `entitlements/{uid}`
    /// is `true` on the server but unreadable — presented a paid account as
    /// unsubscribed, leaving only the Apple-Account half of the entitlement and
    /// making Pro look bound to the Apple ID.
    ///
    /// Deliberately one-directional: it only raises access from a value the
    /// backend already verified for this UID. Revocation (refund, expiry,
    /// cancellation) stays the exclusive job of a real server response, which
    /// `refreshEntitlement()` applies and writes back to the cache.
    private func seedAccountEntitlementFromCache() {
        guard SubscriptionEntitlementSeedPolicy.shouldSeed(
            current: accountIsProActive,
            cached: accountService.cachedEntitlement()
        ) else { return }
        accountIsProActive = true
        Self.subscriptionLog.notice("Seeded account entitlement from keychain cache")
        recomputeEntitlement()
    }

    func authenticationDidChange(isAuthenticated: Bool) async {
        if !isAuthenticated {
            accountIsProActive = false
            recomputeEntitlement()
            return
        }
        // Verified state first, network second: sign-in restore on a launch behind
        // an unreachable Firebase must not present a paid account as unsubscribed.
        seedAccountEntitlementFromCache()
        if let accountEntitlement = await accountService.refreshEntitlement() {
            accountIsProActive = accountEntitlement
            recomputeEntitlement()
        }
        // Backfill: purchases made while signed out (or on another device) were
        // never bound — bind runs only during purchase/restore — so the server
        // document stays missing and refreshEntitlement above keeps returning
        // nil. Sign-in is the last chance to fix the backend while Firebase is
        // known to be reachable.
        await bindCurrentStoreKitEntitlementsToAccount()
    }

    func deleteCurrentAccountSubscriptionData() async throws {
        try await accountService.deleteAccountData()
        accountIsProActive = false
        recomputeEntitlement()
    }

    private func bindCurrentStoreKitEntitlementsToAccount() async {
        var didFailBinding = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result),
                  ProProduct(rawValue: transaction.productID) != nil,
                  SubscriptionEntitlementFilter.shouldAccept(
                    environment: transaction.environment,
                    isDebugBuild: Self.isDebugBuild
                  ) else { continue }
            do {
                accountIsProActive = try await accountService.bind(transaction: result)
                permanentBindFailureProductIDs.remove(transaction.productID)
            } catch {
                didFailBinding = true
                if !accountService.isRetryable(error) {
                    permanentBindFailureProductIDs.insert(transaction.productID)
                }
            }
        }
        recomputeEntitlement()
        if didFailBinding {
            lastErrorMessage = localized("無法將購買綁定到此帳號")
        }
    }

    /// Completes a binding the purchase itself could not do: the buyer was signed
    /// in but Cloud Functions was unreachable, so Apple has a valid transaction
    /// our backend has never seen.
    ///
    /// The trigger is the state itself rather than a persisted flag — signed in,
    /// StoreKit says Pro, backend says nothing — so it stops being true the
    /// moment a bind succeeds and needs no cleanup. Products the backend
    /// permanently rejected are excluded so a transaction owned by someone else
    /// doesn't re-post its error on every foreground.
    private func bindPendingPurchaseIfNeeded() async {
        guard accountService.isAuthenticated,
              storeKitIsProActive,
              !accountIsProActive,
              !purchasedProductIDs.subtracting(permanentBindFailureProductIDs).isEmpty
        else { return }
        Self.subscriptionLog.notice("Retrying deferred purchase binding")
        await bindCurrentStoreKitEntitlementsToAccount()
    }

    private func recomputeEntitlement() {
        let hasPurchase = ProProduct.allCases.contains { purchasedProductIDs.contains($0.rawValue) }
        storeKitIsProActive = hasPurchase
        #if DEBUG
        isProActive = SubscriptionAccessPolicy.isProActive(
            storeKit: hasPurchase || debugForceProActive,
            account: accountIsProActive,
            iCloud: iCloudIsProActive
        )
        #else
        isProActive = SubscriptionAccessPolicy.isProActive(
            storeKit: hasPurchase,
            account: accountIsProActive,
            iCloud: iCloudIsProActive
        )
        #endif
        if isProActive {
            hadProEver = true
        }
        Self.subscriptionLog.notice(
            "Entitlement recompute: storeKit \(hasPurchase, privacy: .public) account \(self.accountIsProActive, privacy: .public) iCloud \(self.iCloudIsProActive, privacy: .public) → pro \(self.isProActive, privacy: .public)"
        )
        // Report when Pro is (now) off on a device that ever had it — covers
        // both in-process drops and cold-start drops (relaunch with the
        // entitlement already false, where `previous` is always false).
        if !isProActive && hadProEver {
            reportEntitlementDrop(
                storeKit: hasPurchase,
                account: accountIsProActive,
                iCloud: iCloudIsProActive
            )
        }
    }

    /// Fire-and-forget telemetry: when the Pro entitlement drops, write the
    /// exact state (StoreKit flag, account flag, owned product IDs, uid,
    /// app version, storefront) to Firestore `entitlementDiagnostics` so the
    /// developer can diagnose a device they cannot reach (e.g. a user
    /// reporting from behind a VPN). Deliberately best-effort: failure must
    /// never affect the reader, and Firebase may not be configured yet at
    /// early launch — guarded.
    private func reportEntitlementDrop(storeKit: Bool, account: Bool, iCloud: Bool) {
        let now = Date()
        if let last = lastDropReportDate, now.timeIntervalSince(last) < 300 { return }
        lastDropReportDate = now
        guard FirebaseApp.app() != nil else { return }
        let info = Bundle.main.infoDictionary
        var data: [String: Any] = [
            "storeKit": storeKit,
            "account": account,
            "iCloud": iCloud,
            "ownedProducts": purchasedProductIDs.sorted().joined(separator: ","),
            "revokedCount": lastRevokedCount,
            "uid": Auth.auth().currentUser?.uid ?? "",
            "appVersion": info?["CFBundleShortVersionString"] as? String ?? "",
            "build": info?["CFBundleVersion"] as? String ?? "",
            "createdAt": FieldValue.serverTimestamp()
        ]
        // Storefront (App Store region) is async; fold it in after the read so
        // the report shows whether Apple resolved the entitlement against the
        // user's home region or the VPN exit region.
        Task {
            let storefrontID = await Storefront.current?.id ?? ""
            data["storefront"] = storefrontID
            // Distinguishes "iCloud signed out, mirror could never help" from
            // "iCloud available and the mirror still had nothing" — the evidence
            // for whether users switch only the App Store account or the whole
            // Apple ID.
            data["iCloudAccountStatus"] = await self.iCloudMirror.accountStatusDescription()
            Self.subscriptionLog.notice("Reporting entitlement drop diagnostic to Firestore")
            try? await Firestore.firestore()
                .collection("entitlementDiagnostics")
                .addDocument(data: data)
        }
    }

    // MARK: - Transaction listener

    private func listenForTransactions() -> Task<Void, Never> {
        Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard let transaction = try? self.checkVerified(result) else { continue }
                await transaction.finish()
                await self.refreshEntitlements()
            }
        }
    }

    private func listenForStorefrontChanges() -> Task<Void, Never> {
        Task { [weak self] in
            for await storefront in Storefront.updates {
                guard let self else { return }
                await self.loadProducts(forStorefrontID: storefront.id, forceReload: true)
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw SubscriptionError.failedVerification
        case .verified(let safe):
            return safe
        }
    }

    enum SubscriptionError: Error {
        case failedVerification
    }
}
