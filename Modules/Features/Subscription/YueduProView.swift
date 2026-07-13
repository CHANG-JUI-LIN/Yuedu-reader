import SwiftUI

/// Pushed settings page describing `Yuedu Pro` status and its features.
/// Free users see a subscribe CTA that presents the paywall; subscribers see an
/// active badge plus a link to manage the subscription in the App Store.
struct YueduProView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.openURL) private var openURL
    @State private var showPaywall = false

    private let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")

    var body: some View {
        Form {
            statusSection
            featuresSection
            manageSection
        }
        .navigationTitle(localized("閱讀Pro"))
        .toolbarTitleDisplayMode(.inline)
        .themedAppSurface(for: .settings)
        .sheet(isPresented: $showPaywall) {
            PaywallView()
                .environmentObject(store)
        }
        .task { await store.loadProducts() }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        Section {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: "crown.fill")
                    .font(DSFont.fixed(size: 28))
                    .foregroundStyle(DSColor.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("閱讀Pro"))
                        .font(DSFont.headline)
                    Text(store.isProActive ? localized("已訂閱，感謝支持") : localized("解鎖高級個人化"))
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
                Spacer(minLength: 0)
                if store.isProActive {
                    Text(localized("已啟用"))
                        .font(DSFont.caption.weight(.semibold))
                        .foregroundStyle(DSColor.success)
                }
            }
            .padding(.vertical, DSSpacing.xs)
        }

        if !store.isProActive {
            Section {
                Button {
                    showPaywall = true
                } label: {
                    Text(localized("查看訂閱方案"))
                        .font(DSFont.bodyBold)
                        .foregroundStyle(DSColor.textOnAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DSSpacing.xs)
                }
                .listRowBackground(DSColor.accent)
            }
        }
    }

    // MARK: - Features

    private var featuresSection: some View {
        Section(header: Text(localized("Pro 功能"))) {
            ForEach(PremiumFeature.allCases) { feature in
                HStack(spacing: DSSpacing.md) {
                    Image(systemName: feature.iconName)
                        .font(DSFont.fixed(size: 17, weight: .medium))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.localizedTitle)
                            .foregroundColor(DSColor.textPrimary)
                        Text(feature.localizedSubtitle)
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: store.hasAccess(feature) ? "checkmark.circle.fill" : "lock.fill")
                        .foregroundStyle(store.hasAccess(feature) ? DSColor.success : DSColor.textSecondary)
                        .accessibilityLabel(store.hasAccess(feature) ? localized("已解鎖") : localized("需要 Pro"))
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Manage

    private var manageSection: some View {
        Section {
            Button {
                Task { await store.restore() }
            } label: {
                HStack {
                    Label(localized("恢復購買"), systemImage: "arrow.clockwise")
                        .labelStyle(IconConsistentLabelStyle())
                    Spacer()
                    if store.isRestoring { ProgressView() }
                }
            }
            .disabled(store.isRestoring)

            if store.isProActive, let manageSubscriptionsURL {
                Button {
                    openURL(manageSubscriptionsURL)
                } label: {
                    Label(localized("管理訂閱"), systemImage: "gear")
                        .labelStyle(IconConsistentLabelStyle())
                }
            }
        } footer: {
            if let error = store.lastErrorMessage {
                Text(error).foregroundColor(DSColor.destructive)
            }
        }
    }
}

#Preview {
    NavigationStack {
        YueduProView()
            .environmentObject(SubscriptionStore.shared)
    }
}
