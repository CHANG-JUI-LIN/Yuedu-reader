import UIKit

// MARK: - Paged reader (RTL / LTR / vertical)
//
// Wraps a `UIPageViewController` over the current chapter's pages or spreads.
// Supports single page, double-page spreads (with cover offset), split wide images,
// and chapter transition cards (ported and adapted from Aidoku).

final class FixedPagePagedViewController: UIViewController, FixedPageModeReader,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    private let controlTapDelegate = FixedPageReaderControlTapDelegate()

    weak var container: FixedPageReaderContainer?

    private let fixedPageReaderConfiguration: FixedPageReaderConfiguration
    private let targetWidth: FixedPageTargetWidth
    private var rawPages: [FixedPage] = []
    private var displayPages: [FixedPage] = []
    private var spreads: [[FixedPage]] = []
    private var currentSpreadIndex = 0
    private let pageVC: UIPageViewController
    /// The zoom each spread was left at, so a page turned away from and back to comes
    /// back as it was. A spread is rebuilt every time it comes on screen (Aidoku keeps
    /// its page controllers alive instead), so only the zoom is kept — not the images.
    /// Keyed by spread index, which means something else once the spreads are rebuilt.
    private var spreadZooms: [Int: FixedPageSpreadViewController.Zoom] = [:]
    private var spreadsGeneration = 0
    private var controlsShown = false

    init(fixedPageReaderConfiguration: FixedPageReaderConfiguration, targetWidth: FixedPageTargetWidth) {
        self.fixedPageReaderConfiguration = fixedPageReaderConfiguration
        self.targetWidth = targetWidth
        let orientation: UIPageViewController.NavigationOrientation = fixedPageReaderConfiguration.navigationAxis == .vertical
            ? .vertical
            : .horizontal
        pageVC = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: orientation,
            options: [.interPageSpacing: fixedPageReaderConfiguration.pageSpacing]
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        pageVC.dataSource = self
        pageVC.delegate = self
        addChild(pageVC)
        pageVC.view.frame = view.bounds
        pageVC.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageVC.view)
        pageVC.didMove(toParent: self)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = controlTapDelegate
        tap.numberOfTapsRequired = 1
        view.addGestureRecognizer(tap)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // If in auto-spread mode, rebuild spreads on orientation changes
        if fixedPageReaderConfiguration.pageSpreadLayout == .auto {
            let wasDouble = spreads.contains { $0.count > 1 }
            let isLandscape = view.bounds.width > view.bounds.height
            if wasDouble != isLandscape && !displayPages.isEmpty {
                let currentPage = currentPageIndex()
                buildSpreads()
                goToPage(currentPage, animated: false)
            }
        }
    }

    // MARK: FixedPageModeReader

    func setPages(_ pages: [FixedPage], startPage: Int) {
        self.rawPages = pages
        self.displayPages = processSplitPages(pages)
        buildSpreads()

        guard !spreads.isEmpty else { return }
        let targetSpread = spreadIndex(forPageIndex: startPage)
        currentSpreadIndex = targetSpread
        if let vc = makeViewController(forSpread: targetSpread) {
            pageVC.setViewControllers([vc], direction: .forward, animated: false)
        }
        reportPageProgress()
    }

    func currentPageIndex() -> Int {
        guard spreads.indices.contains(currentSpreadIndex) else { return 0 }
        return spreads[currentSpreadIndex].first?.id ?? 0
    }

    func setControlsShown(_ shown: Bool) {
        controlsShown = shown
        for case let spread as FixedPageSpreadViewController in pageVC.viewControllers ?? [] {
            spread.controlsShown = shown
        }
    }

    func goToPage(_ index: Int, animated: Bool) {
        let targetSpread = spreadIndex(forPageIndex: index)
        guard spreads.indices.contains(targetSpread),
              let vc = makeViewController(forSpread: targetSpread) else { return }

        let direction: UIPageViewController.NavigationDirection =
            (targetSpread > currentSpreadIndex) ? forwardDirection : backwardDirection
        currentSpreadIndex = targetSpread
        pageVC.setViewControllers([vc], direction: direction, animated: animated)
        reportPageProgress()
    }

    // MARK: Split & Spread Building

    private func processSplitPages(_ pages: [FixedPage]) -> [FixedPage] {
        guard fixedPageReaderConfiguration.splitWideImages else { return pages }
        var result: [FixedPage] = []
        let isRTL = usesRightToLeftProgression

        for page in pages {
            // Split page into right & left halves
            var firstHalf = page
            var secondHalf = page
            if isRTL {
                firstHalf.subPageSide = .right
                secondHalf.subPageSide = .left
            } else {
                firstHalf.subPageSide = .left
                secondHalf.subPageSide = .right
            }
            result.append(firstHalf)
            result.append(secondHalf)
        }
        return result
    }

    private var shouldDisplayDoublePages: Bool {
        switch fixedPageReaderConfiguration.pageSpreadLayout {
        case .single:
            return false
        case .double:
            return true
        case .auto:
            return view.bounds.width > view.bounds.height
        }
    }

    private func buildSpreads() {
        spreadsGeneration += 1
        spreadZooms = [:]
        guard !displayPages.isEmpty else {
            spreads = []
            return
        }

        guard shouldDisplayDoublePages else {
            spreads = displayPages.map { [$0] }
            return
        }

        var newSpreads: [[FixedPage]] = []
        var index = 0

        // Page offset: single cover page first
        if fixedPageReaderConfiguration.pageOffset && index < displayPages.count {
            newSpreads.append([displayPages[index]])
            index += 1
        }

        while index < displayPages.count {
            if index + 1 < displayPages.count {
                newSpreads.append([displayPages[index], displayPages[index + 1]])
                index += 2
            } else {
                newSpreads.append([displayPages[index]])
                index += 1
            }
        }
        spreads = newSpreads
    }

    private func spreadIndex(forPageIndex pageIndex: Int) -> Int {
        for (idx, spread) in spreads.enumerated() {
            if spread.contains(where: { $0.id == pageIndex }) {
                return idx
            }
        }
        return min(max(0, pageIndex), max(0, spreads.count - 1))
    }

    private func reportPageProgress() {
        let page = currentPageIndex()
        let total = rawPages.count
        container?.reader(didMoveToPage: page, total: total)
    }

    // MARK: View Controller Factory

    private func makeViewController(forSpread index: Int) -> UIViewController? {
        guard spreads.indices.contains(index) else { return nil }
        let spread = FixedPageSpreadViewController(
            spreadIndex: index,
            pages: spreads[index],
            fixedPageReaderConfiguration: fixedPageReaderConfiguration,
            targetWidth: targetWidth.value
        )
        spread.restoredZoom = spreadZooms[index]
        spread.controlsShown = controlsShown
        let generation = spreadsGeneration
        spread.onDisappear = { [weak self] spread in
            // From before a rebuild (another chapter, a rotation), this index is another spread.
            guard let self, self.spreadsGeneration == generation else { return }
            self.spreadZooms[spread.spreadIndex] = spread.currentZoom
        }
        return spread
    }

    private var usesRightToLeftProgression: Bool {
        fixedPageReaderConfiguration.progression == .rightToLeft
    }

    private var forwardDirection: UIPageViewController.NavigationDirection {
        usesRightToLeftProgression ? .reverse : .forward
    }

    private var backwardDirection: UIPageViewController.NavigationDirection {
        usesRightToLeftProgression ? .forward : .reverse
    }

    private func advance() {
        let next = currentSpreadIndex + 1
        if next >= spreads.count {
            container?.readerRequestsNextChapter()
        } else if let vc = makeViewController(forSpread: next) {
            currentSpreadIndex = next
            pageVC.setViewControllers([vc], direction: forwardDirection, animated: true)
            reportPageProgress()
        }
    }

    private func goBack() {
        let prev = currentSpreadIndex - 1
        if prev < 0 {
            container?.readerRequestsPreviousChapter()
        } else if let vc = makeViewController(forSpread: prev) {
            currentSpreadIndex = prev
            pageVC.setViewControllers([vc], direction: backwardDirection, animated: true)
            reportPageProgress()
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        let action: TouchAction
        if GlobalSettings.shared.readerTapBothSidesNextPage {
            let xFraction = point.x / max(view.bounds.width, 1)
            action = (0.3...0.7).contains(xFraction) ? .toggleMenu : .nextPage
        } else {
            action = TouchZoneConfig.effective(
                isProActive: SubscriptionStore.shared.isProActive,
                isRTL: usesRightToLeftProgression
            ).action(at: point, in: view.bounds.size)
        }

        // With the controls up, a turning tap only puts them away, as in every reader.
        if action.readerCommand.turnsPage, container?.readerHideControlsForPageTurn() == true { return }
        switch action.readerCommand {
        case .none: break
        case .toggleMenu: container?.readerToggleControls()
        case .previousPage: goBack()
        case .nextPage: advance()
        case .previousChapter: container?.readerRequestsPreviousChapter()
        case .nextChapter: container?.readerRequestsNextChapter()
        case .toggleBookmark: container?.readerToggleBookmark()
        case .tableOfContents: container?.readerShowTableOfContents()
        }
    }

    // MARK: UIPageViewControllerDataSource / Delegate

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        if let transitionVC = vc as? FixedPageTransitionViewController {
            switch transitionVC.direction {
            case .next:
                let target = spreads.count - 1
                return makeViewController(forSpread: target)
            case .previous:
                container?.readerRequestsPreviousChapter()
                return nil
            }
        }

        guard let spreadVC = vc as? FixedPageSpreadViewController else { return nil }
        let targetIndex = usesRightToLeftProgression ? spreadVC.spreadIndex + 1 : spreadVC.spreadIndex - 1

        if targetIndex < 0 {
            return FixedPageTransitionViewController(direction: .previous(
                currentTitle: "",
                prevTitle: nil
            ))
        }
        if targetIndex >= spreads.count {
            return FixedPageTransitionViewController(direction: .next(
                currentTitle: "",
                nextTitle: nil
            ))
        }
        return makeViewController(forSpread: targetIndex)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        if let transitionVC = vc as? FixedPageTransitionViewController {
            switch transitionVC.direction {
            case .next:
                container?.readerRequestsNextChapter()
                return nil
            case .previous:
                return makeViewController(forSpread: 0)
            }
        }

        guard let spreadVC = vc as? FixedPageSpreadViewController else { return nil }
        let targetIndex = usesRightToLeftProgression ? spreadVC.spreadIndex - 1 : spreadVC.spreadIndex + 1

        if targetIndex < 0 {
            return FixedPageTransitionViewController(direction: .previous(
                currentTitle: "",
                prevTitle: nil
            ))
        }
        if targetIndex >= spreads.count {
            return FixedPageTransitionViewController(direction: .next(
                currentTitle: "",
                nextTitle: nil
            ))
        }
        return makeViewController(forSpread: targetIndex)
    }

    func pageViewController(
        _ pvc: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        // UIKit calls this only for a swipe, never for setViewControllers.
        container?.readerHideControlsForPageTurn()
        // The incoming spread was made before the controls went away.
        for case let spread as FixedPageSpreadViewController in pendingViewControllers {
            spread.controlsShown = controlsShown
        }
    }

    func pageViewController(
        _ pvc: UIPageViewController, didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController], transitionCompleted completed: Bool
    ) {
        guard completed else { return }
        if let current = pvc.viewControllers?.first as? FixedPageSpreadViewController {
            currentSpreadIndex = current.spreadIndex
            reportPageProgress()
        }
    }
}
