import UIKit
import WebKit

@MainActor
protocol EPUBPageViewControllerDelegate: AnyObject {
    func didTurnToGlobalPage(_ page: Int)
}

@MainActor
final class EPUBPageViewController: UIPageViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, EPUBPageViewDelegate {
    
    private var totalPages: Int = 1
    private var pageMap: [(chapter: Int, page: Int)] = []
    
    weak var epubDelegate: EPUBPageViewControllerDelegate?
    private var activeWebView: WKWebView?
    
    init() {
        super.init(transitionStyle: .scroll, navigationOrientation: .horizontal, options: nil)
        self.dataSource = self
        self.delegate = self
    }
    
    required init?(coder: NSCoder) { fatalError() }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
    }
    
    func setBookData(totalPages: Int, pageMap: [(chapter: Int, page: Int)]) {
        self.totalPages = totalPages
        self.pageMap = pageMap
    }
    
    func setActiveWebView(_ webView: WKWebView) {
        self.activeWebView = webView
        
        // If there's an active visible view, immediately remount
        if let current = viewControllers?.first as? EPUBPageView {
            current.mountWebView(webView)
        }
    }
    
    func jumpToGlobalPage(_ globalPage: Int, animated: Bool) {
        guard globalPage >= 0 && globalPage < totalPages && !pageMap.isEmpty else { return }
        
        // Prevent unnecessary jumps during manual flip if target is current
        if let current = viewControllers?.first as? EPUBPageView, current.globalPage == globalPage {
            return
        }
        
        let map = pageMap[globalPage]
        let vc = EPUBPageView(globalPage: globalPage, chapterIndex: map.chapter, localPage: map.page)
        vc.delegate = self
        
        let direction: UIPageViewController.NavigationDirection = .forward
        setViewControllers([vc], direction: direction, animated: animated, completion: { [weak self] finished in
            if finished {
                self?.pageViewDidSettle(vc)
            }
        })
    }
    
    // MARK: - DataSource
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let current = viewController as? EPUBPageView else { return nil }
        let target = current.globalPage - 1
        guard target >= 0, target < totalPages, !pageMap.isEmpty else { return nil }
        let map = pageMap[target]
        let vc = EPUBPageView(globalPage: target, chapterIndex: map.chapter, localPage: map.page)
        vc.delegate = self
        return vc
    }
    
    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let current = viewController as? EPUBPageView else { return nil }
        let target = current.globalPage + 1
        guard target < totalPages, !pageMap.isEmpty else { return nil }
        let map = pageMap[target]
        let vc = EPUBPageView(globalPage: target, chapterIndex: map.chapter, localPage: map.page)
        vc.delegate = self
        return vc
    }
    
    // MARK: - Delegate (for programmatic update detection)
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        if completed, let current = viewControllers?.first as? EPUBPageView {
            pageViewDidSettle(current)
        }
    }
    
    // MARK: - EPUBPageViewDelegate
    func pageViewDidSettle(_ view: EPUBPageView) {
        epubDelegate?.didTurnToGlobalPage(view.globalPage)
        if let wv = activeWebView {
            view.mountWebView(wv)
            wv.evaluateJavaScript("gotoPage(\(view.localPage))")
        }
        
        let map = pageMap[view.globalPage]
        EPUBSnapshotManager.shared.prefetchRange(chapter: map.chapter, centerPage: map.page, radius: 2)
    }
    
    func pageViewDidUnsettle(_ view: EPUBPageView) {
        view.unmountWebView()
    }
}
