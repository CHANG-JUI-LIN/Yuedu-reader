import UIKit

// MARK: - Webtoon layout
//
// Vertical, full-width, variable-height layout (adapted from Aidoku's
// VerticalContentOffsetPreservingLayout). Supports offset preservation when
// prepending chapters and pillarboxing for wide/iPad screens.

final class FixedPageWebtoonLayout: UICollectionViewFlowLayout {

    private let defaultRatio: CGFloat = 1.435
    private var ratios: [Int: CGFloat] = [:]
    private var currentAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]
    private var computedContentSize: CGSize = .zero
    private let fixedPageReaderConfiguration: FixedPageReaderConfiguration

    var isInsertingCellsAbove: Bool = false {
        didSet {
            if isInsertingCellsAbove {
                contentSizeBeforeInsertingAbove = collectionViewContentSize
            }
        }
    }
    private var contentSizeBeforeInsertingAbove: CGSize?

    init(fixedPageReaderConfiguration: FixedPageReaderConfiguration) {
        self.fixedPageReaderConfiguration = fixedPageReaderConfiguration
        super.init()
        scrollDirection = .vertical
        minimumInteritemSpacing = 0
        minimumLineSpacing = fixedPageReaderConfiguration.pageSpacing
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
            attributes.frame = CGRect(x: originX, y: originY, width: effectiveWidth, height: h)
            currentAttributes[indexPath] = attributes
            originY += h + minimumLineSpacing
        }
        computedContentSize = CGSize(width: totalWidth, height: max(0, originY - minimumLineSpacing))

        // Preserve scroll offset when inserting cells above
        if isInsertingCellsAbove, let oldSize = contentSizeBeforeInsertingAbove {
            let newSize = computedContentSize
            let deltaY = newSize.height - oldSize.height
            if deltaY > 0 {
                UIView.performWithoutAnimation {
                    collectionView.contentOffset.y += deltaY
                }
            }
            contentSizeBeforeInsertingAbove = nil
            isInsertingCellsAbove = false
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
