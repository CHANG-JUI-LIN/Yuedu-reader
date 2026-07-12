import UIKit

// MARK: - Paged reader (RTL / LTR / vertical)
//
// Wraps a `UIPageViewController` over the current chapter's pages. RTL flips the
// data-source order and tap zones. Tapping forward past the last page (or back
// before the first) asks the container to change chapters.

final class FixedPagePagedViewController: UIViewController, FixedPageModeReader,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    weak var container: FixedPageReaderContainer?

    private let fixedPageReaderConfiguration: FixedPageReaderConfiguration
    private let targetWidth: CGFloat
    private var pages: [FixedPage] = []
    private var currentIndex = 0
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

    // MARK: FixedPageModeReader

    func setPages(_ pages: [FixedPage], startPage: Int) {
        self.pages = pages
        guard !pages.isEmpty else { return }
        currentIndex = max(0, min(startPage, pages.count - 1))
        if let vc = makePage(at: currentIndex) {
            pageVC.setViewControllers([vc], direction: .forward, animated: false)
        }
        container?.reader(didMoveToPage: currentIndex, total: pages.count)
    }

    func currentPageIndex() -> Int { currentIndex }

    func goToPage(_ index: Int, animated: Bool) {
        guard pages.indices.contains(index), index != currentIndex, let vc = makePage(at: index) else { return }
        let direction: UIPageViewController.NavigationDirection =
            (index > currentIndex) ? forwardDirection : backwardDirection
        currentIndex = index
        pageVC.setViewControllers([vc], direction: direction, animated: animated)
        container?.reader(didMoveToPage: currentIndex, total: pages.count)
    }

    // MARK: Navigation

    private func makePage(at index: Int) -> FixedPagePageViewController? {
        guard pages.indices.contains(index) else { return nil }
        return FixedPagePageViewController(
            page: pages[index],
            index: index,
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
        let target = currentIndex + 1
        if target >= pages.count { container?.readerRequestsNextChapter() } else { goToPage(target, animated: true) }
    }

    private func goBack() {
        let target = currentIndex - 1
        if target < 0 { container?.readerRequestsPreviousChapter() } else { goToPage(target, animated: true) }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: view)
        let action: TouchAction
        if GlobalSettings.shared.readerTapBothSidesNextPage {
            let xFraction = point.x / max(view.bounds.width, 1)
            action = (0.3...0.7).contains(xFraction) ? .toggleMenu : .nextPage
        } else {
            action = TouchZoneConfig.effective(
                isProActive: SubscriptionStore.shared.isProActive
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
        guard let current = vc as? FixedPagePageViewController else { return nil }
        return makePage(at: usesRightToLeftProgression ? current.pageIndex + 1 : current.pageIndex - 1)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let current = vc as? FixedPagePageViewController else { return nil }
        return makePage(at: usesRightToLeftProgression ? current.pageIndex - 1 : current.pageIndex + 1)
    }

    func pageViewController(
        _ pvc: UIPageViewController, didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController], transitionCompleted completed: Bool
    ) {
        guard completed, let current = pvc.viewControllers?.first as? FixedPagePageViewController else { return }
        currentIndex = current.pageIndex
        container?.reader(didMoveToPage: currentIndex, total: pages.count)
    }
}
