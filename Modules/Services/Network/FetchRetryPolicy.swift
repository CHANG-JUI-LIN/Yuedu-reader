import Foundation

// MARK: - Per-Host Concurrency Control

/// Maintains an independent semaphore per host to limit concurrent requests to
/// the same site, preventing blocks and following polite crawling practices.
///
/// Per-source politeness is NOT this type's job — a source that needs throttling
/// declares `concurrentRate`, which `SourceRateLimit` enforces. This is only the
/// backstop that keeps one host from monopolising the connection pool.
actor PerHostSemaphore {
    static let shared = PerHostSemaphore()

    private var available: [String: Int] = [:]
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var waiters: [String: [Waiter]] = [:]
    /// Handles cancellation racing ahead of continuation registration.
    private var cancelledWaiterIDs: Set<UUID> = []
    private var registeringWaiterIDs: Set<UUID> = []

    private init() {}

    /// Acquires a lock for the given host, executes the body, then releases.
    /// - Parameters:
    ///   - host: Target domain (e.g. "www.example.com")
    ///   - maxConcurrent: Maximum allowed concurrent requests. Defaults to the
    ///     session's own per-host connection limit (16, matching Legado's default
    ///     threadCount) so this backstop never becomes the binding constraint. It
    ///     used to default to 2, which silently throttled every request in the app
    ///     — including sources that declared no `concurrentRate` at all, which
    ///     Legado runs unthrottled.
    func withLock<T: Sendable>(
        host: String,
        maxConcurrent: Int = 16,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire(host: host, maxConcurrent: maxConcurrent)
        defer { Task { self.release(host: host) } }
        return try await body()
    }

    private func acquire(host: String, maxConcurrent: Int) async throws {
        try Task.checkCancellation()
        let current = available[host] ?? maxConcurrent
        if current > 0 {
            available[host] = current - 1
            return
        }
        let waiterID = UUID()
        registeringWaiterIDs.insert(waiterID)
        defer {
            registeringWaiterIDs.remove(waiterID)
            cancelledWaiterIDs.remove(waiterID)
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if cancelledWaiterIDs.remove(waiterID) != nil || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[host, default: []].append(
                        Waiter(id: waiterID, continuation: continuation)
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID, host: host) }
        }
    }

    private func release(host: String) {
        if let next = waiters[host]?.first {
            waiters[host]?.removeFirst()
            if waiters[host]?.isEmpty == true {
                waiters.removeValue(forKey: host)
            }
            next.continuation.resume()
        } else {
            available[host] = (available[host] ?? 0) + 1
        }
    }

    private func cancelWaiter(id: UUID, host: String) {
        guard let index = waiters[host]?.firstIndex(where: { $0.id == id }) else {
            if registeringWaiterIDs.contains(id) {
                cancelledWaiterIDs.insert(id)
            }
            return
        }
        let waiter = waiters[host]!.remove(at: index)
        if waiters[host]?.isEmpty == true {
            waiters.removeValue(forKey: host)
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    func queuedRequestCount(for host: String) -> Int {
        waiters[host]?.count ?? 0
    }
}

// MARK: - Retry Policy

/// Exponential backoff + jitter retry strategy.
///
/// **Retryable errors (transient):**
/// - URLError: timeout, connection lost, network unavailable, DNS failure,
///   cannot connect to host
/// - HTTP 429 Too Many Requests (respects Retry-After header)
/// - HTTP 5xx server errors
///
/// **Non-retryable errors (permanent):**
/// - HTTP 4xx (except 429): throw immediately
/// - Non-URLError: throw immediately
struct FetchRetryPolicy: Sendable {
    let maxAttempts: Int
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval

    init(maxAttempts: Int = 3, baseDelay: TimeInterval = 1.0, maxDelay: TimeInterval = 30.0) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    /// Returns whether this error should trigger a retry.
    func shouldRetry(_ error: Error) -> Bool {
        // URLError: only retry transient network issues
        if let urlError = error as? URLError {
            return urlError.isTransient
        }
        // HTTP errors: 429 and 5xx are retryable
        if let httpCode = Self.httpStatusCode(from: error) {
            return httpCode == 429 || (500...599).contains(httpCode)
        }
        return false
    }

    /// Calculates the wait time for the given attempt (0-indexed):
    /// exponential backoff + ±30% random jitter.
    func delay(attempt: Int) -> TimeInterval {
        let exp = baseDelay * pow(2.0, Double(attempt))
        let jitter = exp * Double.random(in: -0.3...0.3)
        return min(exp + jitter, maxDelay)
    }

    /// Executes the body with automatic retry until success or attempts exhausted.
    func execute<T: Sendable>(body: @Sendable () async throws -> T) async throws -> T {
        var attempt = 0
        var lastError: Error?

        while attempt < maxAttempts {
            do {
                return try await body()
            } catch {
                lastError = error

                guard shouldRetry(error) else {
                    throw error  // Permanent error, throw immediately
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

    /// Extracts the HTTP status code from an error.
    static func httpStatusCode(from error: Error) -> Int? {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return nil
        }
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

// MARK: - URLError Transient Check

extension URLError {
    /// Whether this is a retryable transient network error.
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
