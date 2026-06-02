import SwiftUI

struct IPadAdaptiveRootTabStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.tabViewStyle(.sidebarAdaptable)
    }
}

extension View {
    func iPadAdaptiveRootTabStyle() -> some View {
        modifier(IPadAdaptiveRootTabStyle())
    }
}
