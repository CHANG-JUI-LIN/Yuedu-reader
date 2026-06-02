import Foundation
import WebKit

// MARK: - WKWebView Background JS Rendering Engine

/// Loads pages that require JavaScript rendering and returns the full DOM HTML.
/// Usage: let html = try await WebViewFetcher.shared.fetchHTML(url: url, timeout: 15)
@MainActor
final class WebViewFetcher: NSObject, WKNavigationDelegate {
    static let shared = WebViewFetcher()

    /// WebView instance pool (reused to avoid repeated creation costs)
    private var pool: [WKWebView] = []
    private let poolSize = AppConfig.webViewPoolSize
    private var waiters: [CheckedContinuation<WKWebView, Never>] = []
    /// Currently active (checked out but not yet returned) WebView count, including temporaries
    private var activeCount: Int = 0

    /// In-flight loading tasks
    private var loadingMap: [WKWebView: CheckedContinuation<String, Error>] = [:]

    private override init() {
        assert(Thread.isMainThread, "WebViewFetcher must be initialized on the main thread")
        super.init()
        // Pre-populate the WebView pool
        for _ in 0..<poolSize {
            pool.append(createWebView())
        }
    }

    private func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // Disable media autoplay to save resources
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.suppressesIncrementalRendering = true

        let wv = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        return wv
    }

    // MARK: - Public API

    /// Polls for page content to be ready before returning outerHTML.
    /// Fast sites return in ~100ms; slow sites wait at most maxWaitMs.
    @MainActor
    private func pollForContent(
        webView: WKWebView,
        minLength: Int = AppConfig.webViewPollingMinTextLength,
        maxWaitMs: Int = AppConfig.webViewPollingMaxWaitMs
    ) async -> String {
        let intervalMs = AppConfig.webViewPollingIntervalMs
        let maxAttempts = maxWaitMs / intervalMs
        let intervalNs = UInt64(intervalMs) * 1_000_000
        for _ in 0..<maxAttempts {
            if let len = try? await webView.evaluateJavaScript("document.body ? document.body.innerText.length : 0") as? Int,
               len >= minLength {
                break
            }
            try? await Task.sleep(nanoseconds: intervalNs)
        }
        return (try? await webView.evaluateJavaScript(
            "document.documentElement.outerHTML") as? String) ?? ""
    }


    /// - Parameters:
    ///   - url: Target URL
    ///   - headers: Custom HTTP headers
    ///   - timeout: Timeout in seconds (includes JS rendering wait)
    ///   - jsWait: Additional wait seconds after JS rendering
    func fetchHTML(
        url: URL, headers: [String: String] = [:],
        timeout: TimeInterval = AppConfig.webViewFetchTimeout, jsWait: TimeInterval = AppConfig.webViewJSRenderWait
    ) async throws -> String {

        let webView = await acquireWebView()

        defer { releaseWebView(webView) }

        let request = await prepareRequest(
            url: url,
            headers: headers,
            timeout: timeout,
            webView: webView
        )

        // Use withThrowingTaskGroup for timeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { throw WebViewError.deallocated }

                let _ = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<String, Error>) in
                    self.loadingMap[webView] = continuation
                    webView.load(request)
                }

                // Wait for JS rendering
                try await Task.sleep(nanoseconds: UInt64(jsWait * 1_000_000_000))

                // Extract full HTML
                let html =
                    try await webView.evaluateJavaScript(
                        "document.documentElement.outerHTML"
                    ) as? String ?? ""

                if LegadoJSBridge.isCloudflareChallengedBody(html) {
                    throw FetchError.cloudflareChallengeRequired(url.absoluteString)
                }
                return html
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebViewError.timeout
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    /// Legado preUpdateJs: loads URL, executes custom JS, then returns current DOM HTML.
    /// Used for TOC pages where JS must run before the list appears.
    func fetchHTMLWithCustomJS(
        url: URL, headers: [String: String] = [:],
        jsAfterLoad: String, timeout: TimeInterval = 20, jsWait: TimeInterval = 2.0
    ) async throws -> String {
        let webView = await acquireWebView()
        defer { releaseWebView(webView) }

        let request = await prepareRequest(
            url: url,
            headers: headers,
            timeout: timeout,
            webView: webView
        )

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { throw WebViewError.deallocated }
                let _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    self.loadingMap[webView] = cont
                    webView.load(request)
                }
                try await Task.sleep(nanoseconds: UInt64(jsWait * 1_000_000_000))
                if !jsAfterLoad.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = try? await webView.evaluateJavaScript(jsAfterLoad)
                    try await Task.sleep(
                        nanoseconds: UInt64(AppConfig.webViewPostLoadJSEffectDelay * 1_000_000_000)
                    )
                }
                let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
                if LegadoJSBridge.isCloudflareChallengedBody(html) {
                    throw FetchError.cloudflareChallengeRequired(url.absoluteString)
                }
                return html
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebViewError.timeout
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    /// Legado loginCheckJs: executes JS on the already-loaded HTML. Returns whether
    /// login is required (truthy = login needed).
    func evaluateInHTML(html: String, baseURL: String, js: String) async throws -> Bool {
        guard !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let webView = await acquireWebView()
        defer { releaseWebView(webView) }
        let base = URL(string: baseURL) ?? URL(string: "about:blank")!
        try await loadHTMLString(html, baseURL: base, into: webView)
        let escaped = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let runJs = "(function(){ var __r; try { __r = (function(){ \(escaped) })(); } catch(e) { __r = true; } return !!__r; })();"
        let result = try await webView.evaluateJavaScript(runJs)
        if let b = result as? Bool { return b }
        if let s = result as? String {
            let t = s.lowercased()
            return !s.isEmpty && (t.contains("login") || t.contains("登") || t.contains("录") || t == "true")
        }
        return (result as? Int).map { $0 != 0 } ?? false
    }

    /// - Parameters:
    ///   - url: Chapter page URL
    ///   - headers: Custom headers (including User-Agent)
    ///   - contentSelectors: Content container selectors tried in order until non-empty text is found (e.g. .txtnav, #txtright)
    ///   - scrollToEndDelay: Seconds to wait after scrolling to the bottom (triggers lazy loading); 0 disables scrolling
    ///   - timeout: Overall timeout
    ///   - jsWait: Seconds to wait after page load (for site JS decryption)
    func fetchChapterContentBySelectors(
        url: URL, headers: [String: String] = [:],
        contentSelectors: [String] = [
            ".txtnav", "#txtright", "#chaptercontent", ".read-content", "#content", ".content",
            "#chapter-content", "#chapterContent", ".chapter-content", "#readcontent", "#read",
            ".BookText", "#booktext", "#chapterbody", "#booktxt", ".novel-text",
            "#articleBody", ".article-body", "article", ".article", ".Readarea", ".readArea"
        ],
        scrollToEndDelay: TimeInterval = 0.5,
        timeout: TimeInterval = 25, jsWait: TimeInterval = 2.0
    ) async throws -> String {
        let webView = await acquireWebView()
        defer { releaseWebView(webView) }

        let request = await prepareRequest(
            url: url,
            headers: headers,
            timeout: timeout,
            webView: webView
        )

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { throw WebViewError.deallocated }

                let _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    self.loadingMap[webView] = cont
                    webView.load(request)
                }

                try await Task.sleep(nanoseconds: UInt64(jsWait * 1_000_000_000))

                if scrollToEndDelay > 0 {
                    _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);")
                    try await Task.sleep(nanoseconds: UInt64(scrollToEndDelay * 1_000_000_000))
                }

                let arrayJson: String = {
                    let enc = contentSelectors.map { sel -> String in
                        let esc = sel.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                        return "\"\(esc)\""
                    }
                    return "[" + enc.joined(separator: ",") + "]"
                }()
                let js = """
                (function(){
                    var sels = \(arrayJson);
                    for (var i = 0; i < sels.length; i++) {
                        try {
                            var el = document.querySelector(sels[i]);
                            if (el && el.innerText) {
                                var t = (el.innerText || '').trim();
                                if (t.length > 50) return t;
                            }
                        } catch(e) {}
                    }
                    try {
                        var bodyText = (document.body && document.body.innerText ? document.body.innerText : '').trim();
                        if (bodyText.length > 200) return bodyText;
                    } catch (e) {}
                    return '';
                })();
                """
                let result = try await webView.evaluateJavaScript(js) as? String ?? ""
                return result.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebViewError.timeout
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            if result.isEmpty { throw WebViewError.emptyContent }
            return result
        }
    }

    // MARK: - WebView JS Dynamic Content Extraction (aligned with Legado BackstageWebView)

    /// Content extraction JS: iterates known selectors for longest text content,
    /// applies heuristic scoring, falls back to body.innerText.
    static let contentExtractJS = """
    (function(){
        var sels=[
            '#chapter-content','#chapterContent','#chaptercontent',
            '.chapter-content','.read-content','#readcontent','#read',
            '.txtnav','#txtright','#htmlContent','.BookText','#BookText',
            '#booktext','#chapterbody','#booktxt',
            '.novel-text','#novelcontent','.readArea','#bookContent',
            '#articleBody','.article-body','.article','#article',
            '#content','.content','.txt','#txt'
        ];
        var longest='';
        for(var i=0;i<sels.length;i++){
            try{var el=document.querySelector(sels[i]);
                if(el){var t=(el.innerText||'').replace(/[\\t ]+/g,' ').trim();
                    if(t.length>longest.length)longest=t;}
            }catch(e){}
        }
        if(longest.length>=200)return longest;
        var all=document.querySelectorAll('div,section,article');
        var bestEl=null,bestLen=0;
        for(var i=0;i<all.length;i++){
            var el=all[i];
            var ci=(el.className||'').toLowerCase()+' '+(el.id||'').toLowerCase();
            if(/(nav|menu|header|footer|sidebar|ad|banner|search|login|toc|toolbar|float)/i.test(ci))continue;
            var t=(el.innerText||'').trim();
            if(t.length>bestLen){bestLen=t.length;bestEl=el;}
        }
        if(bestEl&&bestLen>longest.length)longest=bestEl.innerText.replace(/\\s*\\n\\s*/g,'\\n').trim();
        return longest.length>=100?longest:(document.body?document.body.innerText:'');
    })()
    """

    /// Combined extraction: content + intra-chapter "next page" URL (JSON format).
    static let contentAndNextPageJS = """
    (function(){
        var sels=[
            '#chapter-content','#chapterContent','#chaptercontent',
            '.chapter-content','.read-content','#readcontent','#read',
            '.txtnav','#txtright','#htmlContent','.BookText','#BookText',
            '#booktext','#chapterbody','#booktxt',
            '.novel-text','#novelcontent','.readArea','#bookContent',
            '#articleBody','.article-body','.article','#article',
            '#content','.content','.txt','#txt'
        ];
        var longest='';
        for(var i=0;i<sels.length;i++){
            try{var el=document.querySelector(sels[i]);
                if(el){var t=(el.innerText||'').replace(/[\\t ]+/g,' ').trim();
                    if(t.length>longest.length)longest=t;}
            }catch(e){}
        }
        if(longest.length<200){
            var all=document.querySelectorAll('div,section,article');
            var bestEl=null,bestLen=0;
            for(var i=0;i<all.length;i++){
                var el=all[i];
                var ci=(el.className||'').toLowerCase()+' '+(el.id||'').toLowerCase();
                if(/(nav|menu|header|footer|sidebar|ad|banner|search|login|toc|toolbar|float)/i.test(ci))continue;
                var t=(el.innerText||'').trim();
                if(t.length>bestLen){bestLen=t.length;bestEl=el;}
            }
            if(bestEl&&bestLen>longest.length)longest=bestEl.innerText.replace(/\\s*\\n\\s*/g,'\\n').trim();
        }
        var content=longest.length>=100?longest:(document.body?document.body.innerText:'');
        var nextPage='';
        var cur=location.href;
        var links=document.querySelectorAll('a');
        for(var i=0;i<links.length;i++){
            var a=links[i];
            var txt=(a.innerText||'').trim();
            if(!/下一[页頁]|next\\s*page/i.test(txt))continue;
            var href=a.href;
            if(!href||href===cur)continue;
            var curBase=cur.replace(/_\\d+$/,'');
            var hrefBase=href.replace(/_\\d+$/,'');
            if(hrefBase===curBase&&href!==cur){nextPage=href;break;}
            if(href.indexOf(curBase+'_')===0){nextPage=href;break;}
        }
        return JSON.stringify({c:content,n:nextPage});
    })()
    """

    /// Loads URL, waits for JS render, scrolls to bottom to trigger lazy loading,
    /// then extracts content via innerText.
    func fetchWebContentViaJS(
        url: URL, headers: [String: String] = [:],
        timeout: TimeInterval = 20, jsWait: TimeInterval = 1.5
    ) async throws -> String {
        let webView = await acquireWebView()
        defer { releaseWebView(webView) }

        let request = await prepareRequest(
            url: url,
            headers: headers,
            timeout: timeout,
            webView: webView
        )

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { throw WebViewError.deallocated }
                let _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    self.loadingMap[webView] = cont
                    webView.load(request)
                }
                // Dynamic polling replaces a fixed jsWait delay
                let polledHTML = await self.pollForContent(webView: webView)
                if LegadoJSBridge.isCloudflareChallengedBody(polledHTML) {
                    throw FetchError.cloudflareChallengeRequired(url.absoluteString)
                }

                _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);")

                let first = try await webView.evaluateJavaScript(Self.contentExtractJS) as? String ?? ""
                return first.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebViewError.timeout
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            if result.isEmpty { throw WebViewError.emptyContent }
            return result
        }
    }

    /// Loads URL, extracts content + detects intra-chapter "next page" links (for pagination merging).
    struct PageResult {
        let content: String
        let nextPageURL: String?
    }

    func fetchContentWithNextPage(
        url: URL, headers: [String: String] = [:],
        timeout: TimeInterval = 15, jsWait: TimeInterval = 1.5
    ) async throws -> PageResult {
        let webView = await acquireWebView()
        defer { releaseWebView(webView) }

        let request = await prepareRequest(
            url: url,
            headers: headers,
            timeout: timeout,
            webView: webView
        )

        return try await withThrowingTaskGroup(of: PageResult.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { throw WebViewError.deallocated }
                let _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    self.loadingMap[webView] = cont
                    webView.load(request)
                }
                let polledHTML = await self.pollForContent(webView: webView)
                if LegadoJSBridge.isCloudflareChallengedBody(polledHTML) {
                    throw FetchError.cloudflareChallengeRequired(url.absoluteString)
                }
                _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);")

                let jsonStr = try await webView.evaluateJavaScript(Self.contentAndNextPageJS) as? String ?? "{}"
                guard let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    return PageResult(content: "", nextPageURL: nil)
                }
                let content = (json["c"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let nextPage = json["n"] as? String ?? ""
                return PageResult(
                    content: content,
                    nextPageURL: nextPage.isEmpty ? nil : nextPage
                )
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebViewError.timeout
            }

            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Content Extraction (Readability + Legado rules)

    /// Extracts article content from HTML via Readability (for source-less web pages).
    func extractArticle(html: String, baseURL: String? = nil) async throws -> String? {
        let webView = await acquireWebView()
        defer { releaseWebView(webView) }

        let baseURLForLoad: URL = baseURL.flatMap { URL(string: $0) } ?? URL(string: "about:blank")!
        try await loadHTMLString(html, baseURL: baseURLForLoad, into: webView)

        guard let script = loadBundleScript(name: "Readability", ext: "js") else {
            throw WebViewError.emptyContent
        }
        let runScript = script + """
        ;(function(){
          try {
            var opts = { charThreshold: 0, maxElemsToParse: 0 };
            var r = new Readability(document, opts);
            var a = r.parse();
            return (a && a.content) ? a.content : '';
          } catch(e) { return ''; }
        })();
        """
        let result = try await webView.evaluateJavaScript(runScript) as? String
        let trimmed = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.count >= 100 ? trimmed : nil
    }

    /// Executes Legado rules on the injected HTML, returning a single result string.
    func evaluateHTMLRule(html: String, rule: String, baseURL: String) async throws -> String {
        let webView = await acquireWebView()
        defer { releaseWebView(webView) }

        let baseURLForLoad: URL = URL(string: baseURL) ?? URL(string: "about:blank")!
        try await loadHTMLString(html, baseURL: baseURLForLoad, into: webView)

        guard let script = loadBundleScript(name: "legado-engine", ext: "js") else {
            return ""
        }
        let escaped = rule
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        let baseEscaped = baseURL.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let runScript = script + "\n;(function(){ return (typeof LE !== 'undefined' && LE.getString) ? LE.getString(\"\(escaped)\", null, \"\(baseEscaped)\") : ''; })();"
        let result = try await webView.evaluateJavaScript(runScript) as? String
        return result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Loads an HTML string into a WebView and waits for completion.
    private func loadHTMLString(_ html: String, baseURL: URL, into webView: WKWebView) async throws {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { throw WebViewError.deallocated }
                _ = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
                    self.loadingMap[webView] = cont
                    webView.loadHTMLString(html, baseURL: baseURL)
                }
                return "loaded"
            }
            group.addTask {
                try await Task.sleep(nanoseconds: AppConfig.webViewHTMLLoadTimeout * 1_000_000_000)
                throw WebViewError.timeout
            }
            guard let _ = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
        }
    }

    /// Reads a JS file from the app bundle (Assets/Readability.js, Assets/legado-engine.js).
    private func loadBundleScript(name: String, ext: String) -> String? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Assets"),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let url = bundle.url(forResource: name, withExtension: ext),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return nil
    }

    // MARK: - WebView Pool Management

    private func prepareRequest(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval,
        webView: WKWebView
    ) async -> URLRequest {
        await syncCookiesToWebView(webView, for: url)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if request.value(forHTTPHeaderField: "Cookie") == nil,
            let cookieHeader = cookieHeader(for: url)
        {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func syncCookiesToWebView(_ webView: WKWebView, for url: URL) async {
        let sharedCookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard !sharedCookies.isEmpty else { return }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in sharedCookies {
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    private func cookieHeader(for url: URL) -> String? {
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard !cookies.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    private func acquireWebView() async -> WKWebView {
        if let wv = pool.popLast() {
            activeCount += 1
            return wv
        }
        // Pool exhausted: if active count is below the overflow limit, create a
        // temporary WebView to avoid long queuing.
        let maxActive = poolSize * AppConfig.webViewPoolOverflowMultiplier
        if activeCount < maxActive {
            activeCount += 1
            return createWebView()
        }
        // At capacity — wait in the queue
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseWebView(_ webView: WKWebView) {
        // Only stop the current load; do not call loadHTMLString, which would
        // start a new navigation and cancel it (-999) when the next caller loads
        // a new request, causing the new caller to receive the -999 error.
        webView.stopLoading()
        loadingMap.removeValue(forKey: webView)
        activeCount = max(0, activeCount - 1)

        if let waiter = waiters.first {
            waiters.removeFirst()
            activeCount += 1
            waiter.resume(returning: webView)
        } else if pool.count < poolSize {
            pool.append(webView)
        }
        // Temporary WebViews exceeding the pool size are discarded
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            if let continuation = loadingMap[webView] {
                loadingMap.removeValue(forKey: webView)
                continuation.resume(returning: "loaded")
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        Task { @MainActor in
            if let continuation = loadingMap[webView] {
                loadingMap.removeValue(forKey: webView)
                continuation.resume(throwing: error)
            }
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        Task { @MainActor in
            if let continuation = loadingMap[webView] {
                loadingMap.removeValue(forKey: webView)
                continuation.resume(throwing: error)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if let http = navigationResponse.response as? HTTPURLResponse,
            let url = http.url,
            let headerFields = http.allHeaderFields as? [String: String]
        {
            let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
            if !cookies.isEmpty {
                Task { @MainActor in
                    let store = webView.configuration.websiteDataStore.httpCookieStore
                    for cookie in cookies {
                        HTTPCookieStorage.shared.setCookie(cookie)
                        await withCheckedContinuation { continuation in
                            store.setCookie(cookie) {
                                continuation.resume()
                            }
                        }
                    }
                }
            }
        }
        decisionHandler(.allow)
    }
}

// MARK: - Error Types

enum WebViewError: Error, LocalizedError {
    case timeout
    case deallocated
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .timeout: return "WebView 載入超時"
        case .deallocated: return "WebView 已釋放"
        case .emptyContent: return "WebView 回傳空內容"
        }
    }
}
