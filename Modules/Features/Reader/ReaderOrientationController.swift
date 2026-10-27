import UIKit

@MainActor
final class ReaderOrientationController {
    static let shared = ReaderOrientationController()

    private var overrideMask: UIInterfaceOrientationMask?

    private init() {}

    func supportedMask(for idiom: UIUserInterfaceIdiom) -> UIInterfaceOrientationMask {
        overrideMask ?? Self.defaultMask(for: idiom)
    }

    func request(_ orientation: FixedLayoutOrientation, in scene: UIWindowScene?) {
        let mask = Self.mask(for: orientation)
        overrideMask = mask
        apply(mask: mask, in: scene)
    }

    func restoreDefault(in scene: UIWindowScene?) {
        overrideMask = nil
        apply(mask: nil, in: scene)
    }

    /// Every orientation the device turns to, except upside down on iPhone (no iPhone with a
    /// Dynamic Island supports it, and the app has never declared it for iPhone).
    static func defaultMask(for idiom: UIUserInterfaceIdiom) -> UIInterfaceOrientationMask {
        idiom == .pad ? .all : .allButUpsideDown
    }

    static func mask(for orientation: FixedLayoutOrientation) -> UIInterfaceOrientationMask? {
        switch orientation {
        case .auto:
            return nil
        case .portrait:
            return .portrait
        case .landscape:
            return .landscape
        }
    }

    // TODO: Modernization - A fixed-layout book's 方向 is forced here through the app-wide mask
    // and `requestGeometryUpdate`. On iOS 26+, `prefersInterfaceOrientationLocked` on the reader's
    // view controller (with `setNeedsUpdateOfPrefersInterfaceOrientationLocked()`) is the modern
    // lock, but it keeps the current orientation rather than turning to the book's, so moving to it
    // needs a decision on whether 方向 still rotates the device first.
    private func apply(mask: UIInterfaceOrientationMask?, in scene: UIWindowScene?) {
        guard let scene else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let targetMask = mask ?? Self.defaultMask(for: scene.traitCollection.userInterfaceIdiom)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: targetMask)) { error in
            #if DEBUG
            print("[ReaderOrientation] geometry request failed: \(error.localizedDescription)")
            #endif
        }
    }
}
