import SwiftUI
import UIKit

extension View {
    /// Reserves the leading edge for native back navigation, including pages
    /// with hidden navigation chrome. Interior pans and taps remain available.
    func reservingNavigationBackSwipe() -> some View {
        background(NavigationBackSwipeReservation().frame(width: 0, height: 0))
    }
}

private struct NavigationBackSwipeReservation: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> NavigationBackSwipeProbeController {
        NavigationBackSwipeProbeController()
    }

    func updateUIViewController(_ controller: NavigationBackSwipeProbeController, context: Context) {
        controller.refreshReservationIfVisible()
    }

    static func dismantleUIViewController(_ controller: NavigationBackSwipeProbeController, coordinator: ()) {
        controller.reservation.detach()
    }
}

/// Uses appearance callbacks rather than delays: SwiftUI has attached the real
/// destination to its navigation controller by viewDidAppear.
final class NavigationBackSwipeProbeController: UIViewController {
    let reservation = NavigationBackSwipeReservationController()
    private var isVisible = false

    override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        refreshReservationIfVisible()
    }

    func refreshReservationIfVisible() {
        guard isVisible else { return }
        guard let navigationController else { return }
        var destination: UIViewController = self
        while let parent = destination.parent, parent !== navigationController {
            destination = parent
        }
        reservation.attach(to: navigationController, destination: destination)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        reservation.detach()
    }
}

/// Owns only the system back recognizer's arbitration while one destination is
/// visible. It never changes the navigation path, delegate, or animator.
/// Unimplemented delegate selectors must not be forwarded to UIKit's original
/// delegate: its hidden-bar event veto runs before our public touch/begin gates.
/// UIKit's recognizer and targets still own native progress and cancellation.
@MainActor
final class NavigationBackSwipeReservationController: NSObject, UIGestureRecognizerDelegate {
    private weak var navigationController: UINavigationController?
    private weak var destination: UIViewController?
    private weak var gesture: UIGestureRecognizer?
    private weak var originalDelegate: UIGestureRecognizerDelegate?
    private var originalEnabled = false
    private weak var alternatePopGesture: UIGestureRecognizer?
    private var originalAlternatePopEnabled = false
    private var initialX: CGFloat = 0

    /// iOS 26 exposes the native content-pop recognizer publicly. Constraining
    /// its first touch gives this page a real 30 pt reservation, rather than the
    /// system edge recognizer's narrower, OS-controlled recognition region.
    /// Earlier systems retain native screen-edge back navigation.
    static func backGesture(in navigationController: UINavigationController) -> UIGestureRecognizer? {
        if #available(iOS 26.0, *), let content = navigationController.interactiveContentPopGestureRecognizer {
            return content
        }
        return navigationController.interactivePopGestureRecognizer
    }

    func attach(to navigationController: UINavigationController, destination: UIViewController) {
        guard navigationController.topViewController === destination,
              navigationController.viewControllers.count > 1,
              let gesture = Self.backGesture(in: navigationController) else { return }
        if self.gesture === gesture, gesture.delegate === self {
            // SwiftUI can reapply hidden chrome while the same page stays visible.
            gesture.isEnabled = true
            alternatePopGesture?.isEnabled = false
            return
        }
        detach()
        // Adjacent destinations can finish appearance callbacks in either order.
        // Unwind the previous reservation before capturing UIKit's real delegate.
        (gesture.delegate as? NavigationBackSwipeReservationController)?.detach()
        self.navigationController = navigationController
        self.destination = destination
        self.gesture = gesture
        originalDelegate = gesture.delegate
        originalEnabled = gesture.isEnabled
        if gesture !== navigationController.interactivePopGestureRecognizer {
            // The content recognizer supplies native interactive navigation over
            // the full reserved width; UIKit's physical-edge recognizer accepted
            // a 1 pt start but rejected 8/28 pt starts on iOS 27. Suspend that
            // alternate recognizer while this destination owns back navigation.
            alternatePopGesture = navigationController.interactivePopGestureRecognizer
            originalAlternatePopEnabled = alternatePopGesture?.isEnabled ?? false
            alternatePopGesture?.isEnabled = false
        }
        gesture.delegate = self
        gesture.isEnabled = true
    }

    func detach() {
        // A newer visible destination may already have taken ownership.
        if let gesture, gesture.delegate === self {
            gesture.delegate = originalDelegate
            alternatePopGesture?.isEnabled = originalAlternatePopEnabled
            // A different destination has already applied its own chrome state.
            // Do not overwrite its enabled flag with this page's hidden-bar state.
            if navigationController?.topViewController === destination {
                gesture.isEnabled = originalEnabled
            }
        }
        navigationController = nil
        destination = nil
        gesture = nil
        originalDelegate = nil
        alternatePopGesture = nil
        originalAlternatePopEnabled = false
        initialX = 0
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        initialX = touch.location(in: gestureRecognizer.view).x
        return NavigationBackSwipePolicy.contains(
            initialX: initialX, containerWidth: gestureRecognizer.view?.bounds.width ?? 0
        )
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let navigationController,
              navigationController.topViewController === destination,
              navigationController.viewControllers.count > 1,
              navigationController.transitionCoordinator == nil else { return false }
        let translation = (gestureRecognizer as? UIPanGestureRecognizer)?.translation(in: gestureRecognizer.view) ?? .zero
        return NavigationBackSwipePolicy.shouldBegin(
            initialX: initialX, translation: translation,
            containerWidth: gestureRecognizer.view?.bounds.width ?? 0
        )
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        // Dynamic arbitration also covers page/scroll pans installed later.
        // Do not gate taps: an edge touch without a pan remains a normal tap.
        other is UIPanGestureRecognizer
    }
}

#Preview {
    NavigationStack {
        Text(localized("閱讀"))
            .reservingNavigationBackSwipe()
    }
}
