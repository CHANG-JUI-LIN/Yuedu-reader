import SwiftUI
import WebKit
import Combine
import ObjectiveC
// Modal WebView launched by `java.startBrowser` / `java.startBrowserAwait`.
// Shows a loading state (spinner + top progress bar) while the page loads so
// slow login/key servers don't appear as a frozen blank sheet, plus an error
// state with retry. Syncs WKWebView cookies into CookieStore and
// HTTPCookieStorage when the user taps "Done" (and on each navigation finish).

struct JsBridgeBrowserView: View {
    let urlString: String
    let title: String
    let onDismiss: (_ body: String?) -> Void
    let hidesToolbar: Bool

    init(urlString: String, title: String = "", hidesToolbar: Bool = false, onDismiss: @escaping (_ body: String?) -> Void) {
        self.urlString = urlString
        self.title = title
        self.hidesToolbar = hidesToolbar
        self.onDismiss = onDismiss
    }

    @StateObject private var bridge = JsBridgeBrowserBridge()
    @State private var isSyncing = false

    private var navTitle: String { title.isEmpty ? localized("瀏覽器") : title }

    var body: some View {
        if hidesToolbar {
            contentView
        } else {
            NavigationStack {
                contentView
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
    }

    private var contentView: some View {
        ZStack(alignment: .top) {
            JsBridgeBrowserRepresentable(urlString: urlString, bridge: bridge)
                .edgesIgnoringSafeArea(hidesToolbar ? .all : .bottom)

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
                    .font(DSFont.largeTitle)
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
        // Let JavaScript-driven input focus raise the keyboard (SMS 验证码 fields focus a hidden
        // <input> on tap; the 番茄 验证码 step couldn't open the keyboard otherwise). One-time,
        // process-wide WKContentView patch.
        _ = WKWebView.patchKeyboardFocusOnce

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

        context.coordinator.installKeyboardReFocusWorkaround()

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
        private var keyboardHideObserver: NSObjectProtocol?

        /// WKWebView keeps the tapped `<input>` as `document.activeElement` after the keyboard is
        /// dismissed, so tapping it again fires no new focus event and the keyboard never returns
        /// (e.g. you collapse the 番茄 验证码 keyboard, then can't reopen it). Blur the active
        /// element once the keyboard is fully gone so the next tap is a fresh focus.
        func installKeyboardReFocusWorkaround() {
            keyboardHideObserver = NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardDidHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.webView?.evaluateJavaScript(
                    "if (document.activeElement && document.activeElement.blur) { document.activeElement.blur(); }",
                    completionHandler: nil
                )
            }
        }

        deinit {
            if let keyboardHideObserver {
                NotificationCenter.default.removeObserver(keyboardHideObserver)
            }
        }

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
            // Intercept book-source import deep links so WKWebView doesn't try to
            // navigate to them (an unhandled custom scheme fails as "unsupported URL").
            // We handle our own `yuedu://` scheme plus Legado's `legado://import/...`,
            // which most 書源 update pages emit (e.g. the 更新書源 download button).
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            let scheme = url.scheme?.lowercased()
            let isImportDeepLink = scheme == "yuedu"
                || (scheme == "legado" && url.host?.lowercased() == "import")
            guard isImportDeepLink else {
                decisionHandler(.allow)
                return
            }

            handleImportURL(url, webView: webView)
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
            // Ignore the benign "cancelled" that follows decidePolicy(.cancel) for
            // intercepted yuedu:// / legado:// import links.
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

        private func handleImportURL(_ url: URL, webView: WKWebView) {
            guard let sourceURL = Self.onlineImportSourceURL(from: url) else {
                presentImportResult(localized("無效的書源導入連結"), in: webView)
                return
            }

            URLSession.shared.dataTask(with: sourceURL) { data, _, error in
                DispatchQueue.main.async {
                    if let error {
                        self.presentImportResult(error.localizedDescription, in: webView)
                        return
                    }
                    guard let data else {
                        self.presentImportResult(localized("無法讀取書源資料"), in: webView)
                        return
                    }
                    do {
                        let ext = sourceURL.pathExtension.isEmpty ? "json" : sourceURL.pathExtension
                        let count = try BookSourceStore.shared.importFromData(data, fileExtension: ext)
                        self.presentImportResult(String(format: localized("成功匯入 %d 個書源"), count), in: webView)
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
            let alert = UIAlertController(title: localized("書源導入"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: localized("完成"), style: .default))
            top.present(alert, animated: true)
        }

        static func onlineImportSourceURL(from url: URL) -> URL? {
            guard let scheme = url.scheme?.lowercased() else { return nil }
            let host = url.host?.lowercased()

            // Our own scheme: yuedu://booksource/importOnline?src=URL
            let isYueduImport = scheme == "yuedu"
                && host == "booksource"
                && url.path.lowercased() == "/importonline"
            // Legado deep link: legado://import/{auto,bookSource,bookSourceUrl,…}?src=URL
            // The 更新書源 download button on 書源 sites emits this form.
            let isLegadoImport = scheme == "legado" && host == "import"

            guard isYueduImport || isLegadoImport,
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let sourceString = components.queryItems?.first(where: {
                      let name = $0.name.lowercased()
                      return name == "src" || name == "url"
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

// MARK: - Keyboard-on-programmatic-focus patch
//
// WKWebView suppresses the on-screen keyboard when a web page focuses an `<input>` via JavaScript
// instead of a direct tap. SMS login pages (番茄 included) render the 验证码 field as styled boxes
// whose tap handler calls `input.focus()` — so the phone-number field (a real `<input>` you tap)
// raises the keyboard, but the 验证码 boxes never do. There is no public API for this, so we
// swizzle the private `WKContentView` focus callback ONCE to always report user interaction.
// Runtime-only: no private symbols are linked (looked up via NSClassFromString / sel_getUid).
extension WKWebView {
    /// Lazily-evaluated, thread-safe one-shot patch. Touch `WKWebView.patchKeyboardFocusOnce`
    /// from any web view's `makeUIView` to install it process-wide.
    static let patchKeyboardFocusOnce: Void = {
        guard let contentViewClass = NSClassFromString("WKContentView") else { return }

        // (self, _cmd, focusedElementInfo, userIsInteracting, blurPreviousNode,
        //  activityStateChanges, userObject)
        typealias FocusIMP = @convention(c) (Any, Selector, UnsafeRawPointer, Bool, Bool, UInt, Any?) -> Void

        // iOS 13+ uses `activityStateChanges`; the older `changingActivityState` name is kept as a
        // defensive fallback. Patch whichever exists.
        let selectorNames = [
            "_elementDidFocus:userIsInteracting:blurPreviousNode:activityStateChanges:userObject:",
            "_elementDidFocus:userIsInteracting:blurPreviousNode:changingActivityState:userObject:",
        ]

        for name in selectorNames {
            let selector = sel_getUid(name)
            guard let method = class_getInstanceMethod(contentViewClass, selector) else { continue }
            let originalIMP = method_getImplementation(method)
            let original = unsafeBitCast(originalIMP, to: FocusIMP.self)
            let override: @convention(block) (Any, UnsafeRawPointer, Bool, Bool, UInt, Any?) -> Void = {
                received, element, _, blurPreviousNode, activityStateChanges, userObject in
                // Force `userIsInteracting` = true so the keyboard appears for JS-driven focus.
                original(received, selector, element, true, blurPreviousNode, activityStateChanges, userObject)
            }
            method_setImplementation(method, imp_implementationWithBlock(override))
            return
        }
    }()
}

// MARK: - Preview

#Preview {
    JsBridgeBrowserView(
        urlString: "https://example.com",
        title: "密鑰獲取",
        onDismiss: { _ in }
    )
}
