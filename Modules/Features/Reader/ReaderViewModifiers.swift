import SwiftUI
import UIKit

// MARK: - Scroll Config Observer

struct ScrollConfigObserver: ViewModifier {
    let readerConfig: ReaderConfig
    let readerTheme: ReaderTheme
    let onChanged: () -> Void

    func body(content: Content) -> some View {
        content
            .onChanged(of: readerConfig.fontSize) { _ in onChanged() }
            .onChanged(of: readerConfig.lineHeightMultiple) { _ in onChanged() }
            .onChanged(of: readerConfig.letterSpacing) { _ in onChanged() }
            .onChanged(of: readerConfig.paragraphSpacingMultiplier) { _ in onChanged() }
            .onChanged(of: readerConfig.pageMarginH) { _ in onChanged() }
            .onChanged(of: readerConfig.pageMarginV) { _ in onChanged() }
            .onChanged(of: readerConfig.footerBottomPadding) { _ in onChanged() }
            .onChanged(of: readerConfig.footerTextGap) { _ in onChanged() }
            .onChanged(of: readerConfig.chapterTitleStyle) { _ in onChanged() }
            .onChanged(of: readerConfig.readerFontBold) { _ in onChanged() }
            .onChanged(of: readerTheme) { _ in onChanged() }
    }
}

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
