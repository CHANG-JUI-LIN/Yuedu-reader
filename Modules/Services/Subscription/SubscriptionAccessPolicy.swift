import StoreKit
import os

enum SubscriptionPurchaseAction: Equatable {
    case promptGuest
    case purchaseForAccount
}

enum SubscriptionAccessPolicy {
    /// Three independent grants, unioned. They are keyed by three different
    /// identities on purpose: `storeKit` by the App Store account, `account` by
    /// the Yuedu (Firebase) account, `iCloud` by the iCloud account. A user who
    /// switches App Store accounts loses only the first, which is what makes Pro
    /// look bound to the Apple ID when the other two are empty or unreachable.
    static func isProActive(storeKit: Bool, account: Bool, iCloud: Bool) -> Bool {
        storeKit || account || iCloud
    }

    static func purchaseAction(isAuthenticated: Bool) -> SubscriptionPurchaseAction {
        isAuthenticated ? .purchaseForAccount : .promptGuest
    }
}

/// What the TestFlight screen should do before the user types an address.
enum TestFlightEligibility: Equatable {
    case eligible
    /// Pro, but on a plan that cannot claim a seat.
    case requiresLifetime
    /// This device cannot tell yet. The screen must let the request through and
    /// let the callable answer — guessing `requiresLifetime` here would lock out
    /// a lifetime buyer whose entitlement was cached before product IDs were
    /// recorded, or who is offline.
    case undetermined
}

enum TestFlightAccessPolicy {
    /// Mirrors the `requireLifetimePro` check in Cloud Functions so the screen
    /// can explain the rule up front instead of after a failed submission. The
    /// callable stays the authority; this only decides what to render.
    ///
    /// Lifetime-only because a TestFlight seat cannot be taken back: the
    /// one-time slot is keyed by uid and never released, and the tester stays in
    /// Apple's beta group. Keep this aligned with `entitlementGrantsTestFlight`.
    static func eligibility(
        isProActive: Bool,
        productIDs: [String]?,
        lifetimeProductID: String
    ) -> TestFlightEligibility {
        guard let productIDs else { return .undetermined }
        if productIDs.contains(lifetimeProductID) {
            return isProActive ? .eligible : .requiresLifetime
        }
        return .requiresLifetime
    }
}

enum PaywallPresentationState: Equatable {
    /// Nothing owned yet: the normal offer.
    case offer
    /// An active monthly subscription. Lifetime is still sellable, framed as an
    /// upgrade, and monthly must not be offered again.
    case upgradeFromMonthly
    /// Lifetime owned, or Pro arriving from the Yuedu account / iCloud mirror
    /// with no local transaction to identify the plan. Either way there is
    /// nothing left to sell, so the paywall shows its member page, not an offer.
    case alreadyPro
}

enum PaywallPresentationPolicy {
    /// What the paywall should show on open.
    ///
    /// Opening straight onto the purchase options for someone who already paid —
    /// especially a lifetime buyer — reads as being asked to pay twice, so
    /// ownership is resolved before anything is offered.
    static func state(
        purchasedProductIDs: Set<String>,
        lifetimeProductID: String,
        monthlyProductID: String,
        isProActive: Bool
    ) -> PaywallPresentationState {
        if purchasedProductIDs.contains(lifetimeProductID) { return .alreadyPro }
        if purchasedProductIDs.contains(monthlyProductID) { return .upgradeFromMonthly }
        return isProActive ? .alreadyPro : .offer
    }

    /// The plan the member page names as theirs: lifetime whenever it is owned — a
    /// monthly plan still held beside it is billing to cancel, not their plan — then
    /// monthly. Nil for Pro from the Yuedu account or the iCloud mirror, which has no
    /// transaction on this Apple Account to name a plan by.
    static func ownedPlanID(
        purchasedProductIDs: Set<String>,
        lifetimeProductID: String,
        monthlyProductID: String
    ) -> String? {
        if purchasedProductIDs.contains(lifetimeProductID) { return lifetimeProductID }
        if purchasedProductIDs.contains(monthlyProductID) { return monthlyProductID }
        return nil
    }
}

/// What the paywall's member page offers for Apple's subscription management.
enum ProSubscriptionManagement: Equatable {
    /// No monthly plan on this Apple Account: lifetime only, or Pro granted by the
    /// Yuedu account or the iCloud mirror. Apple's subscription list has nothing
    /// of ours to show, so the page offers no link.
    case unavailable
    /// A monthly subscription the user may want to cancel.
    case monthly
    /// Monthly still held next to lifetime. Buying a non-consumable never ends a
    /// subscription, so the link keeps the cancellation reminder that the
    /// thank-you page shows once, right after the upgrade.
    case monthlyAlongsideLifetime
}

enum ProStatusPagePolicy {
    static func subscriptionManagement(
        purchasedProductIDs: Set<String>,
        lifetimeProductID: String,
        monthlyProductID: String
    ) -> ProSubscriptionManagement {
        guard purchasedProductIDs.contains(monthlyProductID) else { return .unavailable }
        return purchasedProductIDs.contains(lifetimeProductID) ? .monthlyAlongsideLifetime : .monthly
    }
}

enum SubscriptionEntitlementRefreshPolicy {
    /// Whether a server response is authoritative enough to overwrite the local
    /// cache. Only an existing document counts: a missing one means the backend
    /// never verified this account (purchases made while signed out are bound
    /// later on sign-in), and applying its absent value as "false" would revoke
    /// previously verified access. Delete this only when sign-in backfill makes
    /// a missing document impossible to see from a verified purchase.
    static func shouldApplyServerValue(documentExists: Bool) -> Bool {
        documentExists
    }
}

enum SubscriptionEntitlementSeedPolicy {
    /// Whether the entitlement cached in the keychain should raise the in-memory
    /// account flag before any network call. The flag starts at `false` on every
    /// cold launch and can only rise from a live Firebase response, so a device
    /// that cannot reach Firebase showed a backend-verified Pro account as
    /// unsubscribed.
    ///
    /// One-directional on purpose: seeding may only grant access the backend
    /// already verified for this UID. Revoking it stays the exclusive job of a
    /// real server response, so a cached `false` never overrides a fresher live
    /// `true`, and an expired cache reads as `false` before it reaches here.
    static func shouldSeed(current: Bool, cached: Bool?) -> Bool {
        !current && cached == true
    }
}

enum SubscriptionBindRetryPolicy {
    /// Cloud Functions status codes for which binding can never succeed, so a
    /// later foreground must not retry: 3 `invalidArgument`, 6 `alreadyExists`
    /// (the transaction belongs to another account), 7 `permissionDenied`,
    /// 9 `failedPrecondition` (Apple's payload was rejected), 16
    /// `unauthenticated`. These are the standard gRPC codes Firebase reuses, so
    /// the numbers are stable.
    private static let permanentCodes: Set<Int> = [3, 6, 7, 9, 16]

    /// Whether a failed bind is worth retrying once the app comes back to the
    /// foreground. An unreachable backend surfaces as 14 `unavailable` or 4
    /// `deadlineExceeded` — exactly what a purchase made without a VPN hits —
    /// and must stay retryable, or the deferred binding never completes.
    static func shouldRetry(isFunctionsError: Bool, code: Int) -> Bool {
        guard isFunctionsError else { return true }
        return !permanentCodes.contains(code)
    }
}

enum SubscriptionICloudMirrorPolicy {
    enum Action: Equatable {
        case store
        case revoke
        case leaveAlone
    }

    /// What the iCloud mirror should do after a `Transaction.currentEntitlements`
    /// read.
    ///
    /// `leaveAlone` is the entire reason the mirror exists: an App Store account
    /// holding no transactions at all for this app is indistinguishable from
    /// "the user just switched storefront accounts", which is precisely the state
    /// the mirror is there to survive. Only a transaction Apple actually revoked
    /// may clear it.
    static func action(ownedCount: Int, revokedCount: Int) -> Action {
        if ownedCount > 0 { return .store }
        if revokedCount > 0 { return .revoke }
        return .leaveAlone
    }

    /// Whether this build may store or clear the mirror at all. A TestFlight build
    /// that cannot buy reads the App Store's record; anything it wrote there would
    /// be a Sandbox state in the App Store slot — the August leak in reverse — and
    /// a clear would take a paying member's Pro away.
    static func mayWrite(purchaseMode: SubscriptionPurchaseMode) -> Bool {
        purchaseMode == .ownEnvironment
    }
}

/// The environment this build itself runs in, as reported by Apple's
/// `AppTransaction` (the app's own receipt, not any purchase): a TestFlight build
/// reports `.sandbox`, an App Store build `.production`.
///
/// Not actor-isolated, because the keychain cache and the CloudKit mirror both
/// need the storage suffix from outside the main actor.
enum SubscriptionRuntimeEnvironment {
    private static let storageKey = "subscription_running_environment"

    /// `nil` until `AppTransaction` has been read once; persisted after that so
    /// later launches have an answer synchronously and offline.
    ///
    /// This is a CACHE, not the truth. It does change for what iOS treats as one
    /// installed app: a TestFlight build replaced by the App Store build keeps
    /// this container, so a remembered `.sandbox` outlived the build that wrote
    /// it and locked paying customers out of every entitlement path. Callers must
    /// keep asking `AppTransaction` and overwrite this — see
    /// `SubscriptionStore.resolveRunningEnvironment()`.
    static var current: AppStore.Environment? {
        UserDefaults.standard.string(forKey: storageKey)
            .map(AppStore.Environment.init(rawValue:))
    }

    static func remember(_ environment: AppStore.Environment) {
        UserDefaults.standard.set(environment.rawValue, forKey: storageKey)
    }

    /// Gate for every environment-scoped store. Until the environment is known
    /// there is no correct slot to use, and defaulting to the Production one
    /// would let a TestFlight build file its free entitlement where the App Store
    /// build reads it — the exact leak the suffix exists to close. Skipping the
    /// cache entirely is safe: StoreKit still reports the live entitlement.
    static var isResolved: Bool { current != nil }

    private static let isDebugBuild: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// Whether App Store Connect lists this build as waiting for or in App Review;
    /// nil until the backend has answered. Memory-only: a build leaves review, so a
    /// remembered answer would go stale exactly like `current` once did.
    private static let reviewAnswer = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    static var buildUnderReview: Bool? { reviewAnswer.withLock { $0 } }

    static func rememberReviewAnswer(_ underReview: Bool) {
        reviewAnswer.withLock { $0 = underReview }
    }

    static var purchaseMode: SubscriptionPurchaseMode {
        SubscriptionPurchaseModePolicy.mode(
            runningEnvironment: current,
            isDebugBuild: isDebugBuild,
            buildUnderReview: buildUnderReview
        )
    }

    /// The environment whose entitlement this build reads: its own, except on a
    /// TestFlight build that cannot buy, which reads the member's App Store Pro.
    static var entitlementEnvironment: AppStore.Environment? {
        entitlementEnvironment(for: purchaseMode, runningEnvironment: current)
    }

    static func entitlementEnvironment(
        for mode: SubscriptionPurchaseMode,
        runningEnvironment: AppStore.Environment?
    ) -> AppStore.Environment? {
        mode == .testFlightWithoutPurchases ? .production : runningEnvironment
    }

    /// Suffix that keeps each environment's entitlement state in its own storage
    /// slot, for the two stores that outlive the app: the keychain cache and the
    /// CloudKit mirror. Both survive one install replacing another, so a single
    /// slot let a TestFlight install's Pro state be read straight back by an App
    /// Store build put on top of it. Production keeps the bare key so entitlement
    /// state already cached by paying users survives this change.
    static var storageSuffix: String {
        storageSuffix(for: entitlementEnvironment)
    }

    static func storageSuffix(for environment: AppStore.Environment?) -> String {
        guard let environment, environment != .production else { return "" }
        return ".\(environment.rawValue.lowercased())"
    }

    /// Firestore field names on `entitlements/{uid}` for this environment. The
    /// document carries both environments side by side so one account can hold a
    /// TestFlight entitlement and an App Store one independently.
    static var entitlementFieldNames: (isActive: String, expiresAt: String, productIDs: String) {
        entitlementFieldNames(for: entitlementEnvironment)
    }

    static func entitlementFieldNames(
        for environment: AppStore.Environment?
    ) -> (isActive: String, expiresAt: String, productIDs: String) {
        environment == .sandbox ?
            ("sandboxIsProActive", "sandboxExpiresAt", "sandboxProductIds") :
            ("isProActive", "expiresAt", "productIds")
    }
}

/// Which purchase rules this build runs under.
///
/// App Review and TestFlight install the same uploaded binary and both run it in
/// the Sandbox, where purchases are free, so `AppTransaction` alone cannot tell a
/// reviewer from a tester. App Store Connect can: `isBuildUnderReview` in Cloud
/// Functions answers whether this build is the one App Review has open.
enum SubscriptionPurchaseMode: Equatable {
    /// Buys, and keeps its entitlement in its own environment: the App Store
    /// build, a Debug run, and the TestFlight build App Review has open.
    case ownEnvironment
    /// Every other TestFlight build. It cannot buy, and its Pro is the member's
    /// App Store Pro, read from the account and the iCloud mirror. It writes no
    /// entitlement of its own, so nothing from the Sandbox reaches the App Store
    /// slots.
    case testFlightWithoutPurchases
}

enum SubscriptionPurchaseModePolicy {
    static func mode(
        runningEnvironment: AppStore.Environment?,
        isDebugBuild: Bool,
        buildUnderReview: Bool?
    ) -> SubscriptionPurchaseMode {
        guard !isDebugBuild, runningEnvironment == .sandbox else { return .ownEnvironment }
        // Unanswered counts as TestFlight: the backend is unreachable from mainland
        // China without a VPN, and a TestFlight build must not sell there. App
        // Review reaches it, and a purchase asks before it decides.
        return buildUnderReview == true ? .ownEnvironment : .testFlightWithoutPurchases
    }
}

enum SubscriptionEntitlementFilter {
    /// Whether a transaction counts as an entitlement for *this* build.
    ///
    /// StoreKit already separates the two: a TestFlight build's
    /// `Transaction.currentEntitlements` yields Sandbox transactions, an App
    /// Store build's yields Production ones. So this is defence in depth, not the
    /// primary boundary — the entitlement that actually leaked across builds was
    /// the account one in `entitlements/{uid}`, which is why signing out was what
    /// cleared it.
    ///
    /// It compares against the environment whose entitlement the build reads
    /// (`SubscriptionRuntimeEnvironment.entitlementEnvironment`). For a build that
    /// buys, that is its own: a TestFlight build App Review has open must honour
    /// the Sandbox purchase it just made. For a TestFlight build that cannot buy it
    /// is Production, so the free Sandbox purchases testers made before purchases
    /// were closed stop counting.
    static func shouldAccept(
        environment: AppStore.Environment,
        entitlementEnvironment: AppStore.Environment?,
        isDebugBuild: Bool
    ) -> Bool {
        // A local Xcode run buys either through a StoreKit configuration file
        // (.xcode) or a sandbox Apple Account (.sandbox); accept both so testing
        // is not blocked by which one the developer picked.
        if isDebugBuild { return true }
        // Environment not resolved yet (first launch, `AppTransaction` still in
        // flight): trust StoreKit's own separation rather than discarding a real
        // purchase. The account path stays gated on a resolved environment.
        guard let entitlementEnvironment else { return true }
        return environment == entitlementEnvironment
    }
}
