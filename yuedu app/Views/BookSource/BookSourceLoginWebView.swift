import SwiftUI
import WebKit

// MARK: - BookSourceLoginWebView

/// Interactive WebView login for book sources that require cookie authentication.
/// Shows the book source's `loginUrl` (or `bookSourceUrl` as fallback) in a real
/// browser. Cookies are captured from WKWebView on each navigation finish and
/// persisted to `CookieStore`. The user taps "完成" when they have logged in.
struct BookSourceLoginWebView: View {
    let source: BookSource
    let onDismiss: () -> Void

    private let gs = GlobalSettings.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundColor(DSColor.accent)
                    Text(gs.t("請在下方完成登入。登入成功後點「完成」，Cookie 將自動儲存供書源使用。"))
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                    Spacer()
                }
                .padding()
                .background(DSColor.accent.opacity(0.06))

                BookSourceLoginWebViewRepresentable(source: source)
                    .edgesIgnoringSafeArea(.bottom)
            }
            .navigationTitle(gs.t("Cookie 驗證登入"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(gs.t("取消")) { onDismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(gs.t("完成")) { onDismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - UIViewRepresentable

struct BookSourceLoginWebViewRepresentable: UIViewRepresentable {
    let source: BookSource

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = context.coordinator

        if let url = Self.effectiveURL(source: source) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(source: source) }

    /// Resolves the effective URL to open in the WebView.
    /// Legado's `loginUrl` can be:
    ///   1. A plain URL:                `https://www.qidian.com/sign/`
    ///   2. A JS expression:            `@js: java.webView("https://...")`
    ///   3. Empty → fall back to bookSourceUrl
    static func effectiveURL(source: BookSource) -> URL? {
        let raw = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1. Plain URL
        if !raw.isEmpty && !raw.hasPrefix("@") && !raw.hasPrefix("{") {
            if let url = URL(string: raw) { return url }
        }

        // 2. @js: expression — extract the first https?:// URL from inside quotes
        if raw.lowercased().hasPrefix("@js:") {
            let js = raw.dropFirst(4)
            if let range = js.range(of: #"https?://[^"'\s)>]+"#, options: .regularExpression) {
                if let url = URL(string: String(js[range])) { return url }
            }
        }

        // 3. Fall back to bookSourceUrl
        return URL(string: source.bookSourceUrl)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let source: BookSource

        init(source: BookSource) { self.source = source }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncCookies(from: webView)
        }

        /// Copies all WKWebView cookies into CookieStore (for JS bridge) AND into
        /// LoginManager as a Cookie header (for URLSession requests).
        ///
        /// WKWebView uses an isolated cookie store (WKWebsiteDataStore) that does NOT
        /// sync with HTTPCookieStorage / URLSession automatically. We bridge the gap on
        /// every page load so the full cookie jar is available when the user hits "完成".
        private func syncCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [source] cookies in
                guard !cookies.isEmpty else { return }

                // ① Push every cookie into HTTPCookieStorage for URLSession auto-handling
                cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }

                let cookieString = cookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                // ② CookieStore keyed by loginUrl (JS bridge access)
                if let baseURL = BookSourceLoginWebViewRepresentable.effectiveURL(source: source) {
                    CookieStore.shared.set(url: baseURL.absoluteString, cookie: cookieString)
                }

                // ③ LoginManager keyed by bookSourceUrl — this is what applyLoginHeaders()
                //    reads when constructing every URLRequest in the rule engine.
                var headers = LoginManager.shared.getLoginHeaders(sourceUrl: source.bookSourceUrl)
                headers["Cookie"] = cookieString
                LoginManager.shared.storeLoginHeaders(
                    sourceUrl: source.bookSourceUrl, headers: headers
                )
            }
        }
    }
}
