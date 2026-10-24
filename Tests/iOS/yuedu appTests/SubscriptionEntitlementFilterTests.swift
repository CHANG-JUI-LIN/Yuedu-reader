import StoreKit
import Testing
@testable import yuedu_app

@Suite("Subscription entitlement filtering")
struct SubscriptionEntitlementFilterTests {
    @Test("a build honours only its own environment's transactions")
    func matchingEnvironmentOnly() {
        // App Store build: ignores a Sandbox transaction, honours Production.
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, entitlementEnvironment: .production, isDebugBuild: false) == false)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .production, entitlementEnvironment: .production, isDebugBuild: false) == true)
    }

    @Test("a TestFlight build honours the purchase it just made")
    func testFlightHonoursItsOwnPurchase() {
        // Rejecting Sandbox outright meant a TestFlight build discarded its own
        // purchase, so neither the lifetime nor the monthly product ever unlocked
        // there. TestFlight runs in Sandbox and must accept Sandbox.
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, entitlementEnvironment: .sandbox, isDebugBuild: false) == true)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .production, entitlementEnvironment: .sandbox, isDebugBuild: false) == false)
    }

    @Test("an unresolved environment defers to StoreKit's own separation")
    func unresolvedEnvironmentAcceptsTransaction() {
        // Before AppTransaction has been read once there is nothing to compare
        // against. Discarding a real purchase there would be worse than trusting
        // StoreKit, which already yields only this build's environment.
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, entitlementEnvironment: nil, isDebugBuild: false) == true)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .production, entitlementEnvironment: nil, isDebugBuild: false) == true)
    }

    @Test("debug builds accept both local testing environments")
    func debugBuildAcceptsEverything() {
        // A local run buys through either a StoreKit configuration file (.xcode)
        // or a sandbox Apple Account (.sandbox); neither should block testing.
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .xcode, entitlementEnvironment: .production, isDebugBuild: true) == true)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, entitlementEnvironment: .production, isDebugBuild: true) == true)
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
                entitlementEnvironment: SubscriptionRuntimeEnvironment.entitlementEnvironment,
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
                environment: .production, entitlementEnvironment: nil, isDebugBuild: false) == true)
        }
    }
}

/// App Review and TestFlight run one binary in the Sandbox, where purchases are
/// free. A TestFlight build outside review cannot buy and reads the member's App
/// Store Pro; the build App Review has open, the App Store build and Debug runs
/// keep their own environment.
@Suite("Subscription purchase mode")
struct SubscriptionPurchaseModeTests {
    @Test("only a Sandbox Release build outside App Review loses its purchases")
    func modeByEnvironmentAndReview() {
        typealias Policy = SubscriptionPurchaseModePolicy
        #expect(Policy.mode(runningEnvironment: .sandbox, isDebugBuild: false, buildUnderReview: false)
            == .testFlightWithoutPurchases)
        #expect(Policy.mode(runningEnvironment: .sandbox, isDebugBuild: false, buildUnderReview: true)
            == .ownEnvironment)
        for answer in [true, false, nil] as [Bool?] {
            #expect(Policy.mode(runningEnvironment: .production, isDebugBuild: false, buildUnderReview: answer)
                == .ownEnvironment)
        }
        #expect(Policy.mode(runningEnvironment: .sandbox, isDebugBuild: true, buildUnderReview: false)
            == .ownEnvironment)
        #expect(Policy.mode(runningEnvironment: nil, isDebugBuild: false, buildUnderReview: nil)
            == .ownEnvironment)
    }

    @Test("no review answer yet counts as TestFlight")
    func unansweredIsTestFlight() {
        // The backend is unreachable from mainland China without a VPN; a
        // TestFlight build there must not sell. A purchase asks before deciding.
        #expect(SubscriptionPurchaseModePolicy.mode(
            runningEnvironment: .sandbox, isDebugBuild: false, buildUnderReview: nil)
            == .testFlightWithoutPurchases)
    }

    @Test("a TestFlight build that cannot buy reads the App Store slots and drops Sandbox purchases")
    func testFlightReadsAppStoreMembership() {
        let environment = SubscriptionRuntimeEnvironment.entitlementEnvironment(
            for: .testFlightWithoutPurchases, runningEnvironment: .sandbox)
        #expect(environment == .production)
        #expect(SubscriptionRuntimeEnvironment.storageSuffix(for: environment) == "")
        #expect(SubscriptionRuntimeEnvironment.entitlementFieldNames(for: environment).isActive == "isProActive")
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, entitlementEnvironment: environment, isDebugBuild: false) == false)
    }

    @Test("a TestFlight build that cannot buy never writes or clears the App Store mirror")
    func testFlightNeverWritesMirror() {
        // `clear()` goes through `store`, so this one gate covers both.
        #expect(SubscriptionICloudMirrorPolicy.mayWrite(purchaseMode: .testFlightWithoutPurchases) == false)
    }

    @Test("the build App Review has open keeps its Sandbox purchases apart")
    func reviewKeepsSandbox() {
        let environment = SubscriptionRuntimeEnvironment.entitlementEnvironment(
            for: .ownEnvironment, runningEnvironment: .sandbox)
        #expect(environment == .sandbox)
        #expect(SubscriptionRuntimeEnvironment.storageSuffix(for: environment) == ".sandbox")
        #expect(SubscriptionRuntimeEnvironment.entitlementFieldNames(for: environment).isActive == "sandboxIsProActive")
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, entitlementEnvironment: environment, isDebugBuild: false) == true)
        #expect(SubscriptionICloudMirrorPolicy.mayWrite(purchaseMode: .ownEnvironment))
    }

    /// The same binary ships to the App Store, so its path must not move at all.
    @Test("the App Store build reads, writes and filters exactly as before")
    func appStoreUnchanged() {
        let environment = SubscriptionRuntimeEnvironment.entitlementEnvironment(
            for: .ownEnvironment, runningEnvironment: .production)
        #expect(environment == .production)
        #expect(SubscriptionRuntimeEnvironment.storageSuffix(for: environment) == "")
        #expect(SubscriptionRuntimeEnvironment.entitlementFieldNames(for: environment).isActive == "isProActive")
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .production, entitlementEnvironment: environment, isDebugBuild: false) == true)
        #expect(SubscriptionEntitlementFilter.shouldAccept(
            environment: .sandbox, entitlementEnvironment: environment, isDebugBuild: false) == false)
        #expect(SubscriptionICloudMirrorPolicy.mayWrite(purchaseMode: .ownEnvironment))
    }

    @MainActor
    @Test("a build that buys goes straight to the purchase, with no TestFlight notice")
    func buyingBuildShowsNoNotice() async {
        let store = SubscriptionStore(observeTransactions: false)
        #expect(await store.ensurePurchasesAllowed())
        #expect(store.isShowingTestFlightPurchaseNotice == false)
    }
}
