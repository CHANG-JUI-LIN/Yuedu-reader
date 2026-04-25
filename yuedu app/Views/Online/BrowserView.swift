import Combine
import SwiftUI
import UIKit
import WebKit

// MARK: - 搜尋引擎
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

// MARK: - 章節連結（瀏覽器目錄用）
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
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
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
    title
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

// MARK: - 正文提取 JS（Readability.js 優先，CSS 選擇器 fallback）
/// 載入 Mozilla Readability.js 作為主提取方案；若失敗則退回 CSS 選擇器 + 啟發式評分
private let contentExtractJS: String = {
    // 嘗試從 Bundle 載入 Readability.js（位於 Assets/Readability.js）
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

    // Readability 優先，失敗時用 fallback；直接回傳 article.content（含 HTML 標籤）
    // TXTChapterParser.splitIntoParagraphs 會在 Swift 端處理 HTML→段落
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

/// 偵測頁面類型：章節連結 ≥5 → 9999（目錄頁），否則回傳文字長度
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

/// 提取所有章節連結
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

// MARK: - 瀏覽器狀態（對齊 Legado BackstageWebView 的動態提取策略）
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

    // MARK: - 核心：從當前 WebView 直接提取正文（不另發 HTTP 請求）

    /// 從使用者正在瀏覽的頁面直接用 JS 提取正文 + 標題
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
            let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? fallbackTitle
                : payload.title
            completion(title, content, payload.html)
        }
    }

    private func extractTextContent(completion: @escaping (String, String) -> Void) {
        webView.evaluateJavaScript("document.title") { [weak self] t, _ in
            let title = (t as? String) ?? (self?.pageTitle ?? "未知書名")
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

    /// 提取章節目錄連結（先同步 Cookie 到 URLSession 再解析）
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

    /// 在背景 WebView 載入指定 URL 並提取正文（用於目錄轉碼時各章節的懶加載）
    /// 共用使用者瀏覽器的 Cookie（已同步到 HTTPCookieStorage + WKWebsiteDataStore）
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

    /// 用主 WebView 導航到指定 URL 並提取完整正文（下載模式專用）
    /// 加入 15 秒硬限制超時；失敗時最多重試 2 次
    func navigateAndExtract(url: URL, retryCount: Int = 0) async -> String {
        // 硬限制：15 秒超時（用 withThrowingTaskGroup 實現）
        let result = await withTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                self.webView.load(URLRequest(url: url))

                // 等待頁面載入完成（最多 12 秒）
                for _ in 0..<24 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if !self.webView.isLoading { break }
                }

                // JS 渲染等待
                try? await Task.sleep(nanoseconds: 1_500_000_000)

                // 滾動觸發懶加載
                _ = try? await self.webView.evaluateJavaScript(
                    "window.scrollTo(0,document.body.scrollHeight);")
                try? await Task.sleep(nanoseconds: 800_000_000)
                _ = try? await self.webView.evaluateJavaScript("window.scrollTo(0,0);")
                try? await Task.sleep(nanoseconds: 300_000_000)

                return (try? await self.webView.evaluateJavaScript(contentExtractJS)) as? String ?? ""
            }
            // 超時任務（15 秒）
            group.addTask {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                return ""
            }

            let first = await group.next() ?? ""
            group.cancelAll()
            return first
        }

        let cleaned = BookSourceFetcher.cleanChapterContent(result)

        // 內容太少，自動重試（最多 2 次）
        if cleaned.count < 100 && retryCount < 2 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return await navigateAndExtract(url: url, retryCount: retryCount + 1)
        }

        return cleaned
    }

    /// 同步 Cookie
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
        webView.evaluateJavaScript(detectPageJS) { [weak self] result, _ in
            let n = (result as? Int) ?? 0
            DispatchQueue.main.async {
                self?.hasEnoughContent = n >= 500
                self?.hasTOC = n >= 9999
            }
        }
    }
}

// MARK: - 背景 WebView 載入 Handler（用於目錄轉碼各章節抓取）
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

// MARK: - WKWebView 包裝
struct WebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - 瀏覽器主視圖
struct BrowserView: View {
    @EnvironmentObject var store: BookStore
    @StateObject private var browser = BrowserState()
    @ObservedObject private var gs = GlobalSettings.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @FocusState private var addressFocused: Bool

    @State private var addressText = ""
    @State private var isExtracting = false

    // 用 Identifiable item 驅動 fullScreenCover，避免 Bool + UUID 兩條 state 競爭。
    private struct ReaderPresentation: Identifiable {
        let id: UUID
    }
    @State private var readerPresentation: ReaderPresentation?

    @State private var extractedChapters: [WebChapterItem] = []
    @State private var showTOCSheet = false
    @State private var tocBookTitle = ""
    // 延後 present Reader 直到 TOC sheet 真正 dismiss 結束。
    // 在 sheet 還在收起動畫時呼叫 fullScreenCover SwiftUI 會靜默忽略。
    @State private var pendingChapterStart: (chapters: [WebChapterItem], title: String, startIndex: Int)?

    @State private var errorMsg: String?

    private var browserContentMaxWidth: CGFloat {
        (horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad) ? 980 : .infinity
    }

    private var browserHeroSpacing: CGFloat {
        (horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad) ? 28 : 36
    }

    private var browserEngineSpacing: CGFloat {
        (horizontalSizeClass == .regular || UIDevice.current.userInterfaceIdiom == .pad) ? 24 : 32
    }

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if browser.hasPage {
                    addressBar
                    if browser.isLoading {
                        ProgressView().progressViewStyle(.linear).frame(height: 2)
                    }
                    if addressFocused {
                        engineShortcuts
                    }
                    Divider()
                }
                ZStack(alignment: .bottomTrailing) {
                    WebViewRepresentable(webView: browser.webView)
                    if browser.hasPage && browser.hasEnoughContent && !browser.isLoading {
                        extractFAB
                    }
                }
            }

            if !browser.hasPage {
                homePageView
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onReceive(browser.$currentURL) { url in
            if !addressFocused { addressText = url }
        }
        .fullScreenCover(item: $readerPresentation) { presentation in
            ReaderView(bookId: presentation.id)
                .environmentObject(store)
        }
        .sheet(isPresented: $showTOCSheet, onDismiss: {
            // onDismiss 在 sheet 動畫完全結束後觸發，此時才 present Reader 不會 crash。
            guard let pending = pendingChapterStart else { return }
            pendingChapterStart = nil
            startChapterDownload(
                chapters: pending.chapters,
                title: pending.title,
                startIndex: pending.startIndex
            )
        }) {
            AdaptiveSheetContainer(maxWidth: 820) {
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
                    .font(.caption).foregroundColor(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.red.opacity(0.85)).clipShape(Capsule())
                    .padding(.top, 8)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { errorMsg = nil }
                    }
            }
        }
    }

    // MARK: - 建立線上書 → 按需懶加載章節（不預下載全部）
    private func startChapterDownload(chapters: [WebChapterItem], title: String, startIndex: Int) {
        print("[BrowserView] startChapterDownload chapters=\(chapters.count) startIndex=\(startIndex)")
        let refs = chapters.enumerated().map { idx, ch in
            OnlineChapterRef(index: idx, title: ch.title, url: ch.url)
        }
        let bookTitle = title.isEmpty ? "網頁書籍" : title
        let book = store.addWebBrowsedBook(
            name: bookTitle,
            author: "網路",
            sourceURL: browser.currentURL,
            chapters: refs
        )
        print("[BrowserView] book created id=\(book.id)")

        if startIndex > 0, chapters.count > 1 {
            let pos = Double(startIndex) / Double(max(chapters.count - 1, 1))
            store.updatePosition(bookId: book.id, position: pos)
        }

        // 搶先觸發起始章節的網路抓取：ReaderView 開啟後 fetchChapterIfNeeded
        // 會在 ChapterFetchManager 找到同 key 的 Task 並共用，縮短等待時間。
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

        // 把瀏覽器的登入 cookies 同步到 HTTPCookieStorage.shared，
        // 後續 ChapterFetchManager 透過 URLSession / WebViewFetcher 抓章節時才能帶著登入狀態。
        browser.syncCookiesToURLSession {
            print("[BrowserView] cookies synced, presenting Reader")
            readerPresentation = ReaderPresentation(id: book.id)
        }
    }

    // MARK: 首頁
    private var homePageView: some View {
        let iconGray = Color(red: 174/255, green: 174/255, blue: 178/255)   // #AEAEB2
        let labelDark = Color(red: 60/255, green: 60/255, blue: 67/255)     // #3C3C43
        return VStack(alignment: .leading, spacing: 0) {
            if browser.isLoading {
                ProgressView().progressViewStyle(.linear).frame(height: 2)
            }

            // 搜尋欄
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(iconGray)
                    .font(.system(size: 16))
                ZStack(alignment: .leading) {
                    if addressText.isEmpty {
                        Text(localized("網址或搜尋"))
                            .font(.system(size: 16))
                            .foregroundColor(iconGray)
                    }
                    TextField("", text: $addressText)
                        .font(.system(size: 16))
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .focused($addressFocused)
                        .onSubmit {
                            browser.load(addressText)
                            addressFocused = false
                        }
                }
                if !addressText.isEmpty {
                    Button { addressText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(iconGray)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
            .padding(.horizontal, 16)

            Spacer().frame(height: 16)

            // 快捷搜尋列
            HStack(alignment: .top, spacing: 20) {
                ForEach(SearchEngine.allCases) { engine in
                    Button {
                        browser.loadEngine(engine)
                        addressFocused = false
                        addressText = engine.startURL
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(Color.white)
                                    .frame(width: 52, height: 52)
                                    .shadow(color: .black.opacity(0.10), radius: 4, x: 0, y: 1)
                                AsyncImage(url: URL(string: engine.faviconURL)) { phase in
                                    if let image = phase.image {
                                        image.resizable().scaledToFit()
                                    } else {
                                        Color.clear
                                    }
                                }
                                .frame(width: 28, height: 28)
                            }
                            Text(engine.rawValue)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundColor(labelDark)
                        }
                    }.buttonStyle(.plain)
                }
            }
            .padding(.leading, 16)

            Spacer().frame(height: 20)

            // 提示文字
            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundColor(iconGray)
                Text(localized("前往小說章節頁，點擊右下角即可轉碼閱讀"))
                    .font(.system(size: 13))
                    .foregroundColor(iconGray)
            }
            .padding(.leading, 16)

            Spacer()
        }
        .padding(.top, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: 轉碼浮動按鈕
    private var extractFAB: some View {
        Button {
            guard !isExtracting else { return }
            isExtracting = true

            if browser.hasTOC {
                browser.extractChapterLinks { items in
                    isExtracting = false
                    if items.isEmpty {
                        errorMsg = "無法識別章節連結，請直接進入章節頁面再轉碼"
                    } else {
                        tocBookTitle = browser.pageTitle
                        extractedChapters = items
                        showTOCSheet = true
                    }
                }
            } else {
                browser.extractContentPayload { title, content, html in
                    guard content.count >= 200 else {
                        isExtracting = false
                        errorMsg = "抓取到的內容太少，請嘗試進入具體章節頁面"
                        return
                    }
                    do {
                        let book = try store.importWeb(
                            content: html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? content : html,
                            title: title.isEmpty ? "網頁書籍" : title,
                            author: "網路",
                            sourceURL: browser.currentURL,
                            format: .plainText  // 一律存 .txt；TXTChapterParser.splitIntoParagraphs 會在 Swift 端解析 HTML 標籤
                        )
                        isExtracting = false
                        readerPresentation = ReaderPresentation(id: book.id)
                    } catch {
                        isExtracting = false
                        errorMsg = "儲存失敗：\(error.localizedDescription)"
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
                            .font(.system(size: 20, weight: .medium))
                        Text(browser.hasTOC ? "目錄" : "閱讀")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(.white)
                }
            }
        }
        .disabled(isExtracting)
        .padding(.trailing, 16)
        .padding(.bottom, 28)
    }

    // MARK: 地址欄
    private var addressBar: some View {
        HStack(spacing: 8) {
            Button { browser.goBack() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(browser.canGoBack ? .primary : Color.secondary.opacity(0.35))
            }.disabled(!browser.canGoBack)

            Button { browser.goForward() } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(browser.canGoForward ? .primary : Color.secondary.opacity(0.35))
            }.disabled(!browser.canGoForward)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundColor(.secondary)
                TextField(localized("輸入網址或搜尋"), text: $addressText)
                    .font(.system(size: 14))
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
                    .font(.system(size: 15)).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: browserContentMaxWidth)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
    }

    // MARK: 搜尋引擎快捷列
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
                                .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                                .frame(width: 22, height: 22)
                                .background(engine.color).clipShape(Circle())
                            Text(engine.rawValue).font(.subheadline).foregroundColor(.primary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.secondary.opacity(0.15)).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
                Divider().frame(height: 20)
                Text(localized("進入小說章節頁，點「轉碼閱讀」直接開書"))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(maxWidth: browserContentMaxWidth, alignment: .leading)
        }
        .background(Color(UIColor.systemBackground))
    }
}

// MARK: - 目錄選章 Sheet
struct WebTOCSheet: View {
    let title: String
    let chapters: [WebChapterItem]
    @Binding var isPresented: Bool
    var onConfirm: ([OnlineChapterRef], Int) -> Void

    @State private var selectedIndex = 0
    @ObservedObject private var gs = GlobalSettings.shared

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    if !title.isEmpty {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                    }
                    Text(localized("共偵測到") + " \(chapters.count) " + localized("章，選擇開始閱讀的章節"))
                        .font(.caption)
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
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .frame(width: 36, alignment: .trailing)
                            Text(chapters[idx].title.isEmpty ? localized("第") + " \(idx + 1) " + localized("章") : chapters[idx].title)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Spacer()
                            if idx == selectedIndex {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        idx == selectedIndex ? Color.blue.opacity(0.07) : Color.clear
                    )
                }
                .listStyle(.plain)

                Button {
                    let refs = chapters.enumerated().map { i, ch in
                        OnlineChapterRef(
                            index: i,
                            title: ch.title.isEmpty ? localized("第") + " \(i + 1) " + localized("章") : ch.title,
                            url: ch.url
                        )
                    }
                    onConfirm(refs, selectedIndex)
                } label: {
                    Text(localized("從第") + " \(selectedIndex + 1) " + localized("章開始閱讀"))
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(UIColor.systemBackground))
            }
            .navigationTitle(localized("偵測到章節目錄"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(localized("取消")) { isPresented = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
