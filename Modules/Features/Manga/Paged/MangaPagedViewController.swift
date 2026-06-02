import UIKit

// MARK: - Paged reader (RTL / LTR / vertical)
//
// Wraps a `UIPageViewController` over the current chapter's pages. RTL flips the
// data-source order and tap zones. Tapping forward past the last page (or back
// before the first) asks the container to change chapters.

final class MangaPagedViewController: UIViewController, MangaModeReader,
    UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    weak var container: MangaReaderContainer?

    private let mode: MangaReadingMode
    private let targetWidth: CGFloat
    private var pages: [MangaPage] = []
    private var currentIndex = 0
    private let pageVC: UIPageViewController

    init(mode: MangaReadingMode, targetWidth: CGFloat) {
        self.mode = mode
        self.targetWidth = targetWidth
        let orientation: UIPageViewController.NavigationOrientation = (mode == .vertical) ? .vertical : .horizontal
        pageVC = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: orientation,
            options: [.interPageSpacing: 8]
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

    // MARK: MangaModeReader

    func setPages(_ pages: [MangaPage], startPage: Int) {
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

    private func makePage(at index: Int) -> MangaPageViewController? {
        guard pages.indices.contains(index) else { return nil }
        return MangaPageViewController(page: pages[index], index: index, targetWidth: targetWidth)
    }

    private var forwardDirection: UIPageViewController.NavigationDirection { mode.isReversed ? .reverse : .forward }
    private var backwardDirection: UIPageViewController.NavigationDirection { mode.isReversed ? .forward : .reverse }

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
        if mode == .vertical {
            let third = view.bounds.height / 3
            if point.y < third { goBack() }
            else if point.y > 2 * third { advance() }
            else { container?.readerToggleControls() }
            return
        }
        let third = view.bounds.width / 3
        let leftZone = point.x < third
        let rightZone = point.x > 2 * third
        guard leftZone || rightZone else { container?.readerToggleControls(); return }
        if mode.isReversed {
            if leftZone { advance() } else { goBack() }
        } else {
            if rightZone { advance() } else { goBack() }
        }
    }

    // MARK: UIPageViewControllerDataSource / Delegate

    func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
        guard let current = vc as? MangaPageViewController else { return nil }
        return makePage(at: mode.isReversed ? current.pageIndex + 1 : current.pageIndex - 1)
    }

    func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
        guard let current = vc as? MangaPageViewController else { return nil }
        return makePage(at: mode.isReversed ? current.pageIndex - 1 : current.pageIndex + 1)
    }

    func pageViewController(
        _ pvc: UIPageViewController, didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController], transitionCompleted completed: Bool
    ) {
        guard completed, let current = pvc.viewControllers?.first as? MangaPageViewController else { return }
        currentIndex = current.pageIndex
        container?.reader(didMoveToPage: currentIndex, total: pages.count)
    }
}
