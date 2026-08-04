import Testing
@testable import yuedu_app

struct ReaderPageTransitionQueueTests {

    @Test("queues the latest target while a page turn is still animating")
    func queuesLatestTargetDuringTransition() {
        var queue = ReaderPageTransitionQueue()

        let firstDecision = queue.requestTransition(to: 11, visiblePage: 10)
        #expect(firstDecision == .startImmediately)
        #expect(queue.isTransitioning)

        let secondDecision = queue.requestTransition(to: 12, visiblePage: 10)
        #expect(secondDecision == .deferUntilCurrentTransitionFinishes)
        #expect(queue.queuedPage == 12)

        let followUp = queue.transitionFinished(showing: 11)
        #expect(followUp == 12)
        #expect(queue.isTransitioning)

        let finalFollowUp = queue.transitionFinished(showing: 12)
        #expect(finalFollowUp == nil)
        #expect(!queue.isTransitioning)
    }

    @Test("drops a queued target that matches the settled page")
    func ignoresQueuedTargetMatchingSettledPage() {
        var queue = ReaderPageTransitionQueue()

        #expect(queue.requestTransition(to: 11, visiblePage: 10) == .startImmediately)
        #expect(queue.requestTransition(to: 11, visiblePage: 10) == .deferUntilCurrentTransitionFinishes)

        let followUp = queue.transitionFinished(showing: 11)
        #expect(followUp == nil)
        #expect(queue.queuedPage == nil)
    }

    /// A queued target is a global page index, and a global page index only means
    /// what the pagination that produced it says. When the next chapter's layout
    /// lands while the boundary turn is still animating, every page after it is
    /// renumbered, and replaying the stored index turns to a page the user never
    /// asked for. The offset behind the in-flight destination is what survives.
    @Test("a queued turn follows the page that really settled, not its stale index")
    func queuedTargetRebasesOntoTheSettledPage() {
        var queue = ReaderPageTransitionQueue()

        #expect(queue.requestTransition(to: 41, visiblePage: 40) == .startImmediately)
        #expect(queue.requestTransition(to: 42, visiblePage: 40) == .deferUntilCurrentTransitionFinishes)

        // The chapter's real layout replaced the placeholder mid-transition: the
        // page the turn aimed at as 41 settled as 45.
        let followUp = queue.transitionFinished(showing: 45)
        #expect(followUp == 46)
    }

    @Test("a rebased queued turn that lands on the settled page is dropped")
    func rebasedQueuedTargetMatchingSettledPageIsDropped() {
        var queue = ReaderPageTransitionQueue()

        #expect(queue.requestTransition(to: 41, visiblePage: 40) == .startImmediately)
        #expect(queue.requestTransition(to: 41, visiblePage: 40) == .deferUntilCurrentTransitionFinishes)

        #expect(queue.transitionFinished(showing: 45) == nil)
        #expect(queue.queuedPage == nil)
        #expect(!queue.isTransitioning)
    }

    @Test("each chained hand-off re-anchors on its own settled page")
    func chainedHandoffRebasesAgain() {
        var queue = ReaderPageTransitionQueue()

        #expect(queue.requestTransition(to: 11, visiblePage: 10) == .startImmediately)
        #expect(queue.requestTransition(to: 13, visiblePage: 10) == .deferUntilCurrentTransitionFinishes)
        #expect(queue.transitionFinished(showing: 11) == 13)

        // The hand-off is now the in-flight turn; a further tap queues behind it
        // and rebases onto whatever that hand-off settles as.
        #expect(queue.requestTransition(to: 14, visiblePage: 11) == .deferUntilCurrentTransitionFinishes)
        #expect(queue.transitionFinished(showing: 15) == 16)
    }

    @Test("interactive transitions share the same in-flight queue")
    func interactiveTransitionsQueueLatestProgrammaticTarget() {
        var queue = ReaderPageTransitionQueue()

        queue.beginInteractiveTransition()
        #expect(queue.isTransitioning)

        let decision = queue.requestTransition(to: 12, visiblePage: 10)
        #expect(decision == .deferUntilCurrentTransitionFinishes)
        #expect(queue.queuedPage == 12)

        let followUp = queue.transitionFinished(showing: 11)
        #expect(followUp == 12)
        #expect(queue.isTransitioning)

        let finalFollowUp = queue.transitionFinished(showing: 12)
        #expect(finalFollowUp == nil)
        #expect(!queue.isTransitioning)
    }
}
