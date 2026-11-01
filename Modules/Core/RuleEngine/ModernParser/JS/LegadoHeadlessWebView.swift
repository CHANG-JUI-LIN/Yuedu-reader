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
///
/// It also finds the video a source's player page plays (`sniffVideo`), so the episode plays
/// in the app's own player instead of the page.
@MainActor
final class LegadoHeadlessWebView: NSObject, WKNavigationDelegate, WKScriptMessageHandler {

    private enum CaptureMode {
        case evaluatedJavaScript
        case resource(regex: String)
        case overrideURL(regex: String)
        /// The first link the page hands a `<video>`, or the first request `isVideoRequest`
        /// takes for a stream (an HLS player fetches its playlist itself).
        case video(isVideoRequest: (URL) -> Bool)
    }

    private var webView: WKWebView?
    private let js: String
    private let captureMode: CaptureMode
    private var initialURL: String?
    private var continuation: CheckedContinuation<String, Never>?
    private var finished = false
    /// The video `sniffVideo` found, held while the page's cookies are copied out.
    private var sniffedVideo: String?

    /// Strong references that keep in-flight runners alive until they resolve.
    private static var retained: [LegadoHeadlessWebView] = []

    private init(js: String, captureMode: CaptureMode) {
        self.js = js
        self.captureMode = captureMode
        super.init()
    }

    /// Run a headless load + JS evaluation. Always resolves (with "" on failure/timeout).
    static func run(
        html: String?,
        url: String?,
        js: String,
        userAgent: String?,
        timeout: TimeInterval,
        sourceRegex: String? = nil,
        overrideURLRegex: String? = nil
    ) async -> String {
        let mode: CaptureMode
        if let sourceRegex, !sourceRegex.isEmpty {
            mode = .resource(regex: sourceRegex)
        } else if let overrideURLRegex, !overrideURLRegex.isEmpty {
            mode = .overrideURL(regex: overrideURLRegex)
        } else {
            mode = .evaluatedJavaScript
        }
        let runner = LegadoHeadlessWebView(js: js, captureMode: mode)
        retained.append(runner)
        return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            runner.continuation = cont
            let request = url.flatMap(URL.init(string:)).map { URLRequest(url: $0) }
            runner.begin(request: request, html: html, baseURL: url, userAgent: userAgent, timeout: timeout)
        }
    }

    /// The video `page` plays, found the way legado's `sourceRegex` finds a resource: the page
    /// loads unseen and its own script picks the stream; nothing plays and nothing is shown.
    /// Nil when the page hands its player nothing `isVideoRequest` takes by `timeout`.
    static func sniffVideo(
        page: URLRequest,
        userAgent: String?,
        timeout: TimeInterval,
        isVideoRequest: @escaping (URL) -> Bool
    ) async -> URL? {
        let runner = LegadoHeadlessWebView(js: "", captureMode: .video(isVideoRequest: isVideoRequest))
        retained.append(runner)
        let found = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            runner.continuation = cont
            runner.begin(request: page, html: nil, baseURL: page.url?.absoluteString,
                         userAgent: userAgent, timeout: timeout)
        }
        return found.isEmpty ? nil : URL(string: found)
    }

    private func begin(request: URLRequest?, html: String?, baseURL: String?, userAgent: String?, timeout: TimeInterval) {
        let config = WKWebViewConfiguration()
        if case .video = captureMode {
            // Inline and never on its own: the page must not take the screen or make a sound.
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = .all
            config.userContentController.addUserScript(WKUserScript(
                source: Self.videoSnifferScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
            ))
            config.userContentController.add(self, name: Self.videoSnifferMessage)
        }
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: config)
        if let ua = userAgent, !ua.isEmpty { wv.customUserAgent = ua }
        wv.navigationDelegate = self
        webView = wv
        initialURL = baseURL

        // Hard timeout: never leave the JS queue blocked indefinitely.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish("")
        }

        if let request {
            wv.load(request)
        } else if let html {
            wv.loadHTMLString(html, baseURL: baseURL.flatMap { URL(string: $0) })
        } else {
            finish("")
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if case .overrideURL(let pattern) = captureMode,
           let candidate = navigationAction.request.url?.absoluteString,
           candidate != initialURL,
           Self.fullyMatches(candidate, pattern: pattern) {
            persistCookies(from: webView) { [weak self] in self?.finish(candidate) }
            decisionHandler(.cancel)
            return
        }
        // A page that sends itself to the video rather than handing it to a player.
        if case .video(let isVideoRequest) = captureMode,
           let candidate = navigationAction.request.url, isVideoRequest(candidate) {
            found(video: candidate.absoluteString, from: "navigation")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        switch captureMode {
        case .evaluatedJavaScript:
            webView.evaluateJavaScript(js) { [weak self] value, _ in
                guard let self else { return }
                self.persistCookies(from: webView) {
                    self.finish(Self.stringify(value))
                }
            }
        case .resource(let pattern):
            evaluateSnifferJavaScriptIfNeeded(in: webView) { [weak self] in
                guard let self else { return }
                webView.evaluateJavaScript(Self.resourceURLScript) { value, _ in
                    let candidates = (value as? [Any])?.compactMap { $0 as? String } ?? []
                    let matched = candidates.first { Self.fullyMatches($0, pattern: pattern) } ?? ""
                    self.persistCookies(from: webView) { self.finish(matched) }
                }
            }
        case .overrideURL:
            evaluateSnifferJavaScriptIfNeeded(in: webView) { [weak self] in
                guard let self else { return }
                self.persistCookies(from: webView) { self.finish("") }
            }
        case .video:
            // A player usually picks its stream after the page has loaded.
            break
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard case .video(let isVideoRequest) = captureMode,
              let report = message.body as? [String: Any],
              let kind = report["kind"] as? String, let text = report["url"] as? String,
              let url = URL(string: text) else { return }
        guard kind == "video" || isVideoRequest(url) else { return }
        found(video: text, from: kind)
    }

    private func found(video: String, from kind: String) {
        guard !finished, sniffedVideo == nil, let webView else { return }
        sniffedVideo = video
        AppLogger.parse("⟐ video sniffed from page", context: [
            "page": String((initialURL ?? "").prefix(160)), "from": kind, "url": String(video.prefix(160)),
        ])
        // The stream is fetched with the cookies the page was given.
        persistCookies(from: webView) { [weak self] in self?.finish(video) }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    private func navigationFailed(_ error: Error) {
        guard case .video = captureMode else {
            finish("")
            return
        }
        // Cancelling a navigation to the video fails that navigation; the video is the answer.
        guard sniffedVideo == nil else { return }
        AppLogger.parse("⟐ video page failed to load", context: [
            "page": String((initialURL ?? "").prefix(160)), "error": error.localizedDescription,
        ])
        finish("")
    }

    // MARK: - Helpers

    private func evaluateSnifferJavaScriptIfNeeded(
        in webView: WKWebView,
        completion: @escaping () -> Void
    ) {
        guard !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion()
            return
        }
        webView.evaluateJavaScript(js) { _, _ in completion() }
    }

    private func persistCookies(from webView: WKWebView, completion: @escaping () -> Void) {
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
            completion()
        }
    }

    private static func fullyMatches(_ value: String, pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return false }
        return match.range == range
    }

    private static let videoSnifferMessage = "yueduVideoSniffer"

    /// Reports each link a `<video>` (or its `<source>`) is handed, however the page hands it,
    /// and each request the page's script makes. `blob:` links (a Media Source player) are
    /// left out: such a player fetches its playlist by request.
    private static let videoSnifferScript = """
    (() => {
      const post = (kind, value) => {
        try {
          if (!value) return;
          const url = new URL(String(value.url || value), document.baseURI).href;
          if (!/^https?:/i.test(url)) return;
          window.webkit.messageHandlers.\(LegadoHeadlessWebView.videoSnifferMessage).postMessage({ kind, url });
        } catch (_) {}
      };
      const isVideo = (el) => el instanceof HTMLVideoElement ||
        (el instanceof HTMLSourceElement && el.parentElement instanceof HTMLVideoElement);
      const report = (el) => { if (isVideo(el)) post('video', el.getAttribute('src')); };
      for (const proto of [HTMLMediaElement.prototype, HTMLSourceElement.prototype]) {
        const src = Object.getOwnPropertyDescriptor(proto, 'src');
        if (!src || !src.set) continue;
        Object.defineProperty(proto, 'src', { ...src, set(value) {
          if (isVideo(this)) post('video', value);
          return src.set.call(this, value);
        } });
      }
      const setAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        if (String(name).toLowerCase() === 'src' && isVideo(this)) post('video', value);
        return setAttribute.apply(this, arguments);
      };
      const open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        post('request', url);
        return open.apply(this, arguments);
      };
      if (window.fetch) {
        const fetch = window.fetch;
        window.fetch = function (input) {
          post('request', input);
          return fetch.apply(this, arguments);
        };
      }
      new MutationObserver((records) => {
        for (const record of records) {
          if (record.type === 'attributes') { report(record.target); continue; }
          for (const node of record.addedNodes) {
            if (!(node instanceof Element)) continue;
            report(node);
            node.querySelectorAll('video, video > source').forEach(report);
          }
        }
      }).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['src'] });
    })()
    """

    private static let resourceURLScript = """
    (() => {
      const urls = [];
      try { performance.getEntriesByType('resource').forEach(e => urls.push(String(e.name || ''))); } catch (_) {}
      try { document.querySelectorAll('[src],[href]').forEach(e => urls.push(String(e.src || e.href || ''))); } catch (_) {}
      return Array.from(new Set(urls.filter(Boolean)));
    })()
    """

    private func finish(_ value: String) {
        guard !finished else { return }
        finished = true
        // The content controller holds its handler strongly.
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.videoSnifferMessage)
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
