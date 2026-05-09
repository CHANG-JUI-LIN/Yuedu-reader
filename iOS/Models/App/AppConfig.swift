import Foundation

// MARK: - Application Configuration Constants
//
// Centralizes all hardcoded business-logic constants for easier tuning and testing.
// Each constant documents its purpose and reasonable value range.

enum AppConfig {
    // MARK: - Chapter Fetching

    /// Number of cumulative failures before marking a book as quarantined
    /// and stopping automatic retry.
    /// Reasonable range: 3–10; too low risks false positives, too high wastes network resources.
    static let chapterFetchQuarantineThreshold: Int = 5

    // MARK: - Startup Auto-Refresh

    /// Maximum concurrent bookshelf refreshes at app launch.
    /// Too high triggers book-source rate limiting / Cloudflare protection.
    static let startupRefreshMaxConcurrentTasks: Int = 3

    // MARK: - WebView Pool

    /// Fixed size of the WebView pool. Temporary WebViews beyond this count are
    /// discarded after use. Too large wastes memory, too small causes queuing.
    static let webViewPoolSize: Int = 3

    /// Maximum additional temporary WebViews allowed when the pool is fully
    /// occupied (prevents request starvation).
    /// Effective limit = poolSize × webViewPoolOverflowMultiplier.
    static let webViewPoolOverflowMultiplier: Int = 2

    // MARK: - Network Timeouts

    /// Default timeout in seconds for WebView rendering requests.
    static let webViewFetchTimeout: TimeInterval = 15

    /// Default additional seconds to wait for JS rendering after WebView page
    /// load (retained for legacy paths like book-source rules).
    static let webViewJSRenderWait: TimeInterval = 2.0

    /// Timeout in seconds for a single JS rule engine execution.
    static let jsRuleEngineExecutionTimeout: TimeInterval = 8

    /// Maximum timeout in seconds for chapter package fetch.
    /// Exceeding this throws FetchTimeoutError.chapterTimeout.
    static let chapterFetchTimeoutSeconds: UInt64 = 35

    /// Additional seconds to wait after executing `jsAfterLoad` in WebView,
    /// allowing dynamic pages time to apply JS results.
    static let webViewPostLoadJSEffectDelay: TimeInterval = 0.5

    /// Timeout in seconds for waiting after loading an HTML string into WKWebView.
    static let webViewHTMLLoadTimeout: UInt64 = 10

    // MARK: - WebView Dynamic Polling

    /// JS polling: interval between probes (ms).
    static let webViewPollingIntervalMs: Int = 100

    /// JS polling: minimum innerText.length to consider content ready.
    static let webViewPollingMinTextLength: Int = 300

    /// JS polling: maximum wait in ms; exceeded → force-continue fetch.
    static let webViewPollingMaxWaitMs: Int = 1500

    // MARK: - Security

    /// Allowed URL schemes for book sources.
    static let allowedURLSchemes: Set<String> = ["http", "https"]

    /// Local/private IP prefix blocklist to prevent book-source SSRF.
    /// NSAllowsLocalNetworking in Info.plist already permits legitimate LAN
    /// sources; this blocklist prevents URLs in book-source rules from
    /// reaching sensitive internal hosts.
    static let blockedIPPrefixes: [String] = []
}
