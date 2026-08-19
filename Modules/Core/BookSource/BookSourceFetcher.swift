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

/// Safely creates a URL: if `URL(string:)` fails due to unencoded characters (e.g. CJK), retries with percent-encoding.
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

    if let url = URL(string: raw) { return validate(url) }
    // Some Legado book sources return chapter URLs with unencoded CJK or special characters
    if let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
       let url = URL(string: encoded) { return validate(url) }
    return nil
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
/// context remains protected by `BookSourceSession.withBridge`, which serializes only
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

    enum FetchTimeoutError: LocalizedError {
        case chapterTimeout

        var errorDescription: String? {
            switch self {
            case .chapterTimeout:
                return "Chapter load timeout"
            }
        }
    }

    init(webFetcher: WebFetcher = WebFetcher.shared) {
        self.webFetcher = webFetcher
    }

    // MARK: - WebView JS Rendering Helpers

    /// Static method, hops to MainActor to execute WKWebView load
    @MainActor
    static func fetchViaWebView(url: URL, headers: [String: String], jsWait: TimeInterval? = nil) async throws -> String
    {
        try await WebViewFetcher.shared.fetchHTML(url: url, headers: headers, timeout: 15, jsWait: jsWait ?? AppConfig.webViewJSRenderWait)
    }

    // MARK: - HTTP Request

    /// `source`: when provided, the request honors the source's `concurrentRate`
    /// declaration (per-source concurrency/frequency budget — anti-ban).
    func fetchHTML(
        url: URL, method: String, body: String?,
        headers: [String: String], baseURL: String,
        bodyCharset: String? = nil,
        allowInteractiveChallengeOn503: Bool = true,
        source: BookSource? = nil
    ) async throws -> String {
        guard let source else {
            return try await webFetcher.fetchHTML(
                url: url,
                method: method,
                body: body,
                headers: headers,
                baseURL: baseURL,
                bodyCharset: bodyCharset,
                allowInteractiveChallengeOn503: allowInteractiveChallengeOn503
            )
        }
        return try await SourceRateLimit.run(source: source) {
            try await webFetcher.fetchHTML(
                url: url,
                method: method,
                body: body,
                headers: headers,
                baseURL: baseURL,
                bodyCharset: bodyCharset,
                allowInteractiveChallengeOn503: allowInteractiveChallengeOn503
            )
        }
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
    private static let bodyLimit = 8 * 1024

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

        var isCapturingNetwork: Bool { lock.withLock { network } }
        var isCapturingParse: Bool { lock.withLock { network && parse } }

        func set(network value: Bool) { lock.withLock { network = value } }
        func set(parse value: Bool) { lock.withLock { parse = value } }
    }

    private static let gate = Gate()

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
            detail: .body(String(htmlBody.prefix(bodyLimit)))
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
