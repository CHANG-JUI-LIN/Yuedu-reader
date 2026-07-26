import UIKit
import WebKit

/// The `WKUIDelegate` every source-login web view needs.
///
/// A `WKWebView` with no UI delegate **silently discards** four things a login page
/// routinely depends on:
///
/// - `window.open(…)` and `target="_blank"` — WebKit asks the delegate for a second
///   web view to put them in; with no delegate the call returns `null` and nothing
///   at all happens. Slider-captcha and OAuth widgets are commonly opened this way.
/// - `alert()` / `confirm()` / `prompt()` — never displayed. The page's JS resumes
///   with "dismissed" (`false` / `nil`), so a flow gated on 「请先完成验证」 just stops.
///
/// None of it logs, which is why a page can look completely dead. This delegate is
/// deliberately dumb: it shows the page's own dialogs to the user and loads popups
/// in the web view we already have. It never answers a challenge on the user's
/// behalf — a captcha still has to be solved by the person holding the phone.
///
/// `WKWebView.uiDelegate` is a **weak** reference: whoever assigns this must keep a
/// strong one (the representable's Coordinator), or it deallocates on the next line
/// and the hole is silently back.
final class SourceWebUIDelegate: NSObject, WKUIDelegate {

    // MARK: - Popups

    /// `window.open` / `target="_blank"`: there is no second web view to hand back,
    /// so load the request in this one. Returning nil *without* loading is what
    /// leaves the link dead.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame?.isMainFrame != true,
           let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    // MARK: - JS dialogs

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        // WebKit raises if a completion handler is dropped, so every path calls it
        // exactly once — including the one where we have nowhere to present.
        guard let presenter = Self.presenter(for: webView) else {
            completionHandler(); return
        }
        let alert = UIAlertController(
            title: nil, message: Self.bounded(message), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: localized("好"), style: .default) { _ in
            completionHandler()
        })
        presenter.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let presenter = Self.presenter(for: webView) else {
            completionHandler(false); return
        }
        let alert = UIAlertController(
            title: nil, message: Self.bounded(message), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: localized("取消"), style: .cancel) { _ in
            completionHandler(false)
        })
        alert.addAction(UIAlertAction(title: localized("好"), style: .default) { _ in
            completionHandler(true)
        })
        presenter.present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        guard let presenter = Self.presenter(for: webView) else {
            completionHandler(nil); return
        }
        let alert = UIAlertController(
            title: nil, message: Self.bounded(prompt), preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: localized("取消"), style: .cancel) { _ in
            completionHandler(nil)
        })
        alert.addAction(UIAlertAction(title: localized("好"), style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        presenter.present(alert, animated: true)
    }

    // MARK: - Helpers

    /// Nearest view controller above the web view, then its topmost presented one —
    /// found through the responder chain so this stays independent of whichever
    /// screen is hosting the web view.
    private static func presenter(for webView: WKWebView) -> UIViewController? {
        var responder: UIResponder? = webView
        while let current = responder {
            if let controller = current as? UIViewController {
                var top = controller
                while let presented = top.presentedViewController { top = presented }
                return top
            }
            responder = current.next
        }
        return nil
    }

    /// Page-controlled text, bounded before it reaches UIKit layout.
    private static func bounded(_ text: String) -> String {
        text.count <= 500 ? text : String(text.prefix(500)) + "…"
    }
}
