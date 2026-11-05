import Foundation

enum ReaderPageTransitionDecision: Equatable {
    case ignore
    case startImmediately
    case deferUntilCurrentTransitionFinishes
}

/// Where a page turn is headed.
///
/// In single-page modes a turn is named by its reading position: a global page index only
/// means what the pagination that produced it says, and a chapter landing while turns are
/// queued renumbers every page after it. Stepping a queued index on by one walked through
/// chapters that were estimated at one page each because they had not loaded yet — the
/// reader turned past the end of 第20章 and landed on 第23章 (回饋中心 #140). `page` is
/// only today's number for the position, for direction and bookkeeping.
///
/// A spread pairs pages by index, which is what names it, so its turns carry no position
/// (`Technotes/ReaderPagingContract.md`, invariant 1's exception).
struct ReaderPageTurnTarget: Equatable {
    var page: Int
    var position: CoreTextReadingPosition?

    static func page(_ page: Int) -> Self {
        Self(page: page, position: nil)
    }

    /// Whether the two name the same page: by position when both have one, which no
    /// renumbering can change; by index otherwise.
    func isSamePage(as other: Self) -> Bool {
        if let position, let otherPosition = other.position {
            return position == otherPosition
        }
        return page == other.page
    }
}

struct ReaderPageTransitionQueue {
    private(set) var isTransitioning = false
    private(set) var queued: ReaderPageTurnTarget?
    /// Where the transition currently running is headed. A queued spread turn was
    /// computed against the page indexing that was live when the tap landed, so
    /// replaying it needs this to recover the *offset* the user actually asked
    /// for — see `transitionFinished(showing:)`. `nil` for interactive turns
    /// whose destination isn't known until the gesture settles.
    private var inFlightTarget: ReaderPageTurnTarget?
    private var transitionStartTime: CFAbsoluteTime = 0

    private static let watchdogTimeout: CFAbsoluteTime = 2.5

    /// Where the reader ends up once every accepted turn has played: the queued turn,
    /// else the one on screen. A tap steps from here, so a burst of taps accumulates
    /// one page per tap. Nil when idle, during a gesture whose destination isn't known,
    /// and once the watchdog would force-settle a stuck turn — the next request
    /// discards that turn, so stepping from it would skip a page.
    var destination: ReaderPageTurnTarget? {
        guard isTransitioning, !isStuck else { return nil }
        return queued ?? inFlightTarget
    }

    private var isStuck: Bool {
        CFAbsoluteTimeGetCurrent() - transitionStartTime >= Self.watchdogTimeout
    }

    mutating func requestTransition(
        to target: ReaderPageTurnTarget,
        visible: ReaderPageTurnTarget
    ) -> ReaderPageTransitionDecision {
        guard !target.isSamePage(as: visible) else { return .ignore }

        // Check watchdog: if a transition has been stuck for too long, force-unstick it.
        if isTransitioning {
            let elapsed = CFAbsoluteTimeGetCurrent() - transitionStartTime
            if elapsed >= Self.watchdogTimeout {
                AppLogger.render("⟐ pageTurn watchdog fired after \(String(format: "%.1f", elapsed))s — forcing settle")
                isTransitioning = false
                queued = nil
                inFlightTarget = nil
            }
        }

        if isTransitioning {
            queued = target
            return .deferUntilCurrentTransitionFinishes
        }
        isTransitioning = true
        inFlightTarget = target
        transitionStartTime = CFAbsoluteTimeGetCurrent()
        return .startImmediately
    }

    /// - Parameter target: the page the gesture is headed for, when it is known: by
    ///   position in single-page modes, or by an exact index in a spread. Nil
    ///   otherwise — an estimated index would corrupt the re-anchoring in
    ///   `transitionFinished(showing:)` rather than improve it.
    mutating func beginInteractiveTransition(target: ReaderPageTurnTarget? = nil) {
        if isTransitioning {
            // Watchdog: a stuck transition (dropped completion) must not block
            // new interactive gestures forever. Under the timeout, ignore the
            // begin and keep the original clock; past it, log and re-arm below.
            let elapsed = CFAbsoluteTimeGetCurrent() - transitionStartTime
            guard elapsed >= Self.watchdogTimeout else { return }
            AppLogger.render("⟐ pageTurn watchdog fired during interactive begin after \(String(format: "%.1f", elapsed))s")
        }
        isTransitioning = true
        inFlightTarget = target
        transitionStartTime = CFAbsoluteTimeGetCurrent()
    }

    /// - Parameter visible: the page that actually settled, resolved from the shown
    ///   page's reading position — not the index the transition aimed at.
    mutating func transitionFinished(showing visible: ReaderPageTurnTarget) -> ReaderPageTurnTarget? {
        guard let queued else {
            disarm()
            return nil
        }
        let resolved: ReaderPageTurnTarget
        if queued.position != nil {
            // A position is the page itself, whatever the numbering did meanwhile.
            resolved = queued
        } else if let inFlightTarget {
            // A spread turn is an index. A global page index is only meaningful
            // against the pagination that produced it, and a chapter's layout
            // landing mid-transition renumbers every page after it. Replaying the
            // stored absolute index after such a shift turns to a page the user
            // never asked for — the chapter-boundary "jumped one page too far"
            // report. What survives the renumbering is the offset between the
            // queued target and the destination it was queued behind, so carry
            // that instead. With no shift `visible == inFlightTarget` and this
            // resolves to `queued`, exactly as before.
            resolved = .page(visible.page + (queued.page - inFlightTarget.page))
        } else {
            // The turn never reported a destination — an interactive gesture whose
            // far side was still paginating when it began. The absolute target is all
            // we have.
            resolved = queued
        }
        guard !resolved.isSamePage(as: visible) else {
            disarm()
            return nil
        }
        // Atomic handoff: the queued transition starts right away, so stay armed
        // with a fresh clock. Fully disarming here would open a gap where a new
        // request could start a concurrent animated transition (the
        // _UIQueuingScrollView crash this queue exists to prevent), and would let
        // the intermediate settle's publish overwrite newer accumulated taps.
        self.queued = nil
        inFlightTarget = resolved
        transitionStartTime = CFAbsoluteTimeGetCurrent()
        return resolved
    }

    mutating func reset() {
        disarm()
    }

    private mutating func disarm() {
        isTransitioning = false
        queued = nil
        inFlightTarget = nil
        transitionStartTime = 0
    }
}
