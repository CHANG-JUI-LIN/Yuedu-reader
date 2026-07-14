import StoreKit
import SwiftUI

/// Modal paywall for `Yuedu Pro`. Presented from feature lock rows and from the
/// Pro settings page. Shows the value proposition, the monthly/yearly options,
/// and the required "Restore Purchases" / terms links for App Review.
struct PaywallView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    /// The feature the user tapped to reach the paywall, highlighted at the top.
    var highlightedFeature: PremiumFeature?

    @State private var selectedProduct: SubscriptionStore.ProProduct = .lifetime

    private let privacyPolicyURL = URL(string: "https://chang-jui-lin.github.io/Yuedu-reader/privacy.html")
    private let paidTermsURL = URL(string: "https://chang-jui-lin.github.io/Yuedu-reader/paid-terms.html")

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: DSSpacing.xl) {
                    header
                    featureList
                    planPicker
                    subscribeButton
                    restoreAndTerms
                }
                .padding(DSSpacing.lg)
                .frame(maxWidth: DSLayout.readableFormWidth)
                .frame(maxWidth: .infinity)
            }
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .pageBackgroundToolbar(for: .settings)
            .navigationTitle(localized("閱讀Pro"))
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("關閉"))
                }
            }
            .task { await store.loadProducts() }
            .onChange(of: store.isProActive) { _, isActive in
                if isActive { dismiss() }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: DSSpacing.sm) {
            Image(systemName: "crown.fill")
                .font(DSFont.fixed(size: 44))
                .foregroundStyle(DSColor.accent)
                .accessibilityHidden(true)
            Text(localized("閱讀Pro"))
                .font(DSFont.largeTitle.weight(.bold))
            Text(localized("解鎖高級個人化，打造專屬的閱讀體驗"))
                .font(DSFont.subheadline)
                .foregroundColor(DSColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DSSpacing.md)
    }

    // MARK: - Feature list

    private var featureList: some View {
        VStack(spacing: DSSpacing.md) {
            ForEach(orderedFeatures) { feature in
                HStack(spacing: DSSpacing.md) {
                    Image(systemName: feature.iconName)
                        .font(DSFont.fixed(size: 18, weight: .medium))
                        .foregroundStyle(DSColor.accent)
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(feature.localizedTitle)
                            .font(DSFont.bodyBold)
                            .foregroundColor(DSColor.textPrimary)
                        Text(feature.localizedSubtitle)
                            .font(DSFont.caption)
                            .foregroundColor(DSColor.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if feature == highlightedFeature {
                        Image(systemName: "sparkles")
                            .foregroundStyle(DSColor.accent)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(DSSpacing.lg)
        .background(DSColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }

    /// Highlighted feature first, then the rest in declaration order.
    private var orderedFeatures: [PremiumFeature] {
        guard let highlightedFeature else { return PremiumFeature.allCases }
        return [highlightedFeature] + PremiumFeature.allCases.filter { $0 != highlightedFeature }
    }

    // MARK: - Plan picker

    private var planPicker: some View {
        VStack(spacing: DSSpacing.md) {
            if store.isLoadingProducts && store.products.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DSSpacing.lg)
            } else {
                ForEach(SubscriptionStore.ProProduct.allCases, id: \.self) { pro in
                    planOption(pro)
                }
            }
        }
    }

    private func planOption(_ pro: SubscriptionStore.ProProduct) -> some View {
        let product = store.product(for: pro)
        let isSelected = selectedProduct == pro
        return Button {
            selectedProduct = pro
        } label: {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? DSColor.accent : DSColor.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(planTitle(pro))
                        .font(DSFont.bodyBold)
                        .foregroundColor(DSColor.textPrimary)
                    if pro == .lifetime {
                        Text(localized("最超值"))
                            .font(DSFont.caption2)
                            .foregroundColor(DSColor.accent)
                    }
                }
                Spacer(minLength: 0)
                if let product {
                    Text(priceText(for: pro, product: product))
                        .font(DSFont.bodyBold)
                        .foregroundColor(DSColor.textPrimary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(DSSpacing.lg)
            .background(DSColor.surface)
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.lg)
                    .stroke(isSelected ? DSColor.accent : DSColor.border, lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
        }
        .buttonStyle(.plain)
        .disabled(product == nil)
    }

    private func planTitle(_ pro: SubscriptionStore.ProProduct) -> String {
        switch pro {
        case .lifetime: return localized("永久會員")
        case .monthly: return localized("月會員")
        }
    }

    private func priceText(for pro: SubscriptionStore.ProProduct, product: Product) -> String {
        if pro == .lifetime {
            return product.displayPrice
        }
        return product.displayPrice + localized("／月")
    }

    // MARK: - Subscribe

    private var subscribeButton: some View {
        VStack(spacing: DSSpacing.sm) {
            Button {
                Task {
                    guard let product = store.product(for: selectedProduct) else {
                        await store.loadProducts()
                        return
                    }
                    await store.purchase(product)
                }
            } label: {
                Group {
                    if store.isPurchasing {
                        ProgressView().tint(DSColor.textOnAccent)
                    } else {
                        Text(selectedProduct == .lifetime
                             ? localized("購買 閱讀Pro")
                             : localized("訂閱 閱讀Pro"))
                            .font(DSFont.bodyBold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isPurchasing || store.product(for: selectedProduct) == nil)

            if let error = store.lastErrorMessage {
                Text(error)
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.destructive)
                    .multilineTextAlignment(.center)
            }

            Text(selectedProduct == .lifetime
                 ? localized("一次性購買，永久有效")
                 : localized("訂閱會自動續期，可隨時在 App Store 取消"))
                .font(DSFont.caption2)
                .foregroundColor(DSColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Restore & terms

    private var restoreAndTerms: some View {
        VStack(spacing: DSSpacing.md) {
            Button {
                Task { await store.restore() }
            } label: {
                if store.isRestoring {
                    ProgressView()
                } else {
                    Text(localized("恢復購買"))
                        .font(DSFont.subheadline)
                }
            }
            .disabled(store.isRestoring)

            HStack(spacing: DSSpacing.md) {
                if let paidTermsURL {
                    Link(localized("訂閱條款"), destination: paidTermsURL)
                }
                if let privacyPolicyURL {
                    Link(localized("隱私政策"), destination: privacyPolicyURL)
                }
            }
            .font(DSFont.caption)
        }
        .padding(.bottom, DSSpacing.lg)
    }
}

#Preview {
    PaywallView(highlightedFeature: .readerBackgroundImport)
        .environmentObject(SubscriptionStore.shared)
}
