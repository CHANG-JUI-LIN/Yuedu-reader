import SwiftUI
import WebKit
import Combine
// Modal WebView launched by `java.startBrowser` / `java.startBrowserAwait`.
// Shows a loading state (spinner + top progress bar) while the page loads so
// slow login/key servers don't appear as a frozen blank sheet, plus an error
// state with retry. Syncs WKWebView cookies into CookieStore and
// HTTPCookieStorage when the user taps "Done" (and on each navigation finish).

struct JsBridgeBrowserView: View {
    let urlString: String
    let title: String
    let onDismiss: (_ body: String?) -> Void

    @StateObject private var bridge = JsBridgeBrowserBridge()
    @State private var isSyncing = false

    private var navTitle: String { title.isEmpty ? localized("瀏覽器") : title }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                JsBridgeBrowserRepresentable(urlString: urlString, bridge: bridge)
                    .edgesIgnoringSafeArea(.bottom)

                // Full-screen state until the page delivers its first content.
                switch bridge.phase {
                case .loading:
                    loadingOverlay
                case .failed:
                    errorOverlay
                case .committed, .finished:
                    EmptyView()
                }

                // Safari-style thin progress bar across the top while loading.
                if (bridge.phase == .loading || bridge.phase == .committed), bridge.progress < 1 {
                    ProgressView(value: max(bridge.progress, 0.03))
                        .progressViewStyle(.linear)
                        .tint(DSColor.accent)
                        .transition(.opacity)
                }
            }
            .animation(DSAnimation.fast, value: bridge.phase)
            .animation(DSAnimation.fast, value: bridge.progress)
            .navigationTitle(navTitle)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        onDismiss(nil)
                    } label: {
                        Label(localized("取消"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("取消"))
                    .disabled(isSyncing)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isSyncing {
                        ProgressView().scaleEffect(0.85)
                    } else {
                        Button {
                            isSyncing = true
                            bridge.syncCookiesAndDismiss? { body in
                                onDismiss(body)
                            }
                        } label: {
                            Label(localized("完成"), systemImage: "checkmark")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel(localized("完成"))
                    }
                }
            }
        }
    }

    // MARK: - Overlays

    private var loadingOverlay: some View {
        ZStack {
            DSColor.background.ignoresSafeArea()
            VStack(spacing: DSSpacing.md) {
                ProgressView()
                    .controlSize(.large)
                Text(localized("載入中…"))
                    .font(DSFont.subheadline)
                    .foregroundStyle(DSColor.textSecondary)
            }
        }
        .transition(.opacity)
    }

    private var errorOverlay: some View {
        ZStack {
            DSColor.background.ignoresSafeArea()
            VStack(spacing: DSSpacing.md) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(DSColor.textSecondary)
                Text(localized("載入失敗"))
                    .font(DSFont.headline)
                if let detail = bridge.errorText, !detail.isEmpty {
                    Text(detail)
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                        .multilineTextAlignment(.center)
                }
                Button(localized("重試")) { bridge.reload?() }
                    .buttonStyle(.bordered)
                    .tint(DSColor.accent)
            }
            .padding(DSSpacing.lg)
        }
        .transition(.opacity)
    }
}

// MARK: - JsBridgeBrowserBridge

final class JsBridgeBrowserBridge: ObservableObject {
    enum Phase { case loading, committed, finished, failed }

    var syncCookiesAndDismiss: ((@escaping (String?) -> Void) -> Void)?
    var reload: (() -> Void)?

    @Published var progress: Double = 0
    @Published var phase: Phase = .loading
    @Published var errorText: String?
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
        context.coordinator.bridge = bridge

        // Drive the progress bar from the live load estimate.
        context.coordinator.progressObservation = wv.observe(\.estimatedProgress, options: [.new]) { [weak bridge] web, _ in
            DispatchQueue.main.async { bridge?.progress = web.estimatedProgress }
        }

        let coordinator = context.coordinator
        bridge.syncCookiesAndDismiss = { [weak coordinator] completion in
            guard let wv = coordinator?.webView else { completion(nil); return }
            coordinator?.syncCookiesAndDismiss(from: wv, completion: completion)
        }
        bridge.reload = { [weak coordinator, weak bridge] in
            guard let coordinator, let wv = coordinator.webView,
                  let url = URL(string: urlString) else { return }
            bridge?.phase = .loading
            bridge?.errorText = nil
            bridge?.progress = 0
            coordinator.load(url: url, in: wv)
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
        weak var bridge: JsBridgeBrowserBridge?
        var progressObservation: NSKeyValueObservation?

        private func setPhase(_ phase: JsBridgeBrowserBridge.Phase, error: String? = nil) {
            DispatchQueue.main.async { [weak self] in
                self?.bridge?.phase = phase
                if let error { self?.bridge?.errorText = error }
            }
        }

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

        // MARK: Navigation phases (drive the loading / error UI)

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            setPhase(.loading)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            setPhase(.committed)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { [weak self] in
                self?.bridge?.progress = 1
                self?.bridge?.phase = .finished
            }
            syncCookiesAndDismiss(from: webView, completion: nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            setPhase(.failed, error: error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            // Ignore the benign "cancelled" that follows decidePolicy(.cancel) for yuedu:// links.
            if (error as NSError).code == NSURLErrorCancelled { return }
            setPhase(.failed, error: error.localizedDescription)
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

// MARK: - Preview

#Preview {
    JsBridgeBrowserView(
        urlString: "https://example.com",
        title: "密鑰獲取",
        onDismiss: { _ in }
    )
}
