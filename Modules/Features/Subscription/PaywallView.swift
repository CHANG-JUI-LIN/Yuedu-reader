import StoreKit
import SwiftUI
import UIKit

/// Modal paywall for `Yuedu Pro`, and the only Pro page: presented from feature lock
/// rows and from Settings' 「閱讀Pro」 row. Someone who owns Pro gets its member page
/// (`PaywallMemberPage`) instead of the offer; a purchase made here turns the offer into
/// that page, celebrating.
///
/// Laid out the way a reader decides (2026-09-27 redesign): what they came for first —
/// the tapped feature's headline over a picture of it — then the price, with the buy
/// button pinned below so it never scrolls away, then everything Pro adds as three
/// benefits for anyone who reads on. No reviews or user counts: there is no real data
/// to show, and made-up proof would be worse than none. The required "Restore
/// Purchases" / terms links for App Review close the page.
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
    /// Pro unlocked while this sheet was open — a purchase, an Ask to Buy approval, an
    /// offer code, a restore — so the member page is the thank-you, celebrating.
    @State private var justUnlocked = false
    /// That unlock was lifetime reaching a monthly subscriber, so the thank-you page
    /// tells them to cancel the monthly plan. Apple cannot prorate across product types,
    /// so the old subscription keeps billing until they do.
    @State private var upgradedFromMonthly = false

    private let privacyPolicyURL = URL(string: "https://yuedureader.com/privacy")
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

    /// The offer for someone with nothing yet; the member page for an owner, which still
    /// sells lifetime to a monthly subscriber.
    private var presentation: PaywallPresentationState {
        store.paywallPresentationState
    }

    var body: some View {
        NavigationStack {
            Group {
                if justUnlocked || presentation != .offer {
                    PaywallMemberPage(
                        celebrates: justUnlocked,
                        upgradedFromMonthly: upgradedFromMonthly,
                        highlightedFeature: highlightedFeature,
                        onUpgrade: memberPageUpgradeAction
                    )
                    // A new page when Pro unlocks, so the thank-you and its celebration
                    // start from the top — also when the member page was already up, as
                    // it is for a monthly subscriber buying lifetime.
                    .id(justUnlocked)
                } else {
                    paywallContent
                }
            }
            .task { await store.loadProducts() }
            .onChange(of: store.isProActive) { wasPro, isPro in
                // Pro arrived while this sheet was open: a purchase here, an Ask to Buy
                // approval, a restore, family sharing. An offer code celebrates once
                // Apple's redemption sheet is done.
                if !wasPro, isPro, !store.isRedeemingOfferCode {
                    justUnlocked = true
                }
            }
            .onChange(of: store.isRedeemingOfferCode) { _, isRedeeming in
                // The redeem button is on the offer, which only someone without Pro sees,
                // so Pro now means the code unlocked it.
                if !isRedeeming, store.isProActive {
                    justUnlocked = true
                }
            }
            .onChange(of: presentation) { previous, current in
                // Lifetime reached a monthly subscriber, however the upgrade finished —
                // bought here, approved later, restored. Pro was active all along, so
                // nothing above fires; and the monthly plan keeps billing until they
                // cancel it, which the thank-you page has to say.
                if previous == .upgradeFromMonthly, current == .alreadyPro {
                    upgradedFromMonthly = true
                    justUnlocked = true
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

    /// The member page's lifetime upgrade, offered only to a monthly subscriber who has
    /// not just unlocked.
    private var memberPageUpgradeAction: (() -> Void)? {
        let upgrade: () -> Void = upgradeToLifetime
        return presentation == .upgradeFromMonthly && !justUnlocked ? upgrade : nil
    }

    private var paywallContent: some View {
        ScrollView {
            VStack(spacing: DSSpacing.xl) {
                hero
                planPicker
                PaywallPillarList(leading: highlightedFeature)
                restoreAndTerms
            }
            .padding(DSSpacing.lg)
            .frame(maxWidth: DSLayout.readableFormWidth)
            .frame(maxWidth: .infinity)
        }
        .softScrollEdges()
        .safeAreaInset(edge: .bottom, spacing: 0) { purchaseBar }
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

    // MARK: - Hero

    /// What they came for, first: the tapped feature's headline over its pillar's picture —
    /// or Pro as a whole, led by AI, from the Pro row.
    private var hero: some View {
        let pitch = PremiumPitch.pitch(for: highlightedFeature)
        let pillar = highlightedFeature.flatMap(PremiumPillar.pillar(for:)) ?? .understanding
        return VStack(spacing: DSSpacing.lg) {
            PaywallShowcase(pillar: pillar)
            VStack(spacing: DSSpacing.sm) {
                Text(localized(pitch.headlineKey))
                    .font(DSFont.title2.weight(.bold))
                    .foregroundStyle(DSColor.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(localized(pitch.pitchKey))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, DSSpacing.sm)
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
            PaywallPlanCard(
                title: planTitle(pro),
                tag: pro == .lifetime ? localized("最超值") : nil,
                detail: planDescription(pro),
                price: product.map { .shown(priceText(for: pro, product: $0)) } ?? .loading,
                mark: .choice(selected: isSelected)
            )
        }
        .buttonStyle(.plain)
        .disabled(product == nil)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Says what the tap buys and for how much, so nothing on Apple's sheet is a surprise.
    private var subscribeButtonTitle: String {
        let price = store.product(for: selectedProduct)?.displayPrice
        switch selectedProduct {
        case .lifetime:
            return price.map { String(format: localized("永久解鎖・%@"), $0) } ?? localized("購買 閱讀Pro")
        case .monthly:
            return price.map { String(format: localized("訂閱・%@／月"), $0) } ?? localized("訂閱 閱讀Pro")
        }
    }

    /// The one worry each plan raises, answered under the button.
    private var purchaseReassurance: String {
        switch selectedProduct {
        case .lifetime: return localized("一次付清，永久使用全部 Pro 功能")
        case .monthly: return localized("透過 Apple 付款，可隨時在帳號設定取消")
        }
    }

    private func planTitle(_ pro: SubscriptionStore.ProProduct) -> String {
        switch pro {
        case .lifetime: return localized("永久會員")
        case .monthly: return localized("月會員")
        }
    }

    private func planDescription(_ pro: SubscriptionStore.ProProduct) -> String {
        switch pro {
        case .lifetime:
            // What lifetime is worth in the other plan's terms: the anchor the monthly
            // price gives it.
            guard let months = lifetimeInMonthsText else { return localized("一次性購買，永久有效") }
            return String(format: localized("一次付清・約 %@ 個月的月費"), months)
        case .monthly: return localized("每月自動續訂，可隨時取消")
        }
    }

    private var lifetimeInMonthsText: String? {
        guard let lifetime = store.product(for: .lifetime)?.price,
              let monthly = store.product(for: .monthly)?.price,
              let months = PaywallPricing.lifetimeInMonths(lifetime: lifetime, monthly: monthly) else { return nil }
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSDecimalNumber(decimal: months))
    }

    private func priceText(for pro: SubscriptionStore.ProProduct, product: Product) -> String {
        if pro == .lifetime {
            return product.displayPrice
        }
        return String(format: localized("%@／月"), product.displayPrice)
    }

    // MARK: - Subscribe

    /// Pinned under the scroll, so the price and the button stay in reach while the reader
    /// reads what they get.
    private var purchaseBar: some View {
        VStack(spacing: DSSpacing.sm) {
            subscribeButton
            Text(purchaseReassurance)
                .font(DSFont.caption)
                .foregroundStyle(DSColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.sm)
        .frame(maxWidth: DSLayout.readableFormWidth)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private var subscribeButton: some View {
        VStack(spacing: DSSpacing.sm) {
            Button {
                guard let product = store.product(for: selectedProduct) else { return }
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
            .accessibilityIdentifier("paywall_purchase_button")

            if let error = store.lastErrorMessage {
                Text(error)
                    .font(DSFont.caption)
                    .foregroundColor(DSColor.destructive)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// The member page's upgrade: the same purchase path as the offer's buy button.
    private func upgradeToLifetime() {
        guard let product = store.product(for: .lifetime) else { return }
        beginPurchase(product)
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
