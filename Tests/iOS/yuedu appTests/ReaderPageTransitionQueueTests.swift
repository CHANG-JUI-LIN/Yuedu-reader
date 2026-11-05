import Testing
@testable import yuedu_app

struct ReaderPageTransitionQueueTests {

    @Test("queues the latest target while a page turn is still animating")
    func queuesLatestTargetDuringTransition() {
        var queue = ReaderPageTransitionQueue()

        let firstDecision = queue.requestTransition(to: .page(11), visible: .page(10))
        #expect(firstDecision == .startImmediately)
        #expect(queue.isTransitioning)

        let secondDecision = queue.requestTransition(to: .page(12), visible: .page(10))
        #expect(secondDecision == .deferUntilCurrentTransitionFinishes)
        #expect(queue.queued == .page(12))

        let followUp = queue.transitionFinished(showing: .page(11))
        #expect(followUp == .page(12))
        #expect(queue.isTransitioning)

        let finalFollowUp = queue.transitionFinished(showing: .page(12))
        #expect(finalFollowUp == nil)
        #expect(!queue.isTransitioning)
    }

    /// A tap steps from where every accepted turn ends, so a burst adds a page per tap.
    @Test("a tap steps from the queued turn, else the turn on screen, else the page")
    func destinationIsWhereAcceptedTurnsEnd() {
        var queue = ReaderPageTransitionQueue()
        #expect(queue.destination == nil)

        #expect(queue.requestTransition(to: .page(11), visible: .page(10)) == .startImmediately)
        #expect(queue.destination == .page(11))
        #expect(queue.requestTransition(to: .page(12), visible: .page(10)) == .deferUntilCurrentTransitionFinishes)
        #expect(queue.destination == .page(12))

        #expect(queue.transitionFinished(showing: .page(11)) == .page(12))
        #expect(queue.destination == .page(12))
        #expect(queue.transitionFinished(showing: .page(12)) == nil)
        #expect(queue.destination == nil)

        // A swipe whose far side is still paginating has no known destination.
        queue.beginInteractiveTransition()
        #expect(queue.destination == nil)
    }

    @Test("drops a queued target that matches the settled page")
    func ignoresQueuedTargetMatchingSettledPage() {
        var queue = ReaderPageTransitionQueue()

        #expect(queue.requestTransition(to: .page(11), visible: .page(10)) == .startImmediately)
        #expect(queue.requestTransition(to: .page(11), visible: .page(10)) == .deferUntilCurrentTransitionFinishes)

        let followUp = queue.transitionFinished(showing: .page(11))
        #expect(followUp == nil)
        #expect(queue.queued == nil)
    }

    /// A queued target is a global page index, and a global page index only means
    /// what the pagination that produced it says. When the next chapter's layout
    /// lands while the boundary turn is still animating, every page after it is
    /// renumbered, and replaying the stored index turns to a page the user never
    /// asked for. The offset behind the in-flight destination is what survives.
    @Test("a queued turn follows the page that really settled, not its stale index")
    func queuedTargetRebasesOntoTheSettledPage() {
        var queue = ReaderPageTransitionQueue()

        #expect(queue.requestTransition(to: .page(41), visible: .page(40)) == .startImmediately)
        #expect(queue.requestTransition(to: .page(42), visible: .page(40)) == .deferUntilCurrentTransitionFinishes)

        // The chapter's real layout replaced the placeholder mid-transition: the
        // page the turn aimed at as 41 settled as 45.
        let followUp = queue.transitionFinished(showing: .page(45))
        #expect(followUp == .page(46))
    }

    @Test("a rebased queued turn that lands on the settled page is dropped")
    func rebasedQueuedTargetMatchingSettledPageIsDropped() {
        var queue = ReaderPageTransitionQueue()

        #expect(queue.requestTransition(to: .page(41), visible: .page(40)) == .startImmediately)
        #expect(queue.requestTransition(to: .page(41), visible: .page(40)) == .deferUntilCurrentTransitionFinishes)

        #expect(queue.transitionFinished(showing: .page(45)) == nil)
        #expect(queue.queued == nil)
        #expect(!queue.isTransitioning)
    }

    @Test("each chained hand-off re-anchors on its own settled page")
    func chainedHandoffRebasesAgain() {
        var queue = ReaderPageTransitionQueue()

        #expect(queue.requestTransition(to: .page(11), visible: .page(10)) == .startImmediately)
        #expect(queue.requestTransition(to: .page(13), visible: .page(10)) == .deferUntilCurrentTransitionFinishes)
        #expect(queue.transitionFinished(showing: .page(11)) == .page(13))

        // The hand-off is now the in-flight turn; a further tap queues behind it
        // and rebases onto whatever that hand-off settles as.
        #expect(queue.requestTransition(to: .page(14), visible: .page(11)) == .deferUntilCurrentTransitionFinishes)
        #expect(queue.transitionFinished(showing: .page(15)) == .page(16))
    }

    @Test("interactive transitions share the same in-flight queue")
    func interactiveTransitionsQueueLatestProgrammaticTarget() {
        var queue = ReaderPageTransitionQueue()

        queue.beginInteractiveTransition()
        #expect(queue.isTransitioning)

        let decision = queue.requestTransition(to: .page(12), visible: .page(10))
        #expect(decision == .deferUntilCurrentTransitionFinishes)
        #expect(queue.queued == .page(12))

        let followUp = queue.transitionFinished(showing: .page(11))
        #expect(followUp == .page(12))
        #expect(queue.isTransitioning)

        let finalFollowUp = queue.transitionFinished(showing: .page(12))
        #expect(finalFollowUp == nil)
        #expect(!queue.isTransitioning)
    }

    /// A single page's turn is its reading position. A chapter landing while turns
    /// are queued renumbers every page after it; the position is the page itself, so
    /// the queued turn plays to it whatever number it has now.
    @Test("a queued turn named by its position plays to that position after a renumbering")
    func queuedPositionSurvivesRenumbering() {
        var queue = ReaderPageTransitionQueue()
        let shown = ReaderPageTurnTarget(page: 40, position: CoreTextReadingPosition(spineIndex: 3, charOffset: 900))
        let next = ReaderPageTurnTarget(page: 41, position: .chapterStart(4))
        let afterNext = ReaderPageTurnTarget(page: 42, position: CoreTextReadingPosition(spineIndex: 4, charOffset: 310))

        #expect(queue.requestTransition(to: next, visible: shown) == .startImmediately)
        #expect(queue.requestTransition(to: afterNext, visible: shown) == .deferUntilCurrentTransitionFinishes)
        #expect(queue.destination == afterNext)

        // Chapter 4's layout landed mid-turn: its first page is numbered 45 now.
        let settled = ReaderPageTurnTarget(page: 45, position: .chapterStart(4))
        #expect(queue.transitionFinished(showing: settled) == afterNext)
    }

    @Test("a queued position the turn already settled on is dropped, whatever its number")
    func queuedPositionMatchingSettledPageIsDropped() {
        var queue = ReaderPageTransitionQueue()
        let shown = ReaderPageTurnTarget(page: 40, position: CoreTextReadingPosition(spineIndex: 3, charOffset: 900))
        let next = ReaderPageTurnTarget(page: 41, position: .chapterStart(4))

        #expect(queue.requestTransition(to: next, visible: shown) == .startImmediately)
        #expect(queue.requestTransition(to: next, visible: shown) == .deferUntilCurrentTransitionFinishes)
        #expect(queue.transitionFinished(showing: ReaderPageTurnTarget(page: 45, position: .chapterStart(4))) == nil)
        #expect(!queue.isTransitioning)
    }
}
