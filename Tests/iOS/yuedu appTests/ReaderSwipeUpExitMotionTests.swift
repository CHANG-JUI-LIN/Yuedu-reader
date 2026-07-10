import Testing
import UIKit
@testable import yuedu_app

@Suite("Swipe-up exit motion")
struct ReaderSwipeUpExitMotionTests {
    @Test("only clearly upward drags may begin the gesture")
    func beginDirection() {
        #expect(ReaderSwipeUpExitMotion.shouldBegin(velocity: CGPoint(x: 0, y: -300)))
        #expect(ReaderSwipeUpExitMotion.shouldBegin(velocity: CGPoint(x: 100, y: -300)))
        // Downward drag never begins.
        #expect(!ReaderSwipeUpExitMotion.shouldBegin(velocity: CGPoint(x: 0, y: 300)))
        // Horizontal-dominant drags stay with the page-turn gestures.
        #expect(!ReaderSwipeUpExitMotion.shouldBegin(velocity: CGPoint(x: -400, y: -300)))
        #expect(!ReaderSwipeUpExitMotion.shouldBegin(velocity: CGPoint(x: 400, y: -300)))
        // Diagonal drags near 45° are ambiguous; require clear vertical dominance.
        #expect(!ReaderSwipeUpExitMotion.shouldBegin(velocity: CGPoint(x: -300, y: -310)))
    }

    @Test("progress tracks upward travel and clamps to 0...1")
    func progressClamping() {
        #expect(ReaderSwipeUpExitMotion.progress(forTranslationY: 0) == 0)
        // Downward travel maps to zero progress, not negative.
        #expect(ReaderSwipeUpExitMotion.progress(forTranslationY: 120) == 0)
        let half = ReaderSwipeUpExitMotion.progress(
            forTranslationY: -ReaderSwipeUpExitMotion.fullProgressTranslation / 2
        )
        #expect(abs(half - 0.5) < 0.0001)
        let beyond = ReaderSwipeUpExitMotion.progress(
            forTranslationY: -ReaderSwipeUpExitMotion.fullProgressTranslation * 3
        )
        #expect(beyond == 1)
    }

    @Test("release commits past the distance threshold")
    func commitByDistance() {
        #expect(ReaderSwipeUpExitMotion.shouldCommit(
            progress: ReaderSwipeUpExitMotion.commitProgress,
            velocityY: 0
        ))
        #expect(!ReaderSwipeUpExitMotion.shouldCommit(
            progress: ReaderSwipeUpExitMotion.commitProgress - 0.05,
            velocityY: 0
        ))
    }

    @Test("fast upward fling commits early, but a stray flick cannot")
    func commitByVelocity() {
        #expect(ReaderSwipeUpExitMotion.shouldCommit(
            progress: ReaderSwipeUpExitMotion.flingMinimumProgress,
            velocityY: ReaderSwipeUpExitMotion.commitVelocityY
        ))
        // Fast but nearly no travel: don't exit.
        #expect(!ReaderSwipeUpExitMotion.shouldCommit(
            progress: 0.05,
            velocityY: ReaderSwipeUpExitMotion.commitVelocityY
        ))
        // Enough travel but slow release below the distance threshold: don't exit.
        #expect(!ReaderSwipeUpExitMotion.shouldCommit(progress: 0.4, velocityY: -200))
    }

    @Test("chip grows from its minimum scale to full size")
    func chipScale() {
        #expect(ReaderSwipeUpExitMotion.chipScale(forProgress: 0) == ReaderSwipeUpExitMotion.minChipScale)
        #expect(ReaderSwipeUpExitMotion.chipScale(forProgress: 1) == 1)
        let mid = ReaderSwipeUpExitMotion.chipScale(forProgress: 0.5)
        #expect(mid > ReaderSwipeUpExitMotion.minChipScale && mid < 1)
    }

    @Test("chip rises from above the bottom safe area as progress grows")
    func chipRise() {
        let height: CGFloat = 800
        let safeBottom: CGFloat = 34
        let rest = ReaderSwipeUpExitMotion.chipCenterY(
            forProgress: 0, viewHeight: height, bottomSafeInset: safeBottom
        )
        let top = ReaderSwipeUpExitMotion.chipCenterY(
            forProgress: 1, viewHeight: height, bottomSafeInset: safeBottom
        )
        #expect(rest == height - safeBottom - ReaderSwipeUpExitMotion.chipRestBottomInset)
        #expect(rest - top == ReaderSwipeUpExitMotion.chipRise)
    }

    @Test("chip fades in over the first part of the travel")
    func chipAlpha() {
        #expect(ReaderSwipeUpExitMotion.chipAlpha(forProgress: 0) == 0)
        #expect(ReaderSwipeUpExitMotion.chipAlpha(forProgress: 0.2) == 0.5)
        #expect(ReaderSwipeUpExitMotion.chipAlpha(forProgress: 0.4) == 1)
        #expect(ReaderSwipeUpExitMotion.chipAlpha(forProgress: 1) == 1)
    }
}
