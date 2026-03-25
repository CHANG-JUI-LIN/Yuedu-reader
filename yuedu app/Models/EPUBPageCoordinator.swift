import Foundation
import UIKit
import WebKit

@MainActor
final class EPUBPageCoordinator: EPUBPageViewControllerDelegate {
    
    let pageViewController: EPUBPageViewController
    let renderer: EPUBPageRenderer
    
    init(renderer: EPUBPageRenderer) {
        self.renderer = renderer
        self.pageViewController = EPUBPageViewController()
        self.pageViewController.epubDelegate = self
        
        // Pass the interactive WKWebView to the page view controller
        if let activeWebView = renderer.liveWebView {
            self.pageViewController.setActiveWebView(activeWebView)
        }
        
        updateBookData()
    }
    
    func updateBookData() {
        let total = renderer.totalPages
        let map = renderer.globalPageMap
        pageViewController.setBookData(totalPages: total, pageMap: map)
    }
    
    func jumpToPage(_ globalPage: Int, animated: Bool) {
        renderer.currentEpubPage = globalPage
        
        let map = renderer.globalPageMap
        if globalPage < map.count {
            let entry = map[globalPage]
            if renderer.currentChapterIdx != entry.chapter {
                renderer.jumpToChapter(entry.chapter, preferredLocalPage: entry.page)
            }
        }
        
        pageViewController.jumpToGlobalPage(globalPage, animated: animated)
    }
    
    // MARK: - EPUBPageViewControllerDelegate
    func didTurnToGlobalPage(_ page: Int) {
        guard page != renderer.currentEpubPage else { return }
        renderer.currentEpubPage = page
        
        let map = renderer.globalPageMap
        if page < map.count {
            let entry = map[page]
            if renderer.currentChapterIdx != entry.chapter {
                renderer.jumpToChapter(entry.chapter, preferredLocalPage: entry.page)
            }
        }
    }
}
