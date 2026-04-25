import SwiftUI
import WebKit

struct CloudflareChallengeView: View {
    let targetURL: URL
    let onChallengePassed: (String) -> Void
    let onCancel: () -> Void
    let gs = GlobalSettings.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Info banner
                HStack {
                    Image(systemName: "exclamationmark.shield.fill")
                        .foregroundColor(.orange)
                    Text(localized("本站啟用了防護 (Cloudflare / DDoS-Guard)。\n請手動通過人機驗證後，系統將自動繼續。"))
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                    Spacer()
                }
                .padding()
                .background(Color(.systemGray6))

                InteractiveWebView(url: targetURL, onPassed: onChallengePassed)
                    .edgesIgnoringSafeArea(.bottom)
            }
            .navigationTitle(localized("網站安全驗證"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button(localized("放棄")) { onCancel() })
        }
    }
}

struct InteractiveWebView: UIViewRepresentable {
    let url: URL
    let onPassed: (String) -> Void  // Return full HTML source when done

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

        let request = URLRequest(url: url)
        wv.load(request)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: InteractiveWebView
        var checkingTimer: Timer?

        init(_ parent: InteractiveWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            startCheckingCaptcha(webView)
        }

        private func startCheckingCaptcha(_ webView: WKWebView) {
            checkingTimer?.invalidate()
            // Check every 0.5 s — fast sites pass CF in under 1 s; keep latency low.
            checkingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
                [weak self] _ in
                guard let self = self else { return }
                self.checkOnce(webView)
            }
        }

        private func checkOnce(_ webView: WKWebView) {
            // Primary signal: presence of the `cf_clearance` cookie (most reliable).
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                guard let self = self else { return }
                let hasClearance = cookies.contains { $0.name == "cf_clearance" }
                if hasClearance {
                    self.passed(webView)
                    return
                }
                // Fallback: HTML body no longer contains CF challenge markers.
                webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] result, _ in
                    guard let self = self, let html = result as? String else { return }
                    let isChallenge =
                        html.contains("cf-browser-verification")
                        || html.contains("cf_chl_prog")
                        || html.contains("Just a moment")
                        || html.contains("DDoS-Guard")
                    if !isChallenge && html.count > 2000 {
                        self.passed(webView)
                    }
                }
            }
        }

        private func passed(_ webView: WKWebView) {
            guard checkingTimer != nil else { return }  // guard against double-fire
            checkingTimer?.invalidate()
            checkingTimer = nil

            // Harvest all WKWebView cookies into shared stores before returning.
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies {
                [weak self] cookies in
                guard let self = self else { return }

                // Group by domain so we can build CookieStore strings efficiently.
                var byDomain: [String: [HTTPCookie]] = [:]
                for cookie in cookies {
                    HTTPCookieStorage.shared.setCookie(cookie)
                    let domain = cookie.domain.hasPrefix(".")
                        ? String(cookie.domain.dropFirst()) : cookie.domain
                    byDomain[domain, default: []].append(cookie)
                }
                for (domain, domainCookies) in byDomain {
                    let str = domainCookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
                    CookieStore.shared.set(url: "https://\(domain)", cookie: str)
                }

                webView.evaluateJavaScript("document.documentElement.outerHTML") {
                    [weak self] result, _ in
                    let html = (result as? String) ?? ""
                    DispatchQueue.main.async {
                        self?.parent.onPassed(html)
                    }
                }
            }
        }
    }
}
