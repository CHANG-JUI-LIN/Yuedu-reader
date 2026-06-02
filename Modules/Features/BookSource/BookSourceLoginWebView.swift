import SwiftUI
import WebKit
import Combine

/// Interactive WebView login for book sources that require cookie authentication.
/// Shows the book source's `loginUrl` (or `bookSourceUrl` as fallback) in a real
/// browser. Cookies are captured **when the user taps "Done"** — NOT on `didFinish` —
/// so that Cloudflare `cf_clearance` and other async-set cookies are captured
/// after all JS challenges have resolved.
struct BookSourceLoginWebView: View {
    let source: BookSource
    let onDismiss: () -> Void

    private let gs = GlobalSettings.shared
/// Bridge object shared with the UIViewRepresentable; wires the "Done" button to the
/// cookie sync routine running inside the Coordinator.
    @StateObject private var bridge = LoginWebBridge()
    @State private var isSyncing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .foregroundColor(DSColor.accent)
                    Text(localized("請在下方完成登入。登入成功後點「完成」，Cookie 將自動儲存供書源使用。"))
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                    Spacer()
                }
                .padding()
                .background(DSColor.accent.opacity(0.06))

                BookSourceLoginWebViewRepresentable(source: source, bridge: bridge)
                    .edgesIgnoringSafeArea(.bottom)
            }
            .navigationTitle(localized("Cookie 驗證登入"))
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) { onDismiss() }
                        .disabled(isSyncing)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSyncing {
                        ProgressView().scaleEffect(0.85)
                    } else {
                        Button(localized("完成")) {
                            isSyncing = true
                            bridge.syncCookiesAndDismiss? {
                                onDismiss()
                            }
                        }
                        .font(.body.weight(.semibold))
                    }
                }
            }
        }
    }
}

// MARK: - LoginWebBridge

/// Reference-type bridge that lets the SwiftUI "Done" button trigger the WKWebView's
/// cookie extraction inside the UIKit Coordinator.
final class LoginWebBridge: ObservableObject {
    /// Set by the Coordinator after the WKWebView is created.
    /// Calling it triggers a full cookie sync and then invokes `completion`.
    var syncCookiesAndDismiss: ((@escaping () -> Void) -> Void)?
}

// MARK: - UIViewRepresentable

struct BookSourceLoginWebViewRepresentable: UIViewRepresentable {
    let source: BookSource
    let bridge: LoginWebBridge

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

        // Give the Coordinator a weak reference so the bridge closure can reach it
        context.coordinator.webView = wv

        // Wire the "Done" button to the Coordinator's authoritative sync
        let coordinator = context.coordinator
        bridge.syncCookiesAndDismiss = { completion in
            guard let wv = coordinator.webView else { completion(); return }
            coordinator.syncCookies(from: wv, completion: completion)
        }

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
        /// Weak reference set in makeUIView; used by the bridge closure.
        weak var webView: WKWebView?

        init(source: BookSource) { self.source = source }

        /// Intermediate sync on each page load — catches non-Cloudflare cookies early.
        /// The definitive sync always happens when the user taps "Done".
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncCookies(from: webView, completion: nil)
        }

        /// Pull all WKWebView cookies (including async-set Cloudflare `cf_clearance`)
        /// into CookieStore, HTTPCookieStorage, and LoginManager. Calls `completion`
        /// after the async cookie fetch completes.
        func syncCookies(from webView: WKWebView, completion: (() -> Void)?) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [source] cookies in
                guard !cookies.isEmpty else { completion?(); return }

                // (1) Push every cookie into HTTPCookieStorage for URLSession auto-handling
                cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }

                let cookieString = cookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                // (2) CookieStore keyed by loginUrl (JS bridge access)
                if let baseURL = BookSourceLoginWebViewRepresentable.effectiveURL(source: source) {
                    CookieStore.shared.set(url: baseURL.absoluteString, cookie: cookieString)
                }

                // (3) LoginManager keyed by bookSourceUrl — read by applyLoginHeaders()
                //    when constructing every URLRequest in the rule engine.
                var headers = LoginManager.shared.getLoginHeaders(sourceUrl: source.bookSourceUrl)
                headers["Cookie"] = cookieString
                LoginManager.shared.storeLoginHeaders(
                    sourceUrl: source.bookSourceUrl, headers: headers
                )

                completion?()
            }
        }
    }
}

