import Foundation
import Network
import os

/// A request on its way: what a caller of `BoundedResponseLoader.dataTask` and
/// `URLSession.legadoDataTask` holds, a URLSession task or a `SingleWriteHTTPExchange`.
protocol SourceRequestTask: AnyObject, Sendable {
    func resume()
    func cancel()
}

extension URLSessionDataTask: SourceRequestTask {}

/// A source's request whose request line, headers and body leave in one write: a cleartext
/// `http` request with a body.
///
/// URLSession writes a request's headers and its body separately. Measured 2026-11-09 against a
/// local server reading as bytes arrived: 302 B and then the 45 B body, for `httpBody`,
/// `uploadTask(with:from:)`, an explicit `Content-Length` and `Connection: close` alike (a body
/// stream goes out chunked, in three writes). On the wire that is two TCP segments.
/// www.oneceng.com (万层中文, YCK1329#158 and 1330#381; Alibaba Cloud, openresty) drops POSTs that
/// arrive that way: on 2026-11-09 the same bytes from a socket were answered in 0.33–0.44 s when
/// written once (2 of 2) and not at all, 20 s each, when the body followed the headers (3 of 3),
/// and its search waited out 60 s over URLSession. Not always: the same search passed over
/// URLSession in the r11, r13 and r14 audits. Legado's OkHttp (5.3.2 in
/// legado-E) writes the request line, the headers and a known-length body into one buffer and
/// flushes it once (`Http1ExchangeCodec.writeRequest`, `KnownLengthSink`, `finishRequest`). The
/// maintainer chose on 2026-11-09 to send these requests as OkHttp does.
///
/// This is the one path for that request shape, chosen before anything is sent: not a retry and
/// not a fallback. Every other request (https, or no body) stays on URLSession, which has no
/// setting that changes how it writes. What URLSession did for these requests is done here the
/// same way, measured against it:
/// - `Accept: */*`, `Accept-Encoding: gzip, deflate`, `Connection: keep-alive`, a form
///   `Content-Type` for the body and CFNetwork's own User-Agent, each when the request names none;
/// - the session's stored cookies when the request carries no `Cookie` of its own (one of its
///   own is sent alone), and every `Set-Cookie` stored back, from redirects too;
/// - gzip, deflate and br bodies decoded;
/// - the request's `timeoutInterval` as the idle timeout, and the caller's byte limit
///   (`BoundedResponseLoader`).
///
/// Redirects follow OkHttp (`RetryAndFollowUpInterceptor.buildRedirectRequest`): 300–303 turn a
/// POST into a GET without its body or `Content-*` headers, 307 and 308 send the body again, a
/// new host loses `Authorization`, at most 20. The first redirect that is not this shape (a GET,
/// or https) goes back to URLSession (`BoundedResponseLoader.dataTask`). A redirect the caller
/// refuses is not sent, and its 3xx response is the answer, as `BoundedResponseLoader`'s is.
///
/// Not as URLSession: each exchange opens a connection of its own and closes it after the
/// response; a system HTTP proxy (manual or PAC) is not used — Network.framework connects to the
/// host itself, inside a VPN's tunnel as any connection is; and no `Accept-Language` is added to
/// a request that names none (URLSession adds the system's; OkHttp adds none, and the requests a
/// source's rules make name one, `LegadoOutgoingHeaders`).
final class SingleWriteHTTPExchange: SourceRequestTask, @unchecked Sendable {
    typealias Completion = @Sendable (Result<(Data, URLResponse), any Error>) -> Void

    /// OkHttp's `MAX_FOLLOW_UPS`.
    static let maximumRedirects = 20

    /// The requests this path carries: `http`, with a body, sent with a method that has one —
    /// unless a `URLProtocol` installed on `session` claims the request, which URLSession would
    /// hand it to instead of the network (the app installs none; test sessions do).
    static func handles(_ request: URLRequest, on session: URLSession) -> Bool {
        guard request.url?.scheme?.lowercased() == "http",
              let body = request.httpBody, !body.isEmpty else { return false }
        let method = (request.httpMethod ?? "GET").uppercased()
        guard method != "GET", method != "HEAD" else { return false }
        let installed = session.configuration.protocolClasses ?? []
        return !installed.contains { type in
            !systemProtocolClasses.contains(ObjectIdentifier(type))
                && (type as? URLProtocol.Type)?.canInit(with: request) == true
        }
    }

    /// The protocol classes every session starts with: the system's own.
    private static let systemProtocolClasses: Set<ObjectIdentifier> = Set(
        [URLSessionConfiguration.default, .ephemeral].flatMap { $0.protocolClasses ?? [] }.map(ObjectIdentifier.init)
    )

    /// `request` exchanged on its own connection, with `session`'s cookies and network settings.
    /// Cancelling the calling task cancels the exchange (`URLError.cancelled`). `savesCookies`
    /// keeps every response's cookies on a session that keeps none (`BoundedResponseLoader`).
    static func load(
        _ request: URLRequest,
        session: URLSession,
        limit: Int,
        redirect: (@Sendable (URL) -> Bool)?,
        transport: String,
        savesCookies: Bool = false
    ) async throws -> (Data, URLResponse) {
        struct Running {
            var exchange: SingleWriteHTTPExchange?
            var cancelled = false
        }
        let running = OSAllocatedUnfairLock(initialState: Running())
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let exchange = SingleWriteHTTPExchange(
                    request: request, session: session, limit: limit, redirect: redirect,
                    transport: transport, savesCookies: savesCookies, redirectsLeft: maximumRedirects,
                    completion: { continuation.resume(with: $0) }
                )
                let starts = running.withLock { state -> Bool in
                    guard !state.cancelled else { return false }
                    state.exchange = exchange
                    return true
                }
                if starts {
                    exchange.resume()
                } else {
                    exchange.cancel()
                }
            }
        } onCancel: {
            let exchange = running.withLock { state -> SingleWriteHTTPExchange? in
                state.cancelled = true
                return state.exchange
            }
            exchange?.cancel()
        }
    }

    /// An exchange, not yet resumed, that calls `completionHandler` once as
    /// `URLSession.dataTask(with:completionHandler:)` would.
    static func dataTask(
        with request: URLRequest,
        session: URLSession,
        limit: Int,
        redirect: (@Sendable (URL) -> Bool)?,
        transport: String,
        savesCookies: Bool = false,
        completionHandler: @escaping @Sendable (Data?, URLResponse?, (any Error)?) -> Void
    ) -> SingleWriteHTTPExchange {
        SingleWriteHTTPExchange(
            request: request, session: session, limit: limit, redirect: redirect,
            transport: transport, savesCookies: savesCookies, redirectsLeft: maximumRedirects,
            completion: { result in
                switch result {
                case .success(let (data, response)): completionHandler(data, response, nil)
                case .failure(let error): completionHandler(nil, nil, error)
                }
            }
        )
    }

    private let request: URLRequest
    private let url: URL
    private let session: URLSession
    private let limit: Int
    private let redirect: (@Sendable (URL) -> Bool)?
    private let transport: String
    private let savesCookies: Bool
    private let redirectsLeft: Int
    private let queue = DispatchQueue(label: "SingleWriteHTTPExchange", qos: .userInitiated)

    // Everything below is touched on `queue` only. While a connection or a handed-off redirect
    // is running, their handlers hold this exchange, as a session holds its running tasks;
    // `finish` lets go.
    private var completion: Completion?
    private var started = false
    private var connection: NWConnection?
    private var idleTimer: (any DispatchSourceTimer)?
    private var handoff: (any SourceRequestTask)?
    private var reader: HTTPResponseReader

    private init(
        request: URLRequest, session: URLSession, limit: Int, redirect: (@Sendable (URL) -> Bool)?,
        transport: String, savesCookies: Bool, redirectsLeft: Int, completion: @escaping Completion
    ) {
        self.request = request
        self.url = request.url ?? URL(fileURLWithPath: "/")
        self.session = session
        self.limit = limit
        self.redirect = redirect
        self.transport = transport
        self.savesCookies = savesCookies
        self.redirectsLeft = redirectsLeft
        self.completion = completion
        self.reader = HTTPResponseReader(limit: limit, bodiless: request.httpMethod?.uppercased() == "HEAD")
    }

    func resume() {
        queue.async { [self] in
            guard !started, completion != nil else { return }
            started = true
            guard let host = url.host(percentEncoded: false), !host.isEmpty,
                  let port = NWEndpoint.Port(rawValue: UInt16(clamping: url.port ?? 80)) else {
                finish(.failure(Self.urlError(.badURL, url: url)))
                return
            }
            let configuration = session.configuration
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            if !(configuration.allowsCellularAccess && request.allowsCellularAccess) {
                parameters.prohibitedInterfaceTypes = [.cellular]
            }
            parameters.prohibitExpensivePaths =
                !(configuration.allowsExpensiveNetworkAccess && request.allowsExpensiveNetworkAccess)
            parameters.prohibitConstrainedPaths =
                !(configuration.allowsConstrainedNetworkAccess && request.allowsConstrainedNetworkAccess)
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
            self.connection = connection
            connection.stateUpdateHandler = { [self] state in connectionChanged(to: state) }
            armIdleTimer()
            connection.start(queue: queue)
        }
    }

    func cancel() {
        queue.async { [self] in
            handoff?.cancel()
            finish(.failure(Self.urlError(.cancelled, url: url)))
        }
    }

    // MARK: Exchange

    private func connectionChanged(to state: NWConnection.State) {
        guard completion != nil else { return }
        switch state {
        case .ready:
            send()
        case .waiting(let error), .failed(let error):
            // URLSession does not wait for connectivity on these sessions; a host that refuses the
            // connection or cannot be resolved is an error at once.
            finish(.failure(Self.urlError(for: error, url: url)))
        default:
            break
        }
    }

    private func send() {
        guard let connection else { return }
        // The whole request in one `send`: the point of this path.
        let bytes = Self.requestBytes(for: request, session: session)
        connection.send(content: bytes, completion: .contentProcessed { [self] error in
            if let error { finish(.failure(Self.urlError(for: error, url: url))) }
        })
        receive()
    }

    private func receive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [self] content, _, isComplete, error in
            guard completion != nil else { return }
            if let content, !content.isEmpty {
                armIdleTimer()
                if handle(reader.consume(content)) { return }
            }
            if isComplete {
                _ = handle(reader.endOfStream())
                return
            }
            if let error {
                finish(.failure(Self.urlError(for: error, url: url)))
                return
            }
            receive()
        }
    }

    /// Whether `step` ended the exchange's reading.
    private func handle(_ step: HTTPResponseReader.Step) -> Bool {
        switch step {
        case .needMore:
            return false
        case .failed(let error):
            finish(.failure(error))
            return true
        case .tooLarge(let bytes):
            finish(.failure(FetchError.responseTooLarge(bytes: bytes, limit: limit)))
            return true
        case .done(let head, let body):
            responseRead(head, body: body)
            return true
        }
    }

    private func responseRead(_ head: HTTPResponseReader.Head, body raw: Data) {
        closeConnection()
        let body: Data
        do {
            body = try Self.decoded(raw, contentEncoding: head.value(for: "Content-Encoding"), limit: limit)
        } catch {
            finish(.failure(error))
            return
        }
        storeCookies(head)
        guard let response = HTTPURLResponse(
            url: url, statusCode: head.status, httpVersion: "HTTP/1.1", headerFields: head.mergedFields
        ) else {
            finish(.failure(Self.urlError(.badServerResponse, url: url)))
            return
        }
        guard let next = Self.redirectRequest(after: response, for: request) else {
            finish(.success((body, response)))
            return
        }
        if let redirect, let target = next.url, !redirect(target) {
            finish(.success((body, response)))
            return
        }
        guard redirectsLeft > 0 else {
            finish(.failure(Self.urlError(.httpTooManyRedirects, url: url)))
            return
        }
        // The next hop logs a body it refuses at the limit itself. The answer it comes back with
        // was led to by this redirect too (`URLResponse.followedRedirects`).
        let hop = response
        let forward: @Sendable (Data?, URLResponse?, (any Error)?) -> Void = { [self] data, response, error in
            queue.async { [self] in
                if let error {
                    finish(.failure(error), logsOversize: false)
                } else if let response {
                    response.prependRedirects([hop])
                    finish(.success((data ?? Data(), response)))
                } else {
                    finish(.failure(Self.urlError(.badServerResponse, url: url)))
                }
            }
        }
        let task: any SourceRequestTask
        if Self.handles(next, on: session) {
            task = SingleWriteHTTPExchange(
                request: next, session: session, limit: limit, redirect: redirect, transport: transport,
                savesCookies: savesCookies, redirectsLeft: redirectsLeft - 1,
                completion: { result in
                    switch result {
                    case .success(let (data, response)): forward(data, response, nil)
                    case .failure(let error): forward(nil, nil, error)
                    }
                }
            )
        } else {
            task = BoundedResponseLoader.dataTask(
                with: next, session: session, limit: limit, redirect: redirect, transport: transport,
                savesCookies: savesCookies, completionHandler: forward
            )
        }
        handoff = task
        task.resume()
    }

    /// As URLSession keeps them on a session that sets cookies, and as `BoundedResponseLoader`
    /// keeps them for an exchange that `savesCookies` on one that does not.
    private func storeCookies(_ head: HTTPResponseReader.Head) {
        let configuration = session.configuration
        guard request.httpShouldHandleCookies, configuration.httpShouldSetCookies || savesCookies,
              let storage = configuration.httpCookieStorage else { return }
        // One header at a time: an `Expires` date has a comma of its own.
        let cookies = head.values(for: "Set-Cookie").flatMap {
            HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": $0], for: url)
        }
        guard !cookies.isEmpty else { return }
        storage.setCookies(cookies, for: url, mainDocumentURL: request.mainDocumentURL ?? url)
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        let timeout = request.timeoutInterval > 0 ? request.timeoutInterval : WebFetcher.sourceRequestTimeout
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [self] in
            finish(.failure(Self.urlError(.timedOut, url: url)))
        }
        idleTimer = timer
        timer.resume()
    }

    private func closeConnection() {
        idleTimer?.cancel()
        idleTimer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
    }

    private func finish(_ result: Result<(Data, URLResponse), any Error>, logsOversize: Bool = true) {
        guard let completion else { return }
        self.completion = nil
        closeConnection()
        handoff = nil
        if logsOversize, case .failure(FetchError.responseTooLarge(let bytes, _)) = result {
            WebFetcher.logOversized(url: url, bytes: bytes, limit: limit, transport: transport)
        }
        completion(result)
    }

    // MARK: Request

    /// The request line, headers and body of `request` as one buffer, with what URLSession adds
    /// to a request that names none of them.
    static func requestBytes(for request: URLRequest, session: URLSession) -> Data {
        let url = request.url ?? URL(fileURLWithPath: "/")
        let configuration = session.configuration
        let body = request.httpBody ?? Data()

        var target = URLComponents(url: url, resolvingAgainstBaseURL: true)?.percentEncodedPath ?? ""
        if target.isEmpty { target = "/" }
        if let query = url.query(percentEncoded: true) { target += "?" + query }

        var host = url.host(percentEncoded: true) ?? ""
        if host.contains(":") { host = "[\(host)]" }
        if let port = url.port, port != 80 { host += ":\(port)" }

        var fields: [(name: String, value: String)] = []
        func has(_ name: String) -> Bool {
            fields.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        let framing: Set<String> = ["host", "content-length", "transfer-encoding"]
        for (name, value) in request.allHTTPHeaderFields ?? [:] where !framing.contains(name.lowercased()) {
            fields.append((name, value))
        }
        for case let (name as String, value as String) in configuration.httpAdditionalHeaders ?? [:]
        where !framing.contains(name.lowercased()) && !has(name) {
            fields.append((name, value))
        }
        if !has("Cookie"), request.httpShouldHandleCookies, configuration.httpShouldSetCookies,
           let cookies = configuration.httpCookieStorage?.cookies(for: url), !cookies.isEmpty,
           let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] {
            fields.append(("Cookie", header))
        }
        if !has("Content-Type"), !body.isEmpty {
            fields.append(("Content-Type", "application/x-www-form-urlencoded"))
        }
        if !has("Accept") { fields.append(("Accept", "*/*")) }
        if !has("Accept-Encoding") { fields.append(("Accept-Encoding", "gzip, deflate")) }
        if !has("User-Agent") { fields.append(("User-Agent", cfNetworkUserAgent)) }
        if !has("Connection") { fields.append(("Connection", "keep-alive")) }
        fields.append(("Content-Length", String(body.count)))

        var head = "\(request.httpMethod ?? "POST") \(target) HTTP/1.1\r\nHost: \(host)\r\n"
        for (name, value) in fields {
            // A value cannot carry a line break onto the wire.
            let clean = value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            head += "\(name): \(clean)\r\n"
        }
        head += "\r\n"
        var bytes = Data(head.utf8)
        bytes.append(body)
        return bytes
    }

    /// What CFNetwork names itself when a request has no User-Agent: the app's executable and
    /// build, then CFNetwork's and Darwin's versions.
    static let cfNetworkUserAgent: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let name = (info["CFBundleExecutable"] as? String) ?? ProcessInfo.processInfo.processName
        let product = (info["CFBundleVersion"] as? String).map { "\(name)/\($0)" } ?? "\(name) (unknown version)"
        let cfNetwork = (Bundle(identifier: "com.apple.CFNetwork")?.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
        var system = utsname()
        uname(&system)
        let darwin = withUnsafeBytes(of: &system.release) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return "\(product) CFNetwork/\(cfNetwork) Darwin/\(darwin)"
    }()

    /// The request OkHttp sends next for `response` (`buildRedirectRequest`), or nil when it is
    /// not a redirect it follows.
    static func redirectRequest(after response: HTTPURLResponse, for request: URLRequest) -> URLRequest? {
        guard [300, 301, 302, 303, 307, 308].contains(response.statusCode),
              let location = response.value(forHTTPHeaderField: "Location"),
              let base = request.url,
              let target = resolve(location, against: base),
              let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        var next = request
        next.url = target
        let method = (request.httpMethod ?? "GET").uppercased()
        if method != "GET", method != "HEAD" {
            let keepsBody = method == "PROPFIND" || response.statusCode == 307 || response.statusCode == 308
            if !keepsBody {
                next.httpMethod = "GET"
                next.httpBody = nil
                for name in ["Transfer-Encoding", "Content-Length", "Content-Type"] {
                    next.setValue(nil, forHTTPHeaderField: name)
                }
            }
        }
        if target.host?.lowercased() != base.host?.lowercased()
            || target.port ?? defaultPort(target) != base.port ?? defaultPort(base)
            || target.scheme?.lowercased() != base.scheme?.lowercased() {
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        return next
    }

    private static func defaultPort(_ url: URL) -> Int {
        url.scheme?.lowercased() == "https" ? 443 : 80
    }

    /// A Location, relative or not. Some servers send one with raw UTF-8 in it.
    private static func resolve(_ location: String, against base: URL) -> URL? {
        if let url = URL(string: location, relativeTo: base) { return url.absoluteURL }
        let allowed = CharacterSet(charactersIn: Unicode.Scalar(0x21)...Unicode.Scalar(0x7E))
        guard let escaped = location.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: escaped, relativeTo: base)?.absoluteURL
    }

    // MARK: Response

    /// `raw` with its content codings undone, as URLSession hands over a body. A coding it does
    /// not know is left as it is, as URLSession leaves one.
    static func decoded(_ raw: Data, contentEncoding: String?, limit: Int) throws -> Data {
        guard let contentEncoding, !raw.isEmpty else { return raw }
        let codings = contentEncoding.lowercased().split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var body = raw
        // Codings are listed in the order they were applied.
        for coding in codings.reversed() {
            do {
                switch coding {
                case "gzip", "x-gzip":
                    body = try GzipDecoder.decompress(body, maximumBytes: limit)
                case "deflate":
                    // HTTP's `deflate` is a zlib stream; some servers send it raw.
                    let bytes = [UInt8](body.prefix(2))
                    let zlib = bytes.count == 2 && bytes[0] & 0x0F == 8 && (Int(bytes[0]) << 8 | Int(bytes[1])) % 31 == 0
                    body = zlib
                        ? try GzipDecoder.decompressZlib(body, maximumBytes: limit)
                        : try GzipDecoder.decompressRawDeflate(body, maximumBytes: limit)
                case "br":
                    body = try GzipDecoder.decompressBrotli(body, maximumBytes: limit)
                default:
                    return body
                }
            } catch GzipDecoderError.tooLarge {
                // Decoding stopped at the limit; the full size is not known.
                throw FetchError.responseTooLarge(bytes: limit < .max ? limit + 1 : limit, limit: limit)
            } catch {
                throw URLError(.cannotDecodeContentData, userInfo: [NSUnderlyingErrorKey: error])
            }
        }
        return body
    }

    static func urlError(_ code: URLError.Code, url: URL, underlying: (any Error)? = nil) -> URLError {
        var info: [String: Any] = [
            NSURLErrorFailingURLErrorKey: url,
            NSURLErrorFailingURLStringErrorKey: url.absoluteString,
        ]
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return URLError(code, userInfo: info)
    }

    /// The URLSession error for what the connection reported.
    static func urlError(for error: NWError, url: URL) -> URLError {
        let code: URLError.Code
        switch error {
        case .dns:
            code = .cannotFindHost
        case .posix(let posix):
            switch posix {
            case .ETIMEDOUT: code = .timedOut
            case .ECONNRESET, .EPIPE, .ENOTCONN, .ECONNABORTED: code = .networkConnectionLost
            case .ENETDOWN, .ENETUNREACH: code = .notConnectedToInternet
            default: code = .cannotConnectToHost
            }
        default:
            code = .cannotConnectToHost
        }
        return urlError(code, url: url, underlying: error)
    }
}

/// An HTTP/1.1 response read off a connection as its bytes arrive: the status line and headers,
/// then a body framed by `Content-Length`, chunked transfer coding, or the end of the stream.
struct HTTPResponseReader {
    struct Head {
        let status: Int
        let fields: [(name: String, value: String)]

        func values(for name: String) -> [String] {
            fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
        }

        func value(for name: String) -> String? {
            let found = values(for: name)
            return found.isEmpty ? nil : found.joined(separator: ", ")
        }

        /// One value per name, repeated headers joined with ", " as `HTTPURLResponse` keeps them.
        var mergedFields: [String: String] {
            var merged: [String: String] = [:]
            var spelling: [String: String] = [:]
            for (name, value) in fields {
                let key = name.lowercased()
                if let first = spelling[key] {
                    merged[first] = (merged[first].map { $0 + ", " } ?? "") + value
                } else {
                    spelling[key] = name
                    merged[name] = value
                }
            }
            return merged
        }
    }

    enum Step {
        case needMore
        case done(Head, Data)
        case tooLarge(bytes: Int)
        case failed(any Error)
    }

    private enum Framing {
        case none
        case length(Int)
        case chunked
        case untilClose
    }

    private let limit: Int
    private let bodiless: Bool
    private var buffer: [UInt8] = []
    private var cursor = 0
    private var head: Head?
    private var framing = Framing.untilClose
    private var body = Data()
    /// Chunked coding: the bytes left in the chunk being read; nil while a size line is due.
    private var chunkLeft: Int?
    private var inTrailers = false

    init(limit: Int, bodiless: Bool) {
        self.limit = limit
        self.bodiless = bodiless
    }

    mutating func consume(_ data: Data) -> Step {
        buffer.append(contentsOf: data)
        let step = advance()
        compact()
        return step
    }

    mutating func endOfStream() -> Step {
        let step = advance()
        guard case .needMore = step else { return step }
        guard let head else {
            return .failed(URLError(buffer.count > cursor ? .badServerResponse : .networkConnectionLost))
        }
        if case .untilClose = framing {
            body.append(contentsOf: buffer[cursor...])
            cursor = buffer.count
            return body.count > limit ? .tooLarge(bytes: body.count) : .done(head, body)
        }
        return .failed(URLError(.networkConnectionLost))
    }

    private mutating func advance() -> Step {
        while head == nil {
            guard let end = headerEnd() else { return .needMore }
            let block = buffer[cursor ..< end.start]
            cursor = end.next
            guard let parsed = Self.parseHead(block) else { return .failed(URLError(.badServerResponse)) }
            // 1xx answers come before the real one (101 switches protocols, which nothing here asks for).
            if (100 ..< 200).contains(parsed.status), parsed.status != 101 { continue }
            head = parsed
            if bodiless || parsed.status == 204 || parsed.status == 304 || (100 ..< 200).contains(parsed.status) {
                framing = .none
            } else if parsed.values(for: "Transfer-Encoding").joined(separator: ",").lowercased().contains("chunked") {
                framing = .chunked
            } else if let length = parsed.value(for: "Content-Length")
                .flatMap({ Int($0.split(separator: ",").first?.trimmingCharacters(in: .whitespaces) ?? "") }) {
                if length > limit { return .tooLarge(bytes: length) }
                framing = .length(length)
            } else {
                framing = .untilClose
            }
        }
        guard let head else { return .needMore }
        switch framing {
        case .none:
            return .done(head, Data())
        case .length(let length):
            guard buffer.count - cursor >= length else { return .needMore }
            body = Data(buffer[cursor ..< cursor + length])
            cursor += length
            return .done(head, body)
        case .untilClose:
            if buffer.count - cursor > limit { return .tooLarge(bytes: buffer.count - cursor) }
            return .needMore
        case .chunked:
            return readChunks(head)
        }
    }

    private mutating func readChunks(_ head: Head) -> Step {
        while true {
            if inTrailers {
                guard let line = nextLine() else { return .needMore }
                if line.isEmpty { return .done(head, body) }
                continue
            }
            if let left = chunkLeft {
                guard buffer.count - cursor >= left + 2 else { return .needMore }
                body.append(contentsOf: buffer[cursor ..< cursor + left])
                cursor += left + 2
                chunkLeft = nil
                if body.count > limit { return .tooLarge(bytes: body.count) }
                continue
            }
            guard let line = nextLine() else { return .needMore }
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                return .failed(URLError(.badServerResponse))
            }
            if size == 0 {
                inTrailers = true
            } else {
                chunkLeft = size
            }
        }
    }

    /// The end of the header block: a blank line, CRLF or a bare LF.
    private func headerEnd() -> (start: Int, next: Int)? {
        var index = cursor
        while index < buffer.count {
            if buffer[index] == 0x0A {
                if index + 1 < buffer.count, buffer[index + 1] == 0x0A { return (index, index + 2) }
                if index + 2 < buffer.count, buffer[index + 1] == 0x0D, buffer[index + 2] == 0x0A {
                    return (index, index + 3)
                }
            }
            index += 1
        }
        return nil
    }

    /// The next line after `cursor`, without its line break; nil until one has arrived.
    private mutating func nextLine() -> String? {
        guard let newline = buffer[cursor...].firstIndex(of: 0x0A) else { return nil }
        var end = newline
        if end > cursor, buffer[end - 1] == 0x0D { end -= 1 }
        let line = String(decoding: buffer[cursor ..< end], as: UTF8.self)
        cursor = newline + 1
        return line
    }

    private mutating func compact() {
        guard cursor > 64 * 1_024, cursor * 2 > buffer.count else { return }
        buffer.removeFirst(cursor)
        cursor = 0
    }

    private static func parseHead(_ block: ArraySlice<UInt8>) -> Head? {
        let text = String(data: Data(block), encoding: .utf8) ?? String(data: Data(block), encoding: .isoLatin1) ?? ""
        var lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : String($0) }
        guard !lines.isEmpty else { return nil }
        let statusLine = lines.removeFirst()
        let parts = statusLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { return nil }
        var fields: [(name: String, value: String)] = []
        for line in lines where !line.isEmpty {
            if line.first == " " || line.first == "\t", let last = fields.popLast() {
                // An obsolete folded line continues the header above it.
                fields.append((last.name, last.value + " " + line.trimmingCharacters(in: .whitespaces)))
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields.append((name, value))
        }
        return Head(status: status, fields: fields)
    }
}
