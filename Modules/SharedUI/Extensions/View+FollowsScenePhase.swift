import SwiftUI
import UIKit

extension View {
    /// The `scenePhase` of `scene`, for a SwiftUI tree UIKit presents in a hosting controller
    /// it made itself. SwiftUI hands such a host no phase: the reader an Open In book opens
    /// in (`ImportedBookPresentation`) never saw its scene leave or come back (simulator,
    /// iOS 26.5 and 27.1, 2026-11-02), so after one trip out of the app it stopped counting
    /// reading time until it was closed, and never matched a device that turned light or
    /// dark meanwhile. The same reader under a SwiftUI `fullScreenCover` saw every change.
    ///
    /// A bridge, not a second source: the phase is the scene's own, the one SwiftUI derives
    /// for the trees it hosts. Delete it when the Open In reader is presented by SwiftUI, or
    /// once SwiftUI hands hosts the phase itself — remove the call, send the app to the
    /// background with an Open In reader up, and look for the reader's `scenePhase=` line.
    func followsScenePhase(of scene: UIWindowScene) -> some View {
        modifier(FollowsScenePhase(scene: scene))
    }
}

private struct FollowsScenePhase: ViewModifier {
    let scene: UIWindowScene
    /// Starts where the scene is, so the tree sees no change on appearing: a reader presented
    /// while the app is inactive (a system alert up) is not told it came back.
    @State private var phase: ScenePhase

    init(scene: UIWindowScene) {
        self.scene = scene
        _phase = State(initialValue: ScenePhase(scene.activationState))
    }

    func body(content: Content) -> some View {
        content
            .environment(\.scenePhase, phase)
            // The notification, not `activationState`: on `willDeactivate` the state still
            // reads foregroundActive.
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification, object: scene)) { _ in
                phase = .inactive
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification, object: scene)) { _ in
                phase = .background
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.willEnterForegroundNotification, object: scene)) { _ in
                phase = .inactive
            }
            .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification, object: scene)) { _ in
                phase = .active
            }
    }
}

private extension ScenePhase {
    init(_ state: UIScene.ActivationState) {
        switch state {
        case .foregroundActive: self = .active
        case .foregroundInactive: self = .inactive
        case .background, .unattached: self = .background
        @unknown default: self = .background
        }
    }
}
