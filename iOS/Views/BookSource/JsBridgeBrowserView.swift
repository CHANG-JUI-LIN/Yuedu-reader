import SwiftUI
import WebKit
import Combine
// Modal WebView launched by `java.startBrowser` / `java.startBrowserAwait`.
// Syncs WKWebView cookies into CookieStore and HTTPCookieStorage when the user
// taps "Done" (and also on each navigation finish for non-CF scenarios).

struct JsBridgeBrowserView: View {
    let urlString: String
    let title: String
    let onDismiss: (_ body: String?) -> Void

    @StateObject private var bridge = JsBridgeBrowserBridge()
    @State private var isSyncing = false

    var body: some View {
        NavigationView {
            JsBridgeBrowserRepresentable(urlString: urlString, bridge: bridge)
                .edgesIgnoringSafeArea(.bottom)
                .navigationTitle(title.isEmpty ? "瀏覽器" : title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("取消") { onDismiss(nil) }
                            .disabled(isSyncing)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        if isSyncing {
                            ProgressView().scaleEffect(0.85)
                        } else {
                            Button("完成") {
                                isSyncing = true
                                bridge.syncCookiesAndDismiss? { body in
                                    onDismiss(body)
                                }
                            }
                            .font(.body.weight(.semibold))
                        }
                    }
                }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - JsBridgeBrowserBridge

final class JsBridgeBrowserBridge: ObservableObject {
    var syncCookiesAndDismiss: ((@escaping (String?) -> Void) -> Void)?
}

// MARK: - UIViewRepresentable

struct JsBridgeBrowserRepresentable: UIViewRepresentable {
    let urlString: String
    let bridge: JsBridgeBrowserBridge

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
        context.coordinator.webView = wv

        let coordinator = context.coordinator
        bridge.syncCookiesAndDismiss = { completion in
            guard let wv = coordinator.webView else { completion(nil); return }
            coordinator.syncCookiesAndDismiss(from: wv, completion: completion)
        }

        if let url = URL(string: urlString) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            syncCookiesAndDismiss(from: webView, completion: nil)
        }

        func syncCookiesAndDismiss(from webView: WKWebView, completion: ((String?) -> Void)?) {
            webView.evaluateJavaScript("document.documentElement.outerHTML") { body, _ in
                let pageBody = body as? String
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    guard !cookies.isEmpty else { completion?(pageBody); return }

                    cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }

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

                    completion?(pageBody)
                }
            }
        }
    }
}

