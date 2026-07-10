import UIKit

/// Pure math for the paged reader's swipe-up-to-exit gesture: an ✕ chip rises
/// from the bottom and grows while the finger travels up; releasing past the
/// commit point closes the reader. Scroll mode never installs this gesture.
/// Stateless like `ReaderCoverPageMotion` so the thresholds are unit-testable.
enum ReaderSwipeUpExitMotion {
    /// Upward finger travel (pt) that maps to 100% progress.
    static let fullProgressTranslation: CGFloat = 180
    /// Progress at or above which releasing the finger exits the reader.
    static let commitProgress: CGFloat = 0.55
    /// Upward fling velocity (pt/s, negative = up) that commits before the
    /// distance threshold is reached.
    static let commitVelocityY: CGFloat = -1100
    /// A fling still needs this much progress so a stray flick can't exit.
    static let flingMinimumProgress: CGFloat = 0.18

    static let chipDiameter: CGFloat = 54
    static let chipIconPointSize: CGFloat = 22
    /// How far the chip center travels upward from rest at 100% progress.
    static let chipRise: CGFloat = 96
    /// Chip center's rest offset above the bottom safe-area edge.
    static let chipRestBottomInset: CGFloat = 48
    static let minChipScale: CGFloat = 0.35
    /// Extra scale "pop" once the gesture passes the commit point.
    static let armedScaleBoost: CGFloat = 1.1
    static let cancelSettleDuration: TimeInterval = 0.25
    static let commitFadeDuration: TimeInterval = 0.12

    /// The pan may only begin on a clearly upward drag, so horizontal
    /// page-turn pans and downward drags keep their normal behavior.
    static func shouldBegin(velocity: CGPoint) -> Bool {
        velocity.y < 0 && abs(velocity.y) > abs(velocity.x) * 1.4
    }

    static func progress(forTranslationY translationY: CGFloat) -> CGFloat {
        guard translationY < 0 else { return 0 }
        return min(-translationY / fullProgressTranslation, 1)
    }

    static func chipScale(forProgress progress: CGFloat) -> CGFloat {
        minChipScale + (1 - minChipScale) * progress
    }

    /// Fades in over the first 40% of the travel so the chip never pops.
    static func chipAlpha(forProgress progress: CGFloat) -> CGFloat {
        min(progress * 2.5, 1)
    }

    static func chipCenterY(
        forProgress progress: CGFloat,
        viewHeight: CGFloat,
        bottomSafeInset: CGFloat
    ) -> CGFloat {
        viewHeight - bottomSafeInset - chipRestBottomInset - chipRise * progress
    }

    static func shouldCommit(progress: CGFloat, velocityY: CGFloat) -> Bool {
        if progress >= commitProgress { return true }
        return velocityY <= commitVelocityY && progress >= flingMinimumProgress
    }
}
