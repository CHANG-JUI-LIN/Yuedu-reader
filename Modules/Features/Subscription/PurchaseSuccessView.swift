import SwiftUI

/// Shown inside the paywall sheet once a Pro entitlement becomes active —
/// after a purchase, an offer-code redemption, or a successful restore.
/// Wording is "unlocked" rather than "purchased" so all three paths stay
/// accurate. The user leaves via the explicit "開始閱讀" button.
struct PurchaseSuccessView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var appeared = false

    var body: some View {
        ScrollView {
            VStack(spacing: DSSpacing.xl) {
                successHeader
                featureList
                continueButton
            }
            .padding(DSSpacing.lg)
            .frame(maxWidth: DSLayout.readableFormWidth)
            .frame(maxWidth: .infinity)
        }
        .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
        .pageBackgroundToolbar(for: .settings)
        .navigationBarBackButtonHidden(true)
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                appeared = true
            }
        }
    }

    // MARK: - Header

    private var successHeader: some View {
        VStack(spacing: DSSpacing.sm) {
            Image(systemName: "crown.fill")
                .font(DSFont.fixed(size: 56))
                .foregroundStyle(DSColor.accent)
                .scaleEffect(appeared ? 1 : 0.4)
                .opacity(appeared ? 1 : 0)
                .accessibilityHidden(true)
            Text(localized("已解鎖 閱讀Pro"))
                .font(DSFont.largeTitle.weight(.bold))
            Text(localized("感謝你的支持，所有 Pro 功能現在都已啟用"))
                .font(DSFont.subheadline)
                .foregroundColor(DSColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, DSSpacing.lg)
    }

    // MARK: - Feature list

    private var featureList: some View {
        VStack(spacing: DSSpacing.md) {
            ForEach(PremiumFeature.marketedFeatures()) { feature in
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
                }
            }
        }
        .padding(DSSpacing.lg)
        .interfaceCardSurface()
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg))
    }

    // MARK: - Continue

    private var continueButton: some View {
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
}

#Preview {
    NavigationStack {
        PurchaseSuccessView()
    }
}
