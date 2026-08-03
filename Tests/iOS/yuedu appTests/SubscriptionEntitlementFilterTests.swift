import StoreKit
import Testing
@testable import yuedu_app

@Suite("Subscription entitlement filtering")
struct SubscriptionEntitlementFilterTests {
    @Test("a build honours only its own environment's transactions")
    func matchingEnvironmentOnly() {
        // App Store build: ignores a Sandbox transaction, honours Production.
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, runningEnvironment: .production, isDebugBuild: false) == false)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .production, runningEnvironment: .production, isDebugBuild: false) == true)
    }

    @Test("a TestFlight build honours the purchase it just made")
    func testFlightHonoursItsOwnPurchase() {
        // Rejecting Sandbox outright meant a TestFlight build discarded its own
        // purchase, so neither the lifetime nor the monthly product ever unlocked
        // there. TestFlight runs in Sandbox and must accept Sandbox.
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, runningEnvironment: .sandbox, isDebugBuild: false) == true)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .production, runningEnvironment: .sandbox, isDebugBuild: false) == false)
    }

    @Test("an unresolved environment defers to StoreKit's own separation")
    func unresolvedEnvironmentAcceptsTransaction() {
        // Before AppTransaction has been read once there is nothing to compare
        // against. Discarding a real purchase there would be worse than trusting
        // StoreKit, which already yields only this build's environment.
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, runningEnvironment: nil, isDebugBuild: false) == true)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .production, runningEnvironment: nil, isDebugBuild: false) == true)
    }

    @Test("debug builds accept both local testing environments")
    func debugBuildAcceptsEverything() {
        // A local run buys through either a StoreKit configuration file (.xcode)
        // or a sandbox Apple Account (.sandbox); neither should block testing.
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .xcode, runningEnvironment: .production, isDebugBuild: true) == true)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, runningEnvironment: .production, isDebugBuild: true) == true)
    }
}
