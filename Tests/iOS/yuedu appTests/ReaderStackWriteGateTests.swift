import Testing
@testable import yuedu_app

@Suite("ReaderStackWriteGate")
struct ReaderStackWriteGateTests {

    @Test func idleGateWritesImmediately() {
        var gate = ReaderStackWriteGate()
        #expect(!gate.isBusy)
        #expect(gate.request(.chapterReady) == .performNow)
        #expect(!gate.hasPendingWrites)
        #expect(gate.drain() == nil)
    }

    @Test func gestureDefersEveryWrite() {
        var gate = ReaderStackWriteGate()
        gate.beginGesture()

        #expect(gate.request(.chapterReady) == .deferred)
        #expect(gate.request(.externalTarget) == .deferred)
        #expect(gate.request(.link(page: 7)) == .deferred)
        // Still owned by UIKit — nothing may be replayed yet.
        #expect(gate.drain() == nil)

        gate.endGesture()
        #expect(gate.drain() == .externalTarget)
    }

    @Test func animatedTransitionDefersWrites() {
        var gate = ReaderStackWriteGate()
        gate.beginTransition()
        #expect(gate.isBusy)
        #expect(gate.request(.chapterReady) == .deferred)

        gate.endTransition()
        #expect(!gate.isBusy)
        #expect(gate.drain() == .chapterReady)
    }

    /// A queued page-turn burst hands off from one transition straight into the
    /// next. The gate must stay closed across the whole burst, not reopen between
    /// the hand-offs.
    @Test func nestedTransitionsKeepTheGateClosedUntilTheLastOneFinishes() {
        var gate = ReaderStackWriteGate()
        gate.beginTransition()
        gate.beginTransition()
        #expect(gate.request(.chapterReady) == .deferred)

        gate.endTransition()
        #expect(gate.isBusy)
        #expect(gate.drain() == nil)

        gate.endTransition()
        #expect(!gate.isBusy)
        #expect(gate.drain() == .chapterReady)
    }

    @Test func gestureAndTransitionMustBothClearBeforeADrain() {
        var gate = ReaderStackWriteGate()
        gate.beginGesture()
        gate.beginTransition()
        #expect(gate.request(.chapterReady) == .deferred)

        gate.endGesture()
        #expect(gate.drain() == nil, "an animation still owns the stack")

        gate.endTransition()
        #expect(gate.drain() == .chapterReady)
    }

    /// At most one write per drain: two back-to-back `setViewControllers` calls are
    /// exactly the hazard this type exists to prevent.
    @Test func drainYieldsAtMostOneWriteAndClearsTheRest() {
        var gate = ReaderStackWriteGate()
        gate.beginGesture()
        _ = gate.request(.chapterReady)
        _ = gate.request(.externalTarget)
        gate.endGesture()

        #expect(gate.drain() == .externalTarget)
        #expect(gate.drain() == nil)
        #expect(!gate.hasPendingWrites)
    }

    /// Priority, not arrival order — so the outcome can't depend on which UIKit
    /// callback happened to fire first.
    @Test func externalTargetOutranksChapterReadyRegardlessOfOrder() {
        var first = ReaderStackWriteGate()
        first.beginGesture()
        _ = first.request(.externalTarget)
        _ = first.request(.chapterReady)
        first.endGesture()
        #expect(first.drain() == .externalTarget)

        var second = ReaderStackWriteGate()
        second.beginGesture()
        _ = second.request(.chapterReady)
        _ = second.request(.externalTarget)
        second.endGesture()
        #expect(second.drain() == .externalTarget)
    }

    @Test func repeatedWritesOfOneKindCollapseToTheNewest() {
        var gate = ReaderStackWriteGate()
        gate.beginGesture()
        _ = gate.request(.link(page: 3))
        _ = gate.request(.link(page: 9))
        gate.endGesture()

        #expect(gate.drain() == .link(page: 9))
        #expect(gate.drain() == nil)
    }

    @Test func unbalancedEndTransitionDoesNotUnderflow() {
        var gate = ReaderStackWriteGate()
        gate.endTransition()
        gate.endTransition()
        #expect(!gate.isBusy)
        #expect(gate.request(.chapterReady) == .performNow)
    }

    @Test func resetClearsOwnershipAndPendingWrites() {
        var gate = ReaderStackWriteGate()
        gate.beginGesture()
        gate.beginTransition()
        _ = gate.request(.externalTarget)

        gate.reset()

        #expect(!gate.isBusy)
        #expect(!gate.hasPendingWrites)
        #expect(gate.drain() == nil)
    }

    @Test func cancelPendingWritesKeepsOwnershipButDropsTheBacklog() {
        var gate = ReaderStackWriteGate()
        gate.beginGesture()
        _ = gate.request(.chapterReady)
        gate.cancelPendingWrites()
        gate.endGesture()

        #expect(gate.drain() == nil)
    }
}
