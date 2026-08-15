import CoreGraphics
import CoreText
import Foundation

/// Where the reader is looking, expressed so that it survives the geometry changing underneath.
///
/// `Technotes/ViewportScrollArchitecture.md` §4.3 / §8.1. The anchor is a **character offset**,
/// never an index path: chapters get prepended and reloaded, which invalidates indices but never
/// character offsets (see the technote's appendix).
struct ScrollAnchor: Equatable {

    /// Chapter the viewport's leading edge is inside.
    let chapterIndex: Int
    /// Chapter-relative UTF-16 offset of the fragment at the viewport's leading edge.
    let charOffset: CFIndex
    /// Distance from that fragment's leading edge to the viewport's, in points.
    ///
    /// Absolute rather than proportional: the point of the anchor is that the fragment's own top
    /// stays visually still, and a proportional offset would slide the content whenever the
    /// anchored fragment itself was re-measured.
    let distanceIntoFragment: CGFloat
}

/// Converts between a scroll offset and a `ScrollAnchor`, so that a height change can be absorbed
/// without the content appearing to jump.
///
/// This is the mechanism §8.1 calls the highest risk in the migration: once estimated heights are
/// allowed on screen, every fragment that gets re-measured *above* the viewport shifts everything
/// below it. Re-deriving the offset from the anchor after the change is what cancels that shift.
///
/// Pure functions over `FragmentGeometryStore`; no UIKit, no view state, so the invariant is
/// machine-checkable without a device.
@MainActor
enum AnchorCompensator {

    /// The anchor describing what sits at `contentOffset` along the scroll axis.
    ///
    /// Returns `nil` when the offset falls outside the loaded content — the caller has nothing to
    /// preserve in that case, which is different from "preserve position zero".
    static func anchor(
        atScrollOffset contentOffset: CGFloat,
        in store: FragmentGeometryStore
    ) -> ScrollAnchor? {
        var cursor: CGFloat = 0
        for chapter in store.chapterOrder {
            guard let outline = store.outline(for: chapter) else { continue }
            for (index, fragment) in outline.fragments.enumerated() {
                let end = cursor + fragment.height
                // `<` on the trailing edge so a boundary offset anchors to the fragment that
                // starts there, matching what the reader sees at the top of the viewport.
                if contentOffset < end || (index == outline.fragments.count - 1
                    && chapter == store.chapterOrder.last) {
                    return ScrollAnchor(
                        chapterIndex: chapter,
                        charOffset: fragment.charRange.location,
                        distanceIntoFragment: contentOffset - cursor
                    )
                }
                cursor = end
            }
        }
        return nil
    }

    /// The scroll offset that puts `anchor` back where it was.
    ///
    /// Returns `nil` when the anchored text is no longer loaded — evicted, or replaced by a source
    /// change. Callers must not fall back to a stale offset in that case; there is nothing to
    /// restore and forcing a number would scroll the reader somewhere arbitrary.
    static func scrollOffset(
        for anchor: ScrollAnchor,
        in store: FragmentGeometryStore
    ) -> CGFloat? {
        guard let fragment = store.fragmentIndex(
            chapter: anchor.chapterIndex,
            containing: anchor.charOffset
        ),
        let start = store.offsetOfFragment(chapter: anchor.chapterIndex, fragment: fragment)
        else { return nil }
        return start + anchor.distanceIntoFragment
    }

    /// How far the content under `anchor` moved between two states of the geometry.
    ///
    /// Add this to `contentOffset` and the anchored text stays at the same screen position. Zero
    /// when nothing above the anchor changed, which is the common case and costs no adjustment.
    static func compensation(
        for anchor: ScrollAnchor,
        from previousOffset: CGFloat,
        in store: FragmentGeometryStore
    ) -> CGFloat? {
        guard let updated = scrollOffset(for: anchor, in: store) else { return nil }
        return updated - previousOffset
    }
}
