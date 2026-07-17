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
        startDisplayLink()
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
        let p = ReaderCardTransitionMath.clampProgress(progress)
        let visual = ReaderCardVisualState.interpolate(
            progress: p,
            source: sourceGeometry,
            destination: destinationGeometry
        )

        if reduceMotion {
            stage.shadowView.alpha = 0
            stage.coverContainer.alpha = 0
            liveReaderView.transform = .identity
            liveReaderView.layer.cornerRadius = 0
            liveReaderView.layer.masksToBounds = false
            liveReaderView.alpha = p
            backdrop.alpha = p
            return
        }

        let pose = ReaderBookOpeningPose.interpolate(progress: p, direction: source.direction)
        let full = destinationGeometry.frame

        backdrop.alpha = ReaderCardTransitionMath.phase(p, in: 0.04...0.72)

        // The real reader view is the transition's paper: it scales between
        // the shelf card and full screen, so live content grows and shrinks
        // with the card in both directions instead of popping in at the end.
        // Only the transform changes — bounds stay full-screen, so SwiftUI
        // never relayouts mid-flight.
        let scaleX = max(visual.frame.width / max(full.width, 1), 0.001)
        let scaleY = max(visual.frame.height / max(full.height, 1), 0.001)
        liveReaderView.alpha = 1
        liveReaderView.transform = CGAffineTransform(
            translationX: visual.frame.midX - full.midX,
            y: visual.frame.midY - full.midY
        ).scaledBy(x: scaleX, y: scaleY)
        // Corner radius lives in the view's own (unscaled) coordinate space;
        // divide so the on-screen rounding matches the card's.
        liveReaderView.layer.cornerRadius = visual.cornerRadius / scaleX
        liveReaderView.layer.masksToBounds = visual.cornerRadius > 0

        stage.shadowView.alpha = 1
        stage.shadowView.frame = visual.frame
        stage.shadowView.layer.shadowOpacity = Float(visual.shadowOpacity)
        let shadowSize = visual.frame.size
        let shadowRadius = visual.cornerRadius
        let sizeDelta = abs(shadowSize.width - cachedShadowSize.width)
            + abs(shadowSize.height - cachedShadowSize.height)
        if sizeDelta > 0.5 || abs(shadowRadius - cachedShadowRadius) > 0.5 {
            cachedShadowPath = UIBezierPath(
                roundedRect: CGRect(origin: .zero, size: shadowSize),
                cornerRadius: shadowRadius
            ).cgPath
            cachedShadowSize = shadowSize
            cachedShadowRadius = shadowRadius
        }
        stage.shadowView.layer.shadowPath = cachedShadowPath

        // The cover assembly rides the card geometry without clipping, so
        // the hinging cover sweeps outside the card like a real front cover.
        stage.coverContainer.alpha = 1
        stage.coverContainer.frame = visual.frame

        let spineShadowWidth = min(full.width * 0.18, visual.frame.width)
        stage.spineShadowView.frame = CGRect(
            x: source.direction == .leftSpine ? 0 : visual.frame.width - spineShadowWidth,
            y: 0,
            width: spineShadowWidth,
            height: visual.frame.height
        )
        stage.spineShadowView.alpha = pose.spineShadowOpacity

        // Laid out via bounds/position because the layer carries a 3D
        // transform; its hinge anchor was fixed at construction.
        let coverBounds = CGRect(origin: .zero, size: visual.frame.size)
        stage.coverView.layer.bounds = coverBounds
        stage.coverView.layer.position = CGPoint(
            x: coverBounds.width * stage.coverView.layer.anchorPoint.x,
            y: coverBounds.height * stage.coverView.layer.anchorPoint.y
        )
        stage.coverView.layer.cornerRadius = visual.cornerRadius
        var coverTransform = CATransform3DIdentity
        coverTransform.m34 = -1 / 900
        coverTransform = CATransform3DRotate(
            coverTransform,
            pose.coverRotationY,
            0,
            1,
            0
        )
        stage.coverView.layer.transform = coverTransform
        stage.coverView.alpha = pose.coverOpacity

        let shadowDirection: CGFloat = source.direction == .leftSpine ? -1 : 1
        stage.shadowView.layer.shadowOffset = CGSize(
            width: shadowDirection * 10 * ReaderCardTransitionMath.phase(p, in: 0.04...0.55),
            height: 10
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
