import UIKit

// MARK: - Webtoon layout
//
// Vertical, full-width, variable-height layout (adapted from Aidoku's
// VerticalContentOffsetPreservingLayout). Supports offset preservation when
// prepending chapters and pillarboxing for wide/iPad screens.

final class FixedPageWebtoonLayout: UICollectionViewFlowLayout {

    private let defaultRatio: CGFloat = 1.435
    /// Measured height/width of each item's image, by item index. Indices move when a
    /// chapter is prepended, so `insertItemsAtStart(_:)` moves these with them: a ratio
    /// left at its old index sizes a different page by it, and that page's image is then
    /// drawn aspect-fit inside the wrong frame (narrower than the strip, or with bands).
    private var ratios: [Int: CGFloat] = [:]
    private var currentAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var computedContentSize: CGSize = .zero
    private let fixedPageReaderConfiguration: FixedPageReaderConfiguration
    /// Items inserted at the start since the last `prepare()`: maps the previous pass's
    /// item indices onto the current ones for the scroll anchor.
    private var pendingInsertedAtStart = 0
    /// The zoom the previous pass laid out at. A pass that changes it leaves the offset
    /// to the zoom code, which places it around the pinch itself.
    private var preparedZoomScale: CGFloat = 1

    /// Pinch and double-tap zoom: every page and every gap between pages scales by this,
    /// so the content grows in both directions and a zoomed strip scrolls sideways
    /// natively. Pages get larger frames rather than a transform, which keeps hit
    /// testing and the visible-page lookups in the same coordinates as what is drawn.
    var zoomScale: CGFloat = 1

    init(fixedPageReaderConfiguration: FixedPageReaderConfiguration) {
        self.fixedPageReaderConfiguration = fixedPageReaderConfiguration
        super.init()
        scrollDirection = .vertical
        minimumInteritemSpacing = 0
        minimumLineSpacing = fixedPageReaderConfiguration.pageSpacing
        sectionInset = .zero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Forget every measured height, for a strip whose pages were all replaced. The
    /// previous frames go too, so the next pass has no anchor from the old strip.
    func clearRatios() {
        ratios = [:]
        currentAttributes = [:]
        pendingInsertedAtStart = 0
    }

    func setRatio(_ ratio: CGFloat, forItem index: Int) {
        guard ratio > 0, ratios[index] != ratio else { return }
        ratios[index] = ratio
    }

    /// `count` items were inserted before item 0 (a previous chapter prepended). Measured
    /// heights follow their pages to the new indices, and the next pass keeps the page on
    /// screen where it is.
    func insertItemsAtStart(_ count: Int) {
        guard count > 0 else { return }
        ratios = Dictionary(uniqueKeysWithValues: ratios.map { ($0.key + count, $0.value) })
        pendingInsertedAtStart += count
    }

    private func height(for index: Int, width: CGFloat) -> CGFloat {
        width * (ratios[index] ?? defaultRatio)
    }

    /// The item the reader's eye is held to across a relayout, and how far below the
    /// top of the viewport it starts: the first item starting at or below the top edge,
    /// or the one covering the whole viewport. An item above it — prepended, or one whose
    /// image just loaded and changed its height — then grows upwards, out of view,
    /// instead of pushing what is being read down the screen. Aidoku's webtoon layout
    /// does the same for cells above the offset.
    private struct ScrollAnchor {
        let item: Int
        let distanceFromTop: CGFloat
    }

    private func scrollAnchor(in collectionView: UICollectionView) -> ScrollAnchor? {
        guard !currentAttributes.isEmpty else { return nil }
        let top = collectionView.contentOffset.y
        let bottom = top + collectionView.bounds.height
        var startingBelowTop: UICollectionViewLayoutAttributes?
        var coveringTop: UICollectionViewLayoutAttributes?
        for attributes in currentAttributes.values {
            let frame = attributes.frame
            if frame.minY >= top, frame.minY < bottom {
                if startingBelowTop.map({ frame.minY < $0.frame.minY }) ?? true {
                    startingBelowTop = attributes
                }
            } else if frame.minY < top, frame.maxY > top {
                coveringTop = attributes
            }
        }
        guard let anchor = startingBelowTop ?? coveringTop else { return nil }
        return ScrollAnchor(
            item: anchor.indexPath.item + pendingInsertedAtStart,
            distanceFromTop: anchor.frame.minY - top
        )
    }

    override var collectionViewContentSize: CGSize { computedContentSize }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let scale = zoomScale
        let anchor = scale == preparedZoomScale ? scrollAnchor(in: collectionView) : nil
        pendingInsertedAtStart = 0
        preparedZoomScale = scale
        currentAttributes = [:]

        let totalWidth = collectionView.bounds.width
        let effectiveWidth = fixedPageReaderConfiguration.pillarbox
            ? min(totalWidth, max(200, totalWidth * fixedPageReaderConfiguration.pillarboxAmount))
            : totalWidth
        let originX = (totalWidth - effectiveWidth) / 2

        var originY: CGFloat = 0
        let count = collectionView.numberOfItems(inSection: 0)
        for item in 0..<count {
            let indexPath = IndexPath(item: item, section: 0)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            let h = height(for: item, width: effectiveWidth)
            attributes.frame = CGRect(
                x: originX * scale,
                y: originY * scale,
                width: effectiveWidth * scale,
                height: h * scale
            )
            currentAttributes[indexPath] = attributes
            originY += h + minimumLineSpacing
        }
        computedContentSize = CGSize(
            width: totalWidth * scale,
            height: max(0, originY - minimumLineSpacing) * scale
        )

        // Keep the anchor item where it was on screen.
        if let anchor, let frame = currentAttributes[IndexPath(item: anchor.item, section: 0)]?.frame {
            let maxY = max(0, computedContentSize.height - collectionView.bounds.height)
            let y = min(max(0, frame.minY - anchor.distanceFromTop), maxY)
            if abs(y - collectionView.contentOffset.y) > 0.5 {
                UIView.performWithoutAnimation {
                    collectionView.contentOffset.y = y
                }
            }
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        currentAttributes[indexPath]
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        currentAttributes.values.filter { rect.intersects($0.frame) }
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}
