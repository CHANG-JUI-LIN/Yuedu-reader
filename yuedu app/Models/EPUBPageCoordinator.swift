import Foundation
import UIKit
import WebKit

@MainActor
final class EPUBPageCoordinator: EPUBPageViewControllerDelegate {
    
    let pageViewController: EPUBPageViewController
    let reader: LiveWebReader
    
    init(reader: LiveWebReader) {
        self.reader = reader
        self.pageViewController = EPUBPageViewController()
        
        self.pageViewController.epubDelegate = self
        
        // Pass the interactive WKWebView to the page view controller
        if let activeWebView = reader.webView {
            self.pageViewController.setActiveWebView(activeWebView)
        }
        
        // Listen to reader state to build pageMap
        // (In a real scenario, this would observe reader publishers like `totalPages`, `currentEpubPage`)
        updateBookData()
    }
    
    func updateBookData() {
        let total = reader.totalPages
        let map = reader.globalPageMap  // Assuming this is exposed or bridged
        pageViewController.setBookData(totalPages: total, pageMap: map)
    }
    
    func jumpToPage(_ globalPage: Int, animated: Bool) {
        // Critical Fix: Sync state correctly without getting "stuck".
        reader.currentEpubPage = globalPage
        
        if globalPage < reader.globalPageMap.count {
            let map = reader.globalPageMap[globalPage]
            if reader.currentChapterIdx != map.chapter {
                // Background load chapter
                reader.jumpToChapter(map.chapter, preferredLocalPage: map.page)
            }
        }
        
        pageViewController.jumpToGlobalPage(globalPage, animated: animated)
    }
    
    // MARK: - EPUBPageViewControllerDelegate
    func didTurnToGlobalPage(_ page: Int) {
        // When native paging settles on a new page, strictly sync the model progress.
        // This ensures saving locators correctly.
        guard page != reader.currentEpubPage else { return }
        reader.currentEpubPage = page
        
        if page < reader.globalPageMap.count {
            let map = reader.globalPageMap[page]
            if reader.currentChapterIdx != map.chapter {
                // We crossed a boundary via native swipe.
                // The SnapshotManager already served the image, now tell the reader to officially switch its internal active model chapter.
                reader.jumpToChapter(map.chapter, preferredLocalPage: map.page)
            }
        }
    }
}
