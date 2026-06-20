import Foundation
import WebKit

/// Offscreen WKWebView runner backing Legado's `java.webView(html, url, js)`.
///
/// Loads `url` (or raw `html`), waits for the navigation to finish, evaluates
/// `js`, and resolves with the string result. Cookies acquired during the load
/// are copied into `HTTPCookieStorage` so subsequent `java.ajax` /
/// `cookie.getCookie` calls reuse the freshly-issued session (e.g. CSRF tokens).
///
/// The WebView lives on the main actor. The bridge calls `run(...)` from a
/// `Task { @MainActor in … }` while blocking the JS serial queue on a semaphore,
/// mirroring the existing `startBrowserAwait` pattern.
@MainActor
final class LegadoHeadlessWebView: NSObject, WKNavigationDelegate {

    private var webView: WKWebView?
    private let js: String
    private var continuation: CheckedContinuation<String, Never>?
    private var finished = false

    /// Strong references that keep in-flight runners alive until they resolve.
    private static var retained: [LegadoHeadlessWebView] = []

    private init(js: String) {
        self.js = js
        super.init()
    }

    /// Run a headless load + JS evaluation. Always resolves (with "" on failure/timeout).
    static func run(
        html: String?,
        url: String?,
        js: String,
        userAgent: String?,
        timeout: TimeInterval
    ) async -> String {
        let runner = LegadoHeadlessWebView(js: js)
        retained.append(runner)
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            runner.continuation = cont
            runner.begin(html: html, url: url, userAgent: userAgent, timeout: timeout)
        }
    }

    private func begin(html: String?, url: String?, userAgent: String?, timeout: TimeInterval) {
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: config)
        if let ua = userAgent, !ua.isEmpty { wv.customUserAgent = ua }
        wv.navigationDelegate = self
        webView = wv

        // Hard timeout: never leave the JS queue blocked indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish("")
        }

        if let urlStr = url, let u = URL(string: urlStr) {
            wv.load(URLRequest(url: u))
        } else if let html {
            wv.loadHTMLString(html, baseURL: url.flatMap { URL(string: $0) })
        } else {
            finish("")
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(js) { [weak self] value, _ in
            guard let self else { return }
            // Persist cookies set during the load before returning.
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
                self.finish(Self.stringify(value))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish("")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish("")
    }

    // MARK: - Helpers

    private func finish(_ value: String) {
        guard !finished else { return }
        finished = true
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        continuation?.resume(returning: value)
        continuation = nil
        Self.retained.removeAll { $0 === self }
    }

    private static func stringify(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let arr = value as? [Any] {
            return arr.map { stringify($0) }.joined(separator: "\n")
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "\(value)"
    }
}
