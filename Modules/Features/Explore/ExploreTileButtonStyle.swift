import SwiftUI

// MARK: - Press feedback

/// An entry answers the finger the moment it lands: it gives a little under it, or under
/// Reduce Motion dims instead of moving.
struct ExploreTileButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed && reduceMotion ? 0.7 : 1)
            .animation(reduceMotion ? nil : DSAnimation.press, value: configuration.isPressed)
    }
}

#Preview {
    Button {} label: {
        Label(localized("瀏覽器"), systemImage: "safari")
            .padding()
    }
    .buttonStyle(ExploreTileButtonStyle())
}
