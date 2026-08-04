import Foundation

enum ReaderPageTransitionDecision: Equatable {
    case ignore
    case startImmediately
    case deferUntilCurrentTransitionFinishes
}

struct ReaderPageTransitionQueue {
    private(set) var isTransitioning = false
    private(set) var queuedPage: Int?
    /// Where the transition currently running is headed. The queued target was
    /// computed against the page indexing that was live when the tap landed, so
    /// replaying it needs this to recover the *offset* the user actually asked
    /// for — see `transitionFinished(showing:)`. `nil` for interactive turns,
    /// whose destination isn't known until the gesture settles.
    private var inFlightTarget: Int?
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
                inFlightTarget = nil
            }
        }

        if isTransitioning {
            queuedPage = targetPage
            return .deferUntilCurrentTransitionFinishes
        }
        isTransitioning = true
        inFlightTarget = targetPage
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
        inFlightTarget = nil
        transitionStartTime = CFAbsoluteTimeGetCurrent()
    }

    /// - Parameter visiblePage: the page that actually settled, resolved from the
    ///   shown page's reading position — not the index the transition aimed at.
    mutating func transitionFinished(showing visiblePage: Int) -> Int? {
        guard let queuedPage else {
            disarm()
            return nil
        }
        // Re-anchor the queued turn on the page that really settled. A global page
        // index is only meaningful against the pagination that produced it, and a
        // chapter's layout landing mid-transition renumbers every page after it
        // (the project-wide rule: positions are (spineIndex, charOffset), never a
        // global page index). Replaying the stored absolute index after such a
        // shift turns to a page the user never asked for — the chapter-boundary
        // "jumped one page too far" report. What survives the renumbering is the
        // offset between the queued target and the destination it was queued
        // behind, so carry that instead. With no shift `visiblePage ==
        // inFlightTarget` and this resolves to `queuedPage`, exactly as before.
        let resolvedPage: Int
        if let inFlightTarget {
            resolvedPage = visiblePage + (queuedPage - inFlightTarget)
        } else {
            // Interactive turn: nothing knew where it was headed, so the absolute
            // target is all we have. Remove this branch if gesture settles ever
            // start reporting their destination up front.
            resolvedPage = queuedPage
        }
        guard resolvedPage != visiblePage else {
            disarm()
            return nil
        }
        // Atomic handoff: the queued transition starts right away, so stay armed
        // with a fresh clock. Fully disarming here would open a gap where a new
        // request could start a concurrent animated transition (the
        // _UIQueuingScrollView crash this queue exists to prevent), and would let
        // the intermediate settle's publish overwrite newer accumulated taps.
        self.queuedPage = nil
        inFlightTarget = resolvedPage
        transitionStartTime = CFAbsoluteTimeGetCurrent()
        return resolvedPage
    }

    mutating func reset() {
        disarm()
    }

    private mutating func disarm() {
        isTransitioning = false
        queuedPage = nil
        inFlightTarget = nil
        transitionStartTime = 0
    }
}
