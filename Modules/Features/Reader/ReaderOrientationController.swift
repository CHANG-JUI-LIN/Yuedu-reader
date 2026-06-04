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

    static func defaultMask(for idiom: UIUserInterfaceIdiom) -> UIInterfaceOrientationMask {
        idiom == .pad ? .all : .portrait
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

    private func apply(mask: UIInterfaceOrientationMask?, in scene: UIWindowScene?) {
        guard let scene else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        let targetMask = mask ?? Self.defaultMask(for: UIDevice.current.userInterfaceIdiom)
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: targetMask)) { error in
            #if DEBUG
            print("[ReaderOrientation] geometry request failed: \(error.localizedDescription)")
            #endif
        }
    }
}
