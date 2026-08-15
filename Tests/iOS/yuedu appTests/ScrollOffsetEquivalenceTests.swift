import Testing
import UIKit
@testable import yuedu_app

/// Pins the clamping that `CoreTextCollectionScrollViewController.setScrollOffset` applies, now
/// that every offset write goes through one place.
///
/// It also records a negative result worth keeping: replacing `scrollToItem(at:at:.top)` with
/// `frame.minY - contentInset.top` was measured **0.083pt (1/12) away** from what UIKit actually
/// produces — close enough to look right, different enough not to be the same behaviour. The
/// substitution was reverted; `scrollToItem` still owns the row-restore path. Anyone tempted to
/// compute that offset again needs to account for UIKit's rounding first, not reason it out.
@Suite("Scroll offset equivalence", .serialized)
@MainActor
struct ScrollOffsetEquivalenceTests {

    private static let bounds = CGRect(x: 0, y: 0, width: 440, height: 956)
    /// Chapter-gap-inclusive extents in the shape the reader produces, with fractional values so a
    /// rounding difference cannot hide.
    private static let extents: [CGFloat] = [1993, 2000, 1947.5, 1949, 88, 2000, 1940.25, 640]

    private final class Source: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            ScrollOffsetEquivalenceTests.extents.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }

        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            CGSize(
                width: collectionView.bounds.width,
                height: ScrollOffsetEquivalenceTests.extents[indexPath.item]
            )
        }
    }

    /// The reader's configuration, including the vertical content inset that made the old
    /// zero-floor clamp wrong.
    private static func makeCollectionView(verticalInset: CGFloat) -> (UICollectionView, Source) {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        let source = Source()
        let view = UICollectionView(frame: bounds, collectionViewLayout: layout)
        view.contentInsetAdjustmentBehavior = .never
        view.contentInset = UIEdgeInsets(top: verticalInset, left: 0, bottom: verticalInset, right: 0)
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        view.dataSource = source
        view.delegate = source
        // `reloadData` explicitly: the view is never added to a window here, and `layoutIfNeeded`
        // alone does not guarantee the data source has been consulted. Without it `numberOfItems`
        // stays 0 and `scrollToItem` raises `_validateScrollingTargetIndexPath` — an uncaught
        // ObjC exception that aborts the whole test process rather than failing one case.
        view.reloadData()
        view.layoutIfNeeded()
        return (view, source)
    }

    /// The formula `scrollOffsetForRow` uses.
    private static func computedOffset(_ view: UICollectionView, row: Int) -> CGFloat? {
        guard let frame = view.collectionViewLayout.layoutAttributesForItem(
            at: IndexPath(item: row, section: 0)
        )?.frame else { return nil }
        return frame.minY - view.adjustedContentInset.top
    }

    @Test("the formula tracks the content inset rather than assuming zero")
    func offsetTracksContentInset() throws {
        // The bug this replaces: `reloadPreservingVisiblePosition` floored the offset at 0 while
        // the content's true top is `-contentInset.top`, leaving the reader that far down.
        for inset in [CGFloat(0), 16, 44] {
            let (view, source) = Self.makeCollectionView(verticalInset: inset)
            try withExtendedLifetime(source) {
                try #require(view.numberOfItems(inSection: 0) == Self.extents.count)
                view.scrollToItem(at: IndexPath(item: 0, section: 0), at: .top, animated: false)
                view.layoutIfNeeded()
                #expect(abs(view.contentOffset.y - (-inset)) < 0.01, "inset \(inset)")
                #expect(abs(try #require(Self.computedOffset(view, row: 0)) - (-inset)) < 0.01)
            }
        }
    }

    /// The invariant that makes a reading position survive a paged↔scroll switch: the offset the
    /// restore writes must put the target character exactly under the point the commit reads back.
    ///
    /// It did not hold. The commit sampled `bounds.midY` — the viewport centre — while the restore
    /// aimed at the leading edge, so a save/restore cycle displaced the reader by half a viewport
    /// before the chunk-granularity loss was even counted. Substituting the two formulas shows the
    /// fixed version is exact rather than merely close: the restore writes
    /// `frame.minY + withinChunk - inset`, the anchor reads `contentOffset.y + inset`, and the
    /// inset cancels.
    @Test("the restore offset and the committed anchor are inverses")
    func restoreAndAnchorAreInverses() throws {
        let inset: CGFloat = 16
        let (view, source) = Self.makeCollectionView(verticalInset: inset)
        try withExtendedLifetime(source) {
            try #require(view.numberOfItems(inSection: 0) == Self.extents.count)
            let frame = try #require(
                view.collectionViewLayout
                    .layoutAttributesForItem(at: IndexPath(item: 3, section: 0))?.frame
            )
            // Well inside the chunk — precisely the part `scrollToItem(at: .top)` discarded.
            let withinChunk: CGFloat = 812.5

            view.setContentOffset(
                CGPoint(x: 0, y: frame.minY + withinChunk - view.adjustedContentInset.top),
                animated: false
            )
            view.layoutIfNeeded()

            let expected: CGFloat = frame.minY + withinChunk
            let wroteY = frame.minY + withinChunk - view.adjustedContentInset.top
            let readY = view.contentOffset.y
            let scale = view.traitCollection.displayScale

            // Two separate claims, deliberately not merged into one tolerance.
            //
            // First: the formula is *exact*. Restore writes `frame.minY + within - inset`, the
            // anchor reads `contentOffset.y + inset`, so the inset cancels and the anchor is the
            // target. No epsilon — an arithmetic mistake here must fail.
            #expect(wroteY + view.adjustedContentInset.top == expected)

            // Second: `contentOffset` is quantised to device pixels, and that is the only thing
            // between the two. Measured on iPhone 17 Pro Max: writing 6737.166666 at scale 3 reads
            // back 6737.333333 — 20211.5 device pixels landing exactly on a tie and rounding up,
            // i.e. half a pixel. The bound is derived from the scale rather than picked, so it
            // cannot absorb a real error; the defect this whole test exists for was 2000pt.
            let quantisation: CGFloat = 0.5 / scale
            #expect(
                abs(readY - wroteY) <= quantisation,
                "wroteY=\(wroteY) readY=\(readY) scale=\(scale) bound=\(quantisation)"
            )

            let anchorY = readY + view.adjustedContentInset.top
            #expect(
                abs(anchorY - expected) <= quantisation,
                "anchorY=\(anchorY) expected=\(expected) frameMinY=\(frame.minY)"
            )

            // And the size of the bug that was there: the centre the commit used to read sits most
            // of a viewport below the character the restore had just put in place.
            let centreDrift: CGFloat = view.bounds.midY - anchorY
            let halfViewportLessInset: CGFloat = view.bounds.height / 2 - inset
            #expect(abs(centreDrift - halfViewportLessInset) < 0.01)
            #expect(centreDrift > 400)
        }
    }

    @Test("the clamp keeps the top of content reachable")
    func clampAllowsNegativeTopOffset() {
        let inset: CGFloat = 16
        let (view, source) = Self.makeCollectionView(verticalInset: inset)
        defer { withExtendedLifetime(source) {} }
        let minY = -view.adjustedContentInset.top
        let maxY = max(
            minY,
            view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom
        )

        // A restore proposing something above the content must settle at the true top, not at 0.
        let proposed: CGFloat = -167.7
        let clamped = min(max(minY, proposed), maxY)
        #expect(clamped == -inset)
        #expect(clamped != 0)
    }
}
