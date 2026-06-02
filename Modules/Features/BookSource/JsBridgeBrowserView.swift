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
        NavigationStack {
            JsBridgeBrowserRepresentable(urlString: urlString, bridge: bridge)
                .edgesIgnoringSafeArea(.bottom)
                .navigationTitle(title.isEmpty ? "瀏覽器" : title)
                .toolbarTitleDisplayMode(.inlineLarge)
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
            context.coordinator.load(url: url, in: wv)
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  url.scheme?.lowercased() == "yuedu" else {
                decisionHandler(.allow)
                return
            }

            handleYueduURL(url, webView: webView)
            decisionHandler(.cancel)
        }

        func load(url: URL, in webView: WKWebView) {
            let request = URLRequest(url: url)
            let cookies = Self.cookiesForInitialLoad(url: url)
            guard !cookies.isEmpty else {
                webView.load(request)
                return
            }

            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                cookieStore.setCookie(cookie) {
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                webView.load(request)
            }
        }

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

        private func handleYueduURL(_ url: URL, webView: WKWebView) {
            guard let sourceURL = Self.onlineImportSourceURL(from: url) else {
                presentImportResult("無效的書源導入連結", in: webView)
                return
            }

            URLSession.shared.dataTask(with: sourceURL) { data, _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.presentImportResult(error.localizedDescription, in: webView)
                        return
                    }
                    guard let data else {
                        self.presentImportResult("無法讀取書源資料", in: webView)
                        return
                    }
                    do {
                        let ext = sourceURL.pathExtension.isEmpty ? "json" : sourceURL.pathExtension
                        let count = try BookSourceStore.shared.importFromData(data, fileExtension: ext)
                        self.presentImportResult("成功匯入 \(count) 個書源", in: webView)
                    } catch {
                        self.presentImportResult(error.localizedDescription, in: webView)
                    }
                }
            }.resume()
        }

        private func presentImportResult(_ message: String, in webView: WKWebView) {
            guard let presenter = webView.window?.rootViewController else { return }
            var top = presenter
            while let presented = top.presentedViewController {
                top = presented
            }
            let alert = UIAlertController(title: "書源導入", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "完成", style: .default))
            top.present(alert, animated: true)
        }

        static func onlineImportSourceURL(from url: URL) -> URL? {
            guard url.scheme?.lowercased() == "yuedu",
                  url.host?.lowercased() == "booksource",
                  url.path.lowercased() == "/importonline",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let sourceString = components.queryItems?.first(where: {
                      $0.name == "src" || $0.name == "url"
                  })?.value else {
                return nil
            }
            return URL(string: sourceString)
        }

        static func cookiesForInitialLoad(url: URL) -> [HTTPCookie] {
            HTTPCookieStorage.shared.cookies(for: url) ?? []
        }
    }
}
