import Combine
import SwiftUI
import UIKit
import WebKit

// MARK: - Search Engines
enum SearchEngine: String, CaseIterable, Identifiable {
    case google = "Google"
    case baidu = "百度"
    case bing = "Bing"

    var id: String { rawValue }
    var searchURL: String {
        switch self {
        case .google: return "https://www.google.com/search?q="
        case .baidu: return "https://www.baidu.com/s?wd="
        case .bing: return "https://www.bing.com/search?q="
        }
    }
    var startURL: String {
        switch self {
        case .google: return "https://www.google.com"
        case .baidu: return "https://www.baidu.com"
        case .bing: return "https://www.bing.com"
        }
    }
    var icon: String {
        switch self {
        case .google: return "G"
        case .baidu: return "百"
        case .bing: return "B"
        }
    }
    var color: Color {
        switch self {
        case .google: return .blue
        case .baidu: return Color(red: 0.1, green: 0.4, blue: 0.9)
        case .bing: return Color(red: 0.0, green: 0.5, blue: 0.7)
        }
    }
    var faviconURL: String {
        switch self {
        case .google: return "https://www.google.com/favicon.ico"
        case .baidu: return "https://www.baidu.com/favicon.ico"
        case .bing: return "https://www.bing.com/favicon.ico"
        }
    }
}

// MARK: - Chapter Links
struct WebChapterItem: Identifiable, Codable {
    var id = UUID()
    var title: String
    var url: String
    enum CodingKeys: String, CodingKey { case title, url }
}

private func normalizeDetectedChapters(_ items: [WebChapterItem]) -> [WebChapterItem] {
    struct IndexedItem {
        let item: WebChapterItem
        let originalIndex: Int
        let chapterOrder: Int?
    }

    var deduped: [IndexedItem] = []
    var seenURLs = Set<String>()
    var seenTitleURLs = Set<String>()

    for (index, item) in items.enumerated() {
        let title = ReaderHTMLUtilities.displayText(fromHTMLFragment: item.title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let url = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !url.isEmpty else { continue }

        let normalizedURL = normalizeChapterURL(url)
        let titleKey = normalizeChapterTitleKey(title)
        let dedupeKey = "\(titleKey)|\(normalizedURL)"
        guard !seenURLs.contains(normalizedURL) && !seenTitleURLs.contains(dedupeKey) else { continue }

        seenURLs.insert(normalizedURL)
        seenTitleURLs.insert(dedupeKey)
        deduped.append(
            IndexedItem(
                item: WebChapterItem(title: title, url: url),
                originalIndex: index,
                chapterOrder: extractChapterOrder(from: title)
            ))
    }

    let orderedCount = deduped.filter { $0.chapterOrder != nil }.count
    let shouldSortByChapterOrder = orderedCount >= max(3, deduped.count / 2)

    let sorted = deduped.sorted { lhs, rhs in
        if shouldSortByChapterOrder {
            switch (lhs.chapterOrder, rhs.chapterOrder) {
            case let (l?, r?) where l != r:
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
        }
        return lhs.originalIndex < rhs.originalIndex
    }

    return sorted.map(\.item)
}

private func normalizeChapterURL(_ raw: String) -> String {
    guard var components = URLComponents(string: raw) else { return raw }
    components.fragment = nil
    return components.string ?? raw
}

private func normalizeChapterTitleKey(_ title: String) -> String {
    ReaderHTMLUtilities.displayText(fromHTMLFragment: title)
        .lowercased()
        .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
}

private func extractChapterOrder(from title: String) -> Int? {
    let patterns = [
        "第\\s*([0-9]+)\\s*[章节回卷篇部]",
        "第\\s*([零一二三四五六七八九十百千万兩两〇○]+)\\s*[章节回卷篇部]",
        "chapter\\s*([0-9]+)",
    ]

    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            continue
        }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard
            let match = regex.firstMatch(in: title, options: [], range: range),
            match.numberOfRanges > 1,
            let valueRange = Range(match.range(at: 1), in: title)
        else {
            continue
        }
        let value = String(title[valueRange])
        if let number = Int(value) {
            return number
        }
        if let number = parseChineseChapterNumber(value) {
            return number
        }
    }

    return nil
}

private func parseChineseChapterNumber(_ raw: String) -> Int? {
    let digits: [Character: Int] = [
        "零": 0, "〇": 0, "○": 0,
        "一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4,
        "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    let units: [Character: Int] = ["十": 10, "百": 100, "千": 1000, "万": 10000]

    var result = 0
    var section = 0
    var number = 0
    var consumed = false

    for char in raw {
        if let digit = digits[char] {
            number = digit
            consumed = true
            continue
        }

        guard let unit = units[char] else { continue }
        consumed = true

        if unit == 10000 {
            section += max(number, 1)
            result += section * unit
            section = 0
            number = 0
            continue
        }

        section += max(number, 1) * unit
        number = 0
    }

    let total = result + section + number
    return consumed ? total : nil
}

// MARK: - Content Extraction JS
/// Uses Mozilla Readability.js as the primary extraction method; falls back to CSS selectors with heuristic scoring.
private let contentExtractJS: String = {
    // Try to load Readability.js from the bundle (located at Assets/Readability.js)
    let readabilityURL =
        Bundle.main.url(forResource: "Readability", withExtension: "js", subdirectory: "Assets")
        ?? Bundle.main.url(forResource: "Readability", withExtension: "js")
    let readabilityScript = readabilityURL.flatMap {
        try? String(contentsOf: $0, encoding: .utf8)
    } ?? ""

    let fallback = """
    (function(){
        var sels=[
            '#chapter-content','#chaptercontent','#chapterContent',
            '.chapter-content','.read-content','#readcontent','#read',
            '.txtnav','#txtright','#htmlContent','.BookText','#BookText',
            '#booktext','#chapterbody','#booktxt',
            '.novel-text','#novelcontent','.readArea','#bookContent',
            '#articleBody','.article-body','.article','#article',
            '#content','.content','.txt','#txt'
        ];
        var best='';
        for(var i=0;i<sels.length;i++){
            try{var el=document.querySelector(sels[i]);
                if(el){var t=(el.innerText||'').replace(/[\\t ]+/g,' ').trim();
                    if(t.length>best.length)best=t;}
            }catch(e){}
        }
        if(best.length>=200)return best;
        var all=document.querySelectorAll('div,section,article');
        var bestEl=null,bestLen=0;
        for(var i=0;i<all.length;i++){
            var el=all[i];
            var ci=(el.className||'').toLowerCase()+' '+(el.id||'').toLowerCase();
            if(/(nav|menu|header|footer|sidebar|ad|banner|search|login|toc|toolbar|float)/i.test(ci))continue;
            var t=(el.innerText||'').trim();
            if(t.length>bestLen){bestLen=t.length;bestEl=el;}
        }
        if(bestEl&&bestLen>best.length)best=bestEl.innerText.replace(/\\s*\\n\\s*/g,'\\n').trim();
        return best.length>=100?best:(document.body?document.body.innerText:'');
    })()
    """

    guard !readabilityScript.isEmpty else { return fallback }

    // Prefer Readability; fall back if it fails. Returns article.content (with HTML tags).
    // TXTChapterParser.splitIntoParagraphs handles HTML-to-paragraph conversion in Swift.
    return readabilityScript + """
    ;(function(){
        if(typeof Readability!=='undefined'){
            try{
                var a=new Readability(document.cloneNode(true)).parse();
                if(a&&a.content&&a.content.trim().length>=100){
                    return a.content;
                }
            }catch(e){}
        }
        return \(fallback);
    })()
    """
}()

private let contentExtractPayloadJS: String = {
    let readabilityURL =
        Bundle.main.url(forResource: "Readability", withExtension: "js", subdirectory: "Assets")
        ?? Bundle.main.url(forResource: "Readability", withExtension: "js")
    let readabilityScript = readabilityURL.flatMap {
        try? String(contentsOf: $0, encoding: .utf8)
    } ?? ""

    let fallback = """
    (function(){
        var sels=[
            '#reader-content','#chapter-content','#chaptercontent','#chapterContent',
            '.chapter-content','.read-content','#readcontent','#read',
            '.txtnav','#txtright','#htmlContent','.BookText','#BookText',
            '#booktext','#chapterbody','#booktxt',
            '.novel-text','#novelcontent','.readArea','#bookContent',
            '#articleBody','.article-body','.article','#article',
            '#content','.content','.txt','#txt','main','article','[role="main"]'
        ];
        var bestEl = null;
        var bestLen = 0;
        for (var i = 0; i < sels.length; i++) {
            try {
                var el = document.querySelector(sels[i]);
                if (!el) continue;
                var t = (el.innerText || '').replace(/[\\t ]+/g, ' ').trim();
                if (t.length > bestLen) {
                    bestLen = t.length;
                    bestEl = el;
                }
            } catch (e) {}
        }
        if (!bestEl) {
            var all = document.querySelectorAll('div,section,article');
            for (var j = 0; j < all.length; j++) {
                var candidate = all[j];
                var ci = ((candidate.className || '') + ' ' + (candidate.id || '')).toLowerCase();
                if (/(nav|menu|header|footer|sidebar|ad|banner|search|login|toc|toolbar|float)/i.test(ci)) continue;
                var text = (candidate.innerText || '').trim();
                if (text.length > bestLen) {
                    bestLen = text.length;
                    bestEl = candidate;
                }
            }
        }
        var root = bestEl || document.body || document.documentElement;
        return {
            title: (document.title || '').trim(),
            text: (root && root.innerText ? root.innerText : '').replace(/\\s*\\n\\s*/g, '\\n').trim(),
            html: root && root.outerHTML ? root.outerHTML : (document.body ? document.body.innerHTML : '')
        };
    })()
    """

    guard !readabilityScript.isEmpty else {
        return """
        (function(){
            return JSON.stringify(\(fallback));
        })()
        """
    }

    return readabilityScript + """
    ;(function(){
        var payload = null;
        if (typeof Readability !== 'undefined') {
            try {
                var article = new Readability(document.cloneNode(true)).parse();
                if (article && article.content && article.content.trim().length >= 100) {
                    payload = {
                        title: (article.title || document.title || '').trim(),
                        text: article.content,
                        html: article.content || ''
                    };
                }
            } catch (e) {}
        }
        if (!payload) {
            payload = \(fallback);
        }
        return JSON.stringify(payload);
    })()
    """
}()

private struct ExtractedPagePayload: Decodable {
    let title: String
    let text: String
    let html: String
}

/// Detects page type: >=5 chapter links -> 9999 (TOC page), otherwise returns text length.
private let detectPageJS = """
(function(){
    var txt=document.body?document.body.innerText.replace(/\\s+/g,' ').trim():'';
    var links=document.querySelectorAll('a');
    var n=0;
    for(var i=0;i<links.length;i++){
        var t=links[i].innerText||'';
        if(/第[\\d零一二三四五六七八九十百千]+[章節]/i.test(t)||/Chapter\\s*\\d+/i.test(t)) n++;
    }
    return n>=5?9999:txt.length;
})()
"""

/// Extracts all chapter links.
private let extractChaptersJS = """
(function(){
    var links=document.querySelectorAll('a');
    var chapters=[];
    var seen={};
    for(var i=0;i<links.length;i++){
        var t=(links[i].innerText||links[i].textContent||'').trim();
        var u=links[i].href||'';
        if(u&&!seen[u]&&u.indexOf('http')===0&&(
            /第[\\d零一二三四五六七八九十百千万]+[章節]/i.test(t)||
            /Chapter\\s*\\d+/i.test(t)
        )&&t.length<120){
            seen[u]=true;
            chapters.push({title:t,url:u});
        }
    }
    return JSON.stringify(chapters);
})()
"""

// MARK: - Browser State
class BrowserState: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView

    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var pageTitle = ""
    @Published var currentURL = ""
    @Published var hasPage = false
    @Published var hasEnoughContent = false
    @Published var hasTOC = false
    /// Whether the page is being asked for as a desktop browser. Per session, not persisted: it is
    /// an escape hatch for one stubborn site, not a global preference.
    @Published var usesDesktopSite = false

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.customUserAgent = SourceWebIdentity.phoneUserAgent
        observeWebView()
    }

    /// WebKit's own answers, current for every navigation — including the ones a page
    /// makes within itself (`history.pushState`, a hash change), which never reach
    /// `didFinish`. Read only there, ‹ stayed disabled on such pages.
    private func observeWebView() {
        webView.publisher(for: \.canGoBack).assign(to: &$canGoBack)
        webView.publisher(for: \.canGoForward).assign(to: &$canGoForward)
        webView.publisher(for: \.isLoading).assign(to: &$isLoading)
        webView.publisher(for: \.title).map { $0 ?? "" }.assign(to: &$pageTitle)
        webView.publisher(for: \.url).map { $0?.absoluteString ?? "" }.assign(to: &$currentURL)
        webView.publisher(for: \.url).map { $0 != nil }.assign(to: &$hasPage)
    }

    func load(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        if !s.hasPrefix("http://") && !s.hasPrefix("https://") {
            if s.contains(".") && !s.contains(" ") {
                s = "https://" + s
            } else {
                let enc = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
                s = "https://www.google.com/search?q=\(enc)"
            }
        }
        guard let url = URL(string: s) else { return }
        webView.load(URLRequest(url: url))
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        // Per navigation, so a redirect or a followed link stays in the mode the user chose.
        preferences.preferredContentMode = SourceWebIdentity.contentMode(desktop: usesDesktopSite)
        preferences.allowsContentJavaScript = true
        decisionHandler(.allow, preferences)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

    /// Re-asks the site as a desktop browser. Some sites answer a phone with an app-download page
    /// and nothing else — bot.n.cn is one — which left this browser with no way through.
    /// `SourceWebIdentity` widens the layout viewport as well as changing identity; swapping only
    /// the user-agent delivers desktop HTML into a phone-width viewport and is worse than useless.
    func setDesktopSite(_ desktop: Bool) {
        guard usesDesktopSite != desktop else { return }
        usesDesktopSite = desktop
        SourceWebIdentity.apply(desktop: desktop, to: webView)
        webView.reload()
    }

    // MARK: - Extract content directly from the current WebView

    /// Extract content and title directly from the currently displayed page using JS.
    func extractContent(completion: @escaping (String, String) -> Void) {
        extractTextContent { title, text in
            completion(title, text)
        }
    }

    func extractContentPayload(completion: @escaping (String, String, String) -> Void) {
        webView.evaluateJavaScript(contentExtractPayloadJS) { [weak self] result, _ in
            let fallbackTitle = self?.pageTitle ?? "未知書名"
            guard
                let json = result as? String,
                let data = json.data(using: .utf8),
                let payload = try? JSONDecoder().decode(ExtractedPagePayload.self, from: data)
            else {
                self?.extractTextContent { title, content in
                    completion(title, content, "")
                }
                return
            }

            let rawText = payload.text
                .components(separatedBy: .newlines)
                .map { line -> String in
                    var s = line
                    while let f = s.first, f == " " || f == "\t" || f == "\r" { s.removeFirst() }
                    while let l = s.last, l == " " || l == "\t" || l == "\r" { s.removeLast() }
                    return s
                }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .joined(separator: "\n")
            let content = BookSourceFetcher.cleanChapterContent(rawText)
            let title = ReaderHTMLUtilities.displayText(
                fromHTMLFragment: payload.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? fallbackTitle
                    : payload.title
            )
            completion(title, content, payload.html)
        }
    }

    private func extractTextContent(completion: @escaping (String, String) -> Void) {
        webView.evaluateJavaScript("document.title") { [weak self] t, _ in
            let title = ReaderHTMLUtilities.displayText(
                fromHTMLFragment: (t as? String) ?? (self?.pageTitle ?? "未知書名")
            )
            self?.webView.evaluateJavaScript(contentExtractJS) { text, _ in
                let raw = ((text as? String) ?? "")
                    .components(separatedBy: .newlines)
                    .map { line -> String in
                        var s = line
                        while let f = s.first, f == " " || f == "\t" || f == "\r" { s.removeFirst() }
                        while let l = s.last, l == " " || l == "\t" || l == "\r" { s.removeLast() }
                        return s
                    }
                    .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    .joined(separator: "\n")
                let content = BookSourceFetcher.cleanChapterContent(raw)
                completion(title, content)
            }
        }
    }

    /// Extract chapter links (syncs cookies to URLSession before parsing).
    func extractChapterLinks(completion: @escaping ([WebChapterItem]) -> Void) {
        syncCookiesToURLSession {
            self.webView.evaluateJavaScript(extractChaptersJS) { result, _ in
                guard let jsonStr = result as? String,
                      let data = jsonStr.data(using: .utf8),
                      let arr = try? JSONDecoder().decode([WebChapterItem].self, from: data)
                else {
                    completion([])
                    return
                }
                completion(normalizeDetectedChapters(arr))
            }
        }
    }

    /// Loads a URL in a background WebView and extracts content (for lazy-loading chapters during TOC transcoding).
    /// Shares the user browser's cookies (synced to HTTPCookieStorage + WKWebsiteDataStore).
    func fetchChapterContent(url: URL, completion: @escaping (String) -> Void) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        let bgWebView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        bgWebView.customUserAgent = webView.customUserAgent

        let handler = BackgroundWebViewHandler(targetWebView: bgWebView, js: contentExtractJS) { text in
            let cleaned = BookSourceFetcher.cleanChapterContent(text)
            completion(cleaned)
        }
        bgWebView.navigationDelegate = handler
        objc_setAssociatedObject(bgWebView, "handler", handler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        bgWebView.load(URLRequest(url: url))
    }

    /// Navigates the main WebView to a URL and extracts full content (download mode only).
    /// Enforces a 15-second hard timeout; retries up to 2 times on failure.
    func navigateAndExtract(url: URL, retryCount: Int = 0) async -> String {
        let result = await withTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                self.webView.load(URLRequest(url: url))

                // Wait for page load (max 12 seconds)
                for _ in 0..<24 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if !self.webView.isLoading { break }
                }

                // Allow JS rendering to settle
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                // Scroll to trigger lazy loading
                _ = try? await self.webView.evaluateJavaScript(
                    "window.scrollTo(0,document.body.scrollHeight);")
                try? await Task.sleep(nanoseconds: 800_000_000)
                _ = try? await self.webView.evaluateJavaScript("window.scrollTo(0,0);")
                try? await Task.sleep(nanoseconds: 300_000_000)

                return (try? await self.webView.evaluateJavaScript(contentExtractJS)) as? String ?? ""
            }
            // Timeout task (15 seconds)
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return ""
            }

            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }

        let cleaned = BookSourceFetcher.cleanChapterContent(result)

        // Auto-retry if content is too short (up to 2 retries)
        if cleaned.count < 100 && retryCount < 2 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return await navigateAndExtract(url: url, retryCount: retryCount + 1)
        }

        return cleaned
    }

    /// Syncs cookies to URLSession.
    func syncCookiesToURLSession(completion: @escaping () -> Void) {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            for cookie in cookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        hasEnoughContent = false
        hasTOC = false
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        BrowseHistoryStore.shared.record(
            title: webView.title ?? "",
            url: webView.url?.absoluteString ?? ""
        )
        webView.evaluateJavaScript(detectPageJS) { [weak self] result, _ in
            let n = (result as? Int) ?? 0
            DispatchQueue.main.async {
                self?.hasEnoughContent = n >= 500
                self?.hasTOC = n >= 9999
            }
        }
    }
}

// MARK: - Background WebView Handler
private class BackgroundWebViewHandler: NSObject, WKNavigationDelegate {
    let targetWebView: WKWebView
    let js: String
    let onComplete: (String) -> Void
    private var completed = false

    init(targetWebView: WKWebView, js: String, onComplete: @escaping (String) -> Void) {
        self.targetWebView = targetWebView
        self.js = js
        self.onComplete = onComplete
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !completed else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self, !self.completed else { return }
            self.completed = true
            webView.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight);") { _, _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    webView.evaluateJavaScript(self.js) { result, _ in
                        let text = (result as? String) ?? ""
                        self.onComplete(text)
                        objc_setAssociatedObject(webView, "handler", nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard !completed else { return }
        completed = true
        onComplete("")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard !completed else { return }
        completed = true
        onComplete("")
    }
}

// MARK: - WKWebView Wrapper
struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Explore tab

/// The 探索 tab. It owns the in-app browser's state, so the page a reader left is still
/// there when they come back to it from 探索's list.
struct BrowserView: View {
    @EnvironmentObject var store: BookStore
    @StateObject private var browser = BrowserState()

    var body: some View {
        ExploreTabRoot(browser: browser)
            .environmentObject(store)
    }
}

/// Why 探索 opened the browser.
enum BrowserEntry: Hashable {
    /// The browser as it was left.
    case resume
    /// Opens the address.
    case open(String)
    /// Opens the address and goes straight on to 轉碼閱讀 — a bookmark's 「直接轉碼閱讀」.
    case transcode(String)
}

// MARK: - Browser page

/// The in-app browser, full screen over 探索 as the reader is, laid out as Safari is: no
/// title above the page — only ✕ back to 探索 — and the address field and toolbar along
/// the bottom. With no page open it shows Safari's start page: the bookmarks and the
/// sites visited lately.
struct BrowserPage: View {
    @EnvironmentObject var store: BookStore
    @ObservedObject var browser: BrowserState
    let entry: BrowserEntry
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var addressFocused: Bool

    @State private var addressText = ""
    @State private var isExtracting = false

    // Use an Identifiable item to drive fullScreenCover, avoiding race conditions between Bool and UUID states.
    private struct ReaderPresentation: Identifiable {
        let id: UUID
    }
    @State private var readerPresentation: ReaderPresentation?

    @State private var extractedChapters: [WebChapterItem] = []
    @State private var showTOCSheet = false
    @State private var tocBookTitle = ""
    // Delay presenting Reader until the TOC sheet dismiss animation has fully completed.
    // Calling fullScreenCover while the sheet is still animating out causes SwiftUI to silently ignore it.
    @State private var pendingChapterStart: (chapters: [WebChapterItem], title: String, startIndex: Int)?

    @State private var errorMsg: String?
    /// `entry` is acted on once, when the page first appears.
    @State private var appliedEntry = false
    @State private var showBookmarks = false
    /// A bookmark's 「直接轉碼閱讀」 waiting for its page to finish loading.
    @State private var transcodeArmed = false
    @ObservedObject private var bookmarks = BrowserBookmarkStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var browserContentMaxWidth: CGFloat {
        (horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad) ? 980 : .infinity
    }

    /// ‹ on a page's first screen went back to the bookmarks, as Safari's back goes from a
    /// tab's first page to its start page. The page stays loaded; › returns to it.
    @State private var showsSites = false

    /// A page is on screen, or the first one is on its way.
    private var showsPage: Bool { (browser.hasPage || browser.isLoading) && !showsSites }

    var body: some View {
        ZStack {
            // BrowserState owns the WKWebView and keeps its page while 探索 is in front.
            // Only the surface on top belongs in the hit/accessibility tree; a covered
            // WKWebView can claim the controls drawn over it.
            WebViewRepresentable(webView: browser.webView)
                .opacity(showsPage ? 1 : 0)
                .allowsHitTesting(showsPage)
                .accessibilityHidden(!showsPage)
            if !showsPage {
                BrowserStartPage(
                    onOpen: { open($0) },
                    onTranscode: { open($0, transcodes: true) }
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomChrome }
        // Safari shows no title over the page; its host is in the address field.
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button { dismiss() } label: {
                    Label(localized("關閉"), systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
            }
        }
        .onAppear(perform: applyEntry)
        .onReceive(browser.$currentURL) { url in
            if !addressFocused { addressText = url }
        }
        .onChange(of: addressFocused) { _, focused in
            // Safari shows the host at rest and the full address while editing.
            if focused { addressText = browser.currentURL }
        }
        .onReceive(browser.$isLoading) { _ in transcodeIfArmed() }
        .onReceive(browser.$hasEnoughContent) { _ in transcodeIfArmed() }
        .onReceive(browser.$hasTOC) { _ in transcodeIfArmed() }
        .sheet(isPresented: $showBookmarks) {
            BrowserBookmarksSheet(
                onOpen: { open($0) },
                onTranscode: { open($0, transcodes: true) }
            )
        }
        .fullScreenCover(item: $readerPresentation) { presentation in
            BookReaderView(bookId: presentation.id)
                .environmentObject(store)
        }
        .sheet(isPresented: $showTOCSheet, onDismiss: {
            guard let pending = pendingChapterStart else { return }
            pendingChapterStart = nil
            startChapterDownload(
                chapters: pending.chapters,
                title: pending.title,
                startIndex: pending.startIndex
            )
        }) {
            AdaptiveSheetContainer(maxWidth: DSLayout.readablePanelWidth) {
                WebTOCSheet(
                    title: tocBookTitle,
                    chapters: extractedChapters,
                    isPresented: $showTOCSheet
                ) { _, startIndex in
                    pendingChapterStart = (extractedChapters, tocBookTitle, startIndex)
                    showTOCSheet = false
                }
            }
        }
        .alert(
            localized("操作失敗"),
            isPresented: Binding(
                get: { errorMsg != nil },
                set: { isPresented in
                    if !isPresented { errorMsg = nil }
                }
            )
        ) {
            Button(localized("確定"), role: .cancel) {}
        } message: {
            Text(errorMsg ?? localized("操作失敗"))
        }
    }

    // MARK: - Opening pages

    /// Opens `urlString`; with `transcodes`, goes straight on to 轉碼閱讀 once the page
    /// has loaded enough to read — a bookmark's 「直接轉碼閱讀」.
    private func open(_ urlString: String, transcodes: Bool = false) {
        transcodeArmed = transcodes
        showsSites = false
        browser.load(urlString)
        addressText = urlString
        addressFocused = false
    }

    private func goBack() {
        if browser.canGoBack {
            browser.goBack()
        } else {
            showsSites = true
        }
    }

    private func goForward() {
        if showsSites {
            showsSites = false
        } else {
            browser.goForward()
        }
    }

    /// What 探索 pushed this page for, done once.
    private func applyEntry() {
        guard !appliedEntry else { return }
        appliedEntry = true
        switch entry {
        case .resume:
            break
        case .open(let address):
            open(address)
        case .transcode(let address):
            open(address, transcodes: true)
        }
    }

    /// Runs the armed 轉碼閱讀 when the page it was armed for is ready to read. Driven
    /// by the page's own published state, not a delay.
    private func transcodeIfArmed() {
        guard transcodeArmed, canTranscode else { return }
        transcodeArmed = false
        runTranscode()
    }

    // MARK: - Create Online Book with Lazy Chapter Loading
    private func startChapterDownload(chapters: [WebChapterItem], title: String, startIndex: Int) {
        let refs = chapters.enumerated().map { idx, ch in
            OnlineChapterRef(
                index: idx,
                title: ReaderHTMLUtilities.displayText(fromHTMLFragment: ch.title),
                url: ch.url
            )
        }
        let displayTitle = ReaderHTMLUtilities.displayText(fromHTMLFragment: title)
        let bookTitle = displayTitle.isEmpty ? "網頁書籍" : displayTitle
        let book = store.addWebBrowsedBook(
            name: bookTitle,
            author: "網路",
            sourceURL: browser.currentURL,
            chapters: refs
        )

        if startIndex > 0, chapters.count > 1 {
            let pos = Double(startIndex) / Double(max(chapters.count - 1, 1))
            store.updatePosition(bookId: book.id, position: pos)
        }

        // Pre-fetch the starting chapter: after ReaderView opens, fetchChapterIfNeeded
        // will find the same key in ChapterFetchManager and share the task, reducing wait time.
        let prefetchBook = book
        let prefetchStore = store
        Task {
            _ = try? await ChapterFetchManager.shared.fetchChapter(
                book: prefetchBook,
                chapterIndex: startIndex,
                priority: .jump,
                store: prefetchStore
            )
        }

        // Sync browser login cookies to HTTPCookieStorage.shared so ChapterFetchManager
        // can carry the auth state when fetching chapters via URLSession / WebViewFetcher.
        browser.syncCookiesToURLSession {
            readerPresentation = ReaderPresentation(id: book.id)
        }
    }

    // MARK: 轉碼閱讀

    /// Reads the page into the reader: the chapter list when the page is a table of
    /// contents, otherwise the page's own text.
    private func runTranscode() {
        guard !isExtracting else { return }
        isExtracting = true

        if browser.hasTOC {
            browser.extractChapterLinks { items in
                isExtracting = false
                if items.isEmpty {
                    errorMsg = localized("無法識別章節連結，請直接進入章節頁面再轉碼")
                } else {
                    tocBookTitle = ReaderHTMLUtilities.displayText(fromHTMLFragment: browser.pageTitle)
                    extractedChapters = items
                    showTOCSheet = true
                }
            }
        } else {
            browser.extractContentPayload { title, content, html in
                guard content.count >= 200 else {
                    isExtracting = false
                    errorMsg = localized("抓取到的內容太少，請嘗試進入具體章節頁面")
                    return
                }
                let displayTitle = title.isEmpty
                    ? "網頁書籍"
                    : ReaderHTMLUtilities.displayText(fromHTMLFragment: title)
                do {
                    let book = try store.importWeb(
                        content: html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? content : html,
                        title: displayTitle,
                        author: "網路",
                        sourceURL: browser.currentURL,
                        format: .plainText
                    )
                    isExtracting = false
                    readerPresentation = ReaderPresentation(id: book.id)
                } catch {
                    isExtracting = false
                    errorMsg = localized("儲存失敗：") + error.localizedDescription
                }
            }
        }
    }

    /// The condition the old floating 轉碼 button appeared under.
    private var canTranscode: Bool {
        showsPage && browser.hasPage && browser.hasEnoughContent && !browser.isLoading
    }

    // MARK: Bottom chrome (Safari)

    /// The address field and toolbar along the bottom, over a bar material, as
    /// Safari lays them out — reachable with one hand, the page full height above.
    private var bottomChrome: some View {
        VStack(spacing: DSSpacing.sm) {
            if addressFocused {
                engineShortcuts
            }
            addressField
            if !addressFocused {
                toolbarRow
            }
        }
        .frame(maxWidth: browserContentMaxWidth)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.top, DSSpacing.sm)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The host Safari shows at rest — of the page once it reports its URL, of the
    /// address that was asked for until then.
    private var hostText: String {
        guard !showsSites else { return "" }
        let address = browser.currentURL.isEmpty ? addressText : browser.currentURL
        return URL(string: address)?.host ?? address
    }

    private var addressBinding: Binding<String> {
        Binding(
            get: { addressFocused ? addressText : hostText },
            set: { addressText = $0 }
        )
    }

    private var addressField: some View {
        HStack(spacing: DSSpacing.xs) {
            if showsPage && !addressFocused {
                // Safari's Reader button: shown in the field while the page can be read.
                Button {
                    guard !isExtracting else { return }
                    runTranscode()
                } label: {
                    Group {
                        if isExtracting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: browser.hasTOC ? "list.bullet" : "book")
                        }
                    }
                    .font(DSFont.body.weight(.semibold))
                    .foregroundStyle(canTranscode ? DSColor.accent : DSColor.textTertiary)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                }
                .disabled(!canTranscode || isExtracting)
                .accessibilityLabel(browser.hasTOC ? localized("目錄") : localized("轉碼閱讀"))
            } else {
                // Safari's search field, before there is a page to read.
                Image(systemName: "magnifyingglass")
                    .font(DSFont.body)
                    .foregroundStyle(DSColor.textSecondary)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                    .accessibilityHidden(true)
            }

            TextField(localized("輸入網址或搜尋"), text: addressBinding)
                .font(DSFont.body)
                .multilineTextAlignment(addressFocused ? .leading : .center)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.webSearch)
                .submitLabel(.go)
                .focused($addressFocused)
                .onSubmit { open(addressText) }

            if addressFocused {
                Button { addressText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(DSColor.textTertiary)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                }
                .accessibilityLabel(localized("清除"))
            } else {
                Button {
                    if browser.isLoading { browser.webView.stopLoading() } else { browser.reload() }
                } label: {
                    Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                        .font(DSFont.body)
                        .foregroundStyle(DSColor.textPrimary)
                        .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
                }
                .accessibilityLabel(browser.isLoading ? localized("停止") : localized("重新整理"))
                // Over the start page there is no page to reload; the slot stays so the
                // address keeps its place in the middle.
                .opacity(showsPage ? 1 : 0)
                .disabled(!showsPage)
                .accessibilityHidden(!showsPage)
            }
        }
        .background(
            DSColor.surface,
            in: RoundedRectangle(cornerRadius: DSRadius.lg, style: .continuous)
        )
        .shadow(color: DSColor.appIconShadow, radius: DSLayout.browserLiftShadowRadius, y: DSLayout.browserLiftShadowY)
        .overlay(alignment: .bottom) {
            if showsPage, browser.isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(DSColor.accent)
                    .padding(.horizontal, DSSpacing.lg)
            }
        }
    }

    private var toolbarRow: some View {
        HStack {
            toolbarButton("chevron.left", label: localized("上一頁"), enabled: showsPage, action: goBack)
            Spacer()
            toolbarButton(
                "chevron.right",
                label: localized("下一頁"),
                enabled: showsSites ? browser.hasPage : browser.canGoForward,
                action: goForward
            )
            Spacer()
            let bookmarked = bookmarks.isBookmarked(browser.currentURL)
            toolbarButton(
                bookmarked ? "bookmark.fill" : "bookmark",
                label: bookmarked ? localized("移除書籤") : localized("加入書籤"),
                enabled: showsPage && browser.hasPage
            ) {
                bookmarks.toggle(title: browser.pageTitle, url: browser.currentURL)
            }
            Spacer()
            toolbarButton("book", label: localized("書籤"), enabled: true) {
                showBookmarks = true
            }
            Spacer()
            Menu {
                Toggle(isOn: Binding(
                    get: { browser.usesDesktopSite },
                    set: { browser.setDesktopSite($0) }
                )) {
                    Label(localized("電腦版網頁"), systemImage: "desktopcomputer")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(DSFont.title3)
                    .foregroundStyle(.tint)
                    .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
            }
            .accessibilityLabel(localized("更多"))
        }
    }

    private func toolbarButton(
        _ systemImage: String,
        label: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            // Safari's toolbar: the tint where a button can act, grey where it cannot.
            Image(systemName: systemImage)
                .font(DSFont.title3)
                .foregroundStyle(enabled ? AnyShapeStyle(.tint) : AnyShapeStyle(DSColor.textTertiary))
                .frame(width: DSLayout.minimumTapTarget, height: DSLayout.minimumTapTarget)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    // MARK: Search engine shortcuts

    /// While the address is being edited, the search engines sit above the field.
    private var engineShortcuts: some View {
        ScrollView(.horizontal) {
            HStack(spacing: DSSpacing.sm) {
                ForEach(SearchEngine.allCases) { engine in
                    Button { open(engine.startURL) } label: {
                        DSCapsuleLabel(title: engine.rawValue)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

// MARK: - TOC Chapter Picker Sheet
struct WebTOCSheet: View {
    let title: String
    let chapters: [WebChapterItem]
    @Binding var isPresented: Bool
    var onConfirm: ([OnlineChapterRef], Int) -> Void

    @State private var selectedIndex = 0
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    if !title.isEmpty {
                        Text(title)
                            .font(DSFont.subheadline.weight(.medium))
                            .lineLimit(1)
                            .foregroundStyle(DSColor.textPrimary)
                    }
                    Text(
                        String(
                            format: localized("共偵測到 %d 章，選擇開始閱讀的章節"),
                            chapters.count))
                        .font(DSFont.caption)
                        .foregroundStyle(DSColor.textSecondary)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .background(Color(UIColor.systemGroupedBackground))

                Divider()

                List(chapters.indices, id: \.self) { idx in
                    Button {
                        selectedIndex = idx
                    } label: {
                        HStack {
                            Text("\(idx + 1).")
                                .font(DSFont.caption.monospacedDigit())
                                .foregroundStyle(DSColor.textSecondary)
                                .frame(width: 36, alignment: .trailing)
                            Text(
                                chapters[idx].title.isEmpty
                                    ? String(format: localized("第 %d 章"), idx + 1)
                                    : chapters[idx].title)
                                .font(DSFont.body)
                                .foregroundStyle(DSColor.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if idx == selectedIndex {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(DSColor.accent)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        idx == selectedIndex ? DSColor.accent.opacity(0.07) : Color.clear
                    )
                }
                .softScrollEdges()
                .listStyle(.plain)

                Button {
                    let refs = chapters.enumerated().map { i, ch in
                        OnlineChapterRef(
                            index: i,
                            title: ch.title.isEmpty
                                ? String(format: localized("第 %d 章"), i + 1)
                                : ReaderHTMLUtilities.displayText(fromHTMLFragment: ch.title),
                            url: ch.url
                        )
                    }
                    onConfirm(refs, selectedIndex)
                } label: {
                    Text(String(format: localized("從第 %d 章開始閱讀"), selectedIndex + 1))
                        .font(DSFont.fixed(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(DSColor.accent)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle(localized("偵測到章節目錄"))
            .toolbarTitleDisplayMode(.inline)
            .themedAppSurface(for: .explore)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        isPresented = false
                    } label: {
                        Label(localized("取消"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(localized("取消"))
                }
            }
        }
    }
}

#Preview("Explore and browser") {
    BrowserView()
        .environmentObject(BookStore())
        .environmentObject(SubscriptionStore.shared)
}
