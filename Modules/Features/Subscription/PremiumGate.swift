import SwiftUI

/// Reusable gating helpers so every Pro feature presents the same lock UX.
///
/// The renderer/data layers never delete a user's imported content when Pro
/// lapses — gating only controls *entry points*. Use `ProLockBadge` for an
/// inline lock chip, or `.premiumGate(_:isActive:)` to intercept a tap and
/// present the paywall when the feature is locked.
struct ProLockBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "lock.fill")
            Text("Pro")
        }
        .font(DSFont.caption2.weight(.semibold))
        .padding(.horizontal, DSSpacing.sm)
        .padding(.vertical, 2)
        .background(DSColor.accentLight)
        .foregroundStyle(DSColor.accent)
        .clipShape(Capsule())
        .accessibilityLabel(localized("需要 Pro"))
    }
}

private struct PremiumGateModifier: ViewModifier {
    @EnvironmentObject private var store: SubscriptionStore
    let feature: PremiumFeature
    @State private var showPaywall = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .trailing) {
                if !store.hasAccess(feature) {
                    ProLockBadge()
                        .padding(.trailing, DSSpacing.md)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture().onEnded {
                    if !store.hasAccess(feature) { showPaywall = true }
                },
                including: store.hasAccess(feature) ? .subviews : .all
            )
            .sheet(isPresented: $showPaywall) {
                PaywallView(highlightedFeature: feature)
                    .environmentObject(store)
            }
    }
}

extension View {
    /// Wraps a row/control so that, when `feature` is locked, taps present the
    /// paywall (highlighting `feature`) instead of activating the control.
    func premiumGate(_ feature: PremiumFeature) -> some View {
        modifier(PremiumGateModifier(feature: feature))
    }
}
