import StoreKit

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
    /// nothing left to sell, so showing a paywall would be wrong.
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

    /// Suffix that keeps each environment's entitlement state in its own storage
    /// slot, for the two stores that outlive the app: the keychain cache and the
    /// CloudKit mirror. Both survive one install replacing another, so a single
    /// slot let a TestFlight install's Pro state be read straight back by an App
    /// Store build put on top of it. Production keeps the bare key so entitlement
    /// state already cached by paying users survives this change.
    static var storageSuffix: String {
        guard let current, current != .production else { return "" }
        return ".\(current.rawValue.lowercased())"
    }

    /// Firestore field names on `entitlements/{uid}` for this environment. The
    /// document carries both environments side by side so one account can hold a
    /// TestFlight entitlement and an App Store one independently.
    static var entitlementFieldNames: (isActive: String, expiresAt: String, productIDs: String) {
        current == .sandbox ?
            ("sandboxIsProActive", "sandboxExpiresAt", "sandboxProductIds") :
            ("isProActive", "expiresAt", "productIds")
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
    /// Critically this compares against the *running* environment rather than
    /// rejecting Sandbox outright. Rejecting it meant a TestFlight build threw
    /// away the purchase it had just made, so neither the lifetime nor the
    /// monthly product ever unlocked there.
    static func shouldAccept(
        environment: AppStore.Environment,
        runningEnvironment: AppStore.Environment?,
        isDebugBuild: Bool
    ) -> Bool {
        // A local Xcode run buys either through a StoreKit configuration file
        // (.xcode) or a sandbox Apple Account (.sandbox); accept both so testing
        // is not blocked by which one the developer picked.
        if isDebugBuild { return true }
        // Environment not resolved yet (first launch, `AppTransaction` still in
        // flight): trust StoreKit's own separation rather than discarding a real
        // purchase. The account path stays gated on a resolved environment.
        guard let runningEnvironment else { return true }
        return environment == runningEnvironment
    }
}
