import Testing
import UIKit
@testable import yuedu_app

/// Stage 2 of `Technotes/ViewportScrollArchitecture.md`: `ReaderScrollLayout` replaces
/// `UICollectionViewFlowLayout`, and §9 requires it to produce **the same
/// `layoutAttributes`** for the same extents.
///
/// Both layouts are driven by real `UICollectionView` instances rather than compared against
/// hand-computed numbers, so the assertion is against UIKit's actual flow-layout geometry —
/// including anything about it this project did not write down.
@Suite("Reader scroll layout", .serialized)
@MainActor
struct ReaderScrollLayoutTests {

    private static let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)

    /// Extents spanning the shapes the reader actually produces: a tall first chunk, a chapter
    /// gap folded into one item, a short tail, and a couple of near-viewport blocks.
    private static let extents: [CGFloat] = [
        1997, 2000, 431.5, 2000, 2000, 88, 2000, 1204.25, 16, 2000, 640, 2000.75,
    ]

    private final class Source: NSObject, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
        let extents: [CGFloat]
        let axis: CoreTextScrollAxis

        init(extents: [CGFloat], axis: CoreTextScrollAxis) {
            self.extents = extents
            self.axis = axis
        }

        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            extents.count
        }

        func collectionView(
            _ collectionView: UICollectionView,
            cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }

        // Mirrors the production `sizeForItemAt`: full cross axis, extent along the scroll axis.
        func collectionView(
            _ collectionView: UICollectionView,
            layout collectionViewLayout: UICollectionViewLayout,
            sizeForItemAt indexPath: IndexPath
        ) -> CGSize {
            let extent = extents[indexPath.item]
            switch axis {
            case .vertical:
                return CGSize(width: collectionView.bounds.width, height: extent)
            case .horizontalRTL:
                return CGSize(width: extent, height: collectionView.bounds.height)
            }
        }
    }

    /// The production flow-layout configuration, verbatim.
    private static func makeFlowCollectionView(
        axis: CoreTextScrollAxis,
        source: Source
    ) -> UICollectionView {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = axis.collectionScrollDirection
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        let view = UICollectionView(frame: bounds, collectionViewLayout: layout)
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        view.dataSource = source
        view.delegate = source
        view.layoutIfNeeded()
        return view
    }

    private static func makeReaderCollectionView(
        axis: CoreTextScrollAxis,
        source: Source
    ) -> UICollectionView {
        let layout = ReaderScrollLayout()
        layout.axis = axis == .vertical ? .vertical : .horizontalRTL
        layout.extentProvider = { source.extents[$0] }
        let view = UICollectionView(frame: bounds, collectionViewLayout: layout)
        view.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
        view.dataSource = source
        view.delegate = source
        view.layoutIfNeeded()
        return view
    }

    private static func assertEquivalent(axis: CoreTextScrollAxis) throws {
        let flowSource = Source(extents: extents, axis: axis)
        let readerSource = Source(extents: extents, axis: axis)
        let flow = makeFlowCollectionView(axis: axis, source: flowSource)
        let reader = makeReaderCollectionView(axis: axis, source: readerSource)

        #expect(reader.collectionViewLayout.collectionViewContentSize
            == flow.collectionViewLayout.collectionViewContentSize)

        for item in extents.indices {
            let path = IndexPath(item: item, section: 0)
            let expected = try #require(flow.collectionViewLayout.layoutAttributesForItem(at: path))
            let actual = try #require(reader.collectionViewLayout.layoutAttributesForItem(at: path))
            #expect(actual.frame == expected.frame, "item \(item) frame")
        }

        // Out of range must be nil on both, not a zero frame.
        let past = IndexPath(item: extents.count, section: 0)
        #expect(reader.collectionViewLayout.layoutAttributesForItem(at: past) == nil)
    }

    @Test("vertical geometry is identical to flow layout")
    func verticalMatchesFlowLayout() throws {
        try Self.assertEquivalent(axis: .vertical)
    }

    @Test("vertical-RTL geometry is identical to flow layout")
    func verticalRTLMatchesFlowLayout() throws {
        try Self.assertEquivalent(axis: .horizontalRTL)
    }

    @Test("elements in a rect match flow layout's, including at the exact boundary")
    func elementsInRectMatchFlowLayout() throws {
        let flowSource = Source(extents: Self.extents, axis: .vertical)
        let readerSource = Source(extents: Self.extents, axis: .vertical)
        let flow = Self.makeFlowCollectionView(axis: .vertical, source: flowSource)
        let reader = Self.makeReaderCollectionView(axis: .vertical, source: readerSource)

        // Includes offsets that land exactly on an item boundary (1997, 3997), where an
        // off-by-one in the binary search would show up as a missing or extra cell.
        let probes: [CGRect] = [
            CGRect(x: 0, y: 0, width: 390, height: 844),
            CGRect(x: 0, y: 1997, width: 390, height: 844),
            CGRect(x: 0, y: 3997, width: 390, height: 1),
            CGRect(x: 0, y: 4400, width: 390, height: 2000),
            CGRect(x: 0, y: 10_000, width: 390, height: 844),
            CGRect(x: 0, y: 0, width: 390, height: 100_000),
        ]
        for rect in probes {
            let expected = Set(
                (flow.collectionViewLayout.layoutAttributesForElements(in: rect) ?? [])
                    .map(\.indexPath.item)
            )
            let actual = Set(
                (reader.collectionViewLayout.layoutAttributesForElements(in: rect) ?? [])
                    .map(\.indexPath.item)
            )
            #expect(actual == expected, "rect \(rect)")
        }
    }

    @Test("vended attributes are copies, so UIKit cannot write into the cache")
    func vendedAttributesAreCopies() throws {
        let source = Source(extents: Self.extents, axis: .vertical)
        let reader = Self.makeReaderCollectionView(axis: .vertical, source: source)
        let layout = reader.collectionViewLayout
        let path = IndexPath(item: 3, section: 0)

        let first = try #require(layout.layoutAttributesForItem(at: path))
        let second = try #require(layout.layoutAttributesForItem(at: path))
        #expect(first !== second)

        // UIKit mutates the attributes it is handed. If that landed in the cache, the next read
        // would come back wrong — which is what made a restored reading position drift.
        let original = first.frame
        first.frame = CGRect(x: 999, y: 999, width: 9, height: 9)
        let third = try #require(layout.layoutAttributesForItem(at: path))
        #expect(third.frame == original)

        let inRect = try #require(
            layout.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 390, height: 100_000))
        )
        let matching = try #require(inRect.first { $0.indexPath == path })
        #expect(matching.frame == original)
        matching.frame = .zero
        #expect(try #require(layout.layoutAttributesForItem(at: path)).frame == original)
    }

    @Test("appearing and disappearing items report their settled geometry")
    func appearingItemsUseSettledGeometry() throws {
        let source = Source(extents: Self.extents, axis: .vertical)
        let reader = Self.makeReaderCollectionView(axis: .vertical, source: source)
        let layout = try #require(reader.collectionViewLayout as? ReaderScrollLayout)
        let path = IndexPath(item: 4, section: 0)
        let settled = try #require(layout.layoutAttributesForItem(at: path)).frame

        // Chapter prepend goes through `insertItems`; UIKit asks for these during the update, and
        // the reader compensates `contentOffset` rather than animating, so both are the final
        // position.
        #expect(try #require(layout.initialLayoutAttributesForAppearingItem(at: path)).frame == settled)
        #expect(try #require(layout.finalLayoutAttributesForDisappearingItem(at: path)).frame == settled)
    }

    @Test("an empty collection lays out to zero content extent")
    func emptyCollectionIsEmpty() {
        let source = Source(extents: [], axis: .vertical)
        let reader = Self.makeReaderCollectionView(axis: .vertical, source: source)
        #expect(reader.collectionViewLayout.collectionViewContentSize.height == 0)
        #expect(reader.collectionViewLayout.layoutAttributesForElements(in: Self.bounds)?.isEmpty == true)
    }

    @Test("scrolling does not invalidate, but a size change does")
    func invalidationMatchesFlowLayoutTriggers() throws {
        let source = Source(extents: Self.extents, axis: .vertical)
        let reader = Self.makeReaderCollectionView(axis: .vertical, source: source)
        let layout = try #require(reader.collectionViewLayout as? ReaderScrollLayout)

        // Scrolling moves the origin only — invalidating here would rebuild the running sum on
        // every scroll tick.
        var scrolled = reader.bounds
        scrolled.origin.y += 500
        #expect(layout.shouldInvalidateLayout(forBoundsChange: scrolled) == false)

        // Rotation changes the cross axis, which resizes every frame.
        var resized = reader.bounds
        resized.size.width += 100
        #expect(layout.shouldInvalidateLayout(forBoundsChange: resized))
    }

    @Test("content size follows extents after they change and the layout is invalidated")
    func contentSizeFollowsChangedExtents() throws {
        let source = Source(extents: Self.extents, axis: .vertical)
        let reader = Self.makeReaderCollectionView(axis: .vertical, source: source)
        let layout = try #require(reader.collectionViewLayout as? ReaderScrollLayout)
        let before = layout.collectionViewContentSize.height

        // Stage 3 rewrites heights in place after real layout measures a fragment; the layout has
        // to pick the new value up on invalidation rather than caching it forever.
        layout.extentProvider = { _ in 100 }
        layout.invalidateLayout()
        reader.layoutIfNeeded()

        #expect(layout.collectionViewContentSize.height == CGFloat(Self.extents.count) * 100)
        #expect(layout.collectionViewContentSize.height != before)
    }
}
