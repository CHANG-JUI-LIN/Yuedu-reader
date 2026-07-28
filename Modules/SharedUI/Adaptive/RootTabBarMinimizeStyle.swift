import SwiftUI

/// Collapses the bottom tab bar while the user scrolls down through content,
/// restoring it on scroll up. iPhone-only: the iPad sidebar/floating tab bar
/// (`.sidebarAdaptable`) has no minimized form, so we skip it there.
///
/// `tabBarMinimizeBehavior(_:)` is iOS 26+, so the modifier is a no-op on
/// earlier systems (deployment target is iOS 18.0).
struct RootTabBarMinimizeStyle: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), UIDevice.current.userInterfaceIdiom == .phone {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Auto-collapses the iPhone tab bar on scroll-down (iOS 26+).
    func rootTabBarMinimizeStyle() -> some View {
        modifier(RootTabBarMinimizeStyle())
    }
}
