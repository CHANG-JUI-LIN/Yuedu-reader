enum ReaderPageTransitionDecision: Equatable {
    case ignore
    case startImmediately
    case deferUntilCurrentTransitionFinishes
}

struct ReaderPageTransitionQueue {
    private(set) var isTransitioning = false
    private(set) var queuedPage: Int?

    mutating func requestTransition(to targetPage: Int, visiblePage: Int) -> ReaderPageTransitionDecision {
        guard targetPage != visiblePage else { return .ignore }
        if isTransitioning {
            queuedPage = targetPage
            return .deferUntilCurrentTransitionFinishes
        }
        isTransitioning = true
        return .startImmediately
    }

    mutating func beginInteractiveTransition() {
        isTransitioning = true
    }

    mutating func transitionFinished(showing visiblePage: Int) -> Int? {
        isTransitioning = false
        guard let queuedPage else { return nil }
        self.queuedPage = nil
        guard queuedPage != visiblePage else { return nil }
        return queuedPage
    }

    mutating func reset() {
        isTransitioning = false
        queuedPage = nil
    }
}
