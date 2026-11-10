import Combine
import Foundation

// MARK: - Book Source Network Requests + Cache

final class RuntimeVariableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String]?

    init(_ initial: [String: String]?) {
        storage = initial
    }

    func get() -> [String: String]? {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func set(_ value: [String: String]?) {
        lock.lock()
        storage = value
        lock.unlock()
    }
}

// #region agent log
func _dbgLog(
    _ msg: @autoclosure () -> String,
    data: @autoclosure () -> [String: Any] = [:],
    hyp: String = "A"
) {
    #if DEBUG
    let m = msg()
    let d = data()
    let prefix = d.isEmpty ? "" : " | \(d)"
    print("[BSF][\(hyp)] \(m)\(prefix)")
    #endif
}
// #endregion

/// Safely creates a request URL, as OkHttp reads it (`AnalyzeUrl.requestURL`).
/// Also filters dangerous schemes (file://, javascript:, etc.) and private IPs to prevent book source SSRF.
func safeURL(string raw: String) -> URL? {
    func validate(_ url: URL) -> URL? {
        let scheme = url.scheme?.lowercased() ?? ""
        // Only allow whitelisted schemes
        guard AppConfig.allowedURLSchemes.contains(scheme) else {
            AppLogger.security("Book source URL uses a disallowed scheme", context: ["url": raw, "scheme": scheme])
            return nil
        }
        // Block private/reserved IPs (SSRF prevention)
        if let host = url.host, isPrivateOrReservedHost(host) {
            AppLogger.security("Book source URL points to reserved IP range", context: ["url": raw, "host": host])
            return nil
        }
        return url
    }

    // Sources hand over URLs half-encoded — a `%XX` keyword beside raw CJK, a chapter path
    // in Chinese — and `requestURL` reads them as OkHttp does. The `.urlQueryAllowed`
    // retry that was here encoded every `%` a second time.
    guard let url = AnalyzeUrl.requestURL(raw) else { return nil }
    return validate(url)
}

/// Returns true if host is a private/reserved IP (IPv4 or IPv6).
/// Handles standard dotted notation, hex, decimal, and abbreviated forms via inet_pton.
private func isPrivateOrReservedHost(_ host: String) -> Bool {
    var addr4 = in_addr()
    if inet_pton(AF_INET, host, &addr4) == 1 {
        return isPrivateIPv4(UInt32(bigEndian: addr4.s_addr))
    }
    var addr6 = in6_addr()
    if inet_pton(AF_INET6, host, &addr6) == 1 {
        return isPrivateIPv6(addr6)
    }
    return false
}

/// Checks if an IPv4 address (in host byte order) falls in a private/reserved range.
private func isPrivateIPv4(_ ip: UInt32) -> Bool {
    if ip & 0xFF000000 == 0x7F000000 { return true } // 127.0.0.0/8 loopback
    if ip & 0xFF000000 == 0x0A000000 { return true } // 10.0.0.0/8
    if ip & 0xFFF00000 == 0xAC100000 { return true } // 172.16.0.0/12
    if ip & 0xFFFF0000 == 0xC0A80000 { return true } // 192.168.0.0/16
    if ip & 0xFFFF0000 == 0xA9FE0000 { return true } // 169.254.0.0/16 link-local
    if ip & 0xFF000000 == 0x00000000 { return true } // 0.0.0.0/8 this network
    if ip & 0xFFC00000 == 0x64400000 { return true } // 100.64.0.0/10 CGNAT
    return false
}

/// Checks if an IPv6 address is loopback, unique local, or link-local.
private func isPrivateIPv6(_ addr: in6_addr) -> Bool {
    let bytes = withUnsafeBytes(of: addr) { Array($0) }
    if bytes == [0,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,1] { return true } // ::1 loopback
    if bytes[0] & 0xFE == 0xFC { return true }                         // fc00::/7 ULA
    if bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80 { return true }    // fe80::/10 link-local
    return false
}

/// Stateless facade over per-source parsing sessions and the shared HTTP client.
///
/// Cross-source work must not be actor-serialized: source validation/search fan-out
/// parses unrelated sources concurrently, matching Legado's worker pool. Mutable JS
/// context stays on each source's `BookSourceSession` host, which serializes only
/// calls belonging to the same source.
final class BookSourceFetcher: @unchecked Sendable {
    /// Debug log for external callers (log pipeline verification)
    static func debugLog(_ msg: String, data: [String: Any] = [:]) {
        _ = msg
        _ = data
    }
    static let shared = BookSourceFetcher()
    nonisolated static let chapterCacheRepository = ChapterCacheRepository()
    let pipeline = BookSourceParsingPipeline()
    let webFetcher: WebFetcher

    init(webFetcher: WebFetcher = WebFetcher.shared) {
        self.webFetcher = webFetcher
    }

    // MARK: - WebView JS Rendering Helpers

    /// Static method, hops to MainActor to execute WKWebView load
    @MainActor
    static func fetchViaWebView(url: URL, headers: [String: String], jsWait: TimeInterval? = nil) async throws -> String
    {
        // Legado's `BackstageWebView` gives a page 60 s, as the runtime path's
        // `LegadoHeadlessWebView.load` does.
        try await WebViewFetcher.shared.fetchHTML(
            url: url, headers: headers, timeout: WebFetcher.sourceRequestTimeout,
            jsWait: jsWait ?? AppConfig.webViewJSRenderWait
        )
    }

    // MARK: - HTTP Request

    /// `source`: when provided, the request honors the source's `concurrentRate`
    /// declaration (per-source concurrency/frequency budget — anti-ban).
    /// `charset`: the request's `charset` URL option, for the body and the response alike
    /// (`WebFetcher.fetchHTML`).
    func fetchHTML(
        url: URL, method: String, body: String?,
        headers: [String: String], baseURL: String,
        charset: String? = nil,
        source: BookSource? = nil
    ) async throws -> String {
        guard let source else {
            return try await webFetcher.fetchHTML(
                url: url,
                method: method,
                body: body,
                headers: headers,
                baseURL: baseURL,
                charset: charset
            )
        }
        return try await SourceRateLimit.run(source: source) {
            try await webFetcher.fetchHTML(
                url: url,
                method: method,
                body: body,
                headers: headers,
                baseURL: baseURL,
                charset: charset,
                client: .okHttp,
                cookieJar: source.enabledCookieJar
            )
        }
    }

    /// The first request of a stage — search, 詳情, 目錄's first page, 正文's first page.
    ///
    /// Legado (the original, Legado-E and MD3 alike) runs the source's `loginCheckJs` on that
    /// response whatever its status, and the stage goes on with whatever the script hands
    /// back. That is where sources notice their login wall or a Cloudflare page and call
    /// `java.startBrowserAwait`; with the status thrown away first, a 403 never reached the
    /// script. Next pages are not checked, as in Legado.
    ///
    /// The response then goes to the stage's rules whatever its status, with or without a
    /// check: Legado's `AnalyzeUrl.getStrResponseAwait` hands every stage the body of a 404 as
    /// of a 200 (`newCallResponse` returns the last response, `WebBook` reads no status;
    /// legado-E, MD3 and upstream agree). 番茄短剧 (YCK 1330) answers its detail URL with a
    /// 404 its `init` script never reads — it calls the API with the URL's `series_id` — so a
    /// thrown status failed a book Legado opens. A page whose rules read nothing reports its
    /// stage empty, as in Legado; the status is logged (`WebFetcher.fetchDecodedPage`), and a
    /// search that finds nothing keeps it as its failure (`searchOutcome`).
    func fetchStageHTML(
        url: URL, method: String, body: String?,
        headers: [String: String], baseURL: String,
        charset: String? = nil,
        source: BookSource
    ) async throws -> String {
        try await fetchStagePage(
            url: url, method: method, body: body, headers: headers,
            baseURL: baseURL, charset: charset, source: source
        ).html
    }

    /// `fetchStageHTML` with the URL the page came from, after redirects (or the one the
    /// login check's replacement response names).
    ///
    /// - Parameter ruleURL: the rule URL the stage rendered, before it was made absolute — the
    ///   check reads it as `java.ruleUrl`, as Legado's AnalyzeUrl has it. Nil is `url`: a
    ///   detail, TOC or content URL is the book's or chapter's own, already absolute.
    func fetchStagePage(
        url: URL, method: String, body: String?,
        headers: [String: String], baseURL: String,
        charset: String? = nil,
        ruleURL: String? = nil,
        source: BookSource
    ) async throws -> (html: String, finalURL: String, statusCode: Int) {
        guard source.hasLoginCheckJs else {
            let page = try await SourceRateLimit.run(source: source) {
                try await webFetcher.fetchDecodedPage(
                    url: url, method: method, body: body, headers: headers,
                    baseURL: baseURL, charset: charset, throwsOnErrorStatus: false, client: .okHttp,
                    cookieJar: source.enabledCookieJar
                )
            }
            // The source's API failure as of this answer, as every runtime response records
            // it (`ModernParserBridge.finishFetch`): a stage page that answered 429 or 403 was
            // nowhere a failure surface or the 書源檢查 audit could read (领域书库's 正文,
            // YCK1330 #462, 11-08).
            SourceAPIErrorLog.shared.record(
                sourceUrl: source.bookSourceUrl, requestUrl: url.absoluteString,
                statusCode: page.statusCode, body: page.html
            )
            return (page.html, AnalyzeUrl.legadoURLString(final: page.finalURL, requested: url), page.statusCode)
        }
        let page = try await SourceRateLimit.run(source: source) {
            try await webFetcher.fetchPage(
                url: url,
                method: method,
                body: body,
                headers: headers,
                baseURL: baseURL,
                bodyCharset: charset,
                client: .okHttp,
                cookieJar: source.enabledCookieJar
            )
        }
        let result = LegadoHTTPResult.make(
            request: page.request, data: page.data, response: page.response, declaredCharset: charset
        )
        // `fetchPage` records the request, not the response (`fetchDecodedPage` does, on the
        // path above): what the server sent, before `loginCheckJs` can replace it.
        WebCrawlerDebugger.logResponse(url: url.absoluteString, statusCode: result.statusCode, htmlBody: result.body)
        let checked = await pipeline.applyLoginCheck(
            to: result, request: page.request, headers: headers,
            ruleUrl: ruleURL ?? url.absoluteString, charset: charset, source: source
        )
        if !(200...299).contains(checked.code) {
            AppLogger.network("page answered an error status after its login check; its body goes to the rules", context: [
                "source": source.bookSourceName,
                "url": String(url.absoluteString.prefix(120)),
                "statusCode": checked.code,
            ])
        }
        // The answer the rules read, as above.
        SourceAPIErrorLog.shared.record(
            sourceUrl: source.bookSourceUrl, requestUrl: url.absoluteString,
            statusCode: checked.code, body: checked.body
        )
        return (checked.body, checked.url, checked.code)
    }

}

// MARK: - Error Definitions

enum FetchError: LocalizedError {
    case noSearchURL
    case invalidURL(String)
    case httpError(Int)
    case cloudflareChallengeRequired(String)
    case encodingError
    case emptyContent
    case sourceAPIError(String)
    case volumeSeparator(String)
    /// A response body past `WebFetcher.responseByteLimit`: `bytes` is what had arrived (or what
    /// the response declared) when reading stopped.
    case responseTooLarge(bytes: Int, limit: Int)

    var errorDescription: String? {
        switch self {
        case .noSearchURL: return "Book source has no search URL configured"
        case .invalidURL(let u): return "Invalid URL: \(u)"
        case .httpError(let code): return "HTTP error \(code)"
        case .cloudflareChallengeRequired(let url): return "CAPTCHA required: \(url)"
        case .encodingError: return "Page encoding not recognized"
        case .emptyContent: return "Fetched empty content"
        case .sourceAPIError(let message): return "Source API error: \(message)"
        case .volumeSeparator(let title): return "Volume separator has no chapter content: \(title)"
        case .responseTooLarge(let bytes, let limit):
            return "Page too large: \(bytes / 1024) KB (limit \(limit / 1024) KB)"
        }
    }
}

struct CachedChapterMetadata: Codable {
    let sourceURL: String?
    let tocTitle: String?
    let extractedTitle: String?
    let contentChecksum: String
    let savedAt: Date
    let state: ChapterPackageState?
    let failureReason: String?
}

// MARK: - Debugger for testing book sources during development

/// Captures the HTTP exchanges (and optionally the rule matches) behind one book
/// source, for 書源除錯大師.
///
/// **Off by default and cheap when off.** The capture points sit on the request path
/// of every source fetch and on every rule evaluation — `logParse` fires once per
/// matched rule, which during an aggregate search is tens of thousands of calls. The
/// gate below is therefore read *before* anything is allocated: the static entry
/// points take one uncontended lock and return. They previously took a
/// `Task { @MainActor in … }` at each call site, which allocated a task per request
/// and per rule match to reach four empty method bodies.
///
/// Published state is `@MainActor`; the gate is not. That split is the point — a
/// background parse thread must never touch `@Published`.
@MainActor
final class WebCrawlerDebugger: ObservableObject {

    static let shared = WebCrawlerDebugger()

    /// Entries kept. Bounded because a single aggregate search can produce thousands,
    /// and the interesting ones are always the most recent.
    private static let entryLimit = 500
    /// Response bodies are truncated to this before being held. A chapter body can be
    /// megabytes; the head is what identifies a wrong response.
    nonisolated static let defaultBodyLimit = 8 * 1024

    struct LogEntry: Identifiable, Sendable {
        let id = UUID()
        let timestamp = Date()
        let type: LogType
        let message: String
        let url: String?
        let detail: Detail?

        enum LogType: String, Sendable, CaseIterable {
            case info
            case request
            case response
            case parseEvent
            case error
        }

        /// Typed rather than `[String: Any]`, which was neither `Sendable` nor
        /// renderable without casting at the view.
        enum Detail: Sendable {
            case headers([String: String])
            case body(String)
            case text(String)
        }
    }

    @Published private(set) var logs: [LogEntry] = []

    @Published var isRecording: Bool = false {
        didSet { Self.gate.set(network: isRecording) }
    }

    /// Rule matches are a second, far noisier stream — a single search emits orders
    /// of magnitude more of them than network exchanges, so leaving them on would
    /// evict every request from the buffer. Per-rule debugging has its own screen
    /// (`BookSourceRuleDebugView`); this is here for the cases where you need to see
    /// a match against the exact response that produced it.
    @Published var includesParseEvents: Bool = false {
        didSet { Self.gate.set(parse: includesParseEvents) }
    }

    /// Bytes of each response body kept. A source audit that replays its rules against the
    /// response offline needs the whole page, which can hold its results past the first 8 KB.
    var bodyLimit: Int {
        get { Self.gate.bodyLimit }
        set { Self.gate.set(bodyLimit: max(0, newValue)) }
    }

    private init() {}

    func clear() {
        logs.removeAll()
    }

    // MARK: - Gate

    /// The thread-safe half. Two bools, read from every network and parse call.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var network = false
        private var parse = false
        private var limit = WebCrawlerDebugger.defaultBodyLimit

        var isCapturingNetwork: Bool { lock.withLock { network } }
        var isCapturingParse: Bool { lock.withLock { network && parse } }
        var bodyLimit: Int { lock.withLock { limit } }

        func set(network value: Bool) { lock.withLock { network = value } }
        func set(parse value: Bool) { lock.withLock { parse = value } }
        func set(bodyLimit value: Int) { lock.withLock { limit = value } }
    }

    private nonisolated static let gate = Gate()

    // MARK: - Capture points
    //
    // `nonisolated static` so the network and parse layers can call them directly.
    // Each returns before allocating anything when capture is off.

    nonisolated static func logRequest(url: String, method: String, headers: [String: String]) {
        guard gate.isCapturingNetwork else { return }
        append(.init(type: .request, message: method, url: url, detail: .headers(headers)))
    }

    nonisolated static func logResponse(url: String, statusCode: Int, htmlBody: String) {
        guard gate.isCapturingNetwork else { return }
        append(.init(
            type: .response,
            message: "HTTP \(statusCode) · \(htmlBody.utf8.count) B",
            url: url,
            detail: .body(String(htmlBody.prefix(gate.bodyLimit)))
        ))
    }

    /// What a headless WebView answered (`LegadoHeadlessWebView.load`): the rendered page or its
    /// script's result, kept as an HTTP body is, or why it answered nothing. A WebView's page
    /// is not the HTTP response a plain GET of the URL returns: its scripts have run.
    nonisolated static func logWebViewResponse(url: String, body: String, failure: String?) {
        guard gate.isCapturingNetwork else { return }
        if let failure {
            append(.init(type: .error, message: failure, url: url, detail: .text("WebView: \(failure)")))
            return
        }
        append(.init(
            type: .response,
            message: "WebView · \(body.utf8.count) B",
            url: url,
            detail: .body(String(body.prefix(gate.bodyLimit)))
        ))
    }

    nonisolated static func logParse(rule: String, matchCount: Int, url: String) {
        guard gate.isCapturingParse else { return }
        append(.init(
            type: .parseEvent,
            message: "\(matchCount) match(es) · \(rule)",
            url: url.isEmpty ? nil : url,
            detail: nil
        ))
    }

    nonisolated static func logError(_ error: Error, url: String? = nil) {
        guard gate.isCapturingNetwork else { return }
        append(.init(
            type: .error,
            message: error.localizedDescription,
            url: url,
            detail: .text(String(describing: error))
        ))
    }

    nonisolated static func logInfo(_ message: String, url: String? = nil) {
        guard gate.isCapturingNetwork else { return }
        append(.init(type: .info, message: message, url: url, detail: nil))
    }

    private nonisolated static func append(_ entry: LogEntry) {
        Task { @MainActor in
            shared.logs.append(entry)
            if shared.logs.count > entryLimit {
                shared.logs.removeFirst(shared.logs.count - entryLimit)
            }
        }
    }
}
