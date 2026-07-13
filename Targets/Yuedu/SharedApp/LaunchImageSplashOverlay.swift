import SwiftUI

/// Cold-launch splash overlay. iOS's real LaunchScreen can't be swapped at
/// runtime, so this paints the user's chosen image over the app root for a
/// moment on the first appearance, then fades out. Presents only when the
/// feature is enabled, Pro is active, and a matching image exists.
struct LaunchImageSplashOverlay: View {
    @ObservedObject private var settings = GlobalSettings.shared
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var visible = true

    /// Latches after the first appearance so returning from the background or a
    /// theme change never replays the splash.
    private static var hasPlayed = false

    private let holdDuration: UInt64 = 1_300_000_000  // 1.3s before fading
    private let fadeDuration = 0.45

    var body: some View {
        ZStack {
            if visible, let image = currentImage {
                splash(image)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: fadeDuration), value: visible)
        .task {
            guard !Self.hasPlayed else {
                visible = false
                return
            }
            Self.hasPlayed = true
            guard currentImage != nil else {
                visible = false
                return
            }
            try? await Task.sleep(nanoseconds: holdDuration)
            visible = false
        }
    }

    private func splash(_ image: UIImage) -> some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .background(colorScheme == .dark ? Color.black : Color.white)
        }
        .ignoresSafeArea()
    }

    private var currentImage: UIImage? {
        guard settings.launchImageEnabled,
              subscriptionStore.hasAccess(.launchScreen),
              let url = settings.launchImageURL(for: colorScheme),
              let image = UIImage(contentsOfFile: url.path) else {
            return nil
        }
        return image
    }
}

#Preview {
    LaunchImageSplashOverlay()
        .environmentObject(SubscriptionStore.shared)
}
