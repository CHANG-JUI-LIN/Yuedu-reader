import Foundation
import WebKit

/// Offscreen WKWebView runner: Legado's `BackstageWebView`, behind `java.webView(html, url, js)`
/// and behind a request whose URL option says `webView` (`ModernParserBridge.fetch`).
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

    /// Why a load gave no answer. The first two are where Legado's `BackstageWebView` raises
    /// an error rather than answering: `java.webView` rethrows it into the script
    /// (`JsExtensions.webView`'s `runBlocking`), and a `webView` request fails with it.
    enum Failure: LocalizedError, Equatable, Sendable {
        /// `getStrResponse()`'s `withTimeout(timeout ?: 60000L)`: nothing by the deadline.
        case timedOut(milliseconds: Int)
        /// `EvalJsRunnable`: the script still read `null` after Legado's 31 re-reads.
        case scriptTimedOut
        /// The page itself did not load (or was past `WebFetcher.responseByteLimit`). Legado
        /// raises nothing here: its WebView shows Chromium's error page and the script reads
        /// that, which nothing here can produce, so a script reads "". A sniffer whose page
        /// never loaded ends with it too, where Legado's waits for nothing until its timeout.
        case pageFailed(String)

        /// Whether Legado raises it, rather than answering a page.
        var isLegadoError: Bool {
            if case .pageFailed = self { return false }
            return true
        }

        /// Legado's own message where it raises one: what a script's `catch` and the source
        /// check see.
        var message: String {
            switch self {
            case .timedOut(let milliseconds):
                return "kotlinx.coroutines.TimeoutCancellationException: Timed out waiting for \(milliseconds) ms"
            case .scriptTimedOut:
                return "js执行超时"
            case .pageFailed(let reason):
                return "WebView page failed to load: \(reason)"
            }
        }

        var errorDescription: String? { message }
    }

    private enum CaptureMode {
        case evaluatedJavaScript
        /// Legado's `SnifferWebClient.onLoadResource`: the first resource the page loads whose
        /// URL matches is the answer. It listens until then or the deadline — a page that
        /// finishes, or a navigation that fails, ends nothing (`BackstageWebView.kt` 304–376).
        case resource(regex: String)
        /// Legado's `SnifferWebClient.shouldOverrideUrlLoading`: the first navigation whose URL
        /// matches, listened for the same way.
        case overrideURL(regex: String)
        /// The first link the page hands a `<video>`, or the first request `isVideoRequest`
        /// takes for a stream (an HLS player fetches its playlist itself).
        case video(isVideoRequest: (URL) -> Bool)
    }

    private var webView: WKWebView?
    /// Nil is Legado's `javaScript == null`: the page's `outerHTML`, read after `delayMs`.
    private let js: String?
    /// The source's `webViewDelayTime`: how long after the page loads its script is read.
    private let delayMs: Int
    private let captureMode: CaptureMode
    /// The URL of the first page that finished loading — what Legado's response reports.
    private var finishedURL: String?
    private var pendingEvaluation: DispatchWorkItem?
    /// Which scheduled read is current: a read waiting on the page's requests is dropped when a
    /// later finished load has scheduled another.
    private var evaluationGeneration = 0
    private var evaluationRetries = 0
    private var initialURL: String?
    private var continuation: CheckedContinuation<String, Never>?
    private var finished = false
    /// Set with the answer when the load ended in one of Legado's errors.
    private var failure: Failure?
    /// The video or resource a sniffer found, held while the page's cookies are copied out.
    private var sniffed: String?
    /// Whether a page has been committed: a navigation failing before any has means no page
    /// exists to load anything.
    private var committedPage = false

    /// Strong references that keep in-flight runners alive until they resolve.
    private static var retained: [LegadoHeadlessWebView] = []

    private init(js: String?, delayMs: Int = 0, captureMode: CaptureMode) {
        self.js = js
        self.delayMs = delayMs
        self.captureMode = captureMode
        super.init()
    }

    /// Run a headless load + JS evaluation. Always resolves: `failure` is Legado's error when
    /// it raises one, and `body` is "" then and when the page failed to load.
    static func run(
        html: String?,
        url: String?,
        js: String?,
        userAgent: String?,
        timeout: TimeInterval,
        sourceRegex: String? = nil,
        overrideURLRegex: String? = nil
    ) async -> (body: String, failure: Failure?) {
        let page = await load(
            html: html, url: url, js: js, userAgent: userAgent, timeout: timeout,
            sourceRegex: sourceRegex, overrideURLRegex: overrideURLRegex
        )
        return (page.body, page.failure)
    }

    /// `run` with the request's headers and the source's `webViewDelayTime`, answering the
    /// URL the page ended at as well. `body` is "" when the page failed to load, and with
    /// `failure` when nothing came by `timeout` or the script kept reading `null`.
    static func load(
        html: String?,
        url: String?,
        js: String?,
        userAgent: String?,
        headers: [String: String] = [:],
        delayMs: Int = 0,
        timeout: TimeInterval,
        sourceRegex: String? = nil,
        overrideURLRegex: String? = nil
    ) async -> (body: String, url: String?, failure: Failure?) {
        let mode: CaptureMode
        if let sourceRegex, !sourceRegex.isEmpty {
            mode = .resource(regex: sourceRegex)
        } else if let overrideURLRegex, !overrideURLRegex.isEmpty {
            mode = .overrideURL(regex: overrideURLRegex)
        } else {
            mode = .evaluatedJavaScript
        }
        let runner = LegadoHeadlessWebView(js: js, delayMs: max(0, delayMs), captureMode: mode)
        retained.append(runner)
        let resourceBlocking = await SourcePageResourceBlocking.ruleList()
        let body = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            runner.continuation = cont
            // Raw HTML is loaded as HTML even with a URL: the URL is then its base, as in
            // Legado's `loadDataWithBaseURL` (a POST's response rendered at its URL).
            var request = html == nil ? url.flatMap(URL.init(string:)).map { URLRequest(url: $0) } : nil
            for (field, value) in headers { request?.setValue(value, forHTTPHeaderField: field) }
            runner.begin(request: request, html: html, baseURL: url, userAgent: userAgent, timeout: timeout,
                         resourceBlocking: resourceBlocking)
        }
        let answeredURL = runner.finishedURL ?? url
        WebCrawlerDebugger.logWebViewResponse(
            url: answeredURL ?? "about:blank", body: body, failure: runner.failure?.message
        )
        return (body, answeredURL, runner.failure)
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
        let runner = LegadoHeadlessWebView(js: nil, captureMode: .video(isVideoRequest: isVideoRequest))
        retained.append(runner)
        let resourceBlocking = await SourcePageResourceBlocking.ruleList()
        let found = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            runner.continuation = cont
            runner.begin(request: page, html: nil, baseURL: page.url?.absoluteString,
                         userAgent: userAgent, timeout: timeout, resourceBlocking: resourceBlocking)
        }
        return found.isEmpty ? nil : URL(string: found)
    }

    /// `resourceBlocking`: `SourcePageResourceBlocking`'s list — the page loads no network image,
    /// as Legado's `BackstageWebView` (`blockNetworkImage = true`), and no network font (a
    /// deliberate divergence), for every kind of capture.
    private func begin(
        request: URLRequest?, html: String?, baseURL: String?, userAgent: String?, timeout: TimeInterval,
        resourceBlocking: WKContentRuleList?
    ) {
        let config = WKWebViewConfiguration()
        if let resourceBlocking { config.userContentController.add(resourceBlocking) }
        switch captureMode {
        case .video, .resource:
            // Inline and never on its own: the page must not take the screen or make a sound.
            // Legado's pool lets media play unprompted (`mediaPlaybackRequiresUserGesture =
            // false`), so its page fetches the stream it plays; here the link the page hands
            // its player is reported instead (`snifferScript`), and nothing plays.
            config.allowsInlineMediaPlayback = true
            config.mediaTypesRequiringUserActionForPlayback = .all
            config.userContentController.addUserScript(WKUserScript(
                source: Self.snifferScript, injectionTime: .atDocumentStart, forMainFrameOnly: false
            ))
            config.userContentController.add(self, name: Self.snifferMessage)
        case .evaluatedJavaScript:
            PageRequestDrain.install(on: config.userContentController)
        case .overrideURL:
            break
        }
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 667), configuration: config)
        if let ua = userAgent, !ua.isEmpty { wv.customUserAgent = ua }
        wv.navigationDelegate = self
        webView = wv
        initialURL = baseURL

        // Legado's `withTimeout`: the whole load, page and script, within `timeout`.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, !self.finished else { return }
            let failure = Failure.timedOut(milliseconds: Int((timeout * 1000).rounded()))
            AppLogger.parse("Headless WebView gave nothing by its deadline", context: [
                "page": String((self.initialURL ?? "").prefix(160)),
                "pageFinished": self.finishedURL != nil, "reads": self.evaluationRetries,
                "error": failure.message,
            ], level: .warning)
            self.finish("", failure: failure)
        }

        if let request {
            wv.load(request)
        } else if let html {
            wv.loadHTMLString(html, baseURL: baseURL.flatMap { URL(string: $0) })
        } else {
            AppLogger.parse("Headless WebView given no page", context: [
                "url": String((baseURL ?? "nil").prefix(160)),
            ], level: .warning)
            finish("", failure: .pageFailed("no page and no URL to load"))
        }
    }

    // MARK: - WKNavigationDelegate

    /// Accepts the server's certificate, as Legado's WebViews do (`ServerTrustPolicy`).
    func webView(
        _ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        ServerTrustPolicy.answer(challenge)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        if case .overrideURL(let pattern) = captureMode,
           let candidate = navigationAction.request.url?.absoluteString,
           candidate != initialURL,
           Self.fullyMatches(candidate, pattern: pattern) {
            found(match: candidate, from: "navigation")
            decisionHandler(.cancel)
            return
        }
        // A page or frame that loads the resource itself is a resource it loads
        // (`onLoadResource`); the URL asked for is the page, not one it loads.
        if case .resource(let pattern) = captureMode,
           let candidate = navigationAction.request.url?.absoluteString,
           candidate != initialURL,
           Self.fullyMatches(candidate, pattern: pattern) {
            found(match: candidate, from: "navigation")
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

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committedPage = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        switch captureMode {
        case .evaluatedJavaScript:
            if finishedURL == nil { finishedURL = webView.url?.absoluteString }
            // Legado's `onPageFinished`: every finished load (re)starts the wait, so a page that
            // navigates on is read once it settles. Then the page's own requests
            // (`PageRequestDrain`, a deliberate divergence).
            scheduleEvaluation(in: webView, afterMs: 100 + effectiveDelayMs, drainsFirst: true)
        case .resource, .overrideURL:
            // `SnifferWebClient.onPageFinished`: the source's script runs `100 + delayTime` ms
            // after each finished load and answers nothing; the answer is a matching resource
            // or navigation, whenever it comes.
            scheduleSnifferScript(in: webView)
        case .video:
            // A player usually picks its stream after the page has loaded.
            break
        }
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let report = message.body as? [String: Any],
              let kind = report["kind"] as? String, let text = report["url"] as? String,
              let url = URL(string: text) else { return }
        switch captureMode {
        case .video(let isVideoRequest):
            guard kind == "video" || (kind == "request" && isVideoRequest(url)) else { return }
            found(video: text, from: kind)
        case .resource(let pattern):
            // Legado's `resUrl.matches(regex)`: the whole URL.
            guard Self.fullyMatches(text, pattern: pattern) else { return }
            found(match: text, from: kind)
        case .evaluatedJavaScript, .overrideURL:
            break
        }
    }

    /// A resource or navigation the source's regex matches. Legado answers it and destroys the
    /// WebView (`onLoadResource`, `shouldOverrideUrlLoading`): the first match is final.
    private func found(match: String, from kind: String) {
        guard !finished, sniffed == nil, let webView else { return }
        sniffed = match
        AppLogger.parse("⟐ resource sniffed from page", context: [
            "page": String((initialURL ?? "").prefix(160)), "from": kind, "url": String(match.prefix(160)),
        ])
        persistCookies(from: webView) { [weak self] in self?.finish(match) }
    }

    private func found(video: String, from kind: String) {
        guard !finished, sniffed == nil, let webView else { return }
        sniffed = video
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
        let nsError = error as NSError
        let context: [String: Any] = [
            "page": String((initialURL ?? "").prefix(160)),
            "failed": String(((nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String)
                ?? (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? "-").prefix(160)),
            "error": error.localizedDescription, "code": nsError.code,
        ]
        switch captureMode {
        case .evaluatedJavaScript:
            AppLogger.parse("Headless WebView page failed to load", context: context, level: .warning)
            finish("", failure: .pageFailed(error.localizedDescription))
        case .resource, .overrideURL:
            // Cancelling the navigation that matched fails that navigation; the match is the answer.
            guard sniffed == nil else { return }
            guard committedPage else {
                // No page was ever committed, so none exists to load a resource. Legado's
                // WebView shows its error page, which loads nothing, and raises its timeout at
                // the deadline; this ends now with the load's own error instead.
                AppLogger.parse("Headless WebView page failed to load", context: context, level: .warning)
                finish("", failure: .pageFailed(error.localizedDescription))
                return
            }
            // A page that sends itself somewhere WebKit cannot go (an app's own scheme) keeps
            // the page it had, and Legado's sniffer has no error path: it listens on.
            AppLogger.parse("Headless WebView navigation failed; sniffing goes on", context: context)
        case .video:
            // Cancelling a navigation to the video fails that navigation; the video is the answer.
            guard sniffed == nil else { return }
            AppLogger.parse("⟐ video page failed to load", context: context)
            finish("")
        }
    }

    // MARK: - Reading the page (Legado `BackstageWebView.EvalJsRunnable`)

    /// The page's HTML, held to `WebFetcher.responseByteLimit` as every page a source reads is:
    /// measured inside the page, a page past the limit answers only its length (in UTF-16
    /// units, two bytes each here), so the oversized string never crosses into this process.
    private static let outerHTMLScript = """
        (function () {
            var html = document.documentElement.outerHTML;
            return html.length > \(WebFetcher.responseByteLimit / 2) ? html.length : html;
        })()
        """

    /// Legado's re-read intervals while the script still yields nothing.
    private static let retryIntervalsMs = [200, 400, 600, 800, 1000]

    /// Legado gives a page with no script of its own 900 ms to render before its HTML is read.
    /// Waiting on the page's own work here is the reference's contract: a page has no "done
    /// rendering" signal, so Legado waits a fixed time and then re-reads until the script
    /// yields something (`retryIntervalsMs`).
    private var effectiveDelayMs: Int {
        js == nil && delayMs == 0 ? 900 : delayMs
    }

    /// `drainsFirst`: wait for the page's requests before this read — the read after a finished
    /// load, not Legado's re-reads of a script that answered `null`.
    private func scheduleEvaluation(in webView: WKWebView, afterMs delay: Int, drainsFirst: Bool = false) {
        pendingEvaluation?.cancel()
        evaluationGeneration += 1
        let generation = evaluationGeneration
        let work = DispatchWorkItem { [weak self, weak webView] in
            guard let self, let webView, !self.finished else { return }
            guard drainsFirst else {
                self.evaluate(in: webView)
                return
            }
            Task { @MainActor [weak self, weak webView] in
                guard let webView else { return }
                await PageRequestDrain.wait(in: webView)
                // A load that finished meanwhile scheduled its own read.
                guard let self, !self.finished, self.evaluationGeneration == generation else { return }
                self.evaluate(in: webView)
            }
        }
        pendingEvaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay), execute: work)
    }

    private func evaluate(in webView: WKWebView) {
        let ownScript = js.flatMap { $0.isEmpty ? nil : $0 }
        let script = ownScript ?? Self.outerHTMLScript
        webView.evaluateJavaScript(script) { [weak self] value, error in
            guard let self, !self.finished else { return }
            // Past the limit, the page answers as a failed load does: nothing. Its own script's
            // result has already crossed; it is measured here before anything parses it.
            let units = ownScript == nil ? (value as? Int) : (value as? String)?.utf16.count
            if let units, units * 2 > WebFetcher.responseByteLimit {
                let page = URL(string: self.finishedURL ?? self.initialURL ?? "") ?? URL(string: "about:blank")!
                WebFetcher.logOversized(
                    url: page, bytes: units * 2, limit: WebFetcher.responseByteLimit, transport: "headlessWebView"
                )
                self.finish("", failure: .pageFailed(
                    "\(units * 2) bytes, over the \(WebFetcher.responseByteLimit)-byte limit"
                ))
                return
            }
            // Legado reads the script's result as JSON (`evaluateJavascript`) and reads again
            // only on `null`: a script that answered null or undefined, or threw. Any other
            // answer is the page's, an empty string or the text "null" included.
            if let value, !(value is NSNull) {
                let text = Self.stringify(value)
                self.persistCookies(from: webView) { self.finish(text) }
                return
            }
            // `if (retry > 30) onError(NoStackTraceException("js执行超时"))`: 32 reads in all.
            guard self.evaluationRetries <= 30 else {
                AppLogger.parse("Headless WebView script read null on every read", context: [
                    "page": String((self.finishedURL ?? self.initialURL ?? "").prefix(160)),
                    "reads": self.evaluationRetries + 1,
                    "error": error?.localizedDescription ?? "-",
                ], level: .warning)
                self.finish("", failure: .scriptTimedOut)
                return
            }
            let interval = Self.retryIntervalsMs[min(self.evaluationRetries, Self.retryIntervalsMs.count - 1)]
            self.evaluationRetries += 1
            self.scheduleEvaluation(in: webView, afterMs: interval)
        }
    }

    // MARK: - Helpers

    /// `SnifferWebClient.onPageFinished` → `LoadJsRunnable`: the source's script, if it has one,
    /// run `100 + delayTime` ms after a load finishes, its result unread. A later finished load
    /// runs it again.
    private func scheduleSnifferScript(in webView: WKWebView) {
        guard let js, !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingEvaluation?.cancel()
        let work = DispatchWorkItem { [weak self, weak webView] in
            guard let self, let webView, !self.finished else { return }
            webView.evaluateJavaScript(js) { _, error in
                guard let error else { return }
                AppLogger.parse("Headless WebView sniffer script failed", context: [
                    "page": String((self.initialURL ?? "").prefix(160)), "error": error.localizedDescription,
                ], level: .warning)
            }
        }
        pendingEvaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100 + delayMs), execute: work)
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

    private static let snifferMessage = "yueduPageSniffer"

    /// Reports each link a media element (or its `<source>`) is handed, however the page hands
    /// it — `video` for a `<video>`'s, `media` for an `<audio>`'s —, each request the page's
    /// script makes (`request`), and each resource the page loads (`resource`, its Resource
    /// Timing entries): what Legado's `onLoadResource` sees, at the moment the page asks for it.
    /// `blob:` links (a Media Source player) are left out: such a player fetches its playlist
    /// by request.
    private static let snifferScript = """
    (() => {
      const post = (kind, value) => {
        try {
          if (!value) return;
          const url = new URL(String(value.url || value), document.baseURI).href;
          if (!/^https?:/i.test(url)) return;
          window.webkit.messageHandlers.\(LegadoHeadlessWebView.snifferMessage).postMessage({ kind, url });
        } catch (_) {}
      };
      const mediaKind = (el) => {
        const media = el instanceof HTMLSourceElement ? el.parentElement : el;
        if (media instanceof HTMLVideoElement) return 'video';
        if (media instanceof HTMLMediaElement) return 'media';
        return null;
      };
      const report = (el) => { const kind = mediaKind(el); if (kind) post(kind, el.getAttribute('src')); };
      for (const proto of [HTMLMediaElement.prototype, HTMLSourceElement.prototype]) {
        const src = Object.getOwnPropertyDescriptor(proto, 'src');
        if (!src || !src.set) continue;
        Object.defineProperty(proto, 'src', { ...src, set(value) {
          const kind = mediaKind(this);
          if (kind) post(kind, value);
          return src.set.call(this, value);
        } });
      }
      const setAttribute = Element.prototype.setAttribute;
      Element.prototype.setAttribute = function (name, value) {
        if (String(name).toLowerCase() === 'src') { const kind = mediaKind(this); if (kind) post(kind, value); }
        return setAttribute.apply(this, arguments);
      };
      // `new Audio(url)` sets its link without the setter.
      if (window.Audio) {
        const NativeAudio = window.Audio;
        const SniffedAudio = function (src) {
          if (src !== undefined) post('media', src);
          return arguments.length ? new NativeAudio(src) : new NativeAudio();
        };
        SniffedAudio.prototype = NativeAudio.prototype;
        window.Audio = SniffedAudio;
      }
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
      try {
        new PerformanceObserver((list) => list.getEntries().forEach((entry) => post('resource', entry.name)))
          .observe({ type: 'resource', buffered: true });
      } catch (_) {}
      new MutationObserver((records) => {
        for (const record of records) {
          if (record.type === 'attributes') { report(record.target); continue; }
          for (const node of record.addedNodes) {
            if (!(node instanceof Element)) continue;
            report(node);
            node.querySelectorAll('video, audio, video > source, audio > source').forEach(report);
          }
        }
      }).observe(document, { subtree: true, childList: true, attributes: true, attributeFilter: ['src'] });
    })()
    """

    private func finish(_ value: String, failure: Failure? = nil) {
        guard !finished else { return }
        finished = true
        self.failure = failure
        pendingEvaluation?.cancel()
        pendingEvaluation = nil
        // The content controller holds its handler strongly.
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.snifferMessage)
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
