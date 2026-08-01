import StoreKit

enum SubscriptionPurchaseAction: Equatable {
    case promptGuest
    case purchaseForAccount
}

enum SubscriptionAccessPolicy {
    static func isProActive(storeKit: Bool, account: Bool) -> Bool {
        storeKit || account
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
