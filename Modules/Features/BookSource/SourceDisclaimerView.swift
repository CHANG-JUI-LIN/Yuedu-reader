import SwiftUI

/// First-run 注意事項 screen shown before 書源管理 lets the user manage book sources.
///
/// Layout: large title + lead-in line, the four compliance points in a card (each with an
/// accent icon chip), and a full-width 繼續 button pinned to the bottom via
/// `safeAreaInset` — the single way past the screen, per `docs/design.md` onboarding CTA
/// pattern.
struct SourceDisclaimerView: View {
    var onDismiss: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.xl) {
                    Text(localized("使用來源配置前請確認"))
                        .font(DSFont.headline)
                        .foregroundColor(DSColor.textSecondary)

                    disclaimerCard
                }
                .padding(.horizontal, DSSpacing.xl)
                .padding(.top, DSSpacing.lg)
                .padding(.bottom, DSSpacing.xl)
            }
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .navigationTitle(localized("注意事項"))
            .toolbarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    continueButton
                }
                .frame(maxWidth: DSLayout.readableFormWidth)
            }
        }
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            disclaimerRow(icon: "checkmark.seal.fill", text: localized("source_disclaimer_body_1"))
            disclaimerRow(icon: "hand.raised.fill", text: localized("source_disclaimer_body_2"))
            disclaimerRow(icon: "gearshape.fill", text: localized("source_disclaimer_body_3"))
            disclaimerRow(icon: "shield.fill", text: localized("source_disclaimer_body_4"))
        }
        .padding(DSSpacing.lg)
        .interfaceCardSurface()
        .clipShape(RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous))
    }

    /// One compliance point: a decorative icon chip plus the paragraph. The icon is purely
    /// visual (VoiceOver reads the text), so it is hidden from accessibility.
    private func disclaimerRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: DSSpacing.md) {
            Image(systemName: icon)
                .font(DSFont.fixed(size: 14, weight: .semibold))
                .foregroundColor(DSColor.accent)
                .frame(width: 30, height: 30)
                .background(DSColor.accentLight)
                .clipShape(Circle())
                .accessibilityHidden(true)

            Text(text)
                .font(DSFont.body)
                .foregroundColor(DSColor.textPrimary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var continueButton: some View {
        Button {
            onDismiss?()
        } label: {
            Text(localized("繼續"))
                .font(DSFont.headline)
                .foregroundColor(DSColor.textOnAccent)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(DSColor.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DSSpacing.xl)
        .padding(.top, DSSpacing.sm)
        .padding(.bottom, DSSpacing.lg)
    }
}

#Preview("SourceDisclaimerView") {
    SourceDisclaimerView()
}
