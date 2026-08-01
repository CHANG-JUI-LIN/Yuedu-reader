import StoreKit
import Testing
@testable import yuedu_app

@Suite("Subscription entitlement filtering")
struct SubscriptionEntitlementFilterTests {
    @Test("sandbox transactions require a debug build")
    func sandboxFiltering() {
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, isDebugBuild: false) == false)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, isDebugBuild: true) == true)
    }

    @Test("production and xcode environments always count")
    func nonSandboxEnvironments() {
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .production, isDebugBuild: false) == true)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .xcode, isDebugBuild: false) == true)
    }
}
