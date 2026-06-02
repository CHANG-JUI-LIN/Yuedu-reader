import UIKit

// MARK: - Webtoon layout
//
// Vertical, full-width, variable-height layout (adapted from Aidoku's
// VerticalContentOffsetPreservingLayout). Heights come from an owned per-item
// aspect-ratio cache: a placeholder ratio is used until a page image loads, then
// the real ratio is set and the layout invalidated. Within a single chapter the
// item indices are stable, so resizing a not-yet-shown page (always below the
// viewport) never shifts what's on screen.

final class MangaWebtoonLayout: UICollectionViewFlowLayout {

    private let defaultRatio: CGFloat = 1.435
    private var ratios: [Int: CGFloat] = [:]
    private var currentAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var computedContentSize: CGSize = .zero

    override init() {
        super.init()
        scrollDirection = .vertical
        minimumInteritemSpacing = 0
        minimumLineSpacing = 0
        sectionInset = .zero
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func clearRatios() { ratios = [:] }

    func setRatio(_ ratio: CGFloat, forItem index: Int) {
        guard ratio > 0, ratios[index] != ratio else { return }
        ratios[index] = ratio
    }

    private func height(for index: Int, width: CGFloat) -> CGFloat {
        width * (ratios[index] ?? defaultRatio)
    }

    override var collectionViewContentSize: CGSize { computedContentSize }

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        currentAttributes = [:]
        let width = collectionView.bounds.width
        var origin: CGFloat = 0
        let count = collectionView.numberOfItems(inSection: 0)
        for item in 0..<count {
            let indexPath = IndexPath(item: item, section: 0)
            let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
            let h = height(for: item, width: width)
            attributes.frame = CGRect(x: 0, y: origin, width: width, height: h)
            currentAttributes[indexPath] = attributes
            origin += h
        }
        computedContentSize = CGSize(width: width, height: origin)
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
