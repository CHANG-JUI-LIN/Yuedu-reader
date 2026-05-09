import Foundation

// MARK: - 應用配置常量
//
// 集中管理所有硬編碼的業務邏輯常量，方便調整和測試。
// 每個常量都有說明其用途和合理的取值範圍。

enum AppConfig {
    // MARK: - 章節獲取

    /// 同一本書累積失敗幾次後，標記為 quarantined 並停止自動重試
    /// 合理範圍：3~10；太小容易誤判，太大浪費網路資源
    static let chapterFetchQuarantineThreshold: Int = 5

    // MARK: - 啟動時自動更新

    /// App 啟動時並行刷新書架的最大並發數
    /// 過高會觸發書源的 Rate Limiting / Cloudflare 防護
    static let startupRefreshMaxConcurrentTasks: Int = 3

    // MARK: - WebView 池

    /// WebView 池的固定大小；超出此數量的臨時 WebView 用完即棄
    /// 過大會浪費記憶體，過小會排隊等待
    static let webViewPoolSize: Int = 3

    /// WebView 池在全忙時最多允許多建幾個臨時 WebView（防止請求餓死）
    /// 實際上限 = poolSize * webViewPoolOverflowMultiplier
    static let webViewPoolOverflowMultiplier: Int = 2

    // MARK: - 網路超時

    /// WebView 渲染類請求的預設超時秒數
    static let webViewFetchTimeout: TimeInterval = 15

    /// WebView 頁面加載後等待 JS 渲染完成的預設額外秒數（書源規則等舊路徑保留此值）
    static let webViewJSRenderWait: TimeInterval = 2.0

    /// JS 規則引擎單次執行超時秒數
    static let jsRuleEngineExecutionTimeout: TimeInterval = 8

    /// 章節封裝抓取的最大超時秒數（超過即拋出 FetchTimeoutError.chapterTimeout）
    static let chapterFetchTimeoutSeconds: UInt64 = 35

    /// WebView 執行 `jsAfterLoad` 後的額外等待秒數，讓動態頁面有時間套用 JS 結果
    static let webViewPostLoadJSEffectDelay: TimeInterval = 0.5

    /// HTML 字串載入 WKWebView 後等待完成的超時秒數
    static let webViewHTMLLoadTimeout: UInt64 = 10

    // MARK: - WebView 動態輪詢

    /// JS 輪詢：每次探測間隔（毫秒）
    static let webViewPollingIntervalMs: Int = 100

    /// JS 輪詢：認定「內容已就緒」的最低字數（innerText.length）
    static let webViewPollingMinTextLength: Int = 300

    /// JS 輪詢：最多等待毫秒數，超過即強制繼續抓取
    static let webViewPollingMaxWaitMs: Int = 1500

    // MARK: - 安全

    /// 允許書源使用的 URL scheme 白名單
    static let allowedURLSchemes: Set<String> = ["http", "https"]

    /// 本地/私有 IP 前綴黑名單，防止書源探測內網（SSRF）
    /// 注意：NSAllowsLocalNetworking 已在 Info.plist 允許合法 LAN 書源，
    /// 此黑名單用於阻止書源規則中出現的 URL 觸及內網敏感主機。
    static let blockedIPPrefixes: [String] = []
}
