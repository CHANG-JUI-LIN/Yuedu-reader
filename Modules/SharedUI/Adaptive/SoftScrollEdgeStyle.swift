import SwiftUI

/// iOS 26's soft scroll-edge fade (`.scrollEdgeEffectStyle(.soft, for: .all)`).
/// Earlier systems have no scroll edge effect at all, so this is a no-op there.
///
/// The `#if compiler` guard is there because the iOS 26 API only
/// exists in the Xcode 26 SDK, and the project still has to compile on older toolchains.
struct SoftScrollEdgeStyle: ViewModifier {
    /// Drops the top edge effect, for a page whose artwork is meant to show under the
    /// navigation bar (a book detail's cover wash, as Apple Books shows it).
    var hidesTopEdge = false

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .all)
                .scrollEdgeEffectHidden(hidesTopEdge, for: .top)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

extension View {
    /// Gives vertical scroll views an explicit soft top/bottom edge on iOS 26+.
    func softScrollEdges(hidingTop hidesTopEdge: Bool = false) -> some View {
        modifier(SoftScrollEdgeStyle(hidesTopEdge: hidesTopEdge))
    }
}
