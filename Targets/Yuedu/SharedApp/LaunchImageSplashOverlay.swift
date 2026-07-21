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

    /// Max time we wait at cold launch for StoreKit / Firestore entitlements to
    /// resolve before giving up on the splash. Defends against the race where
    /// `SubscriptionStore.refreshEntitlements()` (async, kicked off in
    /// `SubscriptionStore.init`) hasn't finished by the time ContentView's
    /// overlay first appears — without this wait, `isProActive` is still false,
    /// `currentImage` returns nil, the splash dismisses, and `hasPlayed` latches
    /// so the user's enabled splash never shows even though they are Pro.
    /// Can be deleted once entitlements load synchronously at app start.
    private let entitlementWaitNanoseconds: UInt64 = 1_500_000_000  // 1.5s

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
            // Wait for the entitlement gate to settle before latching. The
            // body stays empty while `currentImage` is nil, so this wait is
            // invisible to the user when the splash ends up not showing.
            let deadline = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
                + entitlementWaitNanoseconds
            while currentImage == nil, !subscriptionStore.isProActive {
                if Task.isCancelled { return }
                if UInt64(Date().timeIntervalSince1970 * 1_000_000_000) >= deadline {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms tick
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
