import UIKit

// MARK: - Paged reader (RTL / LTR / vertical)
//
// Wraps a `UIPageViewController` over the current chapter's pages or spreads.
// Supports single page, double-page spreads (with cover offset), split wide images,
// and chapter transition cards (ported and adapted from Aidoku).

final class FixedPagePagedViewController: UIViewController, FixedPageModeReader,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    weak var container: FixedPageReaderContainer?

    private let fixedPageReaderConfiguration: FixedPageReaderConfiguration
    private let targetWidth: CGFloat
    private var rawPages: [FixedPage] = []
    private var displayPages: [FixedPage] = []
    private var spreads: [[FixedPage]] = []
    private var currentSpreadIndex = 0
    private let pageVC: UIPageViewController

    init(fixedPageReaderConfiguration: FixedPageReaderConfiguration, targetWidth: CGFloat) {
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
        return FixedPageSpreadViewController(
            spreadIndex: index,
            pages: spreads[index],
            fixedPageReaderConfiguration: fixedPageReaderConfiguration,
            targetWidth: targetWidth
        )
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
