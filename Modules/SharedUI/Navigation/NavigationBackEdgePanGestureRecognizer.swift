import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - NavigationBackEdgePanGestureRecognizer

/// `UIPanGestureRecognizer.location(in:)` has already moved by the time its
/// delegate is asked whether it should begin. Recording the first touch here
/// makes the edge start region enforceable without an invisible overlay that
/// would steal taps.
///
/// This must be a `UIScreenEdgePanGestureRecognizer`, not a plain pan: the
/// reader's page-turn surfaces (`UIPageViewController`'s queuing scroll view,
/// the cover-mode custom pan, curl) sit deeper in the hierarchy and win
/// arbitration against an outer plain pan, so a plain pan never begins.
/// UIScrollView has built-in deference to screen-edge recognizers — an
/// edge-started touch waits for this recognizer to fail before scrolling.
@MainActor
final class NavigationBackEdgePanGestureRecognizer: UIScreenEdgePanGestureRecognizer {
    private(set) var initialLocation: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view {
            initialLocation = touch.location(in: view)
        }
        super.touchesBegan(touches, with: event)
    }

    override func reset() {
        super.reset()
        initialLocation = .zero
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    /// Every competing pan — page-turn pans (scroll/cover/curl) and UIKit's
    /// own pop recognizers, which are pan subclasses — must wait for this edge
    /// pan to fail before it may begin. A screen-edge recognizer fails
    /// immediately for touches that start away from the edge, so page turns
    /// and taps outside the reserved edge region see no added latency. Taps are
    /// deliberately not gated: an edge touch that never pans lets this
    /// recognizer fail on release and the tap fires normally.
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if otherGestureRecognizer is UIPanGestureRecognizer { return true }
        return super.shouldBeRequiredToFail(by: otherGestureRecognizer)
    }
}

