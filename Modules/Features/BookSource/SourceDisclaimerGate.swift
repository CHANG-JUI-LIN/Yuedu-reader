import Foundation

/// The source disclaimer in front of anything that adds content the app does not ship: a
/// 來源配置 or a module (Phase 6e). It is asked once (`sourceDisclaimerAccepted`); the route asked
/// for before it was accepted opens once it has gone.
@MainActor
struct SourceDisclaimerGate<Route> {
    /// Drives the `SourceDisclaimerView` cover.
    var isPresented = false
    private var pending: Route?

    /// `route` when the disclaimer is accepted; otherwise nil, and the disclaimer shows first.
    mutating func pass(_ route: Route) -> Route? {
        if GlobalSettings.shared.sourceDisclaimerAccepted { return route }
        pending = route
        isPresented = true
        return nil
    }

    mutating func accept() {
        GlobalSettings.shared.sourceDisclaimerAccepted = true
        isPresented = false
    }

    /// The route asked for, from the cover's real `onDismiss`, when the disclaimer was accepted.
    mutating func afterDismissal() -> Route? {
        defer { pending = nil }
        return GlobalSettings.shared.sourceDisclaimerAccepted ? pending : nil
    }
}
