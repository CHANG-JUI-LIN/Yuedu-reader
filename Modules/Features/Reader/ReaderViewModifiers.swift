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
            .onChanged(of: readerConfig.readerTitleVisible) { _ in onChanged() }
            .onChanged(of: readerConfig.readerTitleSize) { _ in onChanged() }
            .onChanged(of: readerConfig.readerTitleTopSpacing) { _ in onChanged() }
            .onChanged(of: readerConfig.readerTitleBottomSpacing) { _ in onChanged() }
            .onChanged(of: readerTheme) { _ in onChanged() }
    }
}

// MARK: - Hide TabBar

struct HideTabBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar(.hidden, for: .tabBar)
    }
}

// MARK: - onChange helper

extension View {
    func onChanged<V: Equatable>(of value: V, _ action: @escaping (V) -> Void) -> some View {
        self.onChange(of: value) { _, newValue in action(newValue) }
    }
}
