import Foundation
import ReadiumShared

protocol RemoteLibraryTransport: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse)
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse)
}

extension RemoteLibraryTransport {
    /// Keeps injected transports source-compatible. The production transport
    /// overrides this with URLSession's file upload, without buffering the book.
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.httpBody = try Data(contentsOf: fileURL)
        return try await data(for: request)
    }
}

/// One transport per saved connection for feeds, covers, downloads and EPUB ranges.
/// Credentials are challenge-based (Basic or Digest) and never offered outside the
/// configured origin. URLSession's global credential/cookie stores are not used.
final class RemoteLibraryHTTPClient: @unchecked Sendable, RemoteLibraryTransport {
    let baseURL: URL
    let session: URLSession
    var readiumClient: any HTTPClient { self }

    init(baseURL: URL, username: String? = nil, password: String? = nil,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.baseURL = baseURL
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        let delegate = RemoteLibraryAuthenticationDelegate(baseURL: baseURL, username: username, password: password)
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        session.sessionDescription = "remote-library-\(UUID().uuidString)"
    }

    deinit { session.invalidateAndCancel() }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try validateMutationDestination(request)
        let (data, response) = try await session.data(for: sanitized(request))
        guard let response = response as? HTTPURLResponse else { throw OPDSError.noData }
        return (data, response)
    }

    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        try validateMutationDestination(request)
        let (data, response) = try await session.upload(for: sanitized(request), fromFile: fileURL)
        guard let response = response as? HTTPURLResponse else { throw OPDSError.noData }
        return (data, response)
    }

    static func isMutation(_ request: URLRequest?) -> Bool {
        guard let request else { return false }
        return !["GET", "HEAD", "OPTIONS", "PROPFIND"].contains((request.httpMethod ?? "GET").uppercased())
    }

    private func validateMutationDestination(_ request: URLRequest) throws {
        if Self.isMutation(request),
           (!Self.sameOrigin(request.url, baseURL) || request.url?.user != nil || request.url?.password != nil) {
            throw RemoteLibraryWriteError.invalidDestination
        }
    }

    /// Returns an owned temporary file; caller must move or remove it.
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) {
        try validateMutationDestination(request)
        let (temporaryURL, response) = try await session.download(for: sanitized(request))
        guard let response = response as? HTTPURLResponse else {
            try FileManager.default.removeItem(at: temporaryURL)
            throw OPDSError.noData
        }
        do { try Self.validate(response) }
        catch {
            try FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        return (temporaryURL, response)
    }

    static func validate(_ response: HTTPURLResponse) throws {
        if response.statusCode == 401 || response.statusCode == 403 { throw OPDSError.authenticationFailed }
        guard (200...299).contains(response.statusCode) else { throw OPDSError.http(response.statusCode) }
    }

    /// A request may contain public, cross-origin acquisition or cover links.
    /// Keep their requests usable, while removing any caller-provided credentials.
    func sanitized(_ request: URLRequest) -> URLRequest {
        var request = request
        if !Self.sameOrigin(request.url, baseURL) {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            request.setValue(nil, forHTTPHeaderField: "Cookie")
            request.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        }
        return request
    }

    static func sameOrigin(_ lhs: URL?, _ rhs: URL?) -> Bool {
        guard let lhs, let rhs,
              let leftScheme = lhs.scheme?.lowercased(), let rightScheme = rhs.scheme?.lowercased(),
              let leftHost = lhs.host?.lowercased(), let rightHost = rhs.host?.lowercased() else { return false }
        let leftPort = lhs.port ?? (leftScheme == "https" ? 443 : 80)
        let rightPort = rhs.port ?? (rightScheme == "https" ? 443 : 80)
        return leftScheme == rightScheme && leftHost == rightHost && leftPort == rightPort
    }

    /// Do not cache a successful-looking 206 containing a different ZIP slice.
    /// A malformed partial response is a protocol error, not range refusal.
    private static func validContentRange(_ value: String, for request: String) -> Bool {
        guard request.hasPrefix("bytes="), value.lowercased().hasPrefix("bytes ") else { return false }
        let requested = request.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard requested.count == 2, parts.count == 2 else { return false }
        let returned = parts[0].split(separator: "-")
        guard returned.count == 2, let start = UInt64(returned[0]), let end = UInt64(returned[1]),
              let total = UInt64(parts[1]), total > 0, start <= end, end < total else { return false }
        if requested[0].isEmpty {
            guard let suffixLength = UInt64(requested[1]), suffixLength > 0 else { return false }
            return start == total - min(total, suffixLength) && end == total - 1
        }
        guard let requestedStart = UInt64(requested[0]), start == requestedStart else { return false }
        guard !requested[1].isEmpty else { return end == total - 1 }
        guard let requestedEnd = UInt64(requested[1]) else { return false }
        return end == min(requestedEnd, total - 1)
    }

    func stream(request convertible: HTTPRequestConvertible,
                consume: @escaping (Data, Double?) -> HTTPResult<Void>) async -> HTTPResult<HTTPResponse> {
        let request: HTTPRequest
        switch convertible.httpRequest() {
        case .failure(let error): return .failure(error)
        case .success(let value): request = value
        }
        var native = URLRequest(url: request.url.url)
        native.httpMethod = request.method.rawValue
        native.allHTTPHeaderFields = request.headers
        native.timeoutInterval = request.timeoutInterval ?? 60
        do {
            try validateMutationDestination(native)
            switch request.body {
            case .data(let data): native.httpBody = data
            case .file(let url): native.httpBody = try Data(contentsOf: url)
            case nil: break
            }
            let (bytes, rawResponse) = try await session.bytes(for: sanitized(native))
            guard let rawResponse = rawResponse as? HTTPURLResponse,
                  let responseURL = rawResponse.url.flatMap({ HTTPURL(url: $0) }) else {
                bytes.task.cancel()
                return .failure(.malformedResponse(nil))
            }
            let response = HTTPResponse(request: request, url: responseURL,
                                        status: HTTPStatus(rawValue: rawResponse.statusCode),
                                        headers: rawResponse.allHeaderFields.reduce(into: [:]) { result, header in
                                            if let key = header.key as? String { result[key] = String(describing: header.value) }
                                        }, mediaType: rawResponse.mimeType.flatMap { MediaType($0) }, body: nil)
            guard (200...299).contains(rawResponse.statusCode) else {
                bytes.task.cancel()
                return .failure(.errorResponse(response))
            }
            // Range refusal is the sole transport signal allowing the caller's
            // full-file compatibility path. Authentication and parse errors stay errors.
            if request.hasHeader("Range") {
                let mime = rawResponse.mimeType?.lowercased()
                if mime == "text/html" || mime == "application/xhtml+xml" {
                    bytes.task.cancel()
                    return .failure(.other(OPDSError.loginPage))
                }
                if rawResponse.statusCode != 206 {
                    bytes.task.cancel()
                    return .failure(.rangeNotSupported)
                }
                guard let requested = native.value(forHTTPHeaderField: "Range"),
                      let received = rawResponse.value(forHTTPHeaderField: "Content-Range"),
                      Self.validContentRange(received, for: requested) else {
                    bytes.task.cancel()
                    return .failure(.malformedResponse(nil))
                }
            }
            var chunk = Data()
            var received: Int64 = 0
            let expected = rawResponse.expectedContentLength
            for try await byte in bytes {
                chunk.append(byte)
                if chunk.count >= 64 * 1024 {
                    received += Int64(chunk.count)
                    if case .failure(let error) = consume(chunk, expected > 0 ? Double(received) / Double(expected) : nil) {
                        bytes.task.cancel()
                        return .failure(error)
                    }
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            if !chunk.isEmpty, case .failure(let error) = consume(chunk, 1) { return .failure(error) }
            return .success(response)
        } catch {
            return .failure(HTTPError.wrap(error) ?? .other(error))
        }
    }
}

final class RemoteLibraryAuthenticationDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let baseURL: URL
    let username: String?
    let password: String?

    init(baseURL: URL, username: String?, password: String?) {
        self.baseURL = baseURL
        self.username = username
        self.password = password
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        let method = space.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var components = URLComponents()
        components.scheme = space.protocol
        components.host = space.host
        components.port = space.port > 0 ? space.port : nil
        guard RemoteLibraryHTTPClient.sameOrigin(components.url, baseURL),
              RemoteLibraryHTTPClient.sameOrigin(task.currentRequest?.url, baseURL),
              challenge.previousFailureCount == 0,
              let username, !username.isEmpty else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(user: username, password: password ?? "", persistence: .none))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Writes must target the reviewed endpoint exactly. In particular a
        // 301/302 must never turn POST into GET, nor replay a book on another
        // origin. Reject all write redirects; the caller reports the 3xx and
        // can correct the saved server address without retrying a mutation.
        if RemoteLibraryHTTPClient.isMutation(task.originalRequest)
            || RemoteLibraryHTTPClient.isMutation(task.currentRequest) {
            completionHandler(nil)
            return
        }
        var redirected = request
        if !RemoteLibraryHTTPClient.sameOrigin(request.url, baseURL) {
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            redirected.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        }
        completionHandler(redirected)
    }
}
