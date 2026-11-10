import SwiftUI

/// 自動換源的提示：搜尋中顯示轉圈，失敗時顯示原因一段時間後收起。
///
/// 跟書籤提示同一條頂端帶狀區，不擋手；VoiceOver 在出現時聽到公告，不當焦點。
struct ReaderAutoChangeSourceBanner: View {
    let notice: ReaderViewModel.AutoChangeSourceNotice
    /// The reader theme's scheme, not the system's (see `ReaderBookmarkToastView`).
    let colorScheme: ColorScheme
    let onExpire: () -> Void

    /// How long a failure stays up — the message's own lifetime, not a wait for state.
    static let failureDisplayDuration: Duration = .milliseconds(3200)

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            switch notice {
            case .changing:
                ProgressView()
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DSColor.warning)
                    .accessibilityHidden(true)
            }
            Text(text)
                .foregroundStyle(.primary)
        }
        .font(DSFont.subheadline.weight(.semibold))
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: DSColor.shadow, radius: DSSpacing.sm, y: DSSpacing.xs)
        .environment(\.colorScheme, colorScheme)
        .accessibilityHidden(true)
        .task(id: notice) {
            UIAccessibility.post(notification: .announcement, argument: text)
            guard case .failed = notice else { return }
            do {
                try await Task.sleep(for: Self.failureDisplayDuration)
            } catch {
                // Cancelled: a newer notice replaced this one, or the reader closed.
                return
            }
            onExpire()
        }
    }

    private var text: String {
        switch notice {
        case .changing: localized("正在自動換源…")
        case .failed(_, let message): message
        }
    }
}

#Preview("自動換源中") {
    ReaderAutoChangeSourceBanner(notice: .changing, colorScheme: .light, onExpire: {})
        .padding()
}

#Preview("自動換源失敗・夜間") {
    ReaderAutoChangeSourceBanner(
        notice: .failed(id: UUID(), message: localized("自動換源失敗：沒有可用的來源配置")),
        colorScheme: .dark,
        onExpire: {}
    )
    .padding()
    .background(Color.black)
}
