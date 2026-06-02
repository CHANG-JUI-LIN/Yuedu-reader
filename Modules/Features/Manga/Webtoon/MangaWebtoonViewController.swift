import UIKit

// MARK: - Webtoon reader (continuous vertical scroll)
//
// Displays one chapter as a continuous vertical list. Over-scrolling past the
// bottom asks for the next chapter; past the top asks for the previous one. Tap
// zones page up/down or toggle the controls.

final class MangaWebtoonViewController: UIViewController, MangaModeReader,
    UICollectionViewDataSource, UICollectionViewDelegate {

    weak var container: MangaReaderContainer?

    private let targetWidth: CGFloat
    private var pages: [MangaPage] = []
    private let layout = MangaWebtoonLayout()
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var currentIndex = 0
    private var didRequestNext = false
    private var didRequestPrev = false

    init(targetWidth: CGFloat) {
        self.targetWidth = targetWidth
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceVertical = true
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(MangaWebtoonCell.self, forCellWithReuseIdentifier: MangaWebtoonCell.reuseID)
        view.addSubview(collectionView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        collectionView.addGestureRecognizer(tap)
    }

    // MARK: MangaModeReader

    func setPages(_ pages: [MangaPage], startPage: Int) {
        self.pages = pages
        didRequestNext = false
        didRequestPrev = false
        layout.clearRatios()
        currentIndex = max(0, min(startPage, max(0, pages.count - 1)))
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        if pages.indices.contains(currentIndex) {
            collectionView.scrollToItem(at: IndexPath(item: currentIndex, section: 0), at: .top, animated: false)
        }
        container?.reader(didMoveToPage: currentIndex, total: pages.count)
    }

    func currentPageIndex() -> Int { currentIndex }

    func goToPage(_ index: Int, animated: Bool) {
        guard pages.indices.contains(index) else { return }
        collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: animated)
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        pages.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: MangaWebtoonCell.reuseID, for: indexPath) as! MangaWebtoonCell
        cell.configure(page: pages[indexPath.item], index: indexPath.item, targetWidth: targetWidth) { [weak self] index, ratio in
            guard let self else { return }
            self.layout.setRatio(ratio, forItem: index)
            self.layout.invalidateLayout()
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? MangaWebtoonCell)?.load()
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? MangaWebtoonCell)?.unload()
    }

    // MARK: Scroll → current page + chapter change on over-scroll

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let midY = scrollView.contentOffset.y + scrollView.bounds.height / 2
        if let indexPath = collectionView.indexPathForItem(at: CGPoint(x: collectionView.bounds.midX, y: midY)),
           indexPath.item != currentIndex {
            currentIndex = indexPath.item
            container?.reader(didMoveToPage: currentIndex, total: pages.count)
        }

        let scrollable = scrollView.contentSize.height > scrollView.bounds.height
        let bottomOverscroll = scrollView.contentOffset.y + scrollView.bounds.height - scrollView.contentSize.height
        if scrollable, bottomOverscroll > 90, !didRequestNext {
            didRequestNext = true
            container?.readerRequestsNextChapter()
        }
        if scrollView.contentOffset.y < -90, !didRequestPrev {
            didRequestPrev = true
            container?.readerRequestsPreviousChapter()
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        let third = view.bounds.height / 3
        let page = view.bounds.height * 0.85
        if point.y < third {
            let target = max(-collectionView.adjustedContentInset.top, collectionView.contentOffset.y - page)
            collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
        } else if point.y > 2 * third {
            let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
            collectionView.setContentOffset(CGPoint(x: 0, y: min(maxY, collectionView.contentOffset.y + page)), animated: true)
        } else {
            container?.readerToggleControls()
        }
    }
}
