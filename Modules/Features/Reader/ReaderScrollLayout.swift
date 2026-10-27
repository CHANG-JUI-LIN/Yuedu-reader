import UIKit

/// Single-axis layout for the CoreText scroll reader, replacing `UICollectionViewFlowLayout`.
///
/// The vertical continuous host supplies estimated or measured extents through
/// `extentProvider`. Scrolling changes only the query window; size corrections
/// explicitly invalidate geometry inside the host's character-anchor transaction.
///
/// Chapter gaps are included in each item's extent. Origins preserve the old
/// flow layout's pixel snapping, covered by `ReaderScrollLayoutTests`.
final class ReaderScrollLayout: UICollectionViewLayout {

    enum Axis {
        case vertical
        case horizontalRTL
    }

    var axis: Axis = .vertical {
        didSet {
            guard axis != oldValue else { return }
            invalidateLayout()
        }
    }

    /// Extent of item `i` along the scroll axis, chapter gap included.
    var extentProvider: ((Int) -> CGFloat)?

    private var itemAttributes: [UICollectionViewLayoutAttributes] = []
    /// Where each item's frame actually ends along the scroll axis. Derived from the built frames
    /// rather than from the raw running sum, so the binary search and the frames can never
    /// disagree about a boundary once pixel snapping has moved an origin.
    private var frameEnds: [CGFloat] = []
    private var contentSize: CGSize = .zero
    private var isPrepared = false

    /// Mirrors `CoreTextScrollFlowLayout`, which set this so vertical-RTL reading flips with the
    /// collection view's semantic content attribute instead of being mirrored by hand.
    override var flipsHorizontallyInOppositeLayoutDirection: Bool { true }

    // MARK: - Layout

    override func prepare() {
        super.prepare()
        guard !isPrepared, let collectionView else { return }
        isPrepared = true

        let bounds = collectionView.bounds
        let itemCount = collectionView.numberOfSections > 0
            ? collectionView.numberOfItems(inSection: 0)
            : 0

        itemAttributes.removeAll(keepingCapacity: true)
        itemAttributes.reserveCapacity(itemCount)
        frameEnds.removeAll(keepingCapacity: true)
        frameEnds.reserveCapacity(itemCount)

        let scale = pixelScale(for: collectionView)
        var cursor: CGFloat = 0
        for item in 0..<itemCount {
            let extent = extentProvider?(item) ?? 0
            // Snap the origin, keep the extent exact, and keep accumulating in full precision.
            // This reproduces `UICollectionViewFlowLayout` exactly — verified against it in
            // `ReaderScrollLayoutTests`, where an unsnapped running sum diverged by 1/scale from
            // the third item onward. Cells landing on whole device pixels is what keeps
            // CoreText-drawn text from rendering blurry.
            let origin = Self.snapped(cursor, scale: scale)
            let attributes = UICollectionViewLayoutAttributes(
                forCellWith: IndexPath(item: item, section: 0)
            )
            switch axis {
            case .vertical:
                attributes.frame = CGRect(x: 0, y: origin, width: bounds.width, height: extent)
            case .horizontalRTL:
                attributes.frame = CGRect(x: origin, y: 0, width: extent, height: bounds.height)
            }
            itemAttributes.append(attributes)
            frameEnds.append(origin + extent)
            cursor += extent
        }

        // The raw sum, not the snapped one: flow layout reports the exact total here, and a
        // content size built from rounded origins would drift from it.
        contentSize = switch axis {
        case .vertical: CGSize(width: bounds.width, height: cursor)
        case .horizontalRTL: CGSize(width: cursor, height: bounds.height)
        }
    }

    /// Device pixels per point of the window the reader is in. `displayScale` is 0 in an
    /// unspecified trait environment (a view that has never been in a window): there is no pixel
    /// grid to snap to yet, and the scroll view controller lays the items out again when the
    /// scale arrives (`CoreTextCollectionScrollViewController`, `UITraitDisplayScale`).
    private func pixelScale(for collectionView: UICollectionView) -> CGFloat? {
        let traitScale = collectionView.traitCollection.displayScale
        return traitScale > 0 ? traitScale : nil
    }

    private static func snapped(_ origin: CGFloat, scale: CGFloat?) -> CGFloat {
        guard let scale else { return origin }
        return (origin * scale).rounded(.toNearestOrAwayFromZero) / scale
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        // Any invalidation that touches item counts or sizes has to rebuild the running sum;
        // a bounds-only invalidation still changes the cross-axis dimension of every frame.
        isPrepared = false
        super.invalidateLayout(with: context)
    }

    override func invalidateLayout() {
        isPrepared = false
        super.invalidateLayout()
    }

    override var collectionViewContentSize: CGSize { contentSize }

    /// Apply measured geometry without starting a programmatic scroll. In particular,
    /// setContentOffset(_:animated: false) stops UIKit's native deceleration.
    func commitViewportGeometry(offsetAdjustment: CGPoint, oldSize: CGSize, newSize: CGSize) {
        let context = UICollectionViewLayoutInvalidationContext()
        context.contentOffsetAdjustment = offsetAdjustment
        context.contentSizeAdjustment = CGSize(width: newSize.width - oldSize.width,
                                               height: newSize.height - oldSize.height)
        invalidateLayout(with: context)
    }

    func snappedOrigin(_ origin: CGFloat) -> CGFloat {
        guard let collectionView else { return origin }
        return Self.snapped(origin, scale: pixelScale(for: collectionView))
    }

    override func layoutAttributesForItem(
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, itemAttributes.indices.contains(indexPath.item) else {
            return nil
        }
        // A copy, never the cached instance. `UICollectionViewLayoutAttributes` is a class and
        // UIKit mutates what it is handed — applying update animations, inset adjustments and
        // its own bookkeeping. Vending the cache directly lets those writes land in it, so every
        // later pass reads frames UIKit rewrote. `UICollectionViewFlowLayout` copies for exactly
        // this reason.
        return itemAttributes[indexPath.item].copy() as? UICollectionViewLayoutAttributes
    }

    // MARK: - Batch updates
    //
    // Chapter prepend goes through `insertItems`, during which UIKit asks for each cell's
    // "before" and "after" attributes. Without these overrides the base class has nothing to
    // answer with for items whose index shifted, and cells land at unrelated positions until a
    // later pass corrects them.
    //
    // Both return the item's settled attributes: this reader never animates insertion — it
    // compensates `contentOffset` instead — so an appearing cell should simply be where the new
    // geometry says it is.

    override func initialLayoutAttributesForAppearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        layoutAttributesForItem(at: itemIndexPath)
    }

    override func finalLayoutAttributesForDisappearingItem(
        at itemIndexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        layoutAttributesForItem(at: itemIndexPath)
    }

    override func layoutAttributesForElements(
        in rect: CGRect
    ) -> [UICollectionViewLayoutAttributes]? {
        guard !itemAttributes.isEmpty else { return [] }
        let start = axis == .vertical ? rect.minY : rect.minX
        let end = axis == .vertical ? rect.maxY : rect.maxX

        // Binary search rather than a full scan: this runs on every scroll tick, and the item
        // count grows with every chapter the reader loads.
        var index = firstIndex(endingAfter: start)
        guard index < itemAttributes.count else { return [] }

        var result: [UICollectionViewLayoutAttributes] = []
        while index < itemAttributes.count {
            let frame = itemAttributes[index].frame
            let itemStart = axis == .vertical ? frame.minY : frame.minX
            guard itemStart < end else { break }
            // Copies here too — same reason as `layoutAttributesForItem`.
            if let copy = itemAttributes[index].copy() as? UICollectionViewLayoutAttributes {
                result.append(copy)
            }
            index += 1
        }
        return result
    }

    /// Index of the first item whose frame ends strictly after `position`.
    private func firstIndex(endingAfter position: CGFloat) -> Int {
        var low = 0
        var high = frameEnds.count - 1
        var result = frameEnds.count
        while low <= high {
            let mid = (low + high) / 2
            if frameEnds[mid] > position {
                result = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return result
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        // Items span the full cross axis, so any size change resizes every frame. Scrolling only
        // moves the origin and must not invalidate, or every scroll tick would rebuild the sum.
        guard let collectionView else { return false }
        return collectionView.bounds.size != newBounds.size
    }
}
