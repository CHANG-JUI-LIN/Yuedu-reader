import Combine
import Foundation
import StoreKit
import SwiftUI

/// Single source of truth for the `Yuedu Pro` subscription.
///
/// Wraps StoreKit 2: loads the monthly/lifetime products, drives purchase and
/// restore, listens for transaction updates in the background, and combines
/// Apple Account entitlements with a verified Firebase account entitlement.
@MainActor
final class SubscriptionStore: ObservableObject {
    static let shared = SubscriptionStore()

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
    /// `true` while any Pro entitlement is active. Everything gates on this.
    @Published private(set) var isProActive: Bool = false
    @Published private(set) var isLoadingProducts: Bool = false
    @Published private(set) var isPurchasing: Bool = false
    @Published private(set) var isRestoring: Bool = false
    /// Human-readable last error for surfacing in the paywall; nil when clear.
    @Published var lastErrorMessage: String?

    /// Debug-only entitlement override so gating can be exercised in the
    /// simulator without a StoreKit transaction. No effect in Release builds.
    @Published var debugForceProActive: Bool = false {
        didSet { recomputeEntitlement() }
    }

    // MARK: - Private

    private var updatesListenerTask: Task<Void, Never>?
    private let accountService = SubscriptionAccountService.shared

    private init() {
        // Start listening for transactions BEFORE any purchase so we never miss
        // an update delivered while the app was backgrounded or during a
        // purchase interrupted by an Ask-to-Buy / SCA prompt.
        updatesListenerTask = listenForTransactions()
        Task { await refreshEntitlements() }
    }

    deinit {
        updatesListenerTask?.cancel()
    }

    // MARK: - Feature gating

    /// The single entitlement gate. Coarse in v1: all features map to Pro.
    func hasAccess(_ feature: PremiumFeature) -> Bool {
        isProActive
    }

    // MARK: - Product loading

    func loadProducts() async {
        guard products.count < ProProduct.allCases.count, !isLoadingProducts else { return }
        isLoadingProducts = true
        lastErrorMessage = nil
        defer { isLoadingProducts = false }
        do {
            let ids = ProProduct.allCases.map(\.rawValue)
            let loaded = try await Product.products(for: ids)
            // Preserve the ProProduct.allCases display order.
            products = ProProduct.allCases.compactMap { pp in
                loaded.first { $0.id == pp.rawValue }
            }
            if products.count != ProProduct.allCases.count {
                lastErrorMessage = localized("無法載入訂閱項目，請稍後再試")
            }
        } catch {
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
        do {
            let token = try await accountService.accountToken()
            return await purchase(product, accountToken: token)
        } catch {
            lastErrorMessage = localized("無法連接帳號服務，請檢查網路後再試")
            return false
        }
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
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }
            if transaction.revocationDate == nil {
                owned.insert(transaction.productID)
            }
        }
        purchasedProductIDs = owned
        recomputeEntitlement()
    }

    /// Call only after Firebase has been configured (app active/auth callbacks).
    func refreshAllEntitlements() async {
        await refreshEntitlements()
        if let accountEntitlement = await accountService.refreshEntitlement() {
            accountIsProActive = accountEntitlement
        }
        recomputeEntitlement()
    }

    func authenticationDidChange(isAuthenticated: Bool) async {
        if !isAuthenticated {
            accountIsProActive = false
            recomputeEntitlement()
            return
        }
        if let accountEntitlement = await accountService.refreshEntitlement() {
            accountIsProActive = accountEntitlement
            recomputeEntitlement()
        }
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
                  ProProduct(rawValue: transaction.productID) != nil else { continue }
            do {
                accountIsProActive = try await accountService.bind(transaction: result)
            } catch {
                didFailBinding = true
            }
        }
        recomputeEntitlement()
        if didFailBinding {
            lastErrorMessage = localized("無法將購買綁定到此帳號")
        }
    }

    private func recomputeEntitlement() {
        let hasPurchase = ProProduct.allCases.contains { purchasedProductIDs.contains($0.rawValue) }
        storeKitIsProActive = hasPurchase
        #if DEBUG
        isProActive = SubscriptionAccessPolicy.isProActive(
            storeKit: hasPurchase || debugForceProActive,
            account: accountIsProActive
        )
        #else
        isProActive = SubscriptionAccessPolicy.isProActive(
            storeKit: hasPurchase,
            account: accountIsProActive
        )
        #endif
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
