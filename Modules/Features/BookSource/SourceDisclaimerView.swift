import SwiftUI

struct SourceDisclaimerView: View {
    var onDismiss: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.xl) {
                    VStack(alignment: .leading, spacing: DSSpacing.sm) {
                        Text(localized("使用來源配置前請確認"))
                            .font(DSFont.title)
                            .foregroundColor(DSColor.textPrimary)

                        Text(localized("source_disclaimer_body_1"))
                            .font(DSFont.body)
                            .foregroundColor(DSColor.textSecondary)
                            .lineSpacing(4)

                        Text(localized("source_disclaimer_body_2"))
                            .font(DSFont.body)
                            .foregroundColor(DSColor.textSecondary)
                            .lineSpacing(4)

                        Text(localized("source_disclaimer_body_3"))
                            .font(DSFont.body)
                            .foregroundColor(DSColor.textSecondary)
                            .lineSpacing(4)

                        Text(localized("source_disclaimer_body_4"))
                            .font(DSFont.body)
                            .foregroundColor(DSColor.textSecondary)
                            .lineSpacing(4)
                    }
                }
                .padding(.horizontal, DSSpacing.xl)
                .padding(.vertical, DSSpacing.xl)
            }
            .background(PageBackgroundView(scope: .settings).ignoresSafeArea())
            .navigationTitle(localized("使用來源配置前請確認"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onDismiss?()
                    } label: {
                        Text(localized("我知道了"))
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }
}
