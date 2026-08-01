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
    /// entitlement. Sandbox transactions (TestFlight purchases) are only
    /// accepted in DEBUG builds or when the user explicitly enables the
    /// "allow test purchases" setting — otherwise an App Store build would
    /// grant free Pro from stale TestFlight transactions lingering in the
    /// device's shared StoreKit database.
    static func shouldAccept(environment: Transaction.Environment, allowSandbox: Bool, isDebugBuild: Bool) -> Bool {
        switch environment {
        case .sandbox:
            return isDebugBuild || allowSandbox
        case .production, .xcode, .localTesting:
            return true
        @unknown default:
            return false
        }
    }
}
