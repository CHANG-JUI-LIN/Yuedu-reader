import SwiftUI
import UIKit

// MARK: - Hide TabBar

struct HideTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar(.hidden, for: .tabBar)
    }
}

// MARK: - Reader interaction isolation

private struct ReaderContentInteractionModifier: ViewModifier {
    let isOverlayEditorActive: Bool

    func body(content: Content) -> some View {
        content.allowsHitTesting(!isOverlayEditorActive)
    }
}

extension View {
    func disablesReaderContentInteraction(
        whileOverlayEditorIsActive isActive: Bool
    ) -> some View {
        modifier(ReaderContentInteractionModifier(isOverlayEditorActive: isActive))
    }
}

// MARK: - onChange helper

extension View {
    func onChanged<V: Equatable>(of value: V, _ action: @escaping (V) -> Void) -> some View {
        self.onChange(of: value) { _, newValue in action(newValue) }
    }

    func onChanged<V: Equatable>(of value: V, _ action: @escaping (V, V) -> Void) -> some View {
        self.onChange(of: value) { oldValue, newValue in
            action(oldValue, newValue)
        }
    }
}

extension View {
    /// Makes a full-bleed loading surface tappable so it can raise the reader chrome.
    /// `ProgressView` and a plain background have no hit area of their own, so a stalled
    /// load used to swallow every touch — leaving refresh, 換源 and back unreachable.
    func readerLoadingChromeTap(_ action: @escaping () -> Void) -> some View {
        contentShape(Rectangle())
            .onTapGesture(perform: action)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(localized("載入中…"))
            .accessibilityHint(localized("顯示閱讀工具列"))
    }
}
