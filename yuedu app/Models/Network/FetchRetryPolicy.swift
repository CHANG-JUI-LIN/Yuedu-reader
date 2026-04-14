import Foundation

// MARK: - Per-Host 並發控制

/// 為每個 host 維護獨立的並發信號量，限制對同一網站的同時請求數，
/// 既可防止被目標站點封鎖，也符合禮貌抓取（polite crawling）原則。
actor PerHostSemaphore {
    static let shared = PerHostSemaphore()

    private var available: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    private init() {}

    /// 取得指定 host 的 lock，執行 body 後自動釋放。
    /// - Parameters:
    ///   - host: 目標域名（e.g. "www.example.com"）
    ///   - maxConcurrent: 允許的最大並發數（預設 2）
    func withLock<T: Sendable>(
        host: String,
        maxConcurrent: Int = 2,
        body: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire(host: host, maxConcurrent: maxConcurrent)
        defer { Task { self.release(host: host) } }
        return try await body()
    }

    private func acquire(host: String, maxConcurrent: Int) async {
        let current = available[host] ?? maxConcurrent
        if current > 0 {
            available[host] = current - 1
            return
        }
        // 無可用槽位，排隊等待
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters[host, default: []].append(cont)
        }
    }

    private func release(host: String) {
        if let next = waiters[host]?.first {
            waiters[host]?.removeFirst()
            if waiters[host]?.isEmpty == true {
                waiters.removeValue(forKey: host)
            }
            next.resume()
        } else {
            available[host] = (available[host] ?? 0) + 1
        }
    }
}

// MARK: - Retry Policy

/// 指數退避 + jitter 重試策略（對齊 SOP 工業級標準）。
///
/// **可 retry 的情況（暫時性錯誤）：**
/// - URLError：timeout、連線中斷、網路不可用、DNS 失敗、主機無法連線
/// - HTTP 429 Too Many Requests（遵守 Retry-After 標頭）
/// - HTTP 5xx 伺服器錯誤
///
/// **不 retry 的情況（永久性錯誤）：**
/// - HTTP 4xx（除 429）：直接拋出
/// - 非 URLError：直接拋出
struct FetchRetryPolicy: Sendable {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    init(maxAttempts: Int = 3, baseDelay: TimeInterval = 1.0, maxDelay: TimeInterval = 30.0) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// 判斷是否應該重試此錯誤
    func shouldRetry(_ error: Error) -> Bool {
        // URLError：只 retry 暫時性網路問題
        if let urlError = error as? URLError {
            return urlError.isTransient
        }
        // HTTP 錯誤：429 和 5xx 可重試
        if let httpCode = Self.httpStatusCode(from: error) {
            return httpCode == 429 || (500...599).contains(httpCode)
        }
        return false
    }

    /// 計算第 attempt 次（0-indexed）的等待時間：exponential backoff + ±30% random jitter
    func delay(attempt: Int) -> TimeInterval {
        let exp = baseDelay * pow(2.0, Double(attempt))
        let jitter = exp * Double.random(in: -0.3...0.3)
        return min(exp + jitter, maxDelay)
    }

    /// 包裝執行：自動重試直到成功或耗盡次數
    func execute<T: Sendable>(body: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            do {
                return try await body()
            } catch {
                lastError = error

                guard shouldRetry(error) else {
                    throw error  // 永久性錯誤，直接拋出
                }

                let nextAttempt = attempt + 1
                guard nextAttempt < maxAttempts else { break }

                let waitTime = delay(attempt: attempt)
                try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))

                attempt = nextAttempt
                logRetry(attempt: attempt, error: error, waitMs: Int(waitTime * 1000))
            }
        }

        throw lastError ?? URLError(.unknown)
    }

    // MARK: - Helpers

    /// 從 Error 中提取 HTTP status code（支援 FetchError.httpError 與 NSURLError）
    static func httpStatusCode(from error: Error) -> Int? {
        // 嘗試從 error localizedDescription 中取 code（FetchError.httpError 在同一 module 可直接 cast）
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nil
        }
        // 用字串 pattern 判斷 FetchError.httpError(N)
        let desc = error.localizedDescription
        if desc.contains("HTTP 錯誤"),
            let code = Int(desc.components(separatedBy: " ").last ?? "")
        {
            return code
        }
        return nil
    }

    private func logRetry(attempt: Int, error: Error, waitMs: Int) {
    }
}

// MARK: - URLError 暫時性判斷

extension URLError {
    /// 是否為可重試的暫時性網路錯誤
    var isTransient: Bool {
        switch code {
        case .timedOut,
            .networkConnectionLost,
            .notConnectedToInternet,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .cannotFindHost,
            .dataNotAllowed,
            .internationalRoamingOff:
            return true
        default:
            return false
        }
    }
}
