import UIKit

// MARK: - Webtoon reader (continuous vertical scroll)
//
// Displays chapters as a continuous vertical list. Features:
// - Multi-chapter seamless infinite scrolling (auto-appends next & prepends previous chapters).
// - CADisplayLink auto-scrolling with touch-pause support.
// - Pinch and double-tap zoom through the layout (`FixedPageWebtoonLayout.zoomScale`):
//   the list itself grows, so a zoomed strip pans in every direction with the list's
//   own scrolling, and the pinch stays under the fingers.
// - Tap zones for stepping and toggling controls.

final class FixedPageWebtoonViewController: UIViewController, FixedPageModeReader,
    UICollectionViewDataSource, UICollectionViewDelegate {

    private let controlTapDelegate = FixedPageReaderControlTapDelegate()

    weak var container: FixedPageReaderContainer?

    private let fixedPageReaderConfiguration: FixedPageReaderConfiguration
    private let targetWidth: FixedPageTargetWidth
    private(set) var pages: [FixedPage] = []
    let layout: FixedPageWebtoonLayout
    private(set) lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private var currentIndex = 0

    // Auto-scroll state
    private var autoScrollDisplayLink: CADisplayLink?
    private(set) var isAutoScrolling = false {
        didSet {
            if oldValue != isAutoScrolling {
                container?.readerAutoScrollStateChanged(isAutoScrolling)
            }
            updateContentScrolling()
        }
    }
    private var isPausedByTouch = false {
        didSet { updateContentScrolling() }
    }
    /// A finger is dragging the list, or it is still gliding after one.
    private var isFingerScrolling = false {
        didSet { updateContentScrolling() }
    }
    /// The page is moving under the auto-scroll button, which dims meanwhile.
    private var isContentScrolling = false {
        didSet {
            if oldValue != isContentScrolling {
                container?.readerContentScrollingChanged(isContentScrolling)
            }
        }
    }

    private func updateContentScrolling() {
        isContentScrolling = isFingerScrolling || (isAutoScrolling && !isPausedByTouch)
    }

    // Infinite scroll loading guards
    private var isLoadingNextChapter = false
    private var isLoadingPrevChapter = false

    // Zoom
    private struct ZoomAnimation {
        let fromScale: CGFloat
        let toScale: CGFloat
        /// The point of the unzoomed content that the animation keeps in view...
        let anchor: CGPoint
        /// ...moving it on screen from here to there.
        let fromPoint: CGPoint
        let toPoint: CGPoint
        var startTime: CFTimeInterval?
    }
    private static let zoomAnimationDuration: CFTimeInterval = 0.3
    private var pinchStartScale: CGFloat = 1
    private var pinchAnchor: CGPoint = .zero
    private var zoomAnimation: ZoomAnimation?
    private var zoomAnimationLink: CADisplayLink?
    /// A pinch or a double-tap zoom is moving the content. The page counter and chapter
    /// loading wait for it to settle rather than react to every frame of it.
    private var isZooming = false
    private var controlsShown = false

    init(fixedPageReaderConfiguration: FixedPageReaderConfiguration, targetWidth: FixedPageTargetWidth) {
        self.fixedPageReaderConfiguration = fixedPageReaderConfiguration
        self.targetWidth = targetWidth
        self.layout = FixedPageWebtoonLayout(fixedPageReaderConfiguration: fixedPageReaderConfiguration)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        autoScrollDisplayLink?.invalidate()
        zoomAnimationLink?.invalidate()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopAutoScroll()
        cancelZoomAnimation()
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

        // Waits for the double tap below through its delegate.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = controlTapDelegate
        collectionView.addGestureRecognizer(tap)

        if fixedPageReaderConfiguration.isZoomEnabled {
            collectionView.addGestureRecognizer(
                UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            )
            collectionView.addGestureRecognizer(
                FixedPageDoubleTapZoomGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
            )
        }
    }

    // MARK: FixedPageModeReader

    func setPages(_ pages: [FixedPage], startPage: Int) {
        self.pages = pages
        isLoadingNextChapter = false
        isLoadingPrevChapter = false
        cancelZoomAnimation()
        layout.zoomScale = 1
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

    func setControlsShown(_ shown: Bool) {
        controlsShown = shown
        updateLiveTextButtons()
    }

    private var showsLiveTextButton: Bool {
        FixedPageZoom.showsLiveTextButton(controlsShown: controlsShown, zoomScale: layout.zoomScale)
    }

    private func updateLiveTextButtons() {
        guard isViewLoaded else { return }
        let shows = showsLiveTextButton
        for case let cell as FixedPageWebtoonCell in collectionView.visibleCells {
            cell.setShowsLiveTextButton(shows)
        }
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
        let link = CADisplayLink(target: self, selector: #selector(handleAutoScrollTick(_:)))
        link.add(to: .main, forMode: .common)
        autoScrollDisplayLink = link
    }

    func stopAutoScroll() {
        autoScrollDisplayLink?.invalidate()
        autoScrollDisplayLink = nil
        isAutoScrolling = false
        isPausedByTouch = false
    }

    @objc private func handleAutoScrollTick(_ link: CADisplayLink) {
        guard isAutoScrolling, !isPausedByTouch else { return }
        let step = Self.autoScrollStep(
            speedSetting: fixedPageReaderConfiguration.autoScrollSpeed,
            frameInterval: link.targetTimestamp - link.timestamp
        )
        let newOffset = collectionView.contentOffset.y + step
        let maxOffset = max(0, collectionView.contentSize.height - collectionView.bounds.height)

        if newOffset >= maxOffset {
            collectionView.contentOffset.y = maxOffset
            stopAutoScroll()
            container?.readerRequestsNextChapter()
        } else {
            collectionView.contentOffset.y = newOffset
        }
    }

    /// Points to scroll in one display-link frame.
    ///
    /// `autoScrollSpeed` was tuned as a step per 60Hz frame, the only rate an
    /// iPhone gave this link before Info.plist unlocked ProMotion. Scaling by the
    /// frame's real interval keeps that distance per second at 120Hz instead of
    /// doubling it.
    nonisolated static func autoScrollStep(speedSetting: Int, frameInterval: CFTimeInterval) -> CGFloat {
        CGFloat(max(1, speedSetting)) * 0.8 * CGFloat(frameInterval * 60)
    }

    // MARK: Pinch & Double-Tap Zoom

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            cancelZoomAnimation()
            stopAutoScroll()
            isZooming = true
            // One writer for the offset: a fling in flight and the list's own pan would
            // both fight the pinch for it.
            collectionView.setContentOffset(collectionView.contentOffset, animated: false)
            collectionView.panGestureRecognizer.isEnabled = false
            pinchStartScale = layout.zoomScale
            let point = gesture.location(in: collectionView)
            pinchAnchor = CGPoint(x: point.x / pinchStartScale, y: point.y / pinchStartScale)
        case .changed:
            let scale = min(max(pinchStartScale * gesture.scale, 1), FixedPageZoom.maximumScale)
            applyZoom(scale, keeping: pinchAnchor, at: viewportLocation(of: gesture))
        case .ended, .cancelled, .failed:
            collectionView.panGestureRecognizer.isEnabled = true
            zoomDidSettle()
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        stopAutoScroll()
        let scale = layout.zoomScale
        let middle = CGPoint(x: collectionView.bounds.width / 2, y: collectionView.bounds.height / 2)
        if scale > 1.01 {
            // Back to the fitted width, keeping what is in the middle of the screen there.
            let offset = collectionView.contentOffset
            let anchor = CGPoint(x: (offset.x + middle.x) / scale, y: (offset.y + middle.y) / scale)
            animateZoom(to: 1, keeping: anchor, from: middle, to: middle)
        } else {
            // 2x, bringing the tapped spot to the middle of the screen.
            let point = gesture.location(in: collectionView)
            let anchor = CGPoint(x: point.x / scale, y: point.y / scale)
            animateZoom(
                to: FixedPageZoom.doubleTapScale,
                keeping: anchor,
                from: viewportLocation(of: gesture),
                to: middle
            )
        }
    }

    /// Where the gesture is within the list's visible area.
    private func viewportLocation(of gesture: UIGestureRecognizer) -> CGPoint {
        let point = gesture.location(in: collectionView)
        return CGPoint(x: point.x - collectionView.contentOffset.x, y: point.y - collectionView.contentOffset.y)
    }

    /// Lays the list out at `scale` with `anchor` — a point of the unzoomed content —
    /// under `viewportPoint`.
    private func applyZoom(_ scale: CGFloat, keeping anchor: CGPoint, at viewportPoint: CGPoint) {
        layout.zoomScale = scale
        layout.invalidateLayout()
        collectionView.layoutIfNeeded()
        collectionView.contentOffset = Self.zoomedContentOffset(
            anchor: anchor,
            scale: scale,
            viewportPoint: viewportPoint,
            contentSize: collectionView.contentSize,
            viewportSize: collectionView.bounds.size
        )
        updateLiveTextButtons()
    }

    /// Content offset that puts `anchor` — a point of the unzoomed content — under
    /// `viewportPoint` at `scale`, kept inside the scrollable range. The list has no
    /// content inset (`contentInsetAdjustmentBehavior = .never`), so the range starts at 0.
    nonisolated static func zoomedContentOffset(
        anchor: CGPoint,
        scale: CGFloat,
        viewportPoint: CGPoint,
        contentSize: CGSize,
        viewportSize: CGSize
    ) -> CGPoint {
        let maxX = max(0, contentSize.width - viewportSize.width)
        let maxY = max(0, contentSize.height - viewportSize.height)
        return CGPoint(
            x: min(max(0, anchor.x * scale - viewportPoint.x), maxX),
            y: min(max(0, anchor.y * scale - viewportPoint.y), maxY)
        )
    }

    private func animateZoom(to scale: CGFloat, keeping anchor: CGPoint, from start: CGPoint, to end: CGPoint) {
        cancelZoomAnimation()
        // Stop a fling in flight; it would keep moving the offset under the animation.
        collectionView.setContentOffset(collectionView.contentOffset, animated: false)
        isZooming = true
        zoomAnimation = ZoomAnimation(
            fromScale: layout.zoomScale,
            toScale: scale,
            anchor: anchor,
            fromPoint: start,
            toPoint: end
        )
        let link = CADisplayLink(target: self, selector: #selector(stepZoomAnimation(_:)))
        link.add(to: .main, forMode: .common)
        zoomAnimationLink = link
    }

    /// One frame of a double-tap zoom. The layout itself changes every frame — nothing
    /// that UIView animation could interpolate — so the frames are driven here.
    @objc private func stepZoomAnimation(_ link: CADisplayLink) {
        guard var animation = zoomAnimation else {
            cancelZoomAnimation()
            return
        }
        let startTime = animation.startTime ?? link.timestamp
        animation.startTime = startTime
        zoomAnimation = animation
        let progress = min(1, (link.targetTimestamp - startTime) / Self.zoomAnimationDuration)
        let eased = progress * progress * (3 - 2 * progress)
        let scale = animation.fromScale + (animation.toScale - animation.fromScale) * eased
        let point = CGPoint(
            x: animation.fromPoint.x + (animation.toPoint.x - animation.fromPoint.x) * eased,
            y: animation.fromPoint.y + (animation.toPoint.y - animation.fromPoint.y) * eased
        )
        applyZoom(scale, keeping: animation.anchor, at: point)
        if progress >= 1 {
            cancelZoomAnimation()
            zoomDidSettle()
        }
    }

    /// Stops a double-tap zoom where it is. Callers that stay on these pages settle it
    /// (`zoomDidSettle`); leaving the reader or replacing its pages does not.
    private func cancelZoomAnimation() {
        zoomAnimationLink?.invalidate()
        zoomAnimationLink = nil
        zoomAnimation = nil
        isZooming = false
    }

    /// The page counter and chapter loading catch up with the zoomed position.
    private func zoomDidSettle() {
        isZooming = false
        scrollViewDidScroll(collectionView)
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
            targetWidth: targetWidth.value,
            cropBorders: fixedPageReaderConfiguration.cropBorders,
            isLiveTextEnabled: fixedPageReaderConfiguration.isLiveTextEnabled
        ) { [weak self] index, page, ratio in
            self?.pageImageDidLoad(index: index, page: page, ratio: ratio)
        }
        cell.setShowsLiveTextButton(showsLiveTextButton)
        return cell
    }

    /// A cell's image arrived: size its item to the image. The cell reports the index it
    /// was configured with, which is stale when a chapter was prepended while the image
    /// loaded — that slot now holds another page, and sizing it by this image draws that
    /// page aspect-fit in the wrong frame. Such a report is dropped; `reloadData` has
    /// already queued the cell to be configured for its new index, and it reports again.
    func pageImageDidLoad(index: Int, page: FixedPage, ratio: CGFloat) {
        guard pages.indices.contains(index), pages[index] == page else { return }
        layout.setRatio(ratio, forItem: index)
        layout.invalidateLayout()
    }

    /// A previous chapter's pages go above the strip. Measured heights move with their
    /// pages, and the layout keeps the page on screen in place.
    func insertPagesAbove(_ newPages: [FixedPage]) {
        guard !newPages.isEmpty else { return }
        layout.insertItemsAtStart(newPages.count)
        pages.insert(contentsOf: newPages, at: 0)
        // The page on screen stays put, now further down the strip.
        currentIndex += newPages.count
        collectionView.reloadData()
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? FixedPageWebtoonCell)?.load()
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        (cell as? FixedPageWebtoonCell)?.unload()
    }

    // MARK: Scroll → progress + multi-chapter infinite loading

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        container?.readerHideControlsForPageTurn()
        isFingerScrolling = true
        if isAutoScrolling { isPausedByTouch = true }
        // A drag takes over from a double-tap zoom still running.
        if zoomAnimation != nil {
            cancelZoomAnimation()
            zoomDidSettle()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { isFingerScrolling = false }
        if isAutoScrolling && !decelerate { isPausedByTouch = false }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        isFingerScrolling = false
        if isAutoScrolling { isPausedByTouch = false }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Zooming moves the offset every frame; this runs once it settles instead.
        guard !isZooming else { return }
        let midY = scrollView.contentOffset.y + scrollView.bounds.height / 2
        // The page column is centred in the content, which a zoomed list may have
        // panned away from the middle of the screen.
        let columnX = scrollView.contentSize.width / 2
        if let indexPath = collectionView.indexPathForItem(at: CGPoint(x: columnX, y: midY)),
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
                if let prevPages = await self.container?.readerPrependPreviousChapter() {
                    self.insertPagesAbove(prevPages)
                }
                self.isLoadingPrevChapter = false
            }
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        let third = view.bounds.height / 3
        let page = view.bounds.height * 0.85
        // With the controls up, a turning tap only puts them away, as in every reader.
        if point.y < third || point.y > 2 * third,
           container?.readerHideControlsForPageTurn() == true {
            return
        }
        // A zoomed list keeps its sideways position while the tap moves it up or down.
        let x = collectionView.contentOffset.x
        if point.y < third {
            let target = max(-collectionView.adjustedContentInset.top, collectionView.contentOffset.y - page)
            collectionView.setContentOffset(CGPoint(x: x, y: target), animated: true)
        } else if point.y > 2 * third {
            let maxY = max(0, collectionView.contentSize.height - collectionView.bounds.height)
            collectionView.setContentOffset(CGPoint(x: x, y: min(maxY, collectionView.contentOffset.y + page)), animated: true)
        } else {
            container?.readerToggleControls()
        }
    }
}
