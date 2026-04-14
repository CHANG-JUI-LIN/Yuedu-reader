import Foundation
import WebKit

// MARK: - WKWebView 背景 JS 渲染引擎

/// 用於載入需要 JavaScript 渲染的網頁，取得完整 DOM HTML
/// 使用方式：let html = try await WebViewFetcher.shared.fetchHTML(url: url, timeout: 15)
@MainActor
final class WebViewFetcher: NSObject, WKNavigationDelegate {
    static let shared = WebViewFetcher()

    /// WebView 實例池（重複使用避免頻繁建立）
    private var pool: [WKWebView] = []
    private let sharedProcessPool = WKProcessPool()
    private let poolSize = AppConfig.webViewPoolSize
    private var waiters: [CheckedContinuation<WKWebView, Never>] = []
    /// 當前在用（已從池中取出但尚未歸還）的 WebView 數量，包含臨時建立的
    private var activeCount: Int = 0

    /// 正在進行的載入任務
    private var loadingMap: [WKWebView: CheckedContinuation<String, Error>] = [:]

    private override init() {
        super.init()
        // 預建立 WebView 池
        for _ in 0..<poolSize {
            pool.append(createWebView())
        }
    }

    private func createWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.processPool = sharedProcessPool

        // 允許 JavaScript
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs

        // 禁用媒體自動播放（省資源）
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.suppressesIncrementalRendering = true

        let wv = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.navigationDelegate = self
        wv.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        return wv
    }

    // MARK: - 公開 API

    /// 載入 URL 並等待 JavaScript 渲染完成，回傳完整 HTML
    /// - Parameters:
    ///   - url: 目標網址
    ///   - headers: 自訂 HTTP 標頭
    ///   - timeout: 超時秒數（含 JS 渲染等待）
    ///   - jsWait: JS 渲染後額外等待秒數
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

        // 使用 withThrowingTaskGroup 實現超時
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { throw WebViewError.deallocated }

                // 載入頁面
                let _ = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<String, Error>) in
                    self.loadingMap[webView] = continuation
                    webView.load(request)
                }

                // JS 渲染等待
                try await Task.sleep(nanoseconds: UInt64(jsWait * 1_000_000_000))

                // 提取完整 HTML
                let html =
                    try await webView.evaluateJavaScript(
                        "document.documentElement.outerHTML"
                    ) as? String ?? ""

                return html
            }

            // 超時任務
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebViewError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Legado preUpdateJs：載入 URL 後執行自訂 JS，再回傳當前 DOM 的 HTML（用於目錄頁需先跑 JS 才出現列表）
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
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5s 讓 JS 生效
                }
                let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
                return html
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebViewError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Legado loginCheckJs：在已取得的 HTML 上執行 JS，回傳值表示是否需登入（truthy = 需登入）
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
    ///   - url: 章節頁 URL
    ///   - headers: 自訂標頭（含 User-Agent）
    ///   - contentSelectors: 正文容器選擇器，依序嘗試直到取到非空字串（例：.txtnav, #txtright）
    ///   - scrollToEndDelay: 載入後先滾動到底部並等待秒數（觸發懶加載），0 表示不滾動
    ///   - timeout: 整體超時
    ///   - jsWait: 頁面載入完成後等待秒數（讓站點 JS 解密完成）
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

            let result = try await group.next()!
            group.cancelAll()
            if result.isEmpty { throw WebViewError.emptyContent }
            return result
        }
    }

    // MARK: - WebView JS 動態正文提取（對齊 Legado BackstageWebView）

    /// 正文提取 JS：遍歷所有已知選擇器找最長內容 → 啟發式評分 → body.innerText
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

    /// 合併提取：正文內容 + 章節內「下一頁」URL（JSON 格式）
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

    /// 載入 URL → 等待 JS 渲染 → 滾動到底部觸發懶加載 → 用 innerText 提取正文
    /// 對齊 Legado BackstageWebView：onPageFinished 後等待 → 執行 JS → 結果太短則重試
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
                try await Task.sleep(nanoseconds: UInt64(jsWait * 1_000_000_000))

                _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);")
                try await Task.sleep(nanoseconds: 300_000_000)

                let first = try await webView.evaluateJavaScript(Self.contentExtractJS) as? String ?? ""
                let firstTrimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
                if firstTrimmed.count >= 100 { return firstTrimmed }

                for _ in 0..<3 {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let result = try await webView.evaluateJavaScript(Self.contentExtractJS) as? String ?? ""
                    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count >= 100 { return trimmed }
                }

                return firstTrimmed
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebViewError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            if result.isEmpty { throw WebViewError.emptyContent }
            return result
        }
    }

    /// 載入 URL → 提取正文 + 偵測章節內「下一頁」連結（用於分頁合併）
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
                try await Task.sleep(nanoseconds: UInt64(jsWait * 1_000_000_000))
                _ = try? await webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);")
                try await Task.sleep(nanoseconds: 300_000_000)

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

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - 正文提取（Readability + Legado 規則）

    /// 從 HTML 字串用 Readability 提取正文（適用無書源網頁）
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
            return (a && a.textContent) ? a.textContent : '';
          } catch(e) { return ''; }
        })();
        """
        let result = try await webView.evaluateJavaScript(runScript) as? String
        let trimmed = result?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.count >= 100 ? trimmed : nil
    }

    /// 在注入的 HTML 上執行 Legado 規則，回傳單一字串（支援 <js> 等）
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

    /// 載入 HTML 字串到 WebView 並等待載入完成
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
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw WebViewError.timeout
            }
            _ = try await group.next()!
            group.cancelAll()
        }
    }

    /// 從 App Bundle 讀取 JS 檔（Assets/Readability.js、Assets/legado-engine.js）
    private func loadBundleScript(name: String, ext: String) -> String? {
        let bundle = Bundle.main
        if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Assets"),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        if let url = bundle.url(forResource: name, withExtension: ext),
           let s = try? String(contentsOf: url, encoding: .utf8) { return s }
        return nil
    }

    // MARK: - WebView 池管理

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
        // 池已空：若活躍數量未超出上限，建立臨時 WebView（避免請求長時間排隊）
        let maxActive = poolSize * AppConfig.webViewPoolOverflowMultiplier
        if activeCount < maxActive {
            activeCount += 1
            return createWebView()
        }
        // 已達上限，進入等待佇列
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func releaseWebView(_ webView: WKWebView) {
        // 僅停止當前載入，不呼叫 loadHTMLString：否則會啟動新導航，下一位取得此 WebView 的
        // 呼叫者呼叫 load(newRequest) 時會取消該導航並觸發 didFail(-999)，該 -999 會被錯誤地
        // resume 給新呼叫者，導致目錄/詳情請求顯示 NSURLErrorDomain error -999。
        webView.stopLoading()
        loadingMap.removeValue(forKey: webView)
        activeCount = max(0, activeCount - 1)

        if let waiter = waiters.first {
            waiters.removeFirst()
            activeCount += 1  // 歸還給等待者，繼續算作已使用
            waiter.resume(returning: webView)
        } else if pool.count < poolSize {
            pool.append(webView)
        }
        // 超出池大小的臨時 WebView 直接丟棄
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

    nonisolated func webView(
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

// MARK: - 錯誤類型

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
