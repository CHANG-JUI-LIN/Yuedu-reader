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

    /// Distinct chapters of one book that must fail before the reader suspects the table of
    /// contents rather than the chapters.
    ///
    /// Chapters fail one at a time; a stale TOC fails all of them, so the count is the signal
    /// no single failure can give. Deliberately below `chapterFetchQuarantineThreshold`:
    /// revalidating the TOC has to get its chance before the same failures quarantine the book.
    static let staleTOCSuspicionThreshold: Int = 3

    // MARK: - Startup Auto-Refresh

    /// Maximum concurrent bookshelf refreshes at app launch.
    /// Too high triggers book-source rate limiting / Cloudflare protection.
    static let startupRefreshMaxConcurrentTasks: Int = 3

    /// Minimum seconds between *automatic* table-of-contents refreshes (cold
    /// launch and returning to the foreground). Manual pull-to-refresh ignores
    /// this. Prevents hammering book sources when the app is switched in and out
    /// rapidly. Reasonable range: 120–600.
    static let autoRefreshMinInterval: TimeInterval = 300

    /// How long a cached table of contents / book-info package may be served without
    /// going back to the source.
    ///
    /// It used to be forever. The cache is keyed by `(sourceId, url)` rather than by book, so
    /// it outlived the books that created it: deleting a book and re-adding it from 發現
    /// replayed the same chapter URLs, and nothing in the app could clear it. A source whose
    /// chapter URLs carry a token or a signature therefore produced "every chapter fails and
    /// only 換源 fixes it" — 換源 being the one action that changes the key. Reasonable range:
    /// hours to a day; the "check for new chapters" path passes `forceRefresh: true` and is
    /// unaffected either way.
    static let tocCacheTTL: TimeInterval = 6 * 60 * 60

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

    /// Default delay after `didFinish` for a plain WebView response. Legado's
    /// `BackstageWebView` waits 900 ms plus its 100 ms dispatch delay when a
    /// source did not provide JavaScript or an explicit `webViewDelayTime`.
    static let webViewJSRenderWait: TimeInterval = 1.0

    /// Delay before executing an explicit source `webJs`. Legado dispatches
    /// explicit JavaScript 100 ms after `onPageFinished`; the old local 2-second
    /// floor was not part of the source contract and accumulated at every stage.
    static let webViewExplicitJSWait: TimeInterval = 0.1

    /// Timeout in seconds for a single JS rule engine execution.
    static let jsRuleEngineExecutionTimeout: TimeInterval = 8

    /// Maximum timeout in seconds for chapter package fetch.
    /// Exceeding this throws FetchTimeoutError.chapterTimeout.
    static let chapterFetchTimeoutSeconds: UInt64 = 35

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
