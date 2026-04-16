import SwiftUI
import WebKit

// MARK: - JsBridgeBrowserView
// Modal WebView launched by `java.startBrowser` / `java.startBrowserAwait`.
// Syncs WKWebView cookies into CookieStore and HTTPCookieStorage on every page load.

struct JsBridgeBrowserView: View {
    let urlString: String
    let title: String
    let onDismiss: () -> Void

    var body: some View {
        NavigationView {
            JsBridgeBrowserRepresentable(urlString: urlString)
                .edgesIgnoringSafeArea(.bottom)
                .navigationTitle(title.isEmpty ? "瀏覽器" : title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("取消") { onDismiss() }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("完成") { onDismiss() }
                            .font(.body.weight(.semibold))
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - UIViewRepresentable

struct JsBridgeBrowserRepresentable: UIViewRepresentable {
    let urlString: String

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
        if let url = URL(string: urlString) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncCookies(from: webView)
        }

        private func syncCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                guard !cookies.isEmpty else { return }

                // ① Push into URLSession's shared cookie storage
                cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }

                // ② Group by domain and push into CookieStore (for JS bridge access)
                var byDomain: [String: [HTTPCookie]] = [:]
                for cookie in cookies {
                    let domain = cookie.domain.hasPrefix(".")
                        ? String(cookie.domain.dropFirst()) : cookie.domain
                    byDomain["https://\(domain)", default: []].append(cookie)
                }
                for (domainKey, domainCookies) in byDomain {
                    let joined = domainCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    CookieStore.shared.set(url: domainKey, cookie: joined)
                }
            }
        }
    }
}
