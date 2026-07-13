import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - ReaderLeadingEdgePanGestureRecognizer

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
private final class ReaderLeadingEdgePanGestureRecognizer: UIScreenEdgePanGestureRecognizer {
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
    /// and taps outside the 10-point strip see no added latency. Taps are
    /// deliberately not gated: an edge touch that never pans lets this
    /// recognizer fail on release and the tap fires normally.
    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if otherGestureRecognizer is UIPanGestureRecognizer { return true }
        return super.shouldBeRequiredToFail(by: otherGestureRecognizer)
    }
}

// MARK: - ReaderNavigationTransitionDriver

/// Owns the UIKit half of reader navigation: the custom push/pop animator,
/// the percent-driven interaction controller, and the leading-edge pan. It
/// attaches to the outer shelf navigation controller before a reader push and
/// forwards unrelated delegate calls to SwiftUI's original delegate.
@MainActor
final class ReaderNavigationTransitionDriver: NSObject {
    enum PendingOperation {
        case push
        case pop
    }

    weak var navigationController: UINavigationController?
    private weak var forwardedDelegate: UINavigationControllerDelegate?
    private var edgePan: ReaderLeadingEdgePanGestureRecognizer?
    private var interactionController: UIPercentDrivenInteractiveTransition?
    private var pendingOperation: PendingOperation?
    private var activeAnimator: ReaderCardTransitionAnimator?
    private weak var expectedFromViewController: UIViewController?
    private weak var expectedToViewController: UIViewController?
    private var observesTransitionInvalidation = false
    private var interactionIsSettling = false
    private var navigationSettleNotificationScheduled = false
    private(set) var isInteractivePopInFlight = false

    var sourceProvider: () -> ReaderTransitionSource? = { nil }
    var readerIsPresented: () -> Bool = { false }
    var onInteractivePopCompleted: () -> Void = {}
    var onPopTransitionCompleted: (Bool) -> Void = { _ in }
    var onPushTransitionCompleted: (Bool) -> Void = { _ in }
    var onNavigationTransitionSettled: () -> Void = {}

    func attach(to navigationController: UINavigationController) {
        if self.navigationController === navigationController {
            installEdgePanIfNeeded(on: navigationController)
            return
        }
        if self.navigationController != nil {
            detach()
        }

        self.navigationController = navigationController
        claimNavigationDelegate()
        installEdgePanIfNeeded(on: navigationController)
        installTransitionInvalidationObserversIfNeeded()
    }

    func detach() {
        if isInteractivePopInFlight, !interactionIsSettling {
            interactionIsSettling = true
            interactionController?.cancel()
        }
        if observesTransitionInvalidation {
            NotificationCenter.default.removeObserver(self)
            observesTransitionInvalidation = false
        }
        if let navigationController, let edgePan {
            navigationController.view.removeGestureRecognizer(edgePan)
        }
        if let navigationController, navigationController.delegate === self {
            navigationController.delegate = forwardedDelegate
        }
        navigationController = nil
        forwardedDelegate = nil
        edgePan = nil
        interactionController = nil
        pendingOperation = nil
        activeAnimator = nil
        expectedFromViewController = nil
        expectedToViewController = nil
        interactionIsSettling = false
        navigationSettleNotificationScheduled = false
        isInteractivePopInFlight = false
    }

    /// Atomically claims the navigation delegate, records the exact
    /// controllers expected by the animator, and only then mutates the UIKit
    /// stack. Keeping all three operations in one main-actor method prevents
    /// SwiftUI from beginning the push before this driver can own it.
    @discardableResult
    func startPush(
        _ viewController: UIViewController,
        animated: Bool = true
    ) -> Bool {
        guard
            let navigationController,
            canStartNavigationTransition,
            navigationController.topViewController !== viewController
        else {
            return false
        }

        claimNavigationDelegate()
        expectedFromViewController = navigationController.topViewController
        expectedToViewController = viewController
        pendingOperation = .push
        navigationController.pushViewController(viewController, animated: animated)
        return true
    }

    /// Starts a programmatic pop under the same delegate ownership as the
    /// interactive edge pop. The coordinator retains its reader id and source
    /// until `onPopTransitionCompleted(true)` confirms that UIKit committed it.
    @discardableResult
    func startProgrammaticPop(animated: Bool = true) -> Bool {
        guard
            let navigationController,
            navigationController.viewControllers.count > 1,
            canStartNavigationTransition
        else {
            return false
        }

        claimNavigationDelegate()
        expectedFromViewController = navigationController.topViewController
        expectedToViewController = navigationController.viewControllers.dropLast().last
        pendingOperation = .pop

        guard navigationController.popViewController(animated: animated) != nil else {
            finishTransition(operation: .pop, completed: false)
            return false
        }
        return true
    }

    private func installEdgePanIfNeeded(on navigationController: UINavigationController) {
        guard edgePan == nil else { return }
        let pan = ReaderLeadingEdgePanGestureRecognizer(
            target: self,
            action: #selector(handleEdgePan(_:))
        )
        // The shipped localizations are all left-to-right, and
        // ReaderCardTransitionMath models the start strip at x == 0. Keep the
        // edge fixed to .left so the recognizer and the math agree; both need
        // mirroring together if an RTL localization is ever added.
        pan.edges = .left
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = true
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        navigationController.view.addGestureRecognizer(pan)
        edgePan = pan
        AppLogger.info("⟐ reader-nav edge pan installed")
    }

    private func installTransitionInvalidationObserversIfNeeded() {
        guard !observesTransitionInvalidation else { return }
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(handleTransitionInvalidation(_:)),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(handleTransitionInvalidation(_:)),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
        observesTransitionInvalidation = true
    }

    @objc private func handleTransitionInvalidation(_ notification: Notification) {
        cancelInteractionForEnvironmentChange()
    }

    private func cancelInteractionForEnvironmentChange() {
        guard isInteractivePopInFlight, !interactionIsSettling else { return }
        interactionIsSettling = true
        interactionController?.cancel()
    }

    @objc private func handleEdgePan(_ gesture: ReaderLeadingEdgePanGestureRecognizer) {
        guard let navigationController else { return }
        let translation = gesture.translation(in: navigationController.view)
        let popProgress = ReaderCardTransitionMath.popProgress(
            translationX: translation.x,
            containerWidth: navigationController.view.bounds.width
        )

        switch gesture.state {
        case .began:
            claimNavigationDelegate()
            let interaction = UIPercentDrivenInteractiveTransition()
            interaction.completionCurve = .easeOut
            interaction.completionSpeed = ReaderCardTransitionMath.maximumCompletionSpeed
            interactionController = interaction
            pendingOperation = .pop
            expectedFromViewController = navigationController.topViewController
            expectedToViewController = navigationController.viewControllers.dropLast().last
            isInteractivePopInFlight = true
            interactionIsSettling = false

            guard navigationController.popViewController(animated: true) != nil else {
                AppLogger.info("⟐ reader-nav edge pop rejected: popViewController returned nil")
                interactionController = nil
                pendingOperation = nil
                expectedFromViewController = nil
                expectedToViewController = nil
                isInteractivePopInFlight = false
                interactionIsSettling = false
                return
            }
            AppLogger.info("⟐ reader-nav interactive pop began")

        case .changed:
            guard !interactionIsSettling else { return }
            interactionController?.update(popProgress)
            activeAnimator?.renderCurrentProgress()

        case .ended:
            guard !interactionIsSettling else { return }
            guard let interaction = interactionController else { return }
            interaction.update(popProgress)
            activeAnimator?.renderCurrentProgress()
            interactionIsSettling = true
            let velocity = gesture.velocity(in: navigationController.view).x
            if ReaderCardTransitionMath.shouldFinishClose(
                closeProgress: popProgress,
                velocity: velocity
            ) {
                interaction.completionSpeed = ReaderCardTransitionMath.maximumCompletionSpeed
                interaction.finish()
            } else {
                let reduceMotion = UIAccessibility.isReduceMotionEnabled
                let transitionDuration = reduceMotion
                    ? DSAnimation.readerBookReducedMotionDuration
                    : DSAnimation.readerBookTransitionDuration
                let minimumSettleDuration = reduceMotion
                    ? DSAnimation.readerBookReducedMotionDuration
                    : DSAnimation.readerBookCancellationSettleDuration
                interaction.pause()
                let animatorOwnsSettle = activeAnimator?.settleInteractiveCancellation(
                    duration: minimumSettleDuration
                ) { [weak self, weak interaction] in
                    guard
                        let self,
                        let interaction,
                        self.interactionController === interaction,
                        self.interactionIsSettling
                    else { return }
                    interaction.completionSpeed =
                        ReaderCardTransitionMath.cancellationFinalizationSpeed
                    interaction.cancel()
                } ?? false

                if !animatorOwnsSettle {
                    interaction.completionSpeed =
                        ReaderCardTransitionMath.cancellationCompletionSpeed(
                            closeProgress: popProgress,
                            transitionDuration: transitionDuration,
                            minimumSettleDuration: minimumSettleDuration
                        )
                    interaction.cancel()
                }
            }

        case .cancelled, .failed:
            cancelInteractionForEnvironmentChange()

        default:
            break
        }
    }

    private func finishTransition(operation: PendingOperation, completed: Bool) {
        let wasInteractive = isInteractivePopInFlight
        interactionController = nil
        activeAnimator = nil
        pendingOperation = nil
        expectedFromViewController = nil
        expectedToViewController = nil
        isInteractivePopInFlight = false
        interactionIsSettling = false

        switch operation {
        case .push:
            onPushTransitionCompleted(completed)
        case .pop:
            if wasInteractive {
                if completed {
                    onInteractivePopCompleted()
                }
            } else {
                onPopTransitionCompleted(completed)
            }
        }
        scheduleNavigationSettledNotification()
    }

    private func scheduleNavigationSettledNotification() {
        guard !navigationSettleNotificationScheduled else { return }
        navigationSettleNotificationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.navigationSettleNotificationScheduled = false
            guard
                self.navigationController != nil,
                self.pendingOperation == nil,
                self.activeAnimator == nil
            else { return }
            self.onNavigationTransitionSettled()
        }
    }

    /// A safety net for a UIKit transaction that changes the stack without
    /// asking this delegate for an animator or delivering `didShow`.
    func reconcilePendingPushAsCompleted() {
        guard pendingOperation == .push, activeAnimator == nil else { return }
        let completed: Bool
        if let expectedToViewController {
            completed = navigationController?.topViewController === expectedToViewController
        } else if let expectedFromViewController {
            completed = navigationController?.topViewController !== expectedFromViewController
        } else {
            completed = readerIsPresented()
        }
        finishTransition(operation: .push, completed: completed)
    }

    /// Symmetric fallback for a UIKit pop that does not request our custom
    /// animator or call the delegate completion path we normally own.
    func reconcilePendingPop() {
        guard pendingOperation == .pop, activeAnimator == nil else { return }
        let completed: Bool
        if let expectedToViewController {
            completed = navigationController?.topViewController === expectedToViewController
        } else if let expectedFromViewController {
            completed = navigationController?.topViewController !== expectedFromViewController
        } else {
            completed = !readerIsPresented()
        }
        finishTransition(operation: .pop, completed: completed)
    }

    var isPushTransitionInFlight: Bool {
        pendingOperation == .push
    }

    var canStartNavigationTransition: Bool {
        guard let navigationController else { return false }
        return pendingOperation == nil
            && activeAnimator == nil
            && navigationController.transitionCoordinator == nil
    }

    /// A reader edge-pop can only start from a settled navigation stack. In
    /// particular, `readerIsPresented` becomes true before the opening push
    /// finishes, so that flag alone is not a safe interaction gate.
    var isReadyForInteractivePop: Bool {
        canStartNavigationTransition
    }

    private func claimNavigationDelegate() {
        guard let navigationController, navigationController.delegate !== self else { return }
        forwardedDelegate = navigationController.delegate
        navigationController.delegate = self
    }

}

// MARK: - UINavigationControllerDelegate

extension ReaderNavigationTransitionDriver: UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController,
        animationControllerFor operation: UINavigationController.Operation,
        from fromVC: UIViewController,
        to toVC: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        let expectedOperation: PendingOperation
        let animatorOperation: ReaderCardTransitionAnimator.Operation
        switch operation {
        case .push:
            expectedOperation = .push
            animatorOperation = .push
        case .pop:
            expectedOperation = .pop
            animatorOperation = .pop
        default:
            return forwardedDelegate?.navigationController?(
                navigationController,
                animationControllerFor: operation,
                from: fromVC,
                to: toVC
            )
        }

        if pendingOperation == expectedOperation {
            expectedFromViewController = fromVC
            expectedToViewController = toVC
        }

        guard pendingOperation == expectedOperation, let source = sourceProvider() else {
            // Only a prepared reader transition that falls through is worth a
            // diagnostic; unrelated pushes in the same stack pass here all the
            // time by design.
            if pendingOperation == expectedOperation {
                AppLogger.info(
                    "⟐ reader-nav animator skipped: no source",
                    context: ["operation": operation == .push ? "push" : "pop"]
                )
            }
            return forwardedDelegate?.navigationController?(
                navigationController,
                animationControllerFor: operation,
                from: fromVC,
                to: toVC
            )
        }

        let animator = ReaderCardTransitionAnimator(
            operation: animatorOperation,
            source: source
        ) { [weak self] completed in
            self?.finishTransition(operation: expectedOperation, completed: completed)
        }
        activeAnimator = animator
        return animator
    }

    func navigationController(
        _ navigationController: UINavigationController,
        interactionControllerFor animationController: UIViewControllerAnimatedTransitioning
    ) -> UIViewControllerInteractiveTransitioning? {
        if animationController === activeAnimator {
            return interactionController
        }
        return forwardedDelegate?.navigationController?(
            navigationController,
            interactionControllerFor: animationController
        )
    }

    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool
    ) {
        forwardedDelegate?.navigationController?(
            navigationController,
            willShow: viewController,
            animated: animated
        )
    }

    func navigationController(
        _ navigationController: UINavigationController,
        didShow viewController: UIViewController,
        animated: Bool
    ) {
        forwardedDelegate?.navigationController?(
            navigationController,
            didShow: viewController,
            animated: animated
        )

        // If UIKit used a non-custom transaction, no animator completion will
        // clear our pending state. `didShow` is authoritative for that fallback
        // path. Custom transitions keep `activeAnimator` non-nil until after
        // `completeTransition`, so they do not double-fire.
        guard let pendingOperation, activeAnimator == nil else {
            scheduleNavigationSettledNotification()
            return
        }
        let completed: Bool
        if let expectedToViewController {
            completed = viewController === expectedToViewController
        } else if let expectedFromViewController {
            completed = viewController !== expectedFromViewController
        } else {
            completed = pendingOperation == .push
                ? readerIsPresented()
                : !readerIsPresented()
        }
        finishTransition(operation: pendingOperation, completed: completed)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension ReaderNavigationTransitionDriver: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard
            let navigationController,
            let pan = gestureRecognizer as? ReaderLeadingEdgePanGestureRecognizer
        else { return false }

        // Fires once per attempted swipe, so each denial names its gate in the
        // device log instead of failing silently.
        if let denial = interactivePopDenialReason(in: navigationController) {
            AppLogger.info("⟐ reader-nav edge swipe rejected: \(denial)")
            return false
        }

        let translation = pan.translation(in: navigationController.view)
        let allowed = ReaderCardTransitionMath.shouldBeginEdgeSwipe(
            initialX: pan.initialLocation.x,
            translationX: translation.x,
            translationY: translation.y,
            containerWidth: navigationController.view.bounds.width
        )
        if !allowed {
            AppLogger.info(
                "⟐ reader-nav edge swipe rejected: start gate",
                context: [
                    "initialX": Int(pan.initialLocation.x),
                    "dx": Int(translation.x),
                    "dy": Int(translation.y)
                ]
            )
        }
        return allowed
    }

    private func interactivePopDenialReason(
        in navigationController: UINavigationController
    ) -> String? {
        if navigationController.viewControllers.count <= 1 {
            return "stack depth \(navigationController.viewControllers.count)"
        }
        if !readerIsPresented() {
            return "reader not presented via coordinator"
        }
        if isInteractivePopInFlight {
            return "pop already in flight"
        }
        if !isReadyForInteractivePop {
            return "transition busy (pending=\(String(describing: pendingOperation)), "
                + "animator=\(activeAnimator != nil), "
                + "coordinatorBusy=\(navigationController.transitionCoordinator != nil))"
        }
        return nil
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        false
    }
}
