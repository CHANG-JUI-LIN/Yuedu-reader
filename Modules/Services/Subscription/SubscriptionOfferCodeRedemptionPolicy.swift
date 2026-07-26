enum SubscriptionOfferCodeRedemptionPolicy {
    enum Action: Equatable {
        case present
        case ignore
        case reportUnavailable
    }

    static func action(isRedeeming: Bool, hasWindowScene: Bool) -> Action {
        guard !isRedeeming else { return .ignore }
        guard hasWindowScene else { return .reportUnavailable }
        return .present
    }
}
