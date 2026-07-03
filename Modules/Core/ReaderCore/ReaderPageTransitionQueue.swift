import Foundation

enum ReaderPageTransitionDecision: Equatable {
    case ignore
    case startImmediately
    case deferUntilCurrentTransitionFinishes
}

struct ReaderPageTransitionQueue {
    private(set) var isTransitioning = false
    private(set) var queuedPage: Int?
    private var transitionStartTime: CFAbsoluteTime = 0

    private static let watchdogTimeout: CFAbsoluteTime = 2.5

    mutating func requestTransition(to targetPage: Int, visiblePage: Int) -> ReaderPageTransitionDecision {
        guard targetPage != visiblePage else { return .ignore }

        // Check watchdog: if a transition has been stuck for too long, force-unstick it.
        if isTransitioning {
            let elapsed = CFAbsoluteTimeGetCurrent() - transitionStartTime
            if elapsed >= Self.watchdogTimeout {
                AppLogger.render("⟐ pageTurn watchdog fired after \(String(format: "%.1f", elapsed))s — forcing settle")
                isTransitioning = false
                queuedPage = nil
            }
        }

        if isTransitioning {
            queuedPage = targetPage
            return .deferUntilCurrentTransitionFinishes
        }
        isTransitioning = true
        transitionStartTime = CFAbsoluteTimeGetCurrent()
        return .startImmediately
    }

    mutating func beginInteractiveTransition() {
        if isTransitioning {
            // Watchdog: a stuck transition (dropped completion) must not block
            // new interactive gestures forever. Under the timeout, ignore the
            // begin and keep the original clock; past it, log and re-arm below.
            let elapsed = CFAbsoluteTimeGetCurrent() - transitionStartTime
            guard elapsed >= Self.watchdogTimeout else { return }
            AppLogger.render("⟐ pageTurn watchdog fired during interactive begin after \(String(format: "%.1f", elapsed))s")
        }
        isTransitioning = true
        transitionStartTime = CFAbsoluteTimeGetCurrent()
    }

    mutating func transitionFinished(showing visiblePage: Int) -> Int? {
        isTransitioning = false
        transitionStartTime = 0
        guard let queuedPage else { return nil }
        self.queuedPage = nil
        guard queuedPage != visiblePage else { return nil }
        return queuedPage
    }

    mutating func reset() {
        isTransitioning = false
        queuedPage = nil
        transitionStartTime = 0
    }
}
