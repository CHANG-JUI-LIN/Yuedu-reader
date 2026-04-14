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
                    Text(gs.t("本站啟用了防護 (Cloudflare / DDoS-Guard)。\n請手動通過人機驗證後，系統將自動繼續。"))
                        .font(.caption)
                        .foregroundColor(DSColor.textSecondary)
                    Spacer()
                }
                .padding()
                .background(Color(.systemGray6))

                InteractiveWebView(url: targetURL, onPassed: onChallengePassed)
                    .edgesIgnoringSafeArea(.bottom)
            }
            .navigationTitle(gs.t("網站安全驗證"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(leading: Button(gs.t("放棄")) { onCancel() })
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
            // Check every 2 seconds if the page no longer has the challenge element
            checkingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
                [weak self] _ in
                guard let self = self else { return }

                webView.evaluateJavaScript(
                    "document.documentElement.outerHTML"
                ) { [weak self] result, error in
                    guard let self = self, let html = result as? String else { return }

                    // Simple heuristic: if the page title is not "Just a moment..." and doesn't contain common CF/DDOS keywords, we assume it's passed.
                    let isChallenge =
                        html.contains("cf-browser-verification") || html.contains("Just a moment")
                        || html.contains("DDoS-Guard")

                    // Ensure the title is not empty, usually CF pages have very specific small titles.
                    // Another reliable way is to check HTTP cookies for `cf_clearance`.
                    // But checking HTML content is easiest.
                    if !isChallenge && html.count > 2000 {
                        // Looks like a real page!
                        self.checkingTimer?.invalidate()
                        self.checkingTimer = nil
                        DispatchQueue.main.async {
                            self.parent.onPassed(html)
                        }
                    }
                }
            }
        }
    }
}
