import SwiftUI

extension View {
    /// Runs a ground — a block of colour, a section's shade, nothing a reader reads or touches —
    /// out under the system's vertical bar: the status bar a folded iPhone Duo stands down one
    /// side, beside its camera. The safe area there is some 84pt wide, and a ground that stopped
    /// at it left a strip of bare page down the screen (FB-207, FB-202).
    ///
    /// Only toward the edge that holds the bar (`toolbarVerticalEdge`, iOS 27.1), and nowhere
    /// else: iPadOS 26's floating sidebar is a side safe area too, and a colour that ran out into
    /// it showed as a strip beside the sidebar (FB-136).
    func groundUnderVerticalBar(isEnabled: Bool = true) -> some View {
        modifier(VerticalBarGround(isEnabled: isEnabled))
    }
}

private struct VerticalBarGround: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(VerticalBarEdgeGround(isEnabled: isEnabled))
        } else {
            content
        }
    }
}

@available(iOS 27.1, *)
private struct VerticalBarEdgeGround: ViewModifier {
    let isEnabled: Bool
    @Environment(\.toolbarVerticalEdge) private var barEdge

    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: isEnabled ? edges : [])
    }

    private var edges: Edge.Set {
        switch barEdge {
        case .leading: .leading
        case .trailing: .trailing
        case nil: []
        }
    }
}
