import CoreGraphics

/// Whether a drag on a curl page that lacks a neighbour on one side may reach UIKit's own pan.
///
/// Crashlytics c5efe011 / 658b2c27 / 1e94b6ec, "The number of view controllers provided (0)
/// doesn't match the number required (2)", and Apple's FB14724519 (Apple Books crashes the same
/// way, developer forums thread 761662). UIKit 26.6 through 27.3 checks the curl pair when its
/// pan asks to begin, but a drag whose direction is still undecided at that moment is checked
/// as "before" — which exists on the last page — and the pan's `.began` then re-derives the
/// direction and hands the "after" answer, an empty pair, to the transition unchecked. Nothing
/// on our side can make that answer non-empty at a real book end, so the drag is stopped before
/// UIKit sees it: on a page missing a neighbour, only a drag already clearly heading for the
/// neighbour that exists gets through.
///
/// UIKit reads the direction from velocity first, translation second, and either way only when
/// the horizontal component dominates (`_shouldBeginNavigationInDirection:…` /
/// `_shouldNavigateInDirection:inResponseToVelocity:…`). A drag passed here has a dominant
/// velocity toward the existing side and no translation toward the missing one, so UIKit, which
/// reads the same touch, decides the existing side or nothing — never the missing one. No UIKit
/// threshold is mirrored: a drag this lets through that UIKit finds too slow simply stays
/// undecided and starts later through the count-checked `.changed` path.
///
/// Delete once UIKit checks the pair it builds in `.began` (FB14724519), verified by a
/// diagonal fling on the last page of a book under 仿真 not throwing without this gate.
enum ReaderCurlBoundaryGate {
    /// - Parameters:
    ///   - hasAfter: UIKit's "after" neighbour exists (the data source would not return nil).
    ///   - hasBefore: UIKit's "before" neighbour exists.
    ///   - afterSign: the sign of a horizontal drag UIKit reads as "after": -1 (leftward) in a
    ///     left-to-right interface, +1 in a right-to-left one. The book's own direction and the
    ///     spine do not enter into it; the data source swaps before/after for RTL books.
    /// - Returns: true when the drag must be stopped before UIKit's curl pan begins.
    static func blocks(
        hasAfter: Bool,
        hasBefore: Bool,
        afterSign: CGFloat,
        translation: CGPoint,
        velocity: CGPoint
    ) -> Bool {
        if hasAfter && hasBefore { return false }
        guard hasAfter || hasBefore else { return true }
        let towardExisting: CGFloat = hasAfter ? afterSign : -afterSign
        let velocityHeadsThere = velocity.x * towardExisting > 0 && abs(velocity.x) > abs(velocity.y)
        let translationNeverLeft = translation.x * towardExisting >= 0
        return !(velocityHeadsThere && translationNeverLeft)
    }
}
