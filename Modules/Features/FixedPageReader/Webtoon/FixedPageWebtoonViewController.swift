import UIKit

// MARK: - Webtoon reader (continuous vertical scroll)
//
// Displays chapters as a continuous vertical list. Features:
// - Multi-chapter seamless infinite scrolling (auto-appends next & prepends previous chapters).
// - CADisplayLink auto-scrolling with touch-pause support.
// - Pinch-to-zoom support for examining comic details.
// - Tap zones for stepping and toggling controls.

final class FixedPageWebtoonViewController: UIViewController, FixedPageModeReader,
    UICollectionViewDataSource, UICollectionViewDelegate {

    weak var container: FixedPageReaderContainer?

    private let fixedPageReaderConfiguration: FixedPageReaderConfiguration
    private let targetWidth: CGFloat
    private var pages: [FixedPage] = []
    private let layout: FixedPageWebtoonLayout
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var currentIndex = 0

    // Auto-scroll state
    private var autoScrollDisplayLink: CADisplayLink?
    private(set) var isAutoScrolling = false
    private var isPausedByTouch = false

    // Infinite scroll loading guards
    private var isLoadingNextChapter = false
    private var isLoadingPrevChapter = false

    // Zoom state
    private var currentZoomScale: CGFloat = 1.0

    init(fixedPageReaderConfiguration: FixedPageReaderConfiguration, targetWidth: CGFloat) {
        self.fixedPageReaderConfiguration = fixedPageReaderConfiguration
        self.targetWidth = targetWidth
        self.layout = FixedPageWebtoonLayout(fixedPageReaderConfiguration: fixedPageReaderConfiguration)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        stopAutoScroll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        collectionView.frame = view.bounds
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.showsVerticalScrollIndicator = false
        collectionView.alwaysBounceVertical = fixedPageReaderConfiguration.layout == .continuousVerticalScroll
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FixedPageWebtoonCell.self, forCellWithReuseIdentifier: FixedPageWebtoonCell.reuseID)
        view.addSubview(collectionView)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        collectionView.addGestureRecognizer(tap)

        if fixedPageReaderConfiguration.isZoomEnabled {
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            collectionView.addGestureRecognizer(pinch)

            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            doubleTap.numberOfTapsRequired = 2
            tap.require(toFail: doubleTap)
            collectionView.addGestureRecognizer(doubleTap)
        }
    }

    // MARK: FixedPageModeReader

    func setPages(_ pages: [FixedPage], startPage: Int) {
        self.pages = pages
        isLoadingNextChapter = false
        isLoadingPrevChapter = false
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

    // MARK: Auto Scroll

    func toggleAutoScroll() {
        if isAutoScrolling {
            stopAutoScroll()
        } else {
            startAutoScroll()
        }
    }

    func startAutoScroll() {
        guard autoScrollDisplayLink == nil else { return }
        isAutoScrolling = true
        isPausedByTouch = false
        let link = CADisplayLink(target: self, selector: #selector(handleAutoScrollTick))
        link.add(to: .main, forMode: .common)
        autoScrollDisplayLink = link
    }

    func stopAutoScroll() {
        autoScrollDisplayLink?.invalidate()
        autoScrollDisplayLink = nil
        isAutoScrolling = false
        isPausedByTouch = false
    }

    @objc private func handleAutoScrollTick() {
        guard isAutoScrolling, !isPausedByTouch else { return }
        let speed = CGFloat(max(1, fixedPageReaderConfiguration.autoScrollSpeed)) * 0.8
        let newOffset = collectionView.contentOffset.y + speed
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)

        if newOffset >= maxOffset {
            collectionView.contentOffset.y = maxOffset
            stopAutoScroll()
            container?.readerRequestsNextChapter()
        } else {
            collectionView.contentOffset.y = newOffset
        }
    }

    // MARK: Pinch & Double-Tap Zoom

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.view != nil else { return }

        if gesture.state == .began || gesture.state == .changed {
            currentZoomScale *= gesture.scale
            currentZoomScale = max(1.0, min(currentZoomScale, 3.5))
            collectionView.transform = CGAffineTransform(scaleX: currentZoomScale, y: currentZoomScale)
            gesture.scale = 1.0
        } else if gesture.state == .ended || gesture.state == .cancelled {
            if currentZoomScale <= 1.05 {
                UIView.animate(withDuration: 0.2) {
                    self.currentZoomScale = 1.0
                    self.collectionView.transform = .identity
                }
            }
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        UIView.animate(withDuration: 0.25) {
            if self.currentZoomScale > 1.05 {
                self.currentZoomScale = 1.0
                self.collectionView.transform = .identity
            } else {
                self.currentZoomScale = 2.0
                self.collectionView.transform = CGAffineTransform(scaleX: 2.0, y: 2.0)
            }
        }
    }

    // MARK: Data source

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        pages.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: FixedPageWebtoonCell.reuseID, for: indexPath) as! FixedPageWebtoonCell
        cell.configure(
            page: pages[indexPath.item],
            index: indexPath.item,
            targetWidth: targetWidth,
            cropBorders: fixedPageReaderConfiguration.cropBorders,
            isLiveTextEnabled: fixedPageReaderConfiguration.isLiveTextEnabled
        ) { [weak self] index, ratio in
            guard let self else { return }
            self.layout.setRatio(ratio, forItem: index)
            self.layout.invalidateLayout()
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? FixedPageWebtoonCell)?.load()
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? FixedPageWebtoonCell)?.unload()
    }

    // MARK: Scroll → progress + multi-chapter infinite loading

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if isAutoScrolling { isPausedByTouch = true }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if isAutoScrolling && !decelerate { isPausedByTouch = false }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if isAutoScrolling { isPausedByTouch = false }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let midY = scrollView.contentOffset.y + scrollView.bounds.height / 2
        if let indexPath = collectionView.indexPathForItem(at: CGPoint(x: collectionView.bounds.midX, y: midY)),
           indexPath.item != currentIndex {
            currentIndex = indexPath.item
            container?.reader(didMoveToPage: currentIndex, total: pages.count)
        }

        let scrollable = scrollView.contentSize.height > scrollView.bounds.height
        let bottomDistance = scrollView.contentSize.height - (scrollView.contentOffset.y + scrollView.bounds.height)

        // Near bottom: trigger next chapter append
        if scrollable, bottomDistance < 1200, !isLoadingNextChapter {
            isLoadingNextChapter = true
            Task { [weak self] in
                guard let self else { return }
                if let nextPages = await self.container?.readerAppendNextChapter(), !nextPages.isEmpty {
                    self.pages.append(contentsOf: nextPages)
                    self.collectionView.reloadData()
                }
                self.isLoadingNextChapter = false
            }
        }

        // Near top: trigger previous chapter prepend
        if scrollView.contentOffset.y < 300, !isLoadingPrevChapter, currentIndex < 3 {
            isLoadingPrevChapter = true
            Task { [weak self] in
                guard let self else { return }
                if let prevPages = await self.container?.readerPrependPreviousChapter(), !prevPages.isEmpty {
                    self.layout.isInsertingCellsAbove = true
                    self.pages.insert(contentsOf: prevPages, at: 0)
                    self.collectionView.reloadData()
                }
                self.isLoadingPrevChapter = false
            }
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
