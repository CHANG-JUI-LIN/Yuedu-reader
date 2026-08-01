import StoreKit
import Testing
@testable import yuedu_app

@Suite("Subscription entitlement filtering")
struct SubscriptionEntitlementFilterTests {
    @Test("sandbox transactions never count in release builds")
    func sandboxFiltering() {
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, allowSandbox: false, isDebugBuild: false) == false)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, allowSandbox: true, isDebugBuild: false) == false)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, allowSandbox: false, isDebugBuild: true) == true)
    }

    @Test("production and xcode environments always count")
    func nonSandboxEnvironments() {
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .production, allowSandbox: false, isDebugBuild: false) == true)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .xcode, allowSandbox: false, isDebugBuild: false) == true)
    }

    @Test("sandbox toggle does not weaken production purchases")
    func sandboxToggleKeepsProduction() {
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .production, allowSandbox: true, isDebugBuild: false) == true)
    }
}
