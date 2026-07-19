import Foundation
import Testing
@testable import yuedu_app

@Suite("Subscription access policy")
struct SubscriptionAccessPolicyTests {
    @Test("StoreKit and account entitlements coexist")
    func entitlementsCoexist() {
        #expect(!SubscriptionAccessPolicy.isProActive(storeKit: false, account: false))
        #expect(SubscriptionAccessPolicy.isProActive(storeKit: true, account: false))
        #expect(SubscriptionAccessPolicy.isProActive(storeKit: false, account: true))
        #expect(SubscriptionAccessPolicy.isProActive(storeKit: true, account: true))
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
}
