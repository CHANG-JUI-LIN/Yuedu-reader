import WebKit

/// The identity every in-app WKWebView presents, in one place.
///
/// The same iPhone user-agent string had been pasted into five WebViews — the source login, the
/// 發現頁 browser, the JS-bridge debug browser, the Cloudflare challenge view, and the headless
/// fetcher — so a site that answers a phone with an app-download page (bot.n.cn) was a dead end in
/// every one of them, and changing that meant finding and editing five literals.
enum SourceWebIdentity {

    /// Written out rather than left to WebKit because WebKit's own default omits the
    /// `Version/… Safari/…` tail, and sites gate on it.
    static let phoneUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// The user-agent for a content mode, or nil to let WebKit choose.
    ///
    /// Desktop deliberately returns nil. "Request desktop site" is
    /// `WKWebpagePreferences.preferredContentMode`, not a string swap: it widens the layout
    /// viewport *and* supplies the matching macOS Safari identity. Overriding the user-agent by
    /// hand delivers desktop HTML into a ~390pt phone viewport, which renders as a squeezed page
    /// with nothing reachable on it.
    static func userAgent(desktop: Bool) -> String? {
        desktop ? nil : phoneUserAgent
    }

    static func contentMode(desktop: Bool) -> WKWebpagePreferences.ContentMode {
        desktop ? .desktop : .mobile
    }

    /// Applies a content mode to a live WebView. The caller reloads: the page already on screen
    /// was chosen for the previous identity, but only the caller knows whether it is safe to
    /// throw away (a half-finished sign-in is not).
    static func apply(desktop: Bool, to webView: WKWebView) {
        webView.customUserAgent = userAgent(desktop: desktop)
        webView.configuration.defaultWebpagePreferences.preferredContentMode =
            contentMode(desktop: desktop)
    }
}
