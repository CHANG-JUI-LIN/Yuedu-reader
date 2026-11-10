import SwiftUI

/// 書籤加入／移除之後跳出來的提示。
///
/// 頂部書籤鈕、觸控區、翻頁模式的下拉三種方式都走 `toggleCurrentPageBookmark()`，
/// 提示就只在那裡發一次，每一種方式得到的回饋都一樣。
struct ReaderBookmarkToast: Equatable, Identifiable {
    let id = UUID()
    let isAdded: Bool

    /// 提示本身的壽命——它就是一段時間，不是在等什麼狀態穩定。
    static let displayDuration: Duration = .milliseconds(1400)

    var titleKey: String { isAdded ? "已加入書籤" : "已移除書籤" }
    var systemImage: String { isAdded ? "bookmark.fill" : "bookmark.slash" }
}

/// 一顆不擋手的膠囊，貼在畫面頂端、動態島正下方。
struct ReaderBookmarkToastView: View {
    let toast: ReaderBookmarkToast
    /// The reader theme's scheme, not the system's: a night page under a light
    /// system appearance still needs the dark material.
    let colorScheme: ColorScheme

    var body: some View {
        Label {
            Text(localized(toast.titleKey))
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: toast.systemImage)
                .foregroundStyle(
                    toast.isAdded ? Color(uiColor: ReaderBookmarkRibbon.color) : Color.secondary
                )
        }
        .font(DSFont.subheadline.weight(.semibold))
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: DSColor.shadow, radius: DSSpacing.sm, y: DSSpacing.xs)
        .environment(\.colorScheme, colorScheme)
        // VoiceOver hears it as an announcement when it appears; a focusable element
        // that vanishes a second later would only strand the cursor.
        .accessibilityHidden(true)
    }
}

/// Narration is waiting on the AI to work out who speaks in the chapter.
struct ReaderTTSPreparationBanner: View {
    let text: String
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            ProgressView()
            Text(text)
                .foregroundStyle(.primary)
        }
        .font(DSFont.subheadline.weight(.semibold))
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: DSColor.shadow, radius: DSSpacing.sm, y: DSSpacing.xs)
        .environment(\.colorScheme, colorScheme)
        // Announced when it appears (`announceTTSPreparation`); not a focus target.
        .accessibilityHidden(true)
    }
}

#Preview("AI 分析中") {
    ReaderTTSPreparationBanner(text: "AI 正在分析本章角色與語氣…", colorScheme: .light)
        .padding()
}

#Preview("已加入") {
    ReaderBookmarkToastView(toast: ReaderBookmarkToast(isAdded: true), colorScheme: .light)
        .padding()
}

#Preview("已移除・夜間") {
    ReaderBookmarkToastView(toast: ReaderBookmarkToast(isAdded: false), colorScheme: .dark)
        .padding()
        .background(Color.black)
}
