import UIKit
import WebKit

/// Owns the live `<iframe>` pages the reader is showing (`ReaderWebEmbed`).
///
/// Like `EPUBVideoPlaybackManager`, it outlives the page views that show it, so turning back to
/// the page re-attaches the same page instead of reloading it. A web address is tapped open and
/// kept one at a time: an iframe can be anything a web page can be, and two of them running at
/// once is two sets of audio and scripts. Starting another, closing the book or leaving the app
/// tears it down. A page the book source built (`ReaderWebEmbed.inlinePage`) shows as soon as
/// it is on screen — the source's player is the chapter's content, as its cover would be (user's
/// choice, 2026-10-10) — so it is not closed by another page starting, and leaving the app only
/// pauses its media; closing the book closes it. WebKit pauses a page's media once its view
/// leaves the window, so a player page does not keep sounding after its page is turned away —
/// it resumes where it was when the page comes back.
@MainActor
final class ReaderWebEmbedManager: NSObject {
    static let shared = ReaderWebEmbedManager()

    private var live: [String: WKWebView] = [:]

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
        live[embed.key] != nil
    }

    /// The live page for `embed`, loading it on first use. Opening a web address closes the
    /// other web address that was open; pages the source built stay.
    func webView(for embed: ReaderWebEmbed) -> WKWebView {
        if let webView = live[embed.key] { return webView }
        if !embed.isSourceBuiltPage {
            close { key in !ReaderWebEmbed.isSourceBuiltPage(key) }
        }

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
        if let page = embed.inlinePage {
            webView.loadHTMLString(page.html, baseURL: page.baseURL)
        } else if let url = URL(string: decoded.src) {
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
        live[embed.key] = webView
        return webView
    }

    /// Closes every live page. Called when the book closes.
    func stopAll() {
        close { _ in true }
    }

    private func close(where shouldClose: (String) -> Bool) {
        let closing = live.filter { shouldClose($0.key) }
        guard !closing.isEmpty else { return }
        for (key, webView) in closing {
            // `stopLoading` only cancels loading: a player that is already playing keeps playing
            // (and, with the reader's playback audio session active, keeps sounding in the
            // background) unless its media is paused and the page itself is replaced.
            webView.pauseAllMediaPlayback()
            webView.stopLoading()
            webView.load(URLRequest(url: URL(string: "about:blank")!))
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.removeFromSuperview()
            live[key] = nil
        }
        // Hosts showing them drop their window, or an empty frame would sit over the card.
        NotificationCenter.default.post(name: .readerWebEmbedDidStop, object: self)
    }

    /// A web address closes; a page the source built stays where it is, its media paused —
    /// on screen it shows without a tap, so closing it would leave an empty card on return.
    @objc private func appDidEnterBackground() {
        for (key, webView) in live where ReaderWebEmbed.isSourceBuiltPage(key) {
            webView.pauseAllMediaPlayback()
        }
        close { key in !ReaderWebEmbed.isSourceBuiltPage(key) }
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
