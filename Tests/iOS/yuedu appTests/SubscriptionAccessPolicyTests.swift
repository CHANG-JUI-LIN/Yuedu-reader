import Foundation
import Testing
@testable import yuedu_app

@Suite("Subscription access policy")
struct SubscriptionAccessPolicyTests {
    @Test("StoreKit, account and iCloud entitlements coexist")
    func entitlementsCoexist() {
        #expect(!SubscriptionAccessPolicy.isProActive(storeKit: false, account: false, iCloud: false))
        #expect(SubscriptionAccessPolicy.isProActive(storeKit: true, account: false, iCloud: false))
        #expect(SubscriptionAccessPolicy.isProActive(storeKit: false, account: true, iCloud: false))
        #expect(SubscriptionAccessPolicy.isProActive(storeKit: false, account: false, iCloud: true))
        #expect(SubscriptionAccessPolicy.isProActive(storeKit: true, account: true, iCloud: true))
    }

    @Test("iCloud alone carries a guest purchase across an App Store account switch")
    func iCloudMirrorSurvivesStoreAccountSwitch() {
        // The reported failure: a guest purchase, so no Yuedu account, and the new
        // App Store account holds no transactions. Only the mirror is left.
        #expect(SubscriptionAccessPolicy.isProActive(storeKit: false, account: false, iCloud: true))
    }

    @Test("an emptied App Store account leaves the iCloud mirror alone")
    func emptyStoreAccountDoesNotClearMirror() {
        // Zero owned and zero revoked is what a switched App Store account looks
        // like. Clearing here would erase the only surviving grant.
        #expect(SubscriptionICloudMirrorPolicy.action(ownedCount: 0, revokedCount: 0) == .leaveAlone)
    }

    @Test("an Apple revocation clears the iCloud mirror")
    func revocationClearsMirror() {
        #expect(SubscriptionICloudMirrorPolicy.action(ownedCount: 0, revokedCount: 1) == .revoke)
    }

    @Test("an active entitlement is mirrored even alongside a revoked one")
    func activeEntitlementIsMirrored() {
        #expect(SubscriptionICloudMirrorPolicy.action(ownedCount: 1, revokedCount: 0) == .store)
        #expect(SubscriptionICloudMirrorPolicy.action(ownedCount: 1, revokedCount: 1) == .store)
    }

    @Test("guest purchases require a choice while signed-in purchases continue")
    func purchasePromptPolicy() {
        #expect(SubscriptionAccessPolicy.purchaseAction(isAuthenticated: false) == .promptGuest)
        #expect(SubscriptionAccessPolicy.purchaseAction(isAuthenticated: true) == .purchaseForAccount)
    }

    @Test("cached monthly entitlement expires offline")
    func cachedEntitlementExpiry() {
        let now = Date(timeIntervalSince1970: 1_000)
        let monthly = CachedSubscriptionEntitlement(
            isProActive: true,
            expiresAt: now.addingTimeInterval(60)
        )
        let lifetime = CachedSubscriptionEntitlement(isProActive: true, expiresAt: nil)

        #expect(monthly.isActive(at: now))
        #expect(!monthly.isActive(at: now.addingTimeInterval(60)))
        #expect(lifetime.isActive(at: now.addingTimeInterval(1_000_000)))
        #expect(!CachedSubscriptionEntitlement(isProActive: false, expiresAt: nil).isActive(at: now))
    }

    @Test("missing entitlement document keeps the cached value")
    func missingEntitlementDocumentKeepsCachedValue() {
        #expect(!SubscriptionEntitlementRefreshPolicy.shouldApplyServerValue(documentExists: false))
    }

    @Test("existing entitlement document is authoritative over the cache")
    func existingEntitlementDocumentIsAuthoritative() {
        #expect(SubscriptionEntitlementRefreshPolicy.shouldApplyServerValue(documentExists: true))
    }

    private static let lifetimeID = "com.zhangruilin.yuedureader.pro.lifetime"
    private static let monthlyID = "com.zhangruilin.yuedureader.pro.monthly"

    private func paywallState(
        purchased: Set<String>,
        isProActive: Bool
    ) -> PaywallPresentationState {
        PaywallPresentationPolicy.state(
            purchasedProductIDs: purchased,
            lifetimeProductID: Self.lifetimeID,
            monthlyProductID: Self.monthlyID,
            isProActive: isProActive
        )
    }

    @Test("a lifetime owner is never shown the purchase options again")
    func lifetimeOwnerSeesNoPaywall() {
        // Opening straight onto the plan picker reads as being asked to pay twice.
        #expect(paywallState(purchased: [Self.lifetimeID], isProActive: true) == .alreadyPro)
        // Even holding both, lifetime wins: there is nothing left to sell.
        #expect(
            paywallState(purchased: [Self.lifetimeID, Self.monthlyID], isProActive: true)
                == .alreadyPro
        )
    }

    @Test("a monthly subscriber is offered the lifetime upgrade")
    func monthlySubscriberSeesUpgrade() {
        #expect(paywallState(purchased: [Self.monthlyID], isProActive: true) == .upgradeFromMonthly)
    }

    @Test("Pro without a local transaction still hides the paywall")
    func accountGrantedProHidesPaywall() {
        // Pro arriving from the Yuedu account or the iCloud mirror — bought on
        // another Apple Account — leaves no local transaction to name the plan,
        // but there is still nothing to sell.
        #expect(paywallState(purchased: [], isProActive: true) == .alreadyPro)
    }

    @Test("a free user sees the normal offer")
    func freeUserSeesOffer() {
        #expect(paywallState(purchased: [], isProActive: false) == .offer)
    }

    @Test("verified cache restores account access before the network answers")
    func cachedEntitlementSeedsColdLaunch() {
        #expect(SubscriptionEntitlementSeedPolicy.shouldSeed(current: false, cached: true))
    }

    @Test("seeding never revokes and never runs without a verified cache")
    func seedingIsOneDirectional() {
        // No cache, or a cache the backend last verified as inactive: leave the
        // cold-launch `false` alone rather than inventing access.
        #expect(!SubscriptionEntitlementSeedPolicy.shouldSeed(current: false, cached: nil))
        #expect(!SubscriptionEntitlementSeedPolicy.shouldSeed(current: false, cached: false))
        // Already active: a stale cached `false` must not pull down a fresher
        // live `true`. Only a real server response revokes.
        #expect(!SubscriptionEntitlementSeedPolicy.shouldSeed(current: true, cached: false))
        #expect(!SubscriptionEntitlementSeedPolicy.shouldSeed(current: true, cached: nil))
        #expect(!SubscriptionEntitlementSeedPolicy.shouldSeed(current: true, cached: true))
    }

    @Test("an unreachable backend keeps the deferred binding retryable")
    func unreachableBackendStaysRetryable() {
        // 14 unavailable / 4 deadlineExceeded is what a purchase made without a
        // VPN hits. These must retry, or the deferred binding never completes.
        #expect(SubscriptionBindRetryPolicy.shouldRetry(isFunctionsError: true, code: 14))
        #expect(SubscriptionBindRetryPolicy.shouldRetry(isFunctionsError: true, code: 4))
        // Not a Functions status at all (URLSession, decoding): treat as temporary.
        #expect(SubscriptionBindRetryPolicy.shouldRetry(isFunctionsError: false, code: 6))
    }

    @Test("a permanently rejected binding is not retried")
    func permanentRejectionStopsRetrying() {
        // 6 alreadyExists: the transaction belongs to another account. Retrying
        // would re-post the same error on every foreground.
        #expect(!SubscriptionBindRetryPolicy.shouldRetry(isFunctionsError: true, code: 6))
        #expect(!SubscriptionBindRetryPolicy.shouldRetry(isFunctionsError: true, code: 9))
        #expect(!SubscriptionBindRetryPolicy.shouldRetry(isFunctionsError: true, code: 3))
        #expect(!SubscriptionBindRetryPolicy.shouldRetry(isFunctionsError: true, code: 7))
        #expect(!SubscriptionBindRetryPolicy.shouldRetry(isFunctionsError: true, code: 16))
    }

    @Test("complete product cache reloads after the App Store storefront changes")
    func productCacheReloadsForChangedStorefront() {
        #expect(SubscriptionProductReloadPolicy.shouldReload(
            loadedProductCount: 2,
            expectedProductCount: 2,
            loadedStorefrontID: "USA",
            currentStorefrontID: "TWN"
        ))
    }

    @Test("complete product cache remains valid for the same storefront")
    func productCacheRemainsValidForSameStorefront() {
        #expect(!SubscriptionProductReloadPolicy.shouldReload(
            loadedProductCount: 2,
            expectedProductCount: 2,
            loadedStorefrontID: "TWN",
            currentStorefrontID: "TWN"
        ))
    }

    @Test("incomplete product cache reloads without storefront information")
    func incompleteProductCacheReloadsWithoutStorefront() {
        #expect(SubscriptionProductReloadPolicy.shouldReload(
            loadedProductCount: 1,
            expectedProductCount: 2,
            loadedStorefrontID: nil,
            currentStorefrontID: nil
        ))
    }

    @Test("idle offer-code request presents when a window scene is available")
    func idleOfferCodeRequestPresents() {
        #expect(SubscriptionOfferCodeRedemptionPolicy.action(
            isRedeeming: false,
            hasWindowScene: true
        ) == .present)
    }

    @Test("offer-code request is ignored while another sheet is active")
    func duplicateOfferCodeRequestIsIgnored() {
        #expect(SubscriptionOfferCodeRedemptionPolicy.action(
            isRedeeming: true,
            hasWindowScene: true
        ) == .ignore)
    }

    @Test("offer-code request reports unavailable without a window scene")
    func offerCodeRequestWithoutSceneReportsUnavailable() {
        #expect(SubscriptionOfferCodeRedemptionPolicy.action(
            isRedeeming: false,
            hasWindowScene: false
        ) == .reportUnavailable)
    }
}
