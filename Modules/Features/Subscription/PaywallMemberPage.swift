import SwiftUI
import StoreKit

/// The paywall for someone who owns Pro — the one Pro page there is. Opened from the
/// 閱讀Pro row it shows the plan they have, what they can do about it, and everything Pro
/// unlocked, in the offer's own cards; opened by the purchase that just unlocked Pro it
/// is the thank-you too, with the celebration.
///
/// What a buyer should get the moment they pay (marketing skills: paywalls
/// "Post-Upgrade", signup "Success State"): the features at once, a confirmation of what
/// they bought, a guide to what it unlocked, and one clear next step.
struct PaywallMemberPage: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Pro unlocked while the paywall was open. Fixed for the page's lifetime: the
    /// paywall gives the page a new identity when it turns true, so the celebration
    /// always plays from its start.
    let celebrates: Bool
    /// That unlock was a monthly subscriber buying lifetime; the monthly plan keeps
    /// billing until they cancel it.
    let upgradedFromMonthly: Bool
    /// The feature that opened the paywall; its pillar leads.
    let highlightedFeature: PremiumFeature?
    /// Buys lifetime for a monthly subscriber; nil when there is no upgrade to sell.
    let onUpgrade: (() -> Void)?

    private struct ConfettiThrow {
        let burst: ConfettiBurst
        let start: Date
    }

    @State private var hasAppeared = false
    @State private var confetti: ConfettiThrow?

    private let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")

    var body: some View {
        ScrollView {
            VStack(spacing: DSSpacing.xl) {
                header
                if let plan = store.ownedPlan {
                    planCard(plan)
                }
                if showsCancellationCard {
                    cancellationCard
                }
                if let onUpgrade {
                    upgrade(onUpgrade)
                }
                PaywallPillarList(leading: highlightedFeature, isUnlocked: true)
                memberActions
            }
            .padding(DSSpacing.lg)
            .frame(maxWidth: DSLayout.readableFormWidth)
            .frame(maxWidth: .infinity)
        }
        .softScrollEdges()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if celebrates {
                continueBar
            }
        }
        .overlay {
            if let confetti {
                ConfettiView(burst: confetti.burst, start: confetti.start)
                    .ignoresSafeArea()
            }
        }
        .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
        .pageBackgroundToolbar(for: .settings)
        .navigationTitle(localized("閱讀Pro"))
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(localized("關閉"))
            }
        }
        .sensoryFeedback(.success, trigger: hasAppeared) { _, appeared in
            celebrates && appeared
        }
        .onAppear {
            hasAppeared = true
            guard celebrates else { return }
            if !reduceMotion {
                confetti = ConfettiThrow(
                    burst: ConfettiBurst(
                        count: DSLayout.celebrationConfettiCount,
                        colors: DSColor.celebration.count,
                        seed: UInt64.random(in: .min ... .max)
                    ),
                    start: .now
                )
            }
            // The sheet changed under a VoiceOver user without their doing; say what happened.
            AccessibilityNotification.Announcement(localized("已解鎖 閱讀Pro")).post()
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: DSSpacing.sm) {
            PaywallAppIcon(celebrates: celebrates)
            Text(localized(celebrates ? "已解鎖 閱讀Pro" : "你已經是 閱讀Pro"))
                .font(DSFont.largeTitle.weight(.bold))
                .foregroundStyle(DSColor.textPrimary)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("pro_status_summary")
            if let subtitle {
                Text(subtitle)
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, DSSpacing.lg)
    }

    private var subtitle: String? {
        if celebrates {
            return localized("感謝你的支持，所有 Pro 功能現在都已啟用")
        }
        // Pro with no plan on this Apple Account behind it: no plan card will say it is on.
        return store.ownedPlan == nil ? localized("所有 Pro 功能都已啟用") : nil
    }

    // MARK: - Plan

    /// The plan they have, as the offer showed it — on the thank-you page, the receipt.
    private func planCard(_ plan: SubscriptionStore.ProProduct) -> some View {
        PaywallPlanCard(
            title: localized(plan == .lifetime ? "永久會員" : "月會員"),
            tag: localized("目前方案"),
            detail: localized(plan == .lifetime ? "一次性購買，永久有效" : "每月自動續訂，可隨時取消"),
            price: price(of: plan),
            mark: .owned
        )
        .accessibilityElement(children: .combine)
    }

    /// A lifetime price is history once paid, so it shows only as the thank-you page's
    /// receipt; the monthly one keeps being charged, so it always shows.
    private func price(of plan: SubscriptionStore.ProProduct) -> PaywallPlanCard.Price {
        guard plan == .monthly || celebrates, let product = store.product(for: plan) else { return .hidden }
        return .shown(plan == .lifetime
                      ? product.displayPrice
                      : String(format: localized("%@／月"), product.displayPrice))
    }

    // MARK: - Monthly after lifetime

    private var showsCancellationCard: Bool {
        celebrates && upgradedFromMonthly
    }

    /// Apple prorates only within a subscription group, and lifetime is a
    /// non-consumable: the monthly plan keeps billing until they cancel it. Leaving that
    /// unsaid would charge them twice.
    private var cancellationCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DSColor.warning)
                    .accessibilityHidden(true)
                Text(localized("請取消月訂閱"))
                    .font(DSFont.bodyBold)
                    .foregroundStyle(DSColor.textPrimary)
            }
            Text(localized("你已擁有永久會員，月訂閱不會自動停止，需要你手動取消才不會繼續扣款。"))
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let manageSubscriptionsURL {
                Button {
                    openURL(manageSubscriptionsURL)
                } label: {
                    Text(localized("前往取消訂閱"))
                        .font(DSFont.bodyBold)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(DSSpacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .interfaceCardSurface()
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }

    // MARK: - Upgrade

    /// A monthly subscriber's way to lifetime, priced on the button like every buy button.
    private func upgrade(_ action: @escaping () -> Void) -> some View {
        VStack(spacing: DSSpacing.sm) {
            Button(action: action) {
                Group {
                    if store.isPurchasing {
                        ProgressView().tint(DSColor.textOnAccent)
                    } else {
                        Text(upgradeTitle)
                            .font(DSFont.bodyBold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: DSLayout.minimumTapTarget)
            }
            // Working, not disabled, while purchasing: see `OnAccentProminentButtonStyle.work`.
            .buttonStyle(.onAccentProminent(working: store.isPurchasing, title: Text(upgradeTitle)))
            .disabled(store.product(for: .lifetime) == nil)
            .accessibilityIdentifier("pro_status_plan_action")
            // Said before they pay, not only after.
            Text(localized("升級後請記得取消月訂閱，否則會繼續扣款"))
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private var upgradeTitle: String {
        store.product(for: .lifetime)
            .map { String(format: localized("升級為永久會員・%@"), $0.displayPrice) }
            ?? localized("升級為永久會員")
    }

    // MARK: - Manage

    private var memberActions: some View {
        VStack(spacing: DSSpacing.md) {
            if store.subscriptionManagement != .unavailable, let manageSubscriptionsURL {
                Button {
                    openURL(manageSubscriptionsURL)
                } label: {
                    Text(localized("管理訂閱"))
                        .font(DSFont.subheadline)
                        .frame(minHeight: DSLayout.minimumTapTarget)
                }
                .accessibilityIdentifier("pro_status_manage_subscription")
            }
            Button {
                Task { await store.restore() }
            } label: {
                Group {
                    if store.isRestoring {
                        ProgressView()
                    } else {
                        Text(localized("恢復購買"))
                            .font(DSFont.subheadline)
                    }
                }
                .frame(minHeight: DSLayout.minimumTapTarget)
            }
            .disabled(store.isRestoring)
            .accessibilityIdentifier("pro_status_restore")
            if store.subscriptionManagement == .monthlyAlongsideLifetime, !showsCancellationCard {
                Text(localized("升級後請記得取消月訂閱，否則會繼續扣款"))
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if let error = store.lastErrorMessage {
                Text(error)
                    .font(DSFont.caption)
                    .foregroundStyle(DSColor.destructive)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.bottom, DSSpacing.lg)
    }

    // MARK: - Continue

    /// The one next step after paying: back to where they were, where the feature they
    /// tapped is now open.
    private var continueBar: some View {
        Button {
            dismiss()
        } label: {
            Text(localized("開始使用"))
                .font(DSFont.bodyBold)
                .frame(maxWidth: .infinity)
                .frame(minHeight: DSLayout.minimumTapTarget)
        }
        .buttonStyle(.onAccentProminent)
        .accessibilityIdentifier("pro_celebration_continue")
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
        .frame(maxWidth: DSLayout.readableFormWidth)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }
}

#Preview("Unlocked just now") {
    NavigationStack {
        PaywallMemberPage(celebrates: true, upgradedFromMonthly: false, highlightedFeature: .customFonts, onUpgrade: nil)
    }
    .environmentObject(SubscriptionStore.shared)
}

#Preview("Upgraded from monthly") {
    NavigationStack {
        PaywallMemberPage(celebrates: true, upgradedFromMonthly: true, highlightedFeature: nil, onUpgrade: nil)
    }
    .environmentObject(SubscriptionStore.shared)
}

#Preview("Monthly member") {
    NavigationStack {
        PaywallMemberPage(celebrates: false, upgradedFromMonthly: false, highlightedFeature: nil, onUpgrade: {})
    }
    .environmentObject(SubscriptionStore.shared)
}
