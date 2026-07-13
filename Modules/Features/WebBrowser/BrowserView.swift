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
        webView.customUserAgent =
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
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

    func loadEngine(_ engine: SearchEngine) { load(engine.startURL) }
    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }

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
        isLoading = true
        hasEnoughContent = false
        hasTOC = false
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError _: Error) {
        isLoading = false
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        isLoading = false
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        pageTitle = webView.title ?? ""
        currentURL = webView.url?.absoluteString ?? ""
        hasPage = webView.url != nil
        BrowseHistoryStore.shared.record(title: pageTitle, url: currentURL)
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

// MARK: - Browser Main View
struct BrowserView: View {
    @EnvironmentObject var store: BookStore
    @StateObject private var browser = BrowserState()
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
    @State private var showHome = true

    private var browserContentMaxWidth: CGFloat {
        (horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad) ? 980 : .infinity
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                addressBar
                if browser.isLoading {
                    ProgressView().progressViewStyle(.linear).frame(height: 2)
                }
                if addressFocused {
                    engineShortcuts
                }
                Divider()
                ZStack(alignment: .bottomTrailing) {
                    WebViewRepresentable(webView: browser.webView)
                    if browser.hasPage && browser.hasEnoughContent && !browser.isLoading {
                        extractFAB
                    }
                }
            }

            if showHome {
                ExploreHomeView(onNavigate: navigateFromExplore)
                    .environmentObject(store)
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onReceive(browser.$currentURL) { url in
            if !addressFocused { addressText = url }
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
        .overlay(alignment: .top) {
            if let msg = errorMsg {
                Text(msg)
                    .font(DSFont.caption).foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.red.opacity(0.85)).clipShape(Capsule())
                    .padding(.top, 8)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { errorMsg = nil }
                    }
            }
        }
    }

    // MARK: - Navigate from Explore home
    private func navigateFromExplore(_ urlString: String) {
        browser.load(urlString)
        addressText = urlString
        addressFocused = false
        withAnimation(DSAnimation.standard) { showHome = false }
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

    // MARK: Extract FAB
    private var extractFAB: some View {
        Button {
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
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: browser.hasTOC
                                ? [Color(red: 0.1, green: 0.65, blue: 0.2), Color(red: 0.05, green: 0.45, blue: 0.1)]
                                : [Color(red: 0.25, green: 0.5, blue: 1.0), Color(red: 0.05, green: 0.28, blue: 0.8)],
                            startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(0.28), radius: 8, x: 0, y: 4)

                if isExtracting {
                    ProgressView().scaleEffect(0.9).tint(.white)
                } else {
                    VStack(spacing: 2) {
                        Image(systemName: browser.hasTOC ? "list.bullet" : "book.fill")
                            .font(DSFont.fixed(size: 20, weight: .medium))
                        Text(localized(browser.hasTOC ? "目錄" : "閱讀"))
                            .font(DSFont.fixed(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .disabled(isExtracting)
        .padding(.trailing, 16)
        .padding(.bottom, 128)
    }

    // MARK: Address Bar
    private var addressBar: some View {
        HStack(spacing: 8) {
            Button { withAnimation(DSAnimation.standard) { showHome = true } } label: {
                Image(systemName: "house")
                    .font(DSFont.fixed(size: 16, weight: .medium))
                    .foregroundColor(.primary)
            }

            Button { browser.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(DSFont.fixed(size: 17, weight: .medium))
                    .foregroundColor(browser.canGoBack ? .primary : Color.secondary.opacity(0.35))
            }.disabled(!browser.canGoBack)

            Button { browser.goForward() } label: {
                Image(systemName: "chevron.right")
                    .font(DSFont.fixed(size: 17, weight: .medium))
                    .foregroundColor(browser.canGoForward ? .primary : Color.secondary.opacity(0.35))
            }.disabled(!browser.canGoForward)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(DSFont.caption).foregroundColor(.secondary)
                TextField(localized("輸入網址或搜尋"), text: $addressText)
                    .font(DSFont.fixed(size: 14))
                    .disableAutocorrection(true)
                    .focused($addressFocused)
                    .onSubmit {
                        browser.load(addressText)
                        addressFocused = false
                    }
                if !addressText.isEmpty {
                    Button { addressText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Color.secondary.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Button { browser.reload() } label: {
                Image(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
                    .font(DSFont.fixed(size: 15)).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: browserContentMaxWidth)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(PageBackgroundView(scope: .explore))
    }

    // MARK: Search Engine Shortcuts
    private var engineShortcuts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(SearchEngine.allCases) { engine in
                    Button {
                        browser.loadEngine(engine)
                        addressFocused = false
                        addressText = engine.startURL
                    } label: {
                        HStack(spacing: 6) {
                            Text(engine.icon)
                                .font(DSFont.fixed(size: 12, weight: .bold)).foregroundColor(.white)
                                .frame(width: 22, height: 22)
                                .background(engine.color).clipShape(Circle())
                            Text(engine.rawValue).font(DSFont.subheadline).foregroundColor(.primary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
                Divider().frame(height: 20)
                Text(localized("進入小說章節頁，點「轉碼閱讀」直接開書"))
                    .font(DSFont.caption).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: browserContentMaxWidth, alignment: .leading)
        }
        .background(Color(UIColor.systemBackground))
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
                    }
                    Text(localized("共偵測到") + " \(chapters.count) " + localized("章，選擇開始閱讀的章節"))
                        .font(DSFont.caption)
                        .foregroundColor(.secondary)
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
                                .foregroundColor(.secondary)
                                .frame(width: 36, alignment: .trailing)
                            Text(chapters[idx].title.isEmpty ? localized("第") + " \(idx + 1) " + localized("章") : chapters[idx].title)
                                .font(DSFont.body)
                                .foregroundColor(.primary)
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
                .listStyle(.plain)

                Button {
                    let refs = chapters.enumerated().map { i, ch in
                        OnlineChapterRef(
                            index: i,
                            title: ch.title.isEmpty
                                ? localized("第") + " \(i + 1) " + localized("章")
                                : ReaderHTMLUtilities.displayText(fromHTMLFragment: ch.title),
                            url: ch.url
                        )
                    }
                    onConfirm(refs, selectedIndex)
                } label: {
                    Text(localized("從第") + " \(selectedIndex + 1) " + localized("章開始閱讀"))
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
