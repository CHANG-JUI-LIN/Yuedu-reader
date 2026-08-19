import Foundation

/// A non-animated write to `UIPageViewController.setViewControllers`, requested
/// while something else may already own the page stack.
///
/// Cases are ordered by priority, not by arrival: see `ReaderStackWriteGate.drain()`.
enum ReaderStackWrite: Equatable {
    /// A chapter layout landed; re-place the current reading position against it.
    case chapterReady
    /// A tapped in-content link resolved to a page.
    case link(page: Int)
    /// The Navigator handed down a new destination (TOC jump, restore, TTS anchor).
    case externalTarget
}

enum ReaderStackWriteDecision: Equatable {
    case performNow
    case deferred
}

/// Owns the single question "may the page stack be rewritten right now?".
///
/// `setViewControllers` must not run while UIKit owns the page stack — inside a
/// gesture-driven transition, or during an animation we started. On the `.scroll`
/// transition style that backs the slide page turn, a write landing inside
/// `didFinishAnimating` re-seeds `_UIQueuingScrollView` while it is still unwinding
/// the just-finished scroll; the visible page then comes out one further along than
/// the user asked for. The `.pageCurl` style corrupts its front/back/under-page
/// bookkeeping the same way.
///
/// Before this type the reader kept four separate flags for this
/// (`activeCurlTransitionCount`, `hasDeferredChapterReady`,
/// `hasDeferredExternalTarget`, `isTransitioning`), and only the curl page-turn
/// style was wired to all of them — slide got none of the protection and every one
/// of the hazards. One owner, every style.
struct ReaderStackWriteGate {
    /// A UIKit gesture-driven transition is in flight (`willTransitionTo` →
    /// `didFinishAnimating`).
    private(set) var isGestureInProgress = false
    /// An animation we started is in flight. Nested because a queued burst can hand
    /// off from one transition straight into the next.
    private(set) var activeTransitionCount = 0
    private var pendingWrites: [ReaderStackWrite] = []
    private var transitionStartTime: CFAbsoluteTime = 0

    /// A dropped UIKit completion would otherwise leak `activeTransitionCount` and
    /// block every later stack write forever — chapter layouts would land but never
    /// reach the screen. Real transitions finish well inside this budget, so a count
    /// still standing after it is a leak, cleared at the next `beginTransition`.
    private static let watchdogTimeout: CFAbsoluteTime = 2.5

    /// True while UIKit or an animation owns the page stack.
    var isBusy: Bool { isGestureInProgress || activeTransitionCount > 0 }

    var isAnimatingTransition: Bool { activeTransitionCount > 0 }

    var hasPendingWrites: Bool { !pendingWrites.isEmpty }

    // MARK: - Ownership windows

    mutating func beginGesture() {
        isGestureInProgress = true
    }

    mutating func endGesture() {
        isGestureInProgress = false
    }

    mutating func beginTransition() {
        resetTransitionCountIfStale()
        activeTransitionCount += 1
        transitionStartTime = CFAbsoluteTimeGetCurrent()
    }

    mutating func endTransition() {
        guard activeTransitionCount > 0 else { return }
        activeTransitionCount -= 1
        if activeTransitionCount == 0 {
            transitionStartTime = 0
        }
    }

    private mutating func resetTransitionCountIfStale() {
        guard activeTransitionCount > 0,
              CFAbsoluteTimeGetCurrent() - transitionStartTime >= Self.watchdogTimeout
        else { return }
        AppLogger.render("⟐ stackWrite watchdog: resetting leaked transition count=\(activeTransitionCount)")
        activeTransitionCount = 0
    }

    // MARK: - Writes

    /// Records the intent and answers whether the caller may write the stack now.
    /// A `.deferred` write is replayed by `drain()` once the stack is free.
    mutating func request(_ write: ReaderStackWrite) -> ReaderStackWriteDecision {
        guard isBusy else { return .performNow }
        record(write)
        AppLogger.render("[FlipTrace] stackWrite deferred \(write) gesture=\(isGestureInProgress) transitions=\(activeTransitionCount)")
        return .deferred
    }

    /// The single owed write, or nil. At most one write is ever returned per drain:
    /// running two `setViewControllers` calls back to back is the hazard this type
    /// exists to prevent.
    ///
    /// When several kinds are owed the highest-priority one wins rather than the
    /// newest, so the outcome does not depend on callback ordering. `externalTarget`
    /// outranks the rest because it is the only one carrying a destination the user
    /// asked for; `chapterReady` merely re-places the position already showing, and
    /// resolves *through* a pending external target anyway, so dropping it loses
    /// nothing.
    mutating func drain() -> ReaderStackWrite? {
        guard !isBusy else { return nil }
        guard !pendingWrites.isEmpty else { return nil }
        let winner = pendingWrites.max(by: { $0.priority < $1.priority })
        pendingWrites.removeAll()
        return winner
    }

    mutating func cancelPendingWrites() {
        pendingWrites.removeAll()
    }

    mutating func reset() {
        isGestureInProgress = false
        activeTransitionCount = 0
        transitionStartTime = 0
        pendingWrites.removeAll()
    }

    private mutating func record(_ write: ReaderStackWrite) {
        // One slot per kind: a second chapter-ready owes no more work than the first.
        // A link keeps its newest page, matching "latest intent wins" within the kind.
        pendingWrites.removeAll { $0.priority == write.priority }
        pendingWrites.append(write)
    }
}

private extension ReaderStackWrite {
    var priority: Int {
        switch self {
        case .chapterReady: return 0
        case .link: return 1
        case .externalTarget: return 2
        }
    }
}
