import Foundation
import UIKit
import WebKit

@MainActor
protocol EPUBSnapshotWorkerDelegate: AnyObject {
    func worker(_ worker: EPUBSnapshotWorker, didReadyForPage page: Int, metrics: PaginationMetrics)
}

struct PaginationMetrics {
    let pageCount: Int
    let pageOffsets: [CGFloat]
    let scrollMode: Bool
}

/// A background worker wrapping WKWebView for taking snapshots.
@MainActor
final class EPUBSnapshotWorker: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let webView: WKWebView
    weak var delegate: EPUBSnapshotWorkerDelegate?
    
    private var pendingSnapshotContinuations: [Int: CheckedContinuation<UIImage?, Never>] = [:]
    
    override init() {
        let config = WKWebViewConfiguration()
        let processPool = WKProcessPool()
        config.processPool = processPool
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        let handler = WKUserContentController()
        config.userContentController = handler
        
        webView = WKWebView(frame: CGRect(origin: .zero, size: UIScreen.main.bounds.size), configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = .white
        webView.scrollView.isScrollEnabled = false
        
        super.init()
        
        handler.add(self, name: "renderReady")
        handler.add(self, name: "paginationReady")
        webView.navigationDelegate = self
    }
    
    func loadHTML(html: String, baseURL: URL) {
        // 確保 WebView 在一個視窗階層中以允許渲染（雖然可能被推到畫面外）
        if webView.superview == nil, let window = UIApplication.shared.windows.first {
            webView.frame = CGRect(x: -webView.bounds.width * 2, y: 0, width: webView.bounds.width, height: webView.bounds.height)
            window.addSubview(webView)
        }
        webView.loadHTMLString(html, baseURL: baseURL)
    }
    
    /// Requests the worker to navigate to a page and capture a snapshot.
    func takeSnapshot(forPage page: Int) async -> UIImage? {
        await withCheckedContinuation { continuation in
            // Execute JS to go to the page
            webView.evaluateJavaScript("gotoPage(\(page))") { [weak self] _, _ in
                guard let self = self else {
                    continuation.resume(returning: nil)
                    return
                }
                
                let config = WKSnapshotConfiguration()
                config.rect = self.webView.bounds
                config.afterScreenUpdates = true // Force true to ensure JS transforms and DOM repaints are settled
                
                self.webView.takeSnapshot(with: config) { image, error in
                    continuation.resume(returning: image)
                }
            }
        }
    }
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let dist = message.body as? [String: Any],
              let type = dist["type"] as? String,
              let payload = dist["payload"] as? [String: Any] else { return }
        
        if message.name == "renderReady" || type == "renderReady" {
            let pageIndex = payload["pageIndex"] as? Int ?? 0
            // We assume paginationReady might have provided metrics previously or simultaneously.
            // For now, we notify delegate.
            delegate?.worker(self, didReadyForPage: pageIndex, metrics: PaginationMetrics(pageCount: 1, pageOffsets: [0], scrollMode: false))
        }
    }
}
