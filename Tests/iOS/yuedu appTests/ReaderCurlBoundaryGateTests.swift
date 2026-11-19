import CoreGraphics
import Testing
@testable import yuedu_app

/// Crashlytics 1e94b6ec / FB14724519: on the last page UIKit's curl pan passes its begin check
/// on an undecided drag (checked as "before"), then decides "after" at `.began` and throws on the
/// empty pair. The gate must stop every drag there that is not already clearly heading back.
@Suite("Curl book-edge gate")
struct ReaderCurlBoundaryGateTests {
    /// Left-to-right interface: a leftward drag is UIKit's "after".
    private let ltr: CGFloat = -1

    @Test("a page with both neighbours is never gated")
    func middlePageNeverGated() {
        #expect(!ReaderCurlBoundaryGate.blocks(
            hasAfter: true, hasBefore: true, afterSign: ltr,
            translation: CGPoint(x: 0, y: 1), velocity: CGPoint(x: -15, y: 167)
        ))
    }

    @Test("last page: the undecided drag of the crash report is stopped")
    func lastPageUndecidedDragStopped() {
        // The pan as it asked to begin in the simulator repro: translation (0, 1), velocity
        // (-15, 167) — UIKit checked it as "before" and let it through.
        #expect(ReaderCurlBoundaryGate.blocks(
            hasAfter: false, hasBefore: true, afterSign: ltr,
            translation: CGPoint(x: 0, y: 1), velocity: CGPoint(x: -15, y: 167)
        ))
    }

    @Test("last page: a drag toward the missing next page is stopped")
    func lastPageForwardDragStopped() {
        // The 11-16 report's breadcrumb: tx=-3 ty=0 vx=-383 vy=261.
        #expect(ReaderCurlBoundaryGate.blocks(
            hasAfter: false, hasBefore: true, afterSign: ltr,
            translation: CGPoint(x: -3, y: 0), velocity: CGPoint(x: -383, y: 261)
        ))
    }

    @Test("last page: a clear drag back still turns back")
    func lastPageBackDragPasses() {
        #expect(!ReaderCurlBoundaryGate.blocks(
            hasAfter: false, hasBefore: true, afterSign: ltr,
            translation: CGPoint(x: 4, y: 1), velocity: CGPoint(x: 420, y: 60)
        ))
    }

    @Test("last page: velocity back but translation already toward the missing side is stopped")
    func lastPageWobbleStopped() {
        #expect(ReaderCurlBoundaryGate.blocks(
            hasAfter: false, hasBefore: true, afterSign: ltr,
            translation: CGPoint(x: -6, y: 0), velocity: CGPoint(x: 300, y: 0)
        ))
    }

    @Test("last page: a mostly vertical drag back is stopped")
    func lastPageVerticalDragStopped() {
        #expect(ReaderCurlBoundaryGate.blocks(
            hasAfter: false, hasBefore: true, afterSign: ltr,
            translation: CGPoint(x: 1, y: 8), velocity: CGPoint(x: 120, y: 400)
        ))
    }

    @Test("first page: a clear drag forward still turns forward")
    func firstPageForwardDragPasses() {
        #expect(!ReaderCurlBoundaryGate.blocks(
            hasAfter: true, hasBefore: false, afterSign: ltr,
            translation: CGPoint(x: -4, y: 0), velocity: CGPoint(x: -500, y: 30)
        ))
    }

    @Test("right-to-left interface: a rightward drag is 'after'")
    func rightToLeftInterfaceFlipsSides() {
        let rtl: CGFloat = 1
        #expect(!ReaderCurlBoundaryGate.blocks(
            hasAfter: false, hasBefore: true, afterSign: rtl,
            translation: CGPoint(x: -4, y: 0), velocity: CGPoint(x: -420, y: 0)
        ))
        #expect(ReaderCurlBoundaryGate.blocks(
            hasAfter: false, hasBefore: true, afterSign: rtl,
            translation: CGPoint(x: 4, y: 0), velocity: CGPoint(x: 420, y: 0)
        ))
    }

    @Test("a page with no neighbour at all is always stopped")
    func loneOrUnmeasuredPageStopped() {
        #expect(ReaderCurlBoundaryGate.blocks(
            hasAfter: false, hasBefore: false, afterSign: ltr,
            translation: CGPoint(x: 5, y: 0), velocity: CGPoint(x: 500, y: 0)
        ))
    }
}
