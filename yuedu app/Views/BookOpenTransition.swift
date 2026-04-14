import SwiftUI

// MARK: - 自訂閱讀器關閉動作（Environment key）
// 讓 ReaderView 內部可觸發開書/關書動畫，而不是直接呼叫 presentationMode.dismiss()

private struct ReaderDismissKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// 設定後，ReaderView 關閉時會播放縮小動畫再清除 state。
    /// 未設定時（如測試/預覽）fallback 至 presentationMode.dismiss()。
    var readerDismiss: (() -> Void)? {
        get { self[ReaderDismissKey.self] }
        set { self[ReaderDismissKey.self] = newValue }
    }
}

// MARK: - 開書 / 關書動畫包裝層

/// 包裝 ReaderView，提供開書放大 + 關書縮小的 spring 動畫。
/// 在 HomeView 以 ZStack overlay 方式使用，取代 fullScreenCover。
struct BookOpenTransition<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var appeared = false

    private let openAnimation  = Animation.spring(response: 0.42, dampingFraction: 0.82)
    private let closeAnimation = Animation.spring(response: 0.30, dampingFraction: 0.90)
    private let closeDuration: TimeInterval = 0.30

    var body: some View {
        content()
            .scaleEffect(appeared ? 1.0 : 0.94)
            .opacity(appeared ? 1.0 : 0)
            .ignoresSafeArea()
            .onAppear {
                withAnimation(openAnimation) { appeared = true }
            }
            .environment(\.readerDismiss, {
                withAnimation(closeAnimation) { appeared = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + closeDuration) {
                    onClose()
                }
            })
    }
}
