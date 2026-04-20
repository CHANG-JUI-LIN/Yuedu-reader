import Combine
import Foundation

// MARK: - 書源網路請求 + 快取

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

/// 安全建立 URL：若 `URL(string:)` 因未編碼字元（如中文）而失敗，嘗試 percent-encoding 後重試。
/// 同時過濾危險 scheme（file://、javascript: 等）和私有 IP，防止書源 SSRF。
func safeURL(string raw: String) -> URL? {
    func validate(_ url: URL) -> URL? {
        let scheme = url.scheme?.lowercased() ?? ""
        // 僅允許白名單 scheme
        guard AppConfig.allowedURLSchemes.contains(scheme) else {
            AppLogger.security("書源 URL 使用了不允許的 scheme，已阻止", context: ["url": raw, "scheme": scheme])
            return nil
        }
        // 阻止私有/保留 IP（防 SSRF）
        if let host = url.host, isPrivateOrReservedHost(host) {
            AppLogger.security("書源 URL 指向保留 IP 範圍，已阻止", context: ["url": raw, "host": host])
            return nil
        }
        return url
    }

    if let url = URL(string: raw) { return validate(url) }
    // 部分 Legado 書源回傳的章節 URL 含有未編碼中文或特殊字元
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

actor BookSourceFetcher {
    /// 供外部呼叫的 debug 日誌（驗證日誌管道）
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
                return "章節載入超時"
            }
        }
    }

    init(webFetcher: WebFetcher = WebFetcher.shared) {
        self.webFetcher = webFetcher
    }

    // MARK: - WebView JS 渲染輔助方法

    /// 靜態方法，跳到 MainActor 執行 WKWebView 載入
    @MainActor
    static func fetchViaWebView(url: URL, headers: [String: String]) async throws -> String
    {
        try await WebViewFetcher.shared.fetchHTML(url: url, headers: headers, timeout: 15)
    }

    // MARK: - HTTP 請求

    func fetchHTML(
        url: URL, method: String, body: String?,
        headers: [String: String], baseURL: String,
        bodyCharset: String? = nil,
        allowInteractiveChallengeOn503: Bool = true
    ) async throws -> String {
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

// MARK: - 錯誤定義

enum FetchError: LocalizedError {
    case noSearchURL
    case invalidURL(String)
    case httpError(Int)
    case cloudflareChallengeRequired(String)
    case encodingError
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .noSearchURL: return "書源未設置搜索 URL"
        case .invalidURL(let u): return "無效 URL：\(u)"
        case .httpError(let code): return "HTTP 錯誤 \(code)"
        case .cloudflareChallengeRequired(let url): return "需要人機驗證：\(url)"
        case .encodingError: return "頁面編碼無法識別"
        case .emptyContent: return "抓取到空內容"
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

// MARK: - Debugger 供開發時測試書源使用

/// A global debugging environment for BookSourceFetcher to broadcast events
class WebCrawlerDebugger: ObservableObject {
    static let shared = WebCrawlerDebugger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let type: LogType
        let message: String
        let url: String?
        let metadata: [String: Any]?

        enum LogType {
            case info
            case request
            case response
            case parseEvent
            case error
        }
    }

    @Published var logs: [LogEntry] = []
    @Published var isRecording: Bool = false

    private init() {}

    @MainActor
    func clear() {
        logs.removeAll()
    }

    func logRequest(url: String, method: String, headers: [String: String]) {}

    func logResponse(url: String, statusCode: Int, htmlBody: String) {}

    func logParse(rule: String, matchCount: Int, url: String) {}

    func logError(_ error: Error, url: String? = nil) {}
}
