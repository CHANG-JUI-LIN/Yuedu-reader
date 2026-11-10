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
///
/// A cleartext `http` request with a body does not go to URLSession at all: it is sent in one
/// write by `SingleWriteHTTPExchange`, under the same limit and redirect rule, because URLSession
/// writes its headers and body separately and some servers never answer that.
///
/// `savesCookies` keeps the cookies every response sets — each redirect's included — in the
/// session's cookie store, on a session that keeps none of its own (`WebFetcher`'s): Legado's
/// network interceptor does that for a request of a source with a cookie jar
/// (`CookieManager.saveResponse`, `HttpHelper.kt`), and for no other.
///
/// The redirects it follows stay with the response they led to (`URLResponse.followedRedirects`):
/// okhttp's `Response.priorResponse()` chain, which a source reads.
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
        /// The redirects followed so far, oldest first.
        var redirects: [HTTPURLResponse] = []
    }

    private let limit: Int
    private let redirect: (@Sendable (URL) -> Bool)?
    private let transport: String
    private let savesCookies: Bool
    private let state = OSAllocatedUnfairLock(initialState: State())

    private init(
        limit: Int, redirect: (@Sendable (URL) -> Bool)?, transport: String, savesCookies: Bool,
        completion: Completion?
    ) {
        self.limit = limit
        self.redirect = redirect
        self.transport = transport
        self.savesCookies = savesCookies
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
        transport: String = "http",
        savesCookies: Bool = false
    ) async throws -> (Data, URLResponse) {
        if SingleWriteHTTPExchange.handles(request, on: session) {
            return try await SingleWriteHTTPExchange.load(
                request, session: session, limit: limit, redirect: redirect, transport: transport,
                savesCookies: savesCookies
            )
        }
        let first = SourceTLSFallback.session(session, for: request.url)
        do {
            let loader = BoundedResponseLoader(
                limit: limit, redirect: redirect, transport: transport, savesCookies: savesCookies, completion: nil
            )
            return try await loader.run(request, session: first)
        } catch {
            // A host that refuses TLS 1.2 on a source's capped session (`SourceTLSFallback`).
            guard let twin = SourceTLSFallback.retrySession(after: error, on: first, request: request) else {
                throw error
            }
            let loader = BoundedResponseLoader(
                limit: limit, redirect: redirect, transport: transport, savesCookies: savesCookies, completion: nil
            )
            return try await loader.run(request, session: twin)
        }
    }

    /// A data task, not yet resumed, that reads `request`'s body up to `limit` bytes and calls
    /// `completionHandler` once as `URLSession.dataTask(with:completionHandler:)` would. A body
    /// past the limit comes back as no data and `FetchError.responseTooLarge`.
    ///
    /// When a host refuses TLS 1.2 on a source's capped session, the request is sent once more
    /// over TLS 1.3 (`SourceTLSFallback`) as a task of its own, which cancelling the returned
    /// task does not reach.
    static func dataTask(
        with request: URLRequest,
        session: URLSession,
        limit: Int = WebFetcher.responseByteLimit,
        redirect: (@Sendable (URL) -> Bool)? = nil,
        transport: String,
        savesCookies: Bool = false,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> any SourceRequestTask {
        if SingleWriteHTTPExchange.handles(request, on: session) {
            return SingleWriteHTTPExchange.dataTask(
                with: request, session: session, limit: limit, redirect: redirect,
                transport: transport, savesCookies: savesCookies, completionHandler: completionHandler
            )
        }
        let first = SourceTLSFallback.session(session, for: request.url)
        let task = first.dataTask(with: request)
        let loader = BoundedResponseLoader(
            limit: limit, redirect: redirect, transport: transport, savesCookies: savesCookies,
            completion: { [weak task] result in
                switch result {
                case .success(let (data, response)):
                    completionHandler(data, response, nil)
                case .failure(let error):
                    if let twin = SourceTLSFallback.retrySession(after: error, on: first, request: request) {
                        BoundedResponseLoader.dataTask(
                            with: request, session: twin, limit: limit, redirect: redirect,
                            transport: transport, savesCookies: savesCookies, completionHandler: completionHandler
                        ).resume()
                        return
                    }
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
        // Its headers are in, whether or not its body is read: Legado's interceptor keeps them
        // before anything reads the body.
        keepCookies(of: response, session: session)
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
        // A refused redirect comes back as the answer, through `didReceive response`; one that is
        // followed passes here only.
        if let redirect, request.url.map(redirect) != true {
            completionHandler(nil)
            return
        }
        keepCookies(of: response, session: session)
        state.withLock { $0.redirects.append(response) }
        completionHandler(request)
    }

    /// The cookies `response` sets, kept in `session`'s store when this exchange keeps them
    /// (`savesCookies`). Read with `value(forHTTPHeaderField:)`, which finds an HTTP/2
    /// `set-cookie` as well, and joins several into the one line `HTTPCookie` parses.
    private func keepCookies(of response: URLResponse, session: URLSession) {
        guard savesCookies, let http = response as? HTTPURLResponse, let url = http.url,
              let line = http.value(forHTTPHeaderField: "Set-Cookie"),
              let storage = session.configuration.httpCookieStorage else { return }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": line], for: url)
        guard !cookies.isEmpty else { return }
        storage.setCookies(cookies, for: url, mainDocumentURL: url)
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
            response.prependRedirects(state.redirects)
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

extension URLResponse {
    /// The redirects followed to reach this response, oldest first, each answered with no body:
    /// okhttp's `Response.priorResponse()` chain, newest first there. Set by the transport that
    /// read the response (`BoundedResponseLoader`, `SingleWriteHTTPExchange`); empty for one no
    /// redirect led to, or one a redirect answered because it was refused.
    var followedRedirects: [HTTPURLResponse] {
        (objc_getAssociatedObject(self, FollowedRedirects.associationKey) as? FollowedRedirects)?.responses ?? []
    }

    /// `hops` put before the redirects already recorded: a transport that hands a redirect to the
    /// next hop's transport learns of the rest only from the answer that comes back.
    func prependRedirects(_ hops: [HTTPURLResponse]) {
        guard !hops.isEmpty else { return }
        objc_setAssociatedObject(
            self, FollowedRedirects.associationKey, FollowedRedirects(hops + followedRedirects),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }
}

private final class FollowedRedirects: NSObject {
    let responses: [HTTPURLResponse]
    init(_ responses: [HTTPURLResponse]) { self.responses = responses }

    /// The association needs an address that is stable and unique in the process: this class
    /// object's. Derived on each use, so there is no global mutable key variable.
    static var associationKey: UnsafeRawPointer {
        UnsafeRawPointer(Unmanaged.passUnretained(FollowedRedirects.self as AnyObject).toOpaque())
    }
}
