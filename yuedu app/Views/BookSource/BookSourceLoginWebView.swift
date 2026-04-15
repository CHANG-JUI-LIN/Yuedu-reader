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

        let loginTarget = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: loginTarget.isEmpty ? source.bookSourceUrl : loginTarget) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(source: source) }

    // MARK: - Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let source: BookSource

        init(source: BookSource) { self.source = source }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncCookies(from: webView)
        }

        /// Copies all domain-relevant WKWebView cookies into `CookieStore`.
        private func syncCookies(from webView: WKWebView) {
            let loginTarget = source.loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            let urlString = loginTarget.isEmpty ? source.bookSourceUrl : loginTarget
            guard let baseURL = URL(string: urlString), let host = baseURL.host else { return }

            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let relevant = cookies.filter { c in
                    let domain = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
                    return domain.hasSuffix(host) || host.hasSuffix(domain)
                }
                guard !relevant.isEmpty else { return }
                let cookieString = relevant
                    .map { "\($0.name)=\($0.value)" }
                    .joined(separator: "; ")
                CookieStore.shared.set(url: baseURL.absoluteString, cookie: cookieString)
            }
        }
    }
}
