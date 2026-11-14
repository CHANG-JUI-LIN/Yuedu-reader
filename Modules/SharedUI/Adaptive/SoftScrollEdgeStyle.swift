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

/// No scroll edge effect on any edge — the "None" of `ScrollEdgeEffectStyle`'s
/// documentation: what scrolls under the bars stays sharp, and the bars' region is the
/// page background. Neither built-in style gives that: `.soft` blurs what passes under
/// the bars, and `.hard`, the system's choice from iOS 27, draws a lighter band ending in
/// a line. A no-op before iOS 26, which has no edge effect.
struct HiddenScrollEdges: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Drops the bottom scroll edge effect of a page that hides the root tab bar.
///
/// For one real case (maintainer, 2026-11-14, iOS 27.2 simulator): a tab bar SwiftUI has
/// hidden still counts as a bar at the bottom of the scroll views above it. The hierarchy
/// kept a bottom `ScrollEdgeEffectView` 126pt tall whose only element was the hidden bar's
/// `_UIScrollPocketBarInteraction`, with `isTabBarHidden` true, so the last lines of a page
/// with nothing at its bottom (作品詳情's 目錄) were blurred. Delete this when a hidden
/// tab bar no longer leaves that effect behind. A no-op before iOS 26, which has no edge effect.
struct HiddenBottomScrollEdge: ViewModifier {
    let isHidden: Bool
    /// False for a page with a bar of its own at the bottom. Fixed for a page, so the branch
    /// below never changes and the page keeps its identity.
    let appliesToPage: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), appliesToPage {
            content.scrollEdgeEffectHidden(isHidden, for: .bottom)
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

    /// Removes the scroll edge effect from every edge on iOS 26+ (see `HiddenScrollEdges`).
    func hiddenScrollEdges() -> some View {
        modifier(HiddenScrollEdges())
    }
}
