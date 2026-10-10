import UIKit
import WebKit

/// Owns the one live `<iframe>` page the reader is showing (`ReaderWebEmbed`).
///
/// Like `EPUBVideoPlaybackManager`, it outlives the page views that show it, so turning back to
/// the page re-attaches the same page instead of reloading it. Unlike video it keeps a single
/// live page: an iframe can be anything a web page can be, and two of them running at once is
/// two sets of audio and scripts. Starting another, closing the book or leaving the app tears
/// the current one down. WebKit pauses a page's media once its view leaves the window, so a
/// player page does not keep sounding after its page is turned away — it resumes where it was
/// when the page comes back.
@MainActor
final class ReaderWebEmbedManager: NSObject {
    static let shared = ReaderWebEmbedManager()

    private var live: (key: String, webView: WKWebView)?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    func isActive(_ embed: ReaderWebEmbed) -> Bool {
        live?.key == embed.key
    }

    /// The live page for `embed`, loading it on first use (and closing any other live page).
    func webView(for embed: ReaderWebEmbed) -> WKWebView {
        if let live, live.key == embed.key { return live.webView }
        stopAll()

        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        // The reader tapped the card to get here; that tap is the user action a player wants.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // The default (shared) website data store, so an embed the reader is signed in to in
        // the source's browser pages sees the same session.
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.accessibilityLabel = embed.title ?? localized("內嵌網頁")

        let decoded = OnlineImageRequestOptions.decode(embed.src)
        if let url = URL(string: decoded.src) {
            var request = URLRequest(url: url)
            for (field, value) in decoded.headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            if request.value(forHTTPHeaderField: "Referer") == nil, let referer = embed.referer,
               referer.lowercased().hasPrefix("http") {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            webView.load(request)
        } else {
            AppLogger.error("Web embed has no loadable URL", context: ["src": String(embed.src.prefix(160))])
        }
        live = (embed.key, webView)
        return webView
    }

    /// Closes the live page. Called when another one starts, when the book closes and when the
    /// app leaves the foreground.
    func stopAll() {
        guard let live else { return }
        // `stopLoading` only cancels loading: a player that is already playing keeps playing
        // (and, with the reader's playback audio session active, keeps sounding in the
        // background) unless its media is paused and the page itself is replaced.
        live.webView.pauseAllMediaPlayback()
        live.webView.stopLoading()
        live.webView.load(URLRequest(url: URL(string: "about:blank")!))
        live.webView.navigationDelegate = nil
        live.webView.uiDelegate = nil
        live.webView.removeFromSuperview()
        self.live = nil
        // Hosts showing it drop their window, or an empty frame would sit over the card.
        NotificationCenter.default.post(name: .readerWebEmbedDidStop, object: self)
    }

    @objc private func appDidEnterBackground() {
        stopAll()
    }
}

extension ReaderWebEmbedManager: WKNavigationDelegate, WKUIDelegate {
    /// The embed stays the embed: a link the reader follows out of it opens in the source
    /// browser sheet instead of replacing the player inside the page.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              navigationAction.targetFrame?.isMainFrame != false,
              let url = navigationAction.request.url
        else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        openInBrowserSheet(url)
    }

    /// `target="_blank"` and `window.open`: no pop-up windows; the link goes to the sheet.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            openInBrowserSheet(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        AppLogger.error("Web embed failed to load", context: ["error": error.localizedDescription])
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        AppLogger.error("Web embed failed to load", context: ["error": error.localizedDescription])
    }

    private func openInBrowserSheet(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        SourceBrowserPresenter.present(
            SourceBrowserRequest(
                url: url.absoluteString,
                title: url.host ?? "",
                urlRequest: URLRequest(url: url),
                awaitsResult: false
            )
        ) { _ in }
    }
}

extension Notification.Name {
    /// `ReaderWebEmbedManager` closed its live page; any view still showing it must go.
    static let readerWebEmbedDidStop = Notification.Name("ReaderWebEmbedDidStop")
}
