import Combine
import Foundation
import SwiftUI

// MARK: - App 語言
enum AppLanguage: String, CaseIterable {
    case traditionalChinese = "繁體中文"
    case simplifiedChinese = "简体中文"
    case english = "English"
}

// MARK: - 書本文字轉換（只在閱讀器使用）
enum TextConversion: String, CaseIterable {
    case original = "原文"
    case toTraditional = "繁體"
    case toSimplified = "简体"
}

// MARK: - 翻頁動畫（對應 Koodo 滑動、Legado 仿真/滑動/覆蓋）
enum PageTurnStyle: String, CaseIterable {
    case slide = "滑動"       // 左右滑動過渡（預設）
    case cover = "覆蓋翻頁"   // 新頁滑入覆蓋舊頁（Legado 同款）
    case curl = "仿真翻書"   // 書頁捲曲效果
    case none = "無動畫"     // 立即切換
}

// MARK: - 閱讀主題
enum ReaderTheme: String, CaseIterable {
    case white = "白天"
    case sepia = "護眼"
    case night = "夜間"

    private static let userDefaultsKey = "yd_reader_theme"

    static func loadPersisted() -> ReaderTheme {
        let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
        return ReaderTheme(rawValue: raw) ?? .sepia
    }

    func persist() {
        UserDefaults.standard.set(rawValue, forKey: Self.userDefaultsKey)
    }

    var backgroundColor: Color {
        switch self {
        case .white: return .white
        case .sepia: return Color(red: 244 / 255, green: 236 / 255, blue: 216 / 255)
        case .night: return Color(red: 26 / 255, green: 26 / 255, blue: 26 / 255)
        }
    }

    var textColor: Color {
        switch self {
        case .white: return Color(red: 51 / 255, green: 51 / 255, blue: 51 / 255)
        case .sepia: return Color(red: 91 / 255, green: 70 / 255, blue: 54 / 255)
        case .night: return Color(red: 217 / 255, green: 217 / 255, blue: 217 / 255)
        }
    }

    var barColor: Color {
        switch self {
        case .white: return Color(UIColor.systemBackground)
        case .sepia: return Color(red: 0.93, green: 0.91, blue: 0.83)
        case .night: return Color(red: 0.12, green: 0.12, blue: 0.12)
        }
    }

    var epubJSName: String {
        switch self {
        case .white: return "white"
        case .sepia: return "sepia"
        case .night: return "night"
        }
    }
}

enum ReaderConfigRefreshKind {
    case layout
    case appearance
}

@MainActor
final class ReaderConfig: ObservableObject {
    static let shared = ReaderConfig()

    @Published var fontSize: CGFloat
    @Published var lineSpacing: CGFloat
    @Published var letterSpacing: CGFloat
    @Published var paragraphSpacing: CGFloat
    @Published var pageMarginH: CGFloat
    @Published var pageMarginV: CGFloat
    @Published var theme: ReaderTheme

    let refresh = PassthroughSubject<ReaderConfigRefreshKind, Never>()

    private var cancellables = Set<AnyCancellable>()
    private var suppressRefresh = false

    private init() {
        let gs = GlobalSettings.shared
        fontSize = CGFloat(gs.readerFontSize)
        lineSpacing = CGFloat(gs.lineSpacing)
        letterSpacing = CGFloat(gs.letterSpacing)
        paragraphSpacing = CGFloat(gs.paragraphSpacing)
        pageMarginH = CGFloat(gs.pageMarginH)
        pageMarginV = CGFloat(gs.pageMarginV)
        theme = ReaderTheme.loadPersisted()
        setupBindings()
    }

    func syncFromGlobalSettings() {
        let gs = GlobalSettings.shared
        suppressRefresh = true
        fontSize = CGFloat(gs.readerFontSize)
        lineSpacing = CGFloat(gs.lineSpacing)
        letterSpacing = CGFloat(gs.letterSpacing)
        paragraphSpacing = CGFloat(gs.paragraphSpacing)
        pageMarginH = CGFloat(gs.pageMarginH)
        pageMarginV = CGFloat(gs.pageMarginV)
        theme = ReaderTheme.loadPersisted()
        suppressRefresh = false
    }

    private func setupBindings() {
        let layoutPublisher = Publishers.CombineLatest4($fontSize, $lineSpacing, $letterSpacing, $paragraphSpacing)
            .combineLatest($pageMarginH, $pageMarginV)
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)

        layoutPublisher
            .dropFirst()
            .sink { [weak self] combined, marginH, marginV in
                guard let self else { return }
                let (fontSize, lineSpacing, letterSpacing, paragraphSpacing) = combined
                let gs = GlobalSettings.shared
                gs.readerFontSize = Double(fontSize)
                gs.lineSpacing = Double(lineSpacing)
                gs.letterSpacing = Double(letterSpacing)
                gs.paragraphSpacing = Double(paragraphSpacing)
                gs.pageMarginH = Double(marginH)
                gs.pageMarginV = Double(marginV)
                guard !self.suppressRefresh else { return }
                self.refresh.send(.layout)
            }
            .store(in: &cancellables)

        $theme
            .dropFirst()
            .sink { [weak self] theme in
                theme.persist()
                guard let self, !self.suppressRefresh else { return }
                self.refresh.send(.appearance)
            }
            .store(in: &cancellables)
    }
}

extension String {
    /// 書本文字 ICU 離線轉換
    func converted(to mode: TextConversion) -> String {
        switch mode {
        case .original: return self
        case .toTraditional:
            return self.applyingTransform(StringTransform(rawValue: "Hans-Hant"), reverse: false)
                ?? self
        case .toSimplified:
            return self.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false)
                ?? self
        }
    }
}

// MARK: - 全局設定（App 語言 + 書本轉換 + 閱讀器）
class GlobalSettings: ObservableObject {
    static let shared = GlobalSettings()

    @Published var appLanguage: AppLanguage {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: "yd_app_lang") }
    }
    @Published var textConversion: TextConversion {
        didSet { UserDefaults.standard.set(textConversion.rawValue, forKey: "yd_text_conv") }
    }
    @Published var lineSpacing: Double {
        didSet { UserDefaults.standard.set(lineSpacing, forKey: "yd_line_spacing") }
    }
    @Published var scrollMode: Bool {
        didSet { UserDefaults.standard.set(scrollMode, forKey: "yd_scroll_mode") }
    }
    @Published var readerBrightness: Double {
        didSet { UserDefaults.standard.set(readerBrightness, forKey: "yd_reader_brightness") }
    }
    @Published var followSystemBrightness: Bool {
        didSet {
            UserDefaults.standard.set(followSystemBrightness, forKey: "yd_follow_sys_brightness")
        }
    }
    @Published var letterSpacing: Double {
        didSet { UserDefaults.standard.set(letterSpacing, forKey: "yd_letter_spacing") }
    }
    @Published var paragraphSpacing: Double {
        didSet { UserDefaults.standard.set(paragraphSpacing, forKey: "yd_paragraph_spacing") }
    }
    @Published var pageMarginH: Double {
        didSet { UserDefaults.standard.set(pageMarginH, forKey: "yd_page_margin_h") }
    }
    @Published var pageMarginV: Double {
        didSet { UserDefaults.standard.set(pageMarginV, forKey: "yd_page_margin_v") }
    }
    @Published var pageTurnStyle: PageTurnStyle {
        didSet { UserDefaults.standard.set(pageTurnStyle.rawValue, forKey: "yd_page_turn_style") }
    }

    // MARK: - 閱讀器字體（跨 session 持久化）
    @Published var readerFontSize: Double {
        didSet { UserDefaults.standard.set(readerFontSize, forKey: "yd_reader_font_size") }
    }

    // MARK: - 網路設定
    @Published var searchConcurrency: Int {
        didSet { UserDefaults.standard.set(searchConcurrency, forKey: "yd_search_concurrency") }
    }
    @Published var searchAutoPauseCount: Int {
        didSet {
            UserDefaults.standard.set(searchAutoPauseCount, forKey: "yd_search_auto_pause_count")
        }
    }
    @Published var searchCacheDays: Int {
        didSet { UserDefaults.standard.set(searchCacheDays, forKey: "yd_search_cache_days") }
    }

    private init() {
        let rawLang = UserDefaults.standard.string(forKey: "yd_app_lang") ?? ""
        appLanguage = AppLanguage(rawValue: rawLang) ?? .traditionalChinese
        let rawConv = UserDefaults.standard.string(forKey: "yd_text_conv") ?? ""
        textConversion = TextConversion(rawValue: rawConv) ?? .original
        lineSpacing = (UserDefaults.standard.object(forKey: "yd_line_spacing") as? Double) ?? 6.0
        scrollMode = UserDefaults.standard.bool(forKey: "yd_scroll_mode")
        readerBrightness =
            (UserDefaults.standard.object(forKey: "yd_reader_brightness") as? Double) ?? 0.8
        // 預設開啟「跟隨系統亮度」
        if UserDefaults.standard.object(forKey: "yd_follow_sys_brightness") == nil {
            followSystemBrightness = true
        } else {
            followSystemBrightness = UserDefaults.standard.bool(forKey: "yd_follow_sys_brightness")
        }
        letterSpacing =
            (UserDefaults.standard.object(forKey: "yd_letter_spacing") as? Double) ?? 0.0
        paragraphSpacing =
            (UserDefaults.standard.object(forKey: "yd_paragraph_spacing") as? Double) ?? 6.0
        pageMarginH =
            (UserDefaults.standard.object(forKey: "yd_page_margin_h") as? Double) ?? 24.0
        pageMarginV =
            (UserDefaults.standard.object(forKey: "yd_page_margin_v") as? Double) ?? 16.0
        let rawPageTurn = UserDefaults.standard.string(forKey: "yd_page_turn_style") ?? ""
        pageTurnStyle = PageTurnStyle(rawValue: rawPageTurn) ?? .slide

        searchConcurrency =
            (UserDefaults.standard.object(forKey: "yd_search_concurrency") as? Int) ?? 8
        searchAutoPauseCount =
            (UserDefaults.standard.object(forKey: "yd_search_auto_pause_count") as? Int) ?? 0
        searchCacheDays =
            (UserDefaults.standard.object(forKey: "yd_search_cache_days") as? Int) ?? 5
        readerFontSize =
            (UserDefaults.standard.object(forKey: "yd_reader_font_size") as? Double) ?? 18.0
    }

    /// App UI 字串本地化（繁→簡 用 ICU，繁→英 用字典）
    func t(_ zhHant: String) -> String {
        switch appLanguage {
        case .traditionalChinese: return zhHant
        case .simplifiedChinese:
            return zhHant.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false)
                ?? zhHant
        case .english:
            return GlobalSettings.en[zhHant] ?? zhHant
        }
    }

    static let en: [String: String] = [
        "書架": "Library",
        "瀏覽": "Browser",
        "設定": "Settings",
        "返回": "Back",
        "目錄": "Contents",
        "上一章": "Prev",
        "下一章": "Next",
        "書簽": "Bookmark",
        "搜索書名或作者": "Search title or author",
        "添加書籍": "Add Book",
        "書名 A-Z": "Title A-Z",
        "加入時間": "Date Added",
        "閱讀進度": "Progress",
        "排序：": "Sort:",
        "排序": "Sort",
        "刪除書籍": "Delete",
        "編輯書籍資訊": "Edit Info",
        "清空書架": "Clear Library",
        "版本": "Version",
        "反饋": "feedback",
        "請郵箱聯繫": "Email Support",
        "支援格式": "Formats",
        "書籍管理": "Manage",
        "書源管理": "Book Sources",
        "管理書源": "Manage Sources",
        "TXT、Web、書源": "TXT、Web、Sources",
        "閱讀統計": "Stats",
        "書架書籍": "Total Books",
        "閱讀中": "Reading",
        "已讀到最新章節": "Up to date",
        "尚未開始": "Not started",
        "載入中…": "Loading…",
        "書架還是空的": "Library is empty",
        "文字轉換": "Text Conversion",
        "背景主題": "Theme",
        "白天": "Light",
        "護眼": "Eye Care",
        "夜間": "Dark",
        "字體大小": "Font Size",
        "編輯": "Edit",
        "關閉": "Close",
        "取消": "Cancel",
        "儲存": "Save",
        "刪除": "Delete",
        "確認刪除": "Confirm Delete",
        "基本資訊": "Book Info",
        "書名": "Title",
        "作者": "Author",
        "來源": "Source",
        "本機文件": "Local File",
        "網頁匯入": "Web Import",
        "關於": "About",
        "App 語言": "App Language",
        "目前進度": "Progress",
        "加入書架": "Bookmarked",
        "完成": "Done",
        "匯入 TXT 文件，或是輸入網址\n抓取網頁小說加入書架":
            "Import TXT files or enter a URL\nto scrape web novels into your library",
        "行距": "Line Spacing",
        "滾動模式": "Scroll Mode",
        "閱讀亮度": "Brightness",
        "上下滾動": "Scroll",
        "左右翻頁": "Page Flip",
        "閱讀瀏覽器": "Reading Browser",
        "輸入網址或搜尋": "Enter URL or search",
        "進入小說章節頁，點右下角按鈕轉碼閱讀": "Go to a novel chapter page, tap the button to read",
        "進入小說章節頁，點「轉碼閱讀」直接開書": "Go to a chapter page, tap \"Read\" to open",

        // AddBookView
        "方式": "Method",
        "匯入文件": "Import File",
        "網址匯入": "URL Import",
        "支援格式：TXT / EPUB": "Supported: TXT / EPUB",
        "支援純文字（.txt）與電子書（.epub）格式。選取後系統自動識別章節結構。":
            "Supports .txt and .epub formats. Chapters are detected automatically.",
        "確認書籍資訊": "Confirm Book Info",
        "已讀取": "Read",
        "字": "chars",
        "未知作者": "Unknown",
        "點擊選取 TXT / EPUB 文件": "Tap to Select a TXT / EPUB File",
        "從文件 App、iCloud、本機儲存等選取": "From Files, iCloud, local storage, etc.",
        "讀取中...": "Loading...",
        "選取失敗：": "Import failed: ",
        "無法讀取文件，請確認格式為 TXT": "Cannot read file. Please use a TXT file.",

        // BookSearchView
        "搜索書籍": "Search Books",
        "搜索失敗": "Search Failed",
        "確認": "OK",
        "輸入書名或作者": "Title or author",
        "全部": "All",
        "搜索中…": "Searching…",
        "沒有找到": "No results for",
        "嘗試換個關鍵字，或切換書源": "Try different keywords or switch source",
        "尚未設置書源": "No Book Sources",
        "請先在書源管理中新增並啟用書源": "Please add and enable a book source first",
        "輸入書名或作者搜索": "Enter title or author to search",
        "已啟用": "Enabled",
        "個書源": "sources",
        "沒有可用的書源，請先啟用書源": "No sources enabled. Please enable one first.",

        // URLImportTab
        "輸入小說網頁網址，系統抓取頁面文字。建議選用有純文字章節頁面的網站。":
            "Enter a novel page URL to fetch its text. Works best with plain-text chapter pages.",
        "網址": "URL",
        "書名（必填）": "Title (required)",
        "作者（選填）": "Author (optional)",
        "已抓取約": "Fetched ~",
        "正在抓取頁面…": "Fetching page…",
        "抓取頁面": "Fetch Page",
        "網路書籍": "Web Book",
        "網址格式不正確": "Invalid URL format",
        "抓取失敗：": "Fetch failed: ",
        "沒有收到資料": "No data received",
        "抓取到的文字太少，網站可能不支援直接抓取":
            "Too little text found. The site may not support direct scraping.",

        // AddBookView (補充)
        "已解析 EPUB 結構，點擊下方按鈕匯入": "EPUB parsed. Tap below to import.",

        // BookSearchView (補充)
        "個": "",
        "失敗": "Failed",
        "源": "sources",
        "超時": "Timeout",

        // BookSourceDebugView
        "啟用網路除錯錄製": "Enable Network Debug Recording",
        "書源除錯大師": "Book Source Debugger",
        "清空紀錄": "Clear Log",

        // BookSourceEditView
        "CSS 選擇器示例：ul.book-list li\n屬性提取：a@href、img@src":
            "CSS selector e.g.: ul.book-list li\nAttribute: a@href, img@src",
        "{{key}} 為搜索關鍵字佔位符。POST 格式：URL,POST,body":
            "{{key}} is the keyword placeholder. POST format: URL,POST,body",
        "下一頁 URL": "Next Page URL",
        "啟用": "Enabled",
        "如：某某小說網": "e.g. Novel Site",
        "如：玄幻、言情": "e.g. Fantasy, Romance",
        "封面": "Cover",
        "搜索 URL": "Search URL",
        "搜索結果規則": "Search Result Rules",
        "搜索設定": "Search Settings",
        "新建書源": "New Source",
        "書源地址": "Source URL",
        "書籍 URL": "Book URL",
        "書籍列表": "Book List",
        "書籍詳情規則": "Book Detail Rules",
        "替換規則": "Replace Rules",
        "替換規則每行格式：regex@@@replacement（空 replacement 表示刪除）":
            "Format per line: regex@@@replacement (empty replacement = delete)",
        "最新章節": "Latest Chapter",
        "正文": "Content",
        "正文規則": "Content Rules",
        "留空使用書籍頁 URL": "Leave empty to use book page URL",
        "登入檢查 JS": "Login Check JS",
        "登入頁 URL": "Login Page URL",
        "目錄 URL 留空則使用書籍 URL": "Leave empty to use book URL",
        "目錄規則": "TOC Rules",
        "章節 URL": "Chapter URL",
        "章節列表": "Chapter List",
        "章節名": "Chapter Title",
        "簡介": "Description",
        "自定 HTTP Header": "Custom HTTP Headers",
        "載入目錄頁後先執行再解析（可留空）": "JS to run before parsing TOC (optional)",
        "進階": "Advanced",
        "loginCheckJs：搜尋取得 HTML 後執行，回傳 true 表示需登入，不解析結果。":
            "loginCheckJs: Runs after fetching HTML. Return true = needs login, skips parsing.",
        "preUpdateJs：載入目錄頁後先執行此 JS 再解析。章節列表：CSS 選擇器。":
            "preUpdateJs: JS to run before parsing TOC. Chapter list: CSS selector.",

        // BookSourceListView
        "個書源到剪貼簿": "source(s) to clipboard",
        "個書源嗎？": "source(s)?",
        "停用選中": "Disable Selected",
        "全選": "Select All",
        "全部停用": "Disable All",
        "全部啟用": "Enable All",
        "匯入": "Import",
        "匯入書源": "Import Source",
        "匯入書源 JSON": "Import Source JSON",
        "匯出全部": "Export All",
        "匯出選中": "Export Selected",
        "反選": "Invert Selection",
        "啟用選中": "Enable Selected",
        "尚無書源": "No Sources Yet",
        "已複製書源 JSON": "Source JSON copied",
        "從文件選取 .json": "Select .json file",
        "搜索書源": "Search Sources",
        "未命名書源": "Unnamed Source",
        "無法讀取文件": "Cannot read file",
        "複製 JSON": "Copy JSON",
        "貼上 Legado 格式的書源 JSON（支援單個 {} 或陣列 []），或選取 .json 文件。":
            "Paste Legado source JSON (single {} or array []), or select a .json file.",
        "點擊右上角 + 手動新增\n或 ↓ 貼上 Legado 書源 JSON 匯入":
            "Tap + to add manually\nor paste Legado source JSON below",

        // BrowserView
        "偵測到章節目錄": "Chapter list detected",
        "章": "ch.",
        "章開始閱讀": "ch. to start reading",
        "章，選擇開始閱讀的章節": "chapters. Choose where to start",

        // CloudflareChallengeView
        "本站啟用了防護 (Cloudflare / DDoS-Guard)。\n請手動通過人機驗證後，系統將自動繼續。":
            "This site uses protection (Cloudflare / DDoS-Guard).\nPlease complete the challenge to continue.",
        "放棄": "Give Up",
        "網站安全驗證": "Security Check",

        // DownloadManagementView
        "下載中": "Downloading",
        "下載管理": "Download Manager",
        "佔用空間": "Storage Used",
        "尚未下載任何書籍": "No books downloaded yet",
        "已下載": "Downloaded",
        "已下載書籍": "Downloaded Books",
        "本": "books",
        "目前沒有下載任務": "No active downloads",
        "移除": "Remove",
        "總覽": "Overview",
        "重新下載": "Re-download",

        // FontSettingsView
        "上下": "Vertical",
        "動畫樣式": "Animation Style",
        "字距": "Letter Spacing",
        "左右": "Horizontal",
        "已開啟": "On",
        "段落間距": "Paragraph Spacing",
        "滑動：左右平移；覆蓋翻頁：新頁滑入蓋住舊頁（Legado）；仿真翻書：捲曲效果；無動畫：立即切換":
            "Slide: Horizontal; Cover: New page slides over; Curl: Page curl effect; None: Instant",
        "目前": "Current",
        "簡↔繁轉換離線完成，永久生效": "SC↔TC conversion is offline and permanent",
        "翻頁動畫": "Page Turn Animation",
        "跟隨系統亮度": "Follow System Brightness",
        "轉換模式": "Conversion Mode",
        "退出閱讀器後自動恢復原始亮度": "Brightness resets after leaving reader",
        "閱讀模式": "Reading Mode",
        "閱讀設定": "Reading Settings",
        "頁面留白": "Page Margin",

        // HomeView (補充)
        "嗎？": "?",
        "已讀": "Read",
        "書籍資訊": "Book Info",

        // NetworkSettingsView
        "並發數": "Concurrency",
        "搜索/缓存/下载等网络请求并发数，建议8个":
            "Concurrent requests for search/cache/download. Recommended: 8",
        "搜索時啟用快取，避免重複搜索，預設快取 5 日":
            "Cache search results to avoid duplicates. Default: 5 days",
        "搜索結果快取天數": "Search Cache (days)",
        "每搜索到N个精確結果(或5N個模糊結果)後自動暫停(0不暫停)，防止設備發燙和流量消耗過多":
            "Auto-pause after N exact results (or 5N fuzzy). 0 = no pause. Saves battery & data.",
        "網路設定": "Network Settings",
        "自動暫停": "Auto Pause",

        // OnlineBookView
        "打開中…": "Opening…",
        "書源已被刪除": "Source has been deleted",
        "書籍詳情": "Book Details",
        "未知書名": "Unknown Title",
        "目錄為空": "Table of contents is empty",
        "載入目錄…": "Loading TOC…",
        "重試": "Retry",

        // ProfileView (補充)
        "TXT、EPUB、Web、書源": "TXT, EPUB, Web, Sources",
        "請郵箱聯繫：<r3212239269@gmail.com>": "Email: <r3212239269@gmail.com>",

        // ReaderView
        "亮度": "Brightness",
        "同步系統": "Sync System",
        "在閱讀時點擊右上角書籤按鈕添加": "Tap the bookmark button while reading to add one",
        "尚無書籤": "No Bookmarks",
        "換源": "Switch Source",
        "暫無其他書源": "No other sources available",
        "正在搜尋其他書源…": "Searching for sources…",
        "正在渲染 EPUB…": "Rendering EPUB…",
        "正在準備翻頁…": "Preparing pages…",
        "渲染中…": "Rendering…",
        "設置": "Settings",
        "載入章節中…": "Loading chapter…",

        // TTSPanelView
        "分鐘": "min",
        "定時停止": "Sleep Timer",
        "當前速度": "Current Speed",
        "秒翻一頁": "sec/page",
        "翻頁速度": "Page Turn Speed",
        "自動閱讀": "Auto Read",
        "語速": "Speed",
        "語音朗讀": "Text to Speech",
    ]
}
