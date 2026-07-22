import UIKit
import SwiftUI

// MARK: - ReaderCardTransitionAnimator

/// A reversible navigation animator that grows a bookshelf cover into the
/// reader while physically unfolding the front cover around the correct
/// spine. UIKit's interaction controller scrubs the same property animator
/// during an edge-pop, so opening, cancelling, and closing share one visual
/// model rather than approximating each other with separate animations.
@MainActor
final class ReaderCardTransitionAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    enum Operation {
        case push
        case pop
    }

    private let operation: Operation
    private let source: ReaderTransitionSource
    private let completion: (Bool) -> Void
    private var propertyAnimator: UIViewPropertyAnimator?
    private weak var activeTransitionContext: UIViewControllerContextTransitioning?
    private var displayLink: CADisplayLink?
    private var runtimeState: RuntimeState?
    private var cancellationSettle: CancellationSettle?
    private var cancellationSettleCompletion: (() -> Void)?
    private var isHoldingOpenAfterCancellationSettle = false
    private var completionDelivered = false
    private var isCompletingTransition = false
    /// Cached shadow-path dimensions so we avoid rebuilding the CGPath every
    /// display-link frame. Only the shadow view size or corner radius changes
    /// trigger a new path.
    private var cachedShadowSize: CGSize = .zero
    private var cachedShadowRadius: CGFloat = 0
    private var cachedShadowPath: CGPath?

    /// Keyframe samples for the non-interactive declarative path
    /// (`runDeclarativeAnimation`). ~60 samples across the 0.62s transition is
    /// dense enough that linear interpolation between the sampled phased-model
    /// values is visually indistinguishable from the per-frame scrub path.
    private static let declarativeKeyframeCount = 60

    init(
        operation: Operation,
        source: ReaderTransitionSource,
        completion: @escaping (Bool) -> Void
    ) {
        self.operation = operation
        self.source = source
        self.completion = completion
        super.init()
    }

    func transitionDuration(
        using transitionContext: UIViewControllerContextTransitioning?
    ) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled
            ? DSAnimation.readerBookReducedMotionDuration
            : DSAnimation.readerBookTransitionDuration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        let animator = interruptibleAnimator(using: transitionContext)
        animator.startAnimation()
    }

    func interruptibleAnimator(
        using transitionContext: UIViewControllerContextTransitioning
    ) -> UIViewImplicitlyAnimating {
        if let propertyAnimator { return propertyAnimator }

        activeTransitionContext = transitionContext
        let container = transitionContext.containerView
        guard
            let fromView = transitionContext.view(forKey: .from),
            let toView = transitionContext.view(forKey: .to),
            let fromController = transitionContext.viewController(forKey: .from),
            let toController = transitionContext.viewController(forKey: .to)
        else {
            let animator = UIViewPropertyAnimator(duration: 0, curve: .linear)
            animator.addCompletion { [weak self] _ in
                guard let self else { return }
                self.isCompletingTransition = true
                transitionContext.completeTransition(false)
                self.isCompletingTransition = false
                self.propertyAnimator = nil
                self.activeTransitionContext = nil
                self.deliverCompletion(false)
            }
            propertyAnimator = animator
            return animator
        }

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let fullFrame = resolvedFullFrame(
            container: container,
            transitionContext: transitionContext,
            fromController: fromController,
            toController: toController
        )

        switch operation {
        case .push:
            toView.frame = fullFrame
            container.addSubview(toView)
            toView.layoutIfNeeded()
        case .pop:
            toView.frame = transitionContext.finalFrame(for: toController)
            if toView.frame.isEmpty { toView.frame = container.bounds }
            container.insertSubview(toView, belowSubview: fromView)
            toView.layoutIfNeeded()
        }

        // On pop, the shelf destination must be inserted and laid out before
        // resolving its live cover frame; recently-read sorting and rotation
        // may have moved the card while the reader was open.
        container.layoutIfNeeded()
        let closedFrame = resolvedClosedFrame(in: container, fullFrame: fullFrame)

        // The live reader view is the transition's paper. No snapshots: a
        // freshly pushed reader has not rendered yet, so a snapshot would be
        // blank paper with content popping in at the end, and pop would look
        // nothing like push. Scaling the real view keeps live content growing
        // with the card in both directions.
        let liveReaderView = operation == .push ? toView : fromView

        let backdrop = UIView(frame: container.bounds)
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backdrop.backgroundColor = UIColor(DSColor.background)

        let stage = makeBookStage(
            initialFrame: operation == .push ? closedFrame : fullFrame
        )

        // Bottom to top: shelf view, backdrop, drop shadow, live reader
        // (transform-scaled between card and full screen), and the un-clipped
        // cover assembly sweeping above everything.
        container.insertSubview(backdrop, belowSubview: liveReaderView)
        container.insertSubview(stage.shadowView, belowSubview: liveReaderView)
        container.addSubview(stage.coverContainer)

        let closedGeometry = ReaderCardGeometry(
            frame: closedFrame,
            cornerRadius: source.cornerRadius
        )
        let openGeometry = ReaderCardGeometry(frame: fullFrame, cornerRadius: 0)

        let startProgress: CGFloat = operation == .push ? 0 : 1
        let endProgress: CGFloat = operation == .push ? 1 : 0

        apply(
            progress: startProgress,
            reduceMotion: reduceMotion,
            stage: stage,
            backdrop: backdrop,
            liveReaderView: operation == .push ? toView : fromView,
            sourceGeometry: closedGeometry,
            destinationGeometry: openGeometry
        )

        let progressProbe = UIView(frame: .zero)
        progressProbe.alpha = 0
        progressProbe.isUserInteractionEnabled = false
        progressProbe.accessibilityElementsHidden = true
        container.addSubview(progressProbe)

        runtimeState = RuntimeState(
            stage: stage,
            backdrop: backdrop,
            progressProbe: progressProbe,
            liveReaderView: operation == .push ? toView : fromView,
            fromView: fromView,
            toView: toView,
            sourceGeometry: closedGeometry,
            destinationGeometry: openGeometry,
            reduceMotion: reduceMotion,
            startProgress: startProgress,
            endProgress: endProgress,
            isInteractive: transitionContext.isInteractive
        )

        // Animate only an invisible probe. A display link reads the property's
        // fractionComplete and re-evaluates the full phased visual model every
        // frame. This is what makes the phased cover unfold and page reveal
        // real at runtime, including while UIKit scrubs an edge pop.
        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: transitionContext),
            curve: .linear
        )
        animator.addAnimations { [weak progressProbe] in
            progressProbe?.alpha = 1
        }
        animator.addCompletion { [weak self] position in
            guard let self else { return }
            let completed = position == .end && !transitionContext.transitionWasCancelled

            if let state = self.runtimeState {
                self.applyRuntimeState(
                    progress: completed ? state.endProgress : state.startProgress,
                    state: state
                )
            }
            self.cleanupTemporaryViews(transitionCompleted: completed)

            self.isCompletingTransition = true
            transitionContext.completeTransition(completed)
            self.isCompletingTransition = false
            self.propertyAnimator = nil
            self.activeTransitionContext = nil
            self.deliverCompletion(completed)
        }
        propertyAnimator = animator
        if transitionContext.isInteractive {
            // Interactive edge-pop scrubs with the finger: keep the per-frame
            // CADisplayLink model so drag position maps 1:1 to the visuals.
            startDisplayLink()
        } else if let state = runtimeState {
            // Non-interactive push / programmatic pop: run the phased model
            // declaratively on the render server (see runDeclarativeAnimation)
            // so a momentarily busy main thread can't drop transition frames.
            runDeclarativeAnimation(
                state: state,
                duration: transitionDuration(using: transitionContext)
            )
        } else {
            startDisplayLink()
        }
        return animator
    }

    func animationEnded(_ transitionCompleted: Bool) {
        cleanupTemporaryViews(transitionCompleted: transitionCompleted)
        propertyAnimator = nil
        activeTransitionContext = nil
        if !isCompletingTransition {
            deliverCompletion(transitionCompleted)
        }
    }

    /// Timeline position of the in-flight transition, if one exists. The
    /// driver's watchdog samples this to distinguish a slow-but-advancing
    /// transition from one UIKit has stopped driving.
    var currentFractionComplete: CGFloat? {
        propertyAnimator?.fractionComplete
    }

    /// Watchdog-only last resort for a transition UIKit began but stopped
    /// driving (observed when a push lands while SwiftUI's `NavigationStack`
    /// is still settling from a previous interactive pop: the animator is
    /// created, then neither the property-animator completion nor `didShow`
    /// ever arrives). Completes the abandoned context ourselves so UIKit
    /// tears the transition down: `completed == false` rolls the push back,
    /// which runs the reader's `viewWillDisappear` and restores the shelf's
    /// navigation/tab bars. Never called on a healthy transition — the driver
    /// only invokes it after the grace window with a frozen timeline.
    func forceSettleStalledTransition(completed: Bool) {
        guard !completionDelivered else { return }
        // A context that already recorded a cancellation (percent-driven
        // `cancel()` ran before the stall) must settle as cancelled: the user
        // chose to keep the from-controller, and UIKit's bookkeeping already
        // committed that decision even though the stack no longer shows it.
        let resolvedCompleted: Bool
        if let context = activeTransitionContext, context.transitionWasCancelled {
            resolvedCompleted = false
        } else {
            resolvedCompleted = completed
        }
        AppLogger.info("⟐ reader-nav forceSettle stalled transition completed=\(resolvedCompleted) animatorState=\(propertyAnimator.map { String(describing: $0.state.rawValue) } ?? "nil") fraction=\(propertyAnimator.map { String(format: "%.2f", $0.fractionComplete) } ?? "-") hasContext=\(activeTransitionContext != nil)")

        // Silence the original completion first so a late CA callback cannot
        // complete the same context a second time.
        if let propertyAnimator, propertyAnimator.state == .active {
            propertyAnimator.stopAnimation(true)
        }

        if let state = runtimeState {
            // Strip any in-flight CA animations (declarative keyframes,
            // UIKit alongside animations) so the endpoint values set below
            // take effect immediately instead of being overridden.
            let animatedViews = [
                state.fromView, state.toView, state.backdrop, state.progressProbe,
                state.stage.shadowView, state.stage.coverContainer,
                state.stage.coverView, state.stage.spineShadowView
            ]
            for view in animatedViews {
                view.layer.removeAllAnimations()
            }
            applyRuntimeState(
                progress: resolvedCompleted ? state.endProgress : state.startProgress,
                state: state
            )
        }
        cleanupTemporaryViews(transitionCompleted: resolvedCompleted)

        guard let transitionContext = activeTransitionContext else {
            // Context already died with the transition; unwind our own
            // bookkeeping so the driver and coordinator can reset.
            propertyAnimator = nil
            deliverCompletion(resolvedCompleted)
            return
        }

        isCompletingTransition = true
        if transitionContext.isInteractive, !transitionContext.transitionWasCancelled {
            if resolvedCompleted {
                transitionContext.finishInteractiveTransition()
            } else {
                transitionContext.cancelInteractiveTransition()
            }
        }
        transitionContext.completeTransition(resolvedCompleted)
        isCompletingTransition = false
        propertyAnimator = nil
        activeTransitionContext = nil
        deliverCompletion(resolvedCompleted)
    }

    /// Keep gesture changes visually in lockstep instead of waiting one
    /// display refresh for the next CADisplayLink callback.
    func renderCurrentProgress() {
        renderAnimationFrame()
    }

    /// UIKit owns the navigation transaction, but the book visuals are drawn
    /// from our phased progress model outside its animation block. On cancel,
    /// replay that model to the open endpoint before UIKit finalizes the pop;
    /// otherwise UIKit can clean up the transition before a visible return is
    /// ever rendered.
    @discardableResult
    func settleInteractiveCancellation(
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) -> Bool {
        guard
            duration > 0,
            let propertyAnimator,
            let state = runtimeState,
            state.isInteractive,
            operation == .pop
        else {
            return false
        }

        let timelineFraction = ReaderCardTransitionMath.clampProgress(
            propertyAnimator.fractionComplete
        )
        let startOpenProgress = ReaderCardTransitionMath.lerp(
            state.startProgress,
            state.endProgress,
            timelineFraction
        )
        cancellationSettle = CancellationSettle(
            startOpenProgress: startOpenProgress,
            startTime: CACurrentMediaTime(),
            duration: duration
        )
        cancellationSettleCompletion = completion
        isHoldingOpenAfterCancellationSettle = false
        applyRuntimeState(progress: startOpenProgress, state: state)
        startDisplayLink()
        return true
    }

    // MARK: Visual construction

    private struct BookStage {
        let shadowView: UIView
        let coverContainer: UIView
        let spineShadowView: UIView
        let coverView: UIView
    }

    /// Soft gradient shading the paper along the spine while the cover is
    /// mid-lift. A gradient-backed view so per-frame layout is just `frame`.
    private final class SpineShadowView: UIView {
        override class var layerClass: AnyClass { CAGradientLayer.self }

        init(direction: ReaderBookOpeningDirection) {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            guard let gradient = layer as? CAGradientLayer else { return }
            let dark = UIColor.black.withAlphaComponent(0.45).cgColor
            let clear = UIColor.black.withAlphaComponent(0).cgColor
            gradient.colors = direction == .leftSpine ? [dark, clear] : [clear, dark]
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private struct RuntimeState {
        let stage: BookStage
        let backdrop: UIView
        let progressProbe: UIView
        let liveReaderView: UIView
        let fromView: UIView
        let toView: UIView
        let sourceGeometry: ReaderCardGeometry
        let destinationGeometry: ReaderCardGeometry
        let reduceMotion: Bool
        let startProgress: CGFloat
        let endProgress: CGFloat
        let isInteractive: Bool
    }

    private struct CancellationSettle {
        let startOpenProgress: CGFloat
        let startTime: CFTimeInterval
        let duration: TimeInterval
    }

    private func startDisplayLink() {
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(renderAnimationFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func renderAnimationFrame() {
        guard let state = runtimeState else { return }

        if isHoldingOpenAfterCancellationSettle {
            applyRuntimeState(progress: state.startProgress, state: state)
            return
        }

        if let cancellationSettle {
            let elapsed = CACurrentMediaTime() - cancellationSettle.startTime
            let timeFraction = ReaderCardTransitionMath.clampProgress(
                CGFloat(elapsed / cancellationSettle.duration)
            )
            let progress = ReaderCardTransitionMath.cancellationOpenProgress(
                from: cancellationSettle.startOpenProgress,
                timeFraction: timeFraction
            )
            applyRuntimeState(progress: progress, state: state)

            if timeFraction >= 1 {
                self.cancellationSettle = nil
                isHoldingOpenAfterCancellationSettle = true
                applyRuntimeState(progress: state.startProgress, state: state)
                let completion = cancellationSettleCompletion
                cancellationSettleCompletion = nil
                completion?()
            }
            return
        }

        guard let propertyAnimator else { return }
        let fraction = ReaderCardTransitionMath.clampProgress(propertyAnimator.fractionComplete)
        let timelineFraction = state.isInteractive
            ? fraction
            : easedTransitionFraction(fraction)
        let progress = ReaderCardTransitionMath.lerp(
            state.startProgress,
            state.endProgress,
            timelineFraction
        )
        applyRuntimeState(progress: progress, state: state)
    }

    private func easedTransitionFraction(_ fraction: CGFloat) -> CGFloat {
        let t = ReaderCardTransitionMath.clampProgress(fraction)
        switch operation {
        case .push:
            // Smoothstep: deliberate lift/open with zero endpoint velocity.
            return t * t * (3 - 2 * t)
        case .pop:
            // Ease-out cubic: responsive close that settles gently on shelf.
            let inverse = 1 - t
            return 1 - inverse * inverse * inverse
        }
    }

    private func applyRuntimeState(progress: CGFloat, state: RuntimeState) {
        apply(
            progress: progress,
            reduceMotion: state.reduceMotion,
            stage: state.stage,
            backdrop: state.backdrop,
            liveReaderView: state.liveReaderView,
            sourceGeometry: state.sourceGeometry,
            destinationGeometry: state.destinationGeometry
        )
    }

    private func cleanupTemporaryViews(transitionCompleted: Bool? = nil) {
        displayLink?.invalidate()
        displayLink = nil
        cancellationSettle = nil
        cancellationSettleCompletion = nil
        isHoldingOpenAfterCancellationSettle = false
        cachedShadowSize = .zero
        cachedShadowRadius = 0
        cachedShadowPath = nil

        guard let state = runtimeState else { return }
        for view in [state.fromView, state.toView] {
            // Clear any declarative keyframe animations still attached to the
            // live reader layer before restoring its resting state.
            view.layer.removeAllAnimations()
            view.isHidden = false
            view.alpha = 1
            view.transform = .identity
            view.layer.cornerRadius = 0
            view.layer.masksToBounds = false
        }
        state.stage.shadowView.removeFromSuperview()
        state.stage.coverContainer.removeFromSuperview()
        state.backdrop.removeFromSuperview()
        state.progressProbe.removeFromSuperview()

        if let transitionCompleted {
            switch (operation, transitionCompleted) {
            case (.push, false):
                state.toView.removeFromSuperview()
            case (.pop, true):
                state.fromView.removeFromSuperview()
            case (.pop, false):
                state.toView.removeFromSuperview()
            case (.push, true):
                break
            }
        }
        runtimeState = nil
    }

    private func deliverCompletion(_ completed: Bool) {
        guard !completionDelivered else { return }
        completionDelivered = true
        completion(completed)
    }

    private func makeBookStage(initialFrame: CGRect) -> BookStage {
        let shadowView = UIView(frame: initialFrame)
        shadowView.backgroundColor = .clear
        shadowView.isUserInteractionEnabled = false
        shadowView.layer.shadowColor = UIColor(DSColor.shadow).cgColor
        shadowView.layer.shadowRadius = 18
        shadowView.layer.shadowOffset = CGSize(width: 0, height: 10)

        // Deliberately not clipped: the hinging front cover must sweep
        // outside the card like a physical book instead of being cropped at
        // the card's edge.
        let coverContainer = UIView(frame: initialFrame)
        coverContainer.backgroundColor = .clear
        coverContainer.isUserInteractionEnabled = false

        let spineShadowView = SpineShadowView(direction: source.direction)
        spineShadowView.alpha = 0
        coverContainer.addSubview(spineShadowView)

        let coverView: UIView
        if let image = source.snapshot {
            let imageView = UIImageView(image: image)
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            coverView = imageView
        } else {
            let fallback = UIView()
            fallback.backgroundColor = UIColor(DSColor.surface)
            fallback.layer.masksToBounds = true
            coverView = fallback
        }
        // The hinge anchor is fixed for the whole transition, so per-frame
        // layout can set bounds/position directly without anchor migration.
        coverView.layer.anchorPoint = CGPoint(
            x: source.direction == .leftSpine ? 0 : 1,
            y: 0.5
        )
        coverView.layer.isDoubleSided = false
        coverContainer.addSubview(coverView)

        return BookStage(
            shadowView: shadowView,
            coverContainer: coverContainer,
            spineShadowView: spineShadowView,
            coverView: coverView
        )
    }

    private func apply(
        progress: CGFloat,
        reduceMotion: Bool,
        stage: BookStage,
        backdrop: UIView,
        liveReaderView: UIView,
        sourceGeometry: ReaderCardGeometry,
        destinationGeometry: ReaderCardGeometry
    ) {
        let values = computeFrameValues(
            progress: progress,
            reduceMotion: reduceMotion,
            sourceGeometry: sourceGeometry,
            destinationGeometry: destinationGeometry
        )
        setFrameValues(
            values,
            stage: stage,
            backdrop: backdrop,
            liveReaderView: liveReaderView
        )
    }

    // MARK: Single-source visual model
    //
    // `computeFrameValues` is the one place the phased book visuals become
    // concrete layer values. Both drivers consume it, so they cannot drift:
    // the interactive edge-pop evaluates it per CADisplayLink frame via
    // `setFrameValues`, and the non-interactive push/pop samples it into
    // keyframes via `runDeclarativeAnimation`.

    /// Every concrete layer value for one progress point.
    private struct FrameValues {
        var reduceMotion: Bool
        var readerTransform: CGAffineTransform
        var readerCornerRadius: CGFloat
        var readerMasksToBounds: Bool
        var readerAlpha: CGFloat
        var backdropAlpha: CGFloat
        var shadowViewAlpha: CGFloat
        var shadowFrame: CGRect
        var shadowOpacity: Float
        var shadowSize: CGSize
        var shadowCornerRadius: CGFloat
        var shadowOffset: CGSize
        var coverContainerAlpha: CGFloat
        var coverContainerFrame: CGRect
        var spineShadowFrame: CGRect
        var spineShadowAlpha: CGFloat
        var coverBounds: CGRect
        var coverPosition: CGPoint
        var coverCornerRadius: CGFloat
        var coverTransform: CATransform3D
        var coverAlpha: CGFloat
    }

    private func computeFrameValues(
        progress: CGFloat,
        reduceMotion: Bool,
        sourceGeometry: ReaderCardGeometry,
        destinationGeometry: ReaderCardGeometry
    ) -> FrameValues {
        let p = ReaderCardTransitionMath.clampProgress(progress)
        let visual = ReaderCardVisualState.interpolate(
            progress: p,
            source: sourceGeometry,
            destination: destinationGeometry
        )

        if reduceMotion {
            return FrameValues(
                reduceMotion: true,
                readerTransform: .identity,
                readerCornerRadius: 0,
                readerMasksToBounds: false,
                readerAlpha: p,
                backdropAlpha: p,
                shadowViewAlpha: 0,
                shadowFrame: visual.frame,
                shadowOpacity: 0,
                shadowSize: visual.frame.size,
                shadowCornerRadius: visual.cornerRadius,
                shadowOffset: CGSize(width: 0, height: 10),
                coverContainerAlpha: 0,
                coverContainerFrame: visual.frame,
                spineShadowFrame: .zero,
                spineShadowAlpha: 0,
                coverBounds: CGRect(origin: .zero, size: visual.frame.size),
                coverPosition: .zero,
                coverCornerRadius: visual.cornerRadius,
                coverTransform: CATransform3DIdentity,
                coverAlpha: 0
            )
        }

        let pose = ReaderBookOpeningPose.interpolate(progress: p, direction: source.direction)
        let full = destinationGeometry.frame

        // The real reader view is the transition's paper: it scales between
        // the shelf card and full screen, so live content grows and shrinks
        // with the card in both directions instead of popping in at the end.
        // Only the transform changes — bounds stay full-screen, so SwiftUI
        // never relayouts mid-flight.
        let scaleX = max(visual.frame.width / max(full.width, 1), 0.001)
        let scaleY = max(visual.frame.height / max(full.height, 1), 0.001)
        let readerTransform = CGAffineTransform(
            translationX: visual.frame.midX - full.midX,
            y: visual.frame.midY - full.midY
        ).scaledBy(x: scaleX, y: scaleY)
        // Corner radius lives in the view's own (unscaled) coordinate space;
        // divide so the on-screen rounding matches the card's.
        let readerCornerRadius = visual.cornerRadius / scaleX

        let spineShadowWidth = min(full.width * 0.18, visual.frame.width)
        let spineShadowFrame = CGRect(
            x: source.direction == .leftSpine ? 0 : visual.frame.width - spineShadowWidth,
            y: 0,
            width: spineShadowWidth,
            height: visual.frame.height
        )

        // Laid out via bounds/position because the layer carries a 3D
        // transform; its hinge anchor was fixed at construction
        // (leftSpine -> 0, rightSpine -> 1).
        let coverBounds = CGRect(origin: .zero, size: visual.frame.size)
        let coverAnchorX: CGFloat = source.direction == .leftSpine ? 0 : 1
        let coverPosition = CGPoint(
            x: coverBounds.width * coverAnchorX,
            y: coverBounds.height * 0.5
        )
        var coverTransform = CATransform3DIdentity
        coverTransform.m34 = -1 / 900
        coverTransform = CATransform3DRotate(
            coverTransform,
            pose.coverRotationY,
            0,
            1,
            0
        )

        let shadowDirection: CGFloat = source.direction == .leftSpine ? -1 : 1
        let shadowOffset = CGSize(
            width: shadowDirection * 10 * ReaderCardTransitionMath.phase(p, in: 0.04...0.55),
            height: 10
        )

        return FrameValues(
            reduceMotion: false,
            readerTransform: readerTransform,
            readerCornerRadius: readerCornerRadius,
            readerMasksToBounds: visual.cornerRadius > 0,
            readerAlpha: 1,
            backdropAlpha: ReaderCardTransitionMath.phase(p, in: 0.04...0.72),
            shadowViewAlpha: 1,
            shadowFrame: visual.frame,
            shadowOpacity: Float(visual.shadowOpacity),
            shadowSize: visual.frame.size,
            shadowCornerRadius: visual.cornerRadius,
            shadowOffset: shadowOffset,
            coverContainerAlpha: 1,
            coverContainerFrame: visual.frame,
            spineShadowFrame: spineShadowFrame,
            spineShadowAlpha: pose.spineShadowOpacity,
            coverBounds: coverBounds,
            coverPosition: coverPosition,
            coverCornerRadius: visual.cornerRadius,
            coverTransform: coverTransform,
            coverAlpha: pose.coverOpacity
        )
    }

    private func setFrameValues(
        _ values: FrameValues,
        stage: BookStage,
        backdrop: UIView,
        liveReaderView: UIView
    ) {
        if values.reduceMotion {
            stage.shadowView.alpha = 0
            stage.coverContainer.alpha = 0
            liveReaderView.transform = .identity
            liveReaderView.layer.cornerRadius = 0
            liveReaderView.layer.masksToBounds = false
            liveReaderView.alpha = values.readerAlpha
            backdrop.alpha = values.backdropAlpha
            return
        }

        backdrop.alpha = values.backdropAlpha

        liveReaderView.alpha = values.readerAlpha
        liveReaderView.transform = values.readerTransform
        liveReaderView.layer.cornerRadius = values.readerCornerRadius
        liveReaderView.layer.masksToBounds = values.readerMasksToBounds

        stage.shadowView.alpha = values.shadowViewAlpha
        stage.shadowView.frame = values.shadowFrame
        stage.shadowView.layer.shadowOpacity = values.shadowOpacity
        let sizeDelta = abs(values.shadowSize.width - cachedShadowSize.width)
            + abs(values.shadowSize.height - cachedShadowSize.height)
        if sizeDelta > 0.5 || abs(values.shadowCornerRadius - cachedShadowRadius) > 0.5 {
            cachedShadowPath = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: values.shadowSize),
                cornerRadius: values.shadowCornerRadius
            ).cgPath
            cachedShadowSize = values.shadowSize
            cachedShadowRadius = values.shadowCornerRadius
        }
        stage.shadowView.layer.shadowPath = cachedShadowPath
        stage.shadowView.layer.shadowOffset = values.shadowOffset

        // The cover assembly rides the card geometry without clipping, so
        // the hinging cover sweeps outside the card like a real front cover.
        stage.coverContainer.alpha = values.coverContainerAlpha
        stage.coverContainer.frame = values.coverContainerFrame

        stage.spineShadowView.frame = values.spineShadowFrame
        stage.spineShadowView.alpha = values.spineShadowAlpha

        stage.coverView.layer.bounds = values.coverBounds
        stage.coverView.layer.position = values.coverPosition
        stage.coverView.layer.cornerRadius = values.coverCornerRadius
        stage.coverView.layer.transform = values.coverTransform
        stage.coverView.alpha = values.coverAlpha
    }

    /// Non-interactive push / programmatic pop. Instead of recomputing the
    /// phased model on the main thread every CADisplayLink frame, sample it
    /// into keyframes once and hand them to Core Animation, which drives the
    /// whole transition on the render server. A momentarily busy main thread
    /// (first CoreText pagination, SwiftUI updates, cover decoding) can then no
    /// longer drop transition frames — the cause of the intermittent stutter on
    /// both opening and closing. The interactive edge-pop deliberately keeps
    /// the per-frame path, because it must scrub with the finger.
    private func runDeclarativeAnimation(state: RuntimeState, duration: TimeInterval) {
        let commitStart = CACurrentMediaTime()

        // Model layers jump to the end state, so the transition is seamless the
        // instant Core Animation removes the presentation-only animations.
        let endValues = computeFrameValues(
            progress: state.endProgress,
            reduceMotion: state.reduceMotion,
            sourceGeometry: state.sourceGeometry,
            destinationGeometry: state.destinationGeometry
        )
        setFrameValues(
            endValues,
            stage: state.stage,
            backdrop: state.backdrop,
            liveReaderView: state.liveReaderView
        )

        let sampleCount = Self.declarativeKeyframeCount
        let keyTimes: [NSNumber] = (0...sampleCount).map {
            NSNumber(value: Double($0) / Double(sampleCount))
        }

        let frames: [FrameValues] = (0...sampleCount).map { index in
            let t = CGFloat(index) / CGFloat(sampleCount)
            // Same easing the scrub path applies to non-interactive playback,
            // so the sampled timeline matches the per-frame model exactly.
            let progress = ReaderCardTransitionMath.lerp(
                state.startProgress,
                state.endProgress,
                easedTransitionFraction(t)
            )
            return computeFrameValues(
                progress: progress,
                reduceMotion: state.reduceMotion,
                sourceGeometry: state.sourceGeometry,
                destinationGeometry: state.destinationGeometry
            )
        }

        func addKeyframe(_ keyPath: String, to layer: CALayer, values: [Any]) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = keyTimes
            animation.duration = duration
            animation.calculationMode = .linear
            animation.isRemovedOnCompletion = true
            layer.add(animation, forKey: "readerTransition.\(keyPath)")
        }

        if state.reduceMotion {
            // Reduce Motion is a plain crossfade: only reader and backdrop
            // opacity carry it, the book stage stays hidden throughout.
            addKeyframe(
                "opacity",
                to: state.liveReaderView.layer,
                values: frames.map { NSNumber(value: Double($0.readerAlpha)) }
            )
            addKeyframe(
                "opacity",
                to: state.backdrop.layer,
                values: frames.map { NSNumber(value: Double($0.backdropAlpha)) }
            )
            AppLogger.info(
                "⟐ reader-transition declarative reduceMotion "
                + "op=\(operation == .push ? "push" : "pop") "
                + "commit=\(String(format: "%.1f", (CACurrentMediaTime() - commitStart) * 1000))ms"
            )
            return
        }

        // masksToBounds cannot animate; enable it for the whole run when any
        // sampled frame needs clipping, matching the scrub path's per-frame
        // rule. The completion handler restores the resting value.
        if frames.contains(where: { $0.readerMasksToBounds }) {
            state.liveReaderView.layer.masksToBounds = true
        }

        let readerLayer = state.liveReaderView.layer
        addKeyframe(
            "transform",
            to: readerLayer,
            values: frames.map {
                NSValue(caTransform3D: CATransform3DMakeAffineTransform($0.readerTransform))
            }
        )
        addKeyframe(
            "cornerRadius",
            to: readerLayer,
            values: frames.map { NSNumber(value: Double($0.readerCornerRadius)) }
        )

        addKeyframe(
            "opacity",
            to: state.backdrop.layer,
            values: frames.map { NSNumber(value: Double($0.backdropAlpha)) }
        )

        let shadowLayer = state.stage.shadowView.layer
        addKeyframe(
            "bounds",
            to: shadowLayer,
            values: frames.map { NSValue(cgRect: CGRect(origin: .zero, size: $0.shadowFrame.size)) }
        )
        addKeyframe(
            "position",
            to: shadowLayer,
            values: frames.map {
                NSValue(cgPoint: CGPoint(x: $0.shadowFrame.midX, y: $0.shadowFrame.midY))
            }
        )
        addKeyframe(
            "opacity",
            to: shadowLayer,
            values: frames.map { NSNumber(value: Double($0.shadowViewAlpha)) }
        )
        addKeyframe(
            "shadowOpacity",
            to: shadowLayer,
            values: frames.map { NSNumber(value: Double($0.shadowOpacity)) }
        )
        addKeyframe(
            "shadowPath",
            to: shadowLayer,
            values: frames.map {
                UIBezierPath(
                    roundedRect: CGRect(origin: .zero, size: $0.shadowSize),
                    cornerRadius: $0.shadowCornerRadius
                ).cgPath
            }
        )
        addKeyframe(
            "shadowOffset",
            to: shadowLayer,
            values: frames.map { NSValue(cgSize: $0.shadowOffset) }
        )

        let coverContainerLayer = state.stage.coverContainer.layer
        addKeyframe(
            "bounds",
            to: coverContainerLayer,
            values: frames.map {
                NSValue(cgRect: CGRect(origin: .zero, size: $0.coverContainerFrame.size))
            }
        )
        addKeyframe(
            "position",
            to: coverContainerLayer,
            values: frames.map {
                NSValue(
                    cgPoint: CGPoint(
                        x: $0.coverContainerFrame.midX,
                        y: $0.coverContainerFrame.midY
                    )
                )
            }
        )
        addKeyframe(
            "opacity",
            to: coverContainerLayer,
            values: frames.map { NSNumber(value: Double($0.coverContainerAlpha)) }
        )

        let spineLayer = state.stage.spineShadowView.layer
        addKeyframe(
            "bounds",
            to: spineLayer,
            values: frames.map {
                NSValue(cgRect: CGRect(origin: .zero, size: $0.spineShadowFrame.size))
            }
        )
        addKeyframe(
            "position",
            to: spineLayer,
            values: frames.map {
                NSValue(
                    cgPoint: CGPoint(
                        x: $0.spineShadowFrame.midX,
                        y: $0.spineShadowFrame.midY
                    )
                )
            }
        )
        addKeyframe(
            "opacity",
            to: spineLayer,
            values: frames.map { NSNumber(value: Double($0.spineShadowAlpha)) }
        )

        let coverLayer = state.stage.coverView.layer
        addKeyframe(
            "bounds",
            to: coverLayer,
            values: frames.map { NSValue(cgRect: $0.coverBounds) }
        )
        addKeyframe(
            "position",
            to: coverLayer,
            values: frames.map { NSValue(cgPoint: $0.coverPosition) }
        )
        addKeyframe(
            "cornerRadius",
            to: coverLayer,
            values: frames.map { NSNumber(value: Double($0.coverCornerRadius)) }
        )
        addKeyframe(
            "transform",
            to: coverLayer,
            values: frames.map { NSValue(caTransform3D: $0.coverTransform) }
        )
        addKeyframe(
            "opacity",
            to: coverLayer,
            values: frames.map { NSNumber(value: Double($0.coverAlpha)) }
        )

        AppLogger.info(
            "⟐ reader-transition declarative committed "
            + "op=\(operation == .push ? "push" : "pop") "
            + "keyframes=\(sampleCount + 1) "
            + "dur=\(String(format: "%.2f", duration))s "
            + "commit=\(String(format: "%.1f", (CACurrentMediaTime() - commitStart) * 1000))ms"
        )
    }

    private func resolvedFullFrame(
        container: UIView,
        transitionContext: UIViewControllerContextTransitioning,
        fromController: UIViewController,
        toController: UIViewController
    ) -> CGRect {
        let controller = operation == .push ? toController : fromController
        let contextFrame = operation == .push
            ? transitionContext.finalFrame(for: controller)
            : transitionContext.initialFrame(for: controller)
        return contextFrame.isEmpty ? container.bounds : contextFrame
    }

    private func resolvedClosedFrame(in container: UIView, fullFrame: CGRect) -> CGRect {
        if let sourceFrame = source.resolvedFrame(
            allowingTapFallback: operation == .push
        ),
           sourceFrame.width > 1,
           sourceFrame.height > 1 {
            if let window = container.window {
                guard window.bounds.intersects(sourceFrame) else {
                    return centeredFallbackFrame(in: fullFrame)
                }
                let converted = container.convert(sourceFrame, from: window)
                if !converted.isEmpty, container.bounds.intersects(converted) {
                    return converted
                }
                return centeredFallbackFrame(in: fullFrame)
            }
            if fullFrame.intersects(sourceFrame) {
                return sourceFrame
            }
        }

        return centeredFallbackFrame(in: fullFrame)
    }

    private func centeredFallbackFrame(in fullFrame: CGRect) -> CGRect {
        let width = min(DSLayout.readerCardFallbackWidth, fullFrame.width * 0.32)
        let height = width * DSLayout.readerCardFallbackAspectRatio
        return CGRect(
            x: fullFrame.midX - width / 2,
            y: fullFrame.midY - height / 2,
            width: width,
            height: height
        )
    }

}
