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
}
