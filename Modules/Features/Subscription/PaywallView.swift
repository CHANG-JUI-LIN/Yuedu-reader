import StoreKit
import SwiftUI
import UIKit

/// Modal paywall for `Yuedu Pro`. Presented from feature lock rows and from the
/// Pro settings page. Shows the value proposition, the monthly/lifetime options,
/// and the required "Restore Purchases" / terms links for App Review.
struct PaywallView: View {
    @EnvironmentObject private var store: SubscriptionStore
    @Environment(\.dismiss) private var dismiss

    /// The feature the user tapped to reach the paywall, highlighted at the top.
    var highlightedFeature: PremiumFeature?

    @State private var selectedProduct: SubscriptionStore.ProProduct = .lifetime
    @State private var pendingProduct: Product?
    @State private var showGuestPurchaseAlert = false
    @State private var showLogin = false
    @State private var purchaseAfterLogin = false
    /// Switches the sheet content to the thank-you page once a Pro
    /// entitlement becomes active (purchase, offer-code redemption, restore).
    @State private var showSuccess = false
    /// Set when the buyer held a monthly subscription as this sheet opened, so
    /// the thank-you page can tell them to cancel it. Apple cannot prorate
    /// across product types, so the old subscription keeps billing until they do.
    @State private var upgradedFromMonthly = false

    private let privacyPolicyURL = URL(string: "https://chang-jui-lin.github.io/Yuedu-reader/privacy.html")
    /// Apple's standard EULA. The custom paid-terms.html page is retired.
    private let paidTermsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")

    private var activeWindowScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first {
                $0.activationState == .foregroundActive
                    && $0.windows.contains(where: \.isKeyWindow)
            }
    }

    /// What to show right now: a thank-you page after a purchase completes here,
    /// an "already Pro" page for someone who has nothing left to buy, or the
    /// offer itself.
    private var presentation: PaywallPresentationState {
        PaywallPresentationPolicy.state(
            purchasedProductIDs: store.purchasedProductIDs,
            lifetimeProductID: SubscriptionStore.ProProduct.lifetime.rawValue,
            monthlyProductID: SubscriptionStore.ProProduct.monthly.rawValue,
            isProActive: store.isProActive
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if showSuccess {
                    PurchaseSuccessView(showsMonthlyCancellationHint: upgradedFromMonthly)
                } else if presentation == .alreadyPro {
                    alreadyProContent
                } else {
                    paywallContent
                }
            }
            .task { await store.loadProducts() }
            .onChange(of: store.isProActive) { _, _ in
                presentSuccessIfProIsReady()
            }
            .onChange(of: store.isRedeemingOfferCode) { _, isRedeeming in
                if !isRedeeming {
                    presentSuccessIfProIsReady()
                }
            }
            .alert(localized("選擇購買方式"), isPresented: $showGuestPurchaseAlert) {
                Button(localized("登入後購買")) {
                    purchaseAfterLogin = true
                    showLogin = true
                }
                Button(localized("直接購買")) {
                    purchaseAfterLogin = false
                    purchasePendingProductForGuest()
                }
                Button(localized("取消"), role: .cancel) {
                    pendingProduct = nil
                    purchaseAfterLogin = false
                }
            } message: {
                Text(localized("未登入時，會員只會跟隨本次購買使用的 Apple 帳號。登入後購買可綁定 Yuedu 帳號，切換 App Store 帳號後仍可使用。"))
            }
            .sheet(isPresented: $showLogin, onDismiss: purchasePendingProductAfterLogin) {
                LoginView()
            }
        }
    }

    private var paywallContent: some View {
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
    }

    /// The "you already have Pro" page. Deliberately not `PurchaseSuccessView`:
    /// nothing was just bought, so celebrating a purchase would be misleading.
    private var alreadyProContent: some View {
        ScrollView {
            VStack(spacing: DSSpacing.xl) {
                VStack(spacing: DSSpacing.sm) {
                    Image(systemName: "crown.fill")
                        .font(DSFont.fixed(size: 56))
                        .foregroundStyle(DSColor.accent)
                        .accessibilityHidden(true)
                    Text(localized("你已經是 閱讀Pro"))
                        .font(DSFont.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                    Text(ownedPlanDescription)
                        .font(DSFont.subheadline)
                        .foregroundColor(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, DSSpacing.lg)

                featureList

                Button {
                    dismiss()
                } label: {
                    Text(localized("開始閱讀"))
                        .font(DSFont.bodyBold)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
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
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(localized("關閉"))
            }
        }
    }

    private var ownedPlanDescription: String {
        store.purchasedProductIDs.contains(SubscriptionStore.ProProduct.lifetime.rawValue)
            ? localized("你持有永久會員，所有 Pro 功能都已啟用")
            : localized("所有 Pro 功能都已啟用")
    }

    private func presentSuccessIfProIsReady() {
        if store.isProActive,
           !store.isRedeemingOfferCode,
           store.lastErrorMessage == nil {
            showSuccess = true
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

            Divider()

            HStack(spacing: DSSpacing.md) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(DSFont.fixed(size: 18, weight: .medium))
                    .foregroundStyle(DSColor.textSecondary)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized("更多客製化功能"))
                        .font(DSFont.bodyBold)
                        .foregroundColor(DSColor.textPrimary)
                    Text(localized("更多個人化設定正在開發中，敬請期待"))
                        .font(DSFont.caption)
                        .foregroundColor(DSColor.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .opacity(0.6)
        }
        .padding(DSSpacing.lg)
        .interfaceCardSurface()
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }

    /// Highlighted feature first, then the implemented marketing features in declaration order.
    private var orderedFeatures: [PremiumFeature] {
        PremiumFeature.marketedFeatures(highlighting: highlightedFeature)
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
        // The plan they already pay for is shown as their current one, never as
        // something to buy again.
        let isCurrentPlan = presentation == .upgradeFromMonthly && pro == .monthly
        let isSelected = selectedProduct == pro && !isCurrentPlan
        return Button {
            selectedProduct = pro
        } label: {
            HStack(spacing: DSSpacing.md) {
                Image(systemName: planMarkSymbol(isCurrentPlan: isCurrentPlan, isSelected: isSelected))
                    .foregroundStyle(isCurrentPlan ? DSColor.success : (isSelected ? DSColor.accent : DSColor.textSecondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: DSSpacing.xs) {
                        Text(planTitle(pro))
                            .font(DSFont.bodyBold)
                            .foregroundColor(DSColor.textPrimary)
                        if isCurrentPlan {
                            Text(localized("目前方案"))
                                .font(DSFont.caption2)
                                .foregroundColor(DSColor.success)
                        } else if pro == .lifetime {
                            Text(presentation == .upgradeFromMonthly
                                 ? localized("升級")
                                 : localized("最超值"))
                                .font(DSFont.caption2)
                                .foregroundColor(DSColor.accent)
                        }
                    }
                    Text(isCurrentPlan ? localized("訂閱中") : planDescription(pro))
                        .font(DSFont.caption2)
                        .foregroundColor(DSColor.textSecondary)
                }
                Spacer(minLength: 0)
                if let product {
                    Text(priceText(for: pro, product: product))
                        .font(DSFont.bodyBold)
                        .foregroundColor(isCurrentPlan ? DSColor.textSecondary : DSColor.textPrimary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(DSSpacing.lg)
            .interfaceCardSurface()
            .overlay(
                RoundedRectangle(cornerRadius: DSRadius.lg)
                    .stroke(isSelected ? DSColor.accent : DSColor.border, lineWidth: isSelected ? 2 : 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
        }
        .buttonStyle(.plain)
        .disabled(product == nil || isCurrentPlan)
    }

    private var subscribeButtonTitle: String {
        if presentation == .upgradeFromMonthly, selectedProduct == .lifetime {
            return localized("升級為永久會員")
        }
        return selectedProduct == .lifetime
            ? localized("購買 閱讀Pro")
            : localized("訂閱 閱讀Pro")
    }

    private func planMarkSymbol(isCurrentPlan: Bool, isSelected: Bool) -> String {
        if isCurrentPlan { return "checkmark.circle.fill" }
        return isSelected ? "largecircle.fill.circle" : "circle"
    }

    private func planTitle(_ pro: SubscriptionStore.ProProduct) -> String {
        switch pro {
        case .lifetime: return localized("永久會員")
        case .monthly: return localized("月會員")
        }
    }

    private func planDescription(_ pro: SubscriptionStore.ProProduct) -> String {
        switch pro {
        case .lifetime: return localized("一次性購買，永久有效")
        case .monthly: return localized("每月自動續訂，可隨時取消")
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
                guard let product = store.product(for: selectedProduct) else { return }
                upgradedFromMonthly = presentation == .upgradeFromMonthly
                beginPurchase(product)
            } label: {
                Group {
                    if store.isPurchasing {
                        ProgressView().tint(DSColor.textOnAccent)
                    } else {
                        Text(subscribeButtonTitle)
                            .font(DSFont.bodyBold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.isPurchasing || store.product(for: selectedProduct) == nil)

            if presentation == .upgradeFromMonthly, selectedProduct == .lifetime {
                // Apple prorates only within a subscription group. Lifetime is a
                // non-consumable, so the monthly subscription keeps billing until
                // the user cancels it themselves — say so before they pay.
                Text(localized("升級後請記得取消月訂閱，否則會繼續扣款"))
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let error = store.lastErrorMessage {
                Text(error)
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.destructive)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func beginPurchase(_ product: Product) {
        switch SubscriptionAccessPolicy.purchaseAction(
            isAuthenticated: FirebaseAuthManager.shared.isAuthenticated
        ) {
        case .promptGuest:
            pendingProduct = product
            showGuestPurchaseAlert = true
        case .purchaseForAccount:
            Task { await store.purchaseForSignedInAccount(product) }
        }
    }

    private func purchasePendingProductForGuest() {
        guard let product = pendingProduct else { return }
        pendingProduct = nil
        Task { await store.purchaseAsGuest(product) }
    }

    private func purchasePendingProductAfterLogin() {
        defer {
            purchaseAfterLogin = false
            pendingProduct = nil
        }
        guard purchaseAfterLogin,
              FirebaseAuthManager.shared.isAuthenticated,
              let product = pendingProduct else { return }
        Task { await store.purchaseForSignedInAccount(product) }
    }

    // MARK: - Restore & terms

    private var restoreAndTerms: some View {
        VStack(spacing: DSSpacing.md) {
            Button {
                let scene = activeWindowScene
                Task { await store.redeemOfferCode(in: scene) }
            } label: {
                Group {
                    if store.isRedeemingOfferCode {
                        ProgressView()
                    } else {
                        Label(localized("兌換優惠碼"), systemImage: "ticket.fill")
                    }
                }
                .font(DSFont.subheadline)
                .frame(minHeight: 44)
            }
            .disabled(store.isRedeemingOfferCode)
            .accessibilityLabel(localized("兌換優惠碼"))

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
                    Link(localized("使用條款 (EULA)"), destination: paidTermsURL)
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
