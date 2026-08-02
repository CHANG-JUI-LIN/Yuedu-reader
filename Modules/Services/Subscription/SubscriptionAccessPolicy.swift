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

enum SubscriptionEntitlementFilter {
    /// Whether a transaction from the given StoreKit environment counts as an
    /// entitlement. Sandbox transactions are accepted only by DEBUG builds
    /// used for local StoreKit testing; Release/TestFlight/App Store builds
    /// never count a sandbox transaction, so stale TestFlight purchases
    /// lingering in the device's shared StoreKit database cannot unlock Pro
    /// in the production app.
    static func shouldAccept(environment: AppStore.Environment, isDebugBuild: Bool) -> Bool {
        switch environment {
        case .sandbox:
            return isDebugBuild
        case .production, .xcode:
            return true
        default:
            return false
        }
    }
}
