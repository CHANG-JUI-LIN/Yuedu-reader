import SwiftUI
import WebKit
import Combine

/// Interactive WebView login for any source that authenticates with a cookie — book sources and
/// voice sources both, via `SourceWebLogin`.
///
/// Cookies are captured **when the user taps "Done"** — NOT on `didFinish` — so that Cloudflare
/// `cf_clearance` and other async-set cookies are captured after all JS challenges have resolved.
struct SourceLoginWebView: View {
    let login: SourceWebLogin
    let onDismiss: () -> Void

    private let gs = GlobalSettings.shared
/// Bridge object shared with the UIViewRepresentable; wires the "Done" button to the
/// cookie sync routine running inside the Coordinator.
    @StateObject private var bridge = LoginWebBridge()
    @State private var isSyncing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SourceLoginWebViewRepresentable(login: login, bridge: bridge)
                    .edgesIgnoringSafeArea(.bottom)
                    .overlay(alignment: .top) {
                        // md3's `LinearProgressIndicator` — visible while the page loads.
                        if bridge.progress > 0 && bridge.progress < 1 {
                            ProgressView(value: bridge.progress)
                                .progressViewStyle(.linear)
                                .tint(DSColor.accent)
                                .transition(.opacity)
                        }
                    }
            }
            .navigationTitle(loginTitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(localized("取消"))
                    .disabled(isSyncing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSyncing {
                        ProgressView().scaleEffect(0.85)
                    } else {
                        Button {
                            isSyncing = true
                            bridge.syncCookiesAndDismiss? {
                                onDismiss()
                            }
                        } label: {
                            Image(systemName: "checkmark")
                        }
                        .accessibilityLabel(localized("完成"))
                    }
                }
            }
        }
    }

    /// Same 「登入：源名稱」 title format as the form login sheet.
    private var loginTitle: String {
        String(format: localized("登入：%@"), login.name)
    }
}

// MARK: - LoginWebBridge

/// Reference-type bridge that lets the SwiftUI "Done" button trigger the WKWebView's
/// cookie extraction inside the UIKit Coordinator, and publishes the page-load
/// progress for the top linear indicator (md3's LinearProgressIndicator).
final class LoginWebBridge: ObservableObject {
    /// Set by the Coordinator after the WKWebView is created.
    /// Calling it triggers a full cookie sync and then invokes `completion`.
    var syncCookiesAndDismiss: ((@escaping () -> Void) -> Void)?
    /// 0…1 while the page loads; 1 (hidden) once loaded.
    @Published var progress: Double = 0
}

// MARK: - UIViewRepresentable

struct SourceLoginWebViewRepresentable: UIViewRepresentable {
    let login: SourceWebLogin
    let bridge: LoginWebBridge

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        // Same reason as JsBridgeBrowserView: a widget that opens its own window
        // (captcha / OAuth) is blocked before the UI delegate is consulted.
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        context.coordinator.clipboardBridge.install(in: config.userContentController)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator.uiDelegate  // weak on WKWebView

        // Give the Coordinator a weak reference so the bridge closure can reach it
        context.coordinator.webView = wv
        context.coordinator.observeProgress(publishingTo: bridge)

        // Wire the "Done" button to the Coordinator's authoritative sync
        let coordinator = context.coordinator
        bridge.syncCookiesAndDismiss = { completion in
            guard let wv = coordinator.webView else { completion(); return }
            coordinator.syncCookies(from: wv, completion: completion)
        }

        wv.load(URLRequest(url: login.url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.clipboardBridge.remove(from: uiView.configuration.userContentController)
    }

    func makeCoordinator() -> Coordinator { Coordinator(login: login) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let login: SourceWebLogin
        /// Weak reference set in makeUIView; used by the bridge closure.
        weak var webView: WKWebView?
        /// Strongly held: `WKWebView.uiDelegate` is weak.
        let uiDelegate = SourceWebUIDelegate()
        let clipboardBridge = SourceWebClipboardBridge()
        private var progressObservation: NSKeyValueObservation?
        private weak var progressBridge: LoginWebBridge?

        init(login: SourceWebLogin) { self.login = login }

        /// KVO on `estimatedProgress` → publishes into the SwiftUI bridge for the
        /// top linear loading indicator (md3's LinearProgressIndicator).
        func observeProgress(publishingTo bridge: LoginWebBridge) {
            progressBridge = bridge
            guard let webView else { return }
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak bridge] wv, _ in
                Task { @MainActor in
                    bridge?.progress = wv.estimatedProgress
                }
            }
        }

        /// Intermediate sync on each page load — catches non-Cloudflare cookies early.
        /// The definitive sync always happens when the user taps "Done".
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in progressBridge?.progress = 1 }
            syncCookies(from: webView, completion: nil)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in progressBridge?.progress = 0 }
        }

        /// Pull all WKWebView cookies (including async-set Cloudflare `cf_clearance`)
        /// into CookieStore, HTTPCookieStorage, and LoginManager. Calls `completion`
        /// after the async cookie fetch completes.
        func syncCookies(from webView: WKWebView, completion: (() -> Void)?) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [login] cookies in
                guard !cookies.isEmpty else { completion?(); return }

                // (1) Push every cookie into HTTPCookieStorage for URLSession auto-handling
                cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }

                let cookieString = cookies
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")

                // (2) CookieStore keyed by the page that was opened (JS bridge access)
                CookieStore.shared.set(url: login.url.absoluteString, cookie: cookieString)

                // (3) LoginManager keyed by the source's own key — read by applyLoginHeaders()
                //    when the rule engine builds a request, and merged into every TTS synthesis
                //    request by `CustomHTTPProvider.buildJSRequestOrThrow`.
                var headers = LoginManager.shared.getLoginHeaders(sourceUrl: login.storageKey)
                headers["Cookie"] = cookieString
                LoginManager.shared.storeLoginHeaders(
                    sourceUrl: login.storageKey, headers: headers
                )

                completion?()
            }
        }
    }
}
