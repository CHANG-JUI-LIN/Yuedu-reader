import Foundation
import os

/// One HTTP exchange whose body is read only up to `limit` bytes.
///
/// `URLSession.data(for:)` reads a body whole before anything can look at it, so a page of tens
/// of megabytes — or a binary file a source mislabels as its chapter — came into memory and went
/// on to SwiftSoup and `ChapterContentCleaner`, which then needed several times that in one
/// allocation (3.0.0 (143): 51, 68 and 145 MB failed, Crashlytics a8e12705, 038cde45, dd961765).
/// Here a body is collected chunk by chunk through the task's own delegate: a declared
/// `Content-Length` past the limit is refused before the body is read, and a body that grows past
/// it (chunked or compressed responses declare no usable length) is cancelled at the chunk that
/// crosses it. Either way the exchange ends in `FetchError.responseTooLarge`.
///
/// Every transport that reads a page for a source goes through here: `WebFetcher.fetchPage`
/// (`load`) and the JS bridge's `java.*` requests and rule-URL fetches (`dataTask`, `load`).
///
/// It also answers redirects: a refused redirect is not sent, and its 3xx response comes back
/// as the answer.
final class BoundedResponseLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Completion = @Sendable (Result<(Data, URLResponse), any Error>) -> Void

    private struct State {
        var data = Data()
        var response: URLResponse?
        /// Bytes that had arrived (or were declared) when reading stopped at the limit.
        var overLimitBytes: Int?
        var completion: Completion?
        var task: URLSessionDataTask?
        var cancelled = false
    }

    private let limit: Int
    private let redirect: (@Sendable (URL) -> Bool)?
    private let transport: String
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init(limit: Int, redirect: (@Sendable (URL) -> Bool)?, transport: String, completion: Completion?) {
        self.limit = limit
        self.redirect = redirect
        self.transport = transport
        super.init()
        state.withLock { $0.completion = completion }
    }

    /// `request` sent on `session`; its body, at most `limit` bytes, and its response. Cancelling
    /// the calling task cancels the exchange (`URLError.cancelled`, as `data(for:)` throws).
    /// `transport` names the caller in the size-limit log line.
    static func load(
        _ request: URLRequest,
        session: URLSession,
        limit: Int = WebFetcher.responseByteLimit,
        redirect: (@Sendable (URL) -> Bool)? = nil,
        transport: String = "http"
    ) async throws -> (Data, URLResponse) {
        let loader = BoundedResponseLoader(limit: limit, redirect: redirect, transport: transport, completion: nil)
        return try await loader.run(request, session: session)
    }

    /// A data task, not yet resumed, that reads `request`'s body up to `limit` bytes and calls
    /// `completionHandler` once as `URLSession.dataTask(with:completionHandler:)` would. A body
    /// past the limit comes back as no data and `FetchError.responseTooLarge`.
    static func dataTask(
        with request: URLRequest,
        session: URLSession,
        limit: Int = WebFetcher.responseByteLimit,
        redirect: (@Sendable (URL) -> Bool)? = nil,
        transport: String,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> URLSessionDataTask {
        let task = session.dataTask(with: request)
        let loader = BoundedResponseLoader(
            limit: limit, redirect: redirect, transport: transport,
            completion: { [weak task] result in
                switch result {
                case .success(let (data, response)):
                    completionHandler(data, response, nil)
                case .failure(let error):
                    completionHandler(nil, task?.response, error)
                }
            }
        )
        loader.state.withLock { $0.task = task }
        task.delegate = loader
        return task
    }

    private func run(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                task.delegate = self
                let starts = state.withLock { state -> Bool in
                    guard !state.cancelled else { return false }
                    state.completion = { continuation.resume(with: $0) }
                    state.task = task
                    return true
                }
                if starts {
                    task.resume()
                } else {
                    continuation.resume(throwing: URLError(.cancelled))
                }
            }
        } onCancel: {
            let task = state.withLock { state -> URLSessionDataTask? in
                state.cancelled = true
                return state.task
            }
            task?.cancel()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        // A compressed body declares its compressed size, which the decoded body can only exceed.
        let declared = response.expectedContentLength
        let refused = state.withLock { state -> Bool in
            if declared > Int64(limit) {
                state.overLimitBytes = Int(declared)
                return true
            }
            state.response = response
            if declared > 0 { state.data.reserveCapacity(Int(declared)) }
            return false
        }
        completionHandler(refused ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let crossed = state.withLock { state -> Bool in
            guard state.overLimitBytes == nil else { return false }
            let total = state.data.count + data.count
            guard total <= limit else {
                state.overLimitBytes = total
                state.data = Data()
                return true
            }
            state.data.append(data)
            return false
        }
        if crossed { dataTask.cancel() }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let redirect else {
            completionHandler(request)
            return
        }
        guard let url = request.url, redirect(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let limit = self.limit
        let (completion, result, oversized) = state.withLock {
            state -> (Completion?, Result<(Data, URLResponse), any Error>, Int?) in
            let completion = state.completion
            state.completion = nil
            // The task holds this delegate until it completes; drop the way back to it.
            state.task = nil
            if let bytes = state.overLimitBytes {
                return (completion, .failure(FetchError.responseTooLarge(bytes: bytes, limit: limit)), bytes)
            }
            if let error {
                return (completion, .failure(error), nil)
            }
            guard let response = state.response ?? task.response else {
                return (completion, .failure(URLError(.badServerResponse)), nil)
            }
            let data = state.data
            state.data = Data()
            return (completion, .success((data, response)), nil)
        }
        if let oversized, let url = task.originalRequest?.url {
            WebFetcher.logOversized(url: url, bytes: oversized, limit: limit, transport: transport)
        }
        completion?(result)
    }
}
