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
