import Foundation
import WebKit

@MainActor
enum WebViewRole: String {
    case current
    case prev
    case next
}

@MainActor
protocol EPUBWebViewPoolDelegate: AnyObject {
    func pool(_ pool: EPUBWebViewPool, didReceiveMessage type: String, payload: [String: Any], from webView: WKWebView, role: WebViewRole?)
}

@MainActor
final class EPUBWebViewPool: NSObject, WKScriptMessageHandler {
    
    let processPool = WKProcessPool()
    var pool: [WebViewRole: WKWebView] = [:]
    var preloadedChapter: [WebViewRole: Int] = [:]
    var preloadedReady: [WebViewRole: Bool] = [:]
    
    weak var delegate: EPUBWebViewPoolDelegate?
    var bridgeName: String
    
    init(bridgeName: String) {
        self.bridgeName = bridgeName
        super.init()
    }
    
    func webView(for role: WebViewRole) -> WKWebView? {
        return pool[role]
    }
    
    func createWebView(role: WebViewRole, frame: CGRect) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = processPool
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        
        let uc = WKUserContentController()
        uc.add(self, name: bridgeName)
        config.userContentController = uc
        
        let webView = WKWebView(frame: frame, configuration: config)
        webView.isOpaque = true
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        
        pool[role] = webView
        return webView
    }
    
    func clearAll() {
        pool.values.forEach { 
            $0.loadHTMLString("", baseURL: nil)
            $0.removeFromSuperview()
        }
        pool.removeAll()
        preloadedChapter.removeAll()
        preloadedReady.removeAll()
    }
    
    func resetPreloadState(for role: WebViewRole) {
        preloadedChapter[role] = nil
        preloadedReady[role] = false
    }
    
    func role(for webView: WKWebView) -> WebViewRole? {
        return pool.first { $0.value === webView }?.key
    }
    
    // MARK: - WKScriptMessageHandler
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == bridgeName,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        
        var payload = body["payload"] as? [String: Any] ?? [:]
        if payload["pageCount"] == nil, let pc = body["pageCount"] as? Int {
            payload["pageCount"] = pc
        }
        
        if let webView = message.webView {
            let role = self.role(for: webView)
            delegate?.pool(self, didReceiveMessage: type, payload: payload, from: webView, role: role)
        }
    }
}
