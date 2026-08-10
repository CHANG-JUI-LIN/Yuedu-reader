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

/// A remembered running environment is a cache, not the truth. A paying customer
/// lost Pro on every path at once because a TestFlight install's `.sandbox` was
/// still in UserDefaults after the App Store build replaced it.
@Suite("Subscription runtime environment")
struct SubscriptionRuntimeEnvironmentTests {

    private func withStoredEnvironment(_ value: String?, _ body: () -> Void) {
        let key = "subscription_running_environment"
        let previous = UserDefaults.standard.string(forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        if let value { UserDefaults.standard.set(value, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
        body()
    }

    @Test("a stale sandbox value routes the account read to the sandbox field")
    func sandboxSelectsSandboxFields() {
        withStoredEnvironment("Sandbox") {
            #expect(SubscriptionRuntimeEnvironment.entitlementFieldNames.isActive == "sandboxIsProActive")
            #expect(SubscriptionRuntimeEnvironment.storageSuffix == ".sandbox")
        }
    }

    /// The three symptoms that identified the bug, asserted together: with the
    /// environment stuck at Sandbox an App Store build reads the wrong Firestore
    /// field, the wrong keychain/CloudKit slot, and discards its own Production
    /// transaction — which is why Restore Purchases also came back empty.
    @Test("a stale sandbox value disables all three entitlement paths")
    func staleSandboxDisablesEveryPath() {
        withStoredEnvironment("Sandbox") {
            #expect(SubscriptionEntitlementFilter.shouldAccept(
                environment: .production,
                runningEnvironment: SubscriptionRuntimeEnvironment.current,
                isDebugBuild: false) == false)
            #expect(SubscriptionRuntimeEnvironment.entitlementFieldNames.isActive == "sandboxIsProActive")
            #expect(SubscriptionRuntimeEnvironment.storageSuffix == ".sandbox")
        }
    }

    @Test("production keeps the bare storage slot so existing caches survive")
    func productionUsesBareSlot() {
        withStoredEnvironment("Production") {
            #expect(SubscriptionRuntimeEnvironment.entitlementFieldNames.isActive == "isProActive")
            #expect(SubscriptionRuntimeEnvironment.storageSuffix == "")
        }
    }

    @Test("an unresolved environment reads production fields and accepts transactions")
    func unresolvedFallsBackToProduction() {
        withStoredEnvironment(nil) {
            #expect(SubscriptionRuntimeEnvironment.current == nil)
            #expect(SubscriptionRuntimeEnvironment.entitlementFieldNames.isActive == "isProActive")
            #expect(SubscriptionEntitlementFilter.shouldAccept(
                environment: .production, runningEnvironment: nil, isDebugBuild: false) == true)
        }
    }
}
