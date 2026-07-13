import CoreGraphics
import Foundation

// MARK: - ReaderCardTransitionMath
//
// Pure, side-effect-free math for the interactive card reader transition.
// One normalized value, `progress`, drives every visual property:
//
//   progress 1.0  -> reader fully open (full-screen card)
//   progress 0.0  -> reader fully closed (card at source-cover geometry)
//
// Opening animates 0 -> 1. Interactive closing (pop) drags 1 -> 0; UIKit's
// interactive pop percentage is converted to the same model so a single
// source of truth feeds the animator, interaction controller, and the
// book-opening effect.
//
// This file deliberately depends only on CoreGraphics / Foundation / UIKit
// types so it can be unit-tested in isolation.

enum ReaderCardTransitionMath {
    /// Width of the leading screen-edge start region (points). This is a
    /// defensive upper bound layered over `UIScreenEdgePanGestureRecognizer`'s
    /// own edge decision, not the primary filter: a real finger entering from
    /// the bezel is first sampled 5–20pt inside the screen (device logs showed
    /// legitimate swipes reporting initialX of 8/11/18), so a tight strip
    /// rejects most honest attempts. The system recognizer is what guarantees
    /// the touch actually started at the edge.
    static let edgeStartWidth: CGFloat = 30

    /// Closing progress required before a slow release commits the pop.
    /// Below this point the physical book transition reverses to fully open.
    static let closeCompletionThreshold: CGFloat = 0.20

    /// Horizontal velocity (points/second) that overrides the distance rule.
    /// Positive velocity continues toward close; negative velocity returns
    /// toward the open reader.
    static let closeVelocityThreshold: CGFloat = 600

    /// Normal UIKit settle speed used when no slower visible return is needed.
    static let maximumCompletionSpeed: CGFloat = 0.92

    /// UIKit finalizes only its navigation state after the custom animator has
    /// already drawn a cancelled book fully open, so this hidden tail can run
    /// faster than real time without affecting visible motion.
    static let cancellationFinalizationSpeed: CGFloat = 4

    // MARK: Progress

    /// Clamp any raw progress value into the canonical 0...1 range.
    static func clampProgress(_ progress: CGFloat) -> CGFloat {
        min(max(progress, 0), 1)
    }

    /// Convert UIKit interactive-pop percentage to open-state progress.
    ///
    /// `popPercentage` is the value UIKit feeds
    /// `UIPercentDrivenInteractiveTransition.update(_:)`: 0.0 at the start of
    /// the pop (reader fully open) and 1.0 once the pop is complete (reader
    /// gone). Open-state progress is the inverse scale the animator uses: 1.0
    /// = reader fully open, 0.0 = reader fully closed.
    static func openProgress(fromPopPercentage popPercentage: CGFloat) -> CGFloat {
        clampProgress(1 - popPercentage)
    }

    /// Convert open-state progress back to a UIKit pop percentage (the value
    /// to feed `update`/`finish`/`cancel`). Useful when a custom gesture drives
    /// the transition rather than the default edge-pan percentage.
    static func popPercentage(fromOpenProgress progress: CGFloat) -> CGFloat {
        clampProgress(1 - progress)
    }

    // MARK: Phase mapping

    /// Map open-state progress onto a sub-range of the transition, returning a
    /// 0...1 value that ramps from 0 at the range's lower bound to 1 at the
    /// upper bound and stays clamped outside. Used so each visual property can
    /// span its own phase (e.g. shadow `0.0...0.25`, content reveal
    /// `0.55...1.0`) while remaining a continuous function of one progress.
    static func phase(_ progress: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        let lo = range.lowerBound
        let hi = range.upperBound
        guard hi > lo else { return progress >= hi ? 1 : 0 }
        let t = (progress - lo) / (hi - lo)
        return min(max(t, 0), 1)
    }

    /// Linear interpolation between two scalar endpoints, clamped to 0...1 in
    /// the interpolation parameter.
    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return a + (b - a) * clamped
    }

    /// Linear interpolation of two rects by a 0...1 parameter.
    static func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        let clamped = min(max(t, 0), 1)
        return CGRect(
            x: a.minX + (b.minX - a.minX) * clamped,
            y: a.minY + (b.minY - a.minY) * clamped,
            width: a.width + (b.width - a.width) * clamped,
            height: a.height + (b.height - a.height) * clamped
        )
    }

    /// Linear interpolation between two sizes.
    static func lerp(_ a: CGSize, _ b: CGSize, _ t: CGFloat) -> CGSize {
        let clamped = min(max(t, 0), 1)
        return CGSize(
            width: a.width + (b.width - a.width) * clamped,
            height: a.height + (b.height - a.height) * clamped
        )
    }

    // MARK: Finish / cancel decision

    /// Decide whether releasing the edge swipe should close the reader.
    /// Distance handles deliberate drags while velocity preserves natural
    /// flicks and lets a fast reverse gesture explicitly restore the reader.
    static func shouldFinishClose(closeProgress: CGFloat, velocity: CGFloat) -> Bool {
        let progress = clampProgress(closeProgress)
        if velocity >= closeVelocityThreshold { return true }
        if velocity <= -closeVelocityThreshold { return false }
        return progress >= closeCompletionThreshold
    }

    /// Slow short cancellations enough that the reverse book-opening motion
    /// remains perceptible. `UIPercentDrivenInteractiveTransition` otherwise
    /// settles proportionally to the tiny travelled distance, which turns a
    /// small cancelled swipe into a one-frame flash.
    static func cancellationCompletionSpeed(
        closeProgress: CGFloat,
        transitionDuration: TimeInterval,
        minimumSettleDuration: TimeInterval
    ) -> CGFloat {
        let progress = clampProgress(closeProgress)
        guard
            progress > 0,
            transitionDuration > 0,
            minimumSettleDuration > 0
        else {
            return maximumCompletionSpeed
        }

        let speedForMinimumDuration = CGFloat(
            transitionDuration * Double(progress) / minimumSettleDuration
        )
        return min(speedForMinimumDuration, maximumCompletionSpeed)
    }

    /// Open-state progress for the animator-owned cancellation settle. The
    /// physical book model is evaluated again at every returned progress, so
    /// the visible return follows the same frame, hinge, shadow, and content
    /// phases as opening instead of snapping UIKit's transition endpoint.
    static func cancellationOpenProgress(
        from startOpenProgress: CGFloat,
        timeFraction: CGFloat
    ) -> CGFloat {
        let t = clampProgress(timeFraction)
        let inverse = 1 - t
        let eased = 1 - inverse * inverse * inverse
        return lerp(clampProgress(startOpenProgress), 1, eased)
    }

    // MARK: Gesture gating helpers

    /// True when the touch point is within `edgeStartWidth` of the leading
    /// edge of the given container width. `pointX` is in the container's
    /// coordinate space (0 at the leading edge).
    static func isWithinEdgeStart(pointX: CGFloat, containerWidth: CGFloat) -> Bool {
        pointX >= 0 && pointX <= edgeStartWidth && containerWidth > 0
    }

    /// True when horizontal drag intent is dominant over vertical, i.e. the
    /// recognizer should proceed; false when the gesture is predominantly
    /// vertical and should fail early.
    static func isPredominantlyHorizontal(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) >= abs(dy)
    }

    /// Central policy for deciding whether the custom reader edge gesture may
    /// start. The recognizer records `initialX` in `touchesBegan`, rather than
    /// asking for the current location after UIKit's pan threshold has already
    /// moved the finger beyond the edge strip. Scroll reading mode gets no
    /// special casing: its vertical pan is rejected by the horizontal-intent
    /// check and its scroll views defer to the screen-edge recognizer anyway.
    static func shouldBeginEdgeSwipe(
        initialX: CGFloat,
        translationX: CGFloat,
        translationY: CGFloat,
        containerWidth: CGFloat
    ) -> Bool {
        guard isWithinEdgeStart(pointX: initialX, containerWidth: containerWidth) else {
            return false
        }
        // A screen-edge recognizer consults its delegate the moment its own
        // edge decision succeeds — before any translation accumulates (device
        // logs: dx=0 dy=0). Zero translation therefore means "the system
        // already vetted an inward edge swipe"; direction checks apply only
        // once real movement exists.
        if translationX == 0 && translationY == 0 { return true }
        guard translationX > 0 else { return false }
        return isPredominantlyHorizontal(dx: translationX, dy: translationY)
    }

    /// Convert a rightward drag into UIKit's interactive-pop percentage.
    static func popProgress(translationX: CGFloat, containerWidth: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return 0 }
        return clampProgress(translationX / containerWidth)
    }
}

// MARK: - ReaderCardGeometry

/// Snapshot of the bounds the transition interpolates between, snapped at
/// transition start so bookshelf scrolling, rotation, or layout changes do
/// not leave the animator chasing a moving target.
struct ReaderCardGeometry: Equatable {
    var frame: CGRect
    var cornerRadius: CGFloat

    static let zero = ReaderCardGeometry(frame: .zero, cornerRadius: 0)

    init(frame: CGRect, cornerRadius: CGFloat) {
        self.frame = frame
        self.cornerRadius = cornerRadius
    }
}

// MARK: - ReaderCardVisualState

/// The per-frame visual state produced by interpolating a single progress
/// value across the transition's phases. Every property is a continuous
/// function of `progress`, so reversing the gesture stays visually smooth.
struct ReaderCardVisualState: Equatable {
    /// Card frame, from source cover to full-screen bounds.
    var frame: CGRect
    /// Corner radius, from the shelf card's radius to zero.
    var cornerRadius: CGFloat
    /// Outer shadow opacity, full shelf shadow down to no shadow.
    var shadowOpacity: CGFloat
    /// Reader content opacity: stays 0 through the lifting/expansion phases,
    /// then fades in across `0.55...1.0`.
    var contentOpacity: CGFloat
    /// Source cover opacity: hidden once the transition's snapshot represents
    /// it, restored at both completion and cancellation.
    var coverOpacity: CGFloat

    static func interpolate(
        progress: CGFloat,
        source: ReaderCardGeometry,
        destination: ReaderCardGeometry
    ) -> ReaderCardVisualState {
        let p = ReaderCardTransitionMath.clampProgress(progress)

        // Phase windows (mapping ranges, not separate queued animations):
        //   0.00 ... 0.25  lift card, strengthen shadow
        //   0.02 ... 1.00  grow toward the destination frame
        //   0.14 ... 0.90  cover unfold (ReaderBookOpeningPose)
        //   0.55 ... 1.00  reveal live reader content, remove rounding/shadow
        let revealPhase   = ReaderCardTransitionMath.phase(p, in: 0.55...1.00)

        // Growth leads: the card starts expanding almost immediately while
        // the cover is still shut, then the cover hinges open on the way to
        // full screen — matching the physical reference motion.
        let framePhase = ReaderCardTransitionMath.phase(p, in: 0.02...1.00)

        let frame = ReaderCardTransitionMath.lerp(source.frame, destination.frame, framePhase)
        let cornerRadius = ReaderCardTransitionMath.lerp(
            source.cornerRadius,
            destination.cornerRadius,
            framePhase
        )

        // Shadow strengthens during lift (0.00...0.25) then fades as the card
        // becomes full-screen (0.40...1.00).
        let shadowBuild = ReaderCardTransitionMath.phase(p, in: 0.00...0.25)
        let shadowFade  = ReaderCardTransitionMath.phase(p, in: 0.40...1.00)
        let shadowOpacity = clamp01(CGFloat(0.18) + CGFloat(0.20) * shadowBuild - CGFloat(0.38) * shadowFade)

        // Reader content reveals late.
        let contentOpacity = revealPhase

        // Continuous source handoff; no opacity jump while an interactive pop
        // reverses across a phase boundary.
        let coverOpacity = 1 - ReaderCardTransitionMath.phase(p, in: 0.02...0.18)

        return ReaderCardVisualState(
            frame: frame,
            cornerRadius: cornerRadius,
            shadowOpacity: shadowOpacity,
            contentOpacity: contentOpacity,
            coverOpacity: coverOpacity
        )
    }

    private static func clamp01(_ v: CGFloat) -> CGFloat {
        min(max(v, 0 as CGFloat), 1 as CGFloat)
    }
}
