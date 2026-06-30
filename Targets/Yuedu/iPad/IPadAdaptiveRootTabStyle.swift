import SwiftUI

struct IPadAdaptiveRootTabStyle: ViewModifier {
    func body(content: Content) -> some View {
        // `.sidebarAdaptable` is iOS 18+. On iOS 17 keep the default tab style.
        if #available(iOS 18.0, *) {
            content.tabViewStyle(.sidebarAdaptable)
        } else {
            content
        }
    }
}

extension View {
    func iPadAdaptiveRootTabStyle() -> some View {
        modifier(IPadAdaptiveRootTabStyle())
    }
}
