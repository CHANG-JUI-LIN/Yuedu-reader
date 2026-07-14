import Combine
import Foundation
import StoreKit
import SwiftUI

/// Single source of truth for the `Yuedu Pro` subscription.
///
/// Wraps StoreKit 2: loads the monthly/yearly products, drives purchase and
/// restore, listens for transaction updates in the background, and derives the
/// `isProActive` entitlement plus the per-feature `hasAccess(_:)` gate that the
/// rest of the app reads. There is no receipt server in v1 — the Apple ID's
/// current entitlements are authoritative and sync across the user's devices.
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
    func purchase(_ product: Product) async -> Bool {
        guard !isPurchasing else { return false }
        isPurchasing = true
        lastErrorMessage = nil
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
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

    private func recomputeEntitlement() {
        let hasPurchase = ProProduct.allCases.contains { purchasedProductIDs.contains($0.rawValue) }
        #if DEBUG
        isProActive = hasPurchase || debugForceProActive
        #else
        isProActive = hasPurchase
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
