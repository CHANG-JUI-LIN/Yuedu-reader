import Foundation
import Network
import os
import Testing
@testable import yuedu_app

/// A cleartext request with a body leaves in one write (`SingleWriteHTTPExchange`).
///
/// The premise was measured outside these tests (2026-11-09): URLSession wrote such a request
/// as 302 B of headers and then its 45 B body, and www.oneceng.com left 3 of 3 POSTs that
/// arrived that way unanswered. Here a local server records what its first read of each
/// connection held.
@Suite("Single-write HTTP", .serialized)
struct SingleWriteHTTPTests {
    private static let form = Data("searchkey=%E6%96%97%E7%BD%97&searchtype=all".utf8)

    private func post(_ url: URL, body: Data = form) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    @Test("a cleartext POST reaches the server in one read, framed as URLSession frames it")
    func postArrivesInOneRead() async throws {
        let server = try ScriptedHTTPServer { _ in .send(.http("200 OK", body: Data("ok".utf8))) }
        let base = try await server.start()
        defer { server.stop() }

        let (data, response) = try await BoundedResponseLoader.load(
            post(base.appending(path: "modules/article/search.php")), session: URLSession.sourceSites(.ephemeral)
        )
        #expect(String(decoding: data, as: UTF8.self) == "ok")
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let request = try #require(server.requests.first)
        #expect(request.firstRead == request.raw)
        #expect(request.line == "POST /modules/article/search.php HTTP/1.1")
        #expect(request.headers["host"] == "127.0.0.1:\(base.port ?? 0)")
        #expect(request.headers["content-length"] == String(Self.form.count))
        #expect(request.headers["content-type"] == "application/x-www-form-urlencoded")
        #expect(request.headers["accept"] == "*/*")
        #expect(request.headers["accept-encoding"] == "gzip, deflate")
        #expect(request.headers["connection"] == "keep-alive")
        #expect(request.headers["user-agent"]?.contains(" CFNetwork/") == true)
        #expect(request.body == Self.form)
    }

    @Test("a chunked, gzipped answer is handed over decoded")
    func chunkedGzipIsDecoded() async throws {
        let page = Data(String(repeating: "<li><a href=\"/book/1\">斗罗大陆</a></li>", count: 200).utf8)
        let gzipped = try Self.gzip(page)
        let split = gzipped.count / 3
        var chunked = Data()
        for part in [gzipped.prefix(split), gzipped.dropFirst(split)] {
            chunked.append(Data("\(String(part.count, radix: 16));ext=1\r\n".utf8))
            chunked.append(part)
            chunked.append(Data("\r\n".utf8))
        }
        chunked.append(Data("0\r\nX-Trailer: 1\r\n\r\n".utf8))
        let reply = Data.http(
            "200 OK", headers: [("Transfer-Encoding", "chunked"), ("Content-Encoding", "gzip")], rawBody: chunked
        )
        let server = try ScriptedHTTPServer { _ in .send(reply) }
        let base = try await server.start()
        defer { server.stop() }

        let (data, _) = try await BoundedResponseLoader.load(post(base), session: URLSession.sourceSites(.ephemeral))
        #expect(data == page)
    }

    @Test("a 302 is followed as a GET without the body, carrying the cookie it set")
    func foundBecomesGetWithCookie() async throws {
        let server = try ScriptedHTTPServer { request in
            if request.method == "POST" {
                return .send(.http("302 Found", headers: [
                    ("Location", "/result?id=7"), ("Set-Cookie", "PHPSESSID=abc; path=/"),
                ]))
            }
            return .send(.http("200 OK", body: Data("result".utf8)))
        }
        let base = try await server.start()
        defer { server.stop() }

        let (data, response) = try await BoundedResponseLoader.load(post(base), session: URLSession.sourceSites(.ephemeral))
        #expect(String(decoding: data, as: UTF8.self) == "result")
        #expect(response.url?.path() == "/result")

        let followed = try #require(server.requests.last)
        #expect(server.requests.count == 2)
        #expect(followed.line == "GET /result?id=7 HTTP/1.1")
        #expect(followed.body.isEmpty)
        #expect(followed.headers["content-type"] == nil)
        #expect(followed.headers["cookie"] == "PHPSESSID=abc")
    }

    @Test("a 307 sends the POST and its body again, in one write")
    func temporaryRedirectKeepsBody() async throws {
        let server = try ScriptedHTTPServer { request in
            request.line.hasPrefix("POST /first")
                ? .send(.http("307 Temporary Redirect", headers: [("Location", "/second")]))
                : .send(.http("200 OK", body: Data("second".utf8)))
        }
        let base = try await server.start()
        defer { server.stop() }

        let (data, _) = try await BoundedResponseLoader.load(
            post(base.appending(path: "first")), session: URLSession.sourceSites(.ephemeral)
        )
        #expect(String(decoding: data, as: UTF8.self) == "second")
        let again = try #require(server.requests.last)
        #expect(again.line == "POST /second HTTP/1.1")
        #expect(again.body == Self.form)
        #expect(again.firstRead == again.raw)
    }

    @Test("a refused redirect is not sent; its 3xx is the answer")
    func refusedRedirectReturnsResponse() async throws {
        let server = try ScriptedHTTPServer { _ in
            .send(.http("302 Found", headers: [("Location", "/elsewhere")], body: Data("moved".utf8)))
        }
        let base = try await server.start()
        defer { server.stop() }

        let (data, response) = try await BoundedResponseLoader.load(
            post(base), session: URLSession.sourceSites(.ephemeral), redirect: { _ in false }
        )
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 302)
        #expect(http.value(forHTTPHeaderField: "Location") == "/elsewhere")
        #expect(String(decoding: data, as: UTF8.self) == "moved")
        #expect(server.requests.count == 1)
    }

    @Test("a request's own Cookie is sent alone; without one the stored cookies go")
    func explicitCookieWins() async throws {
        let server = try ScriptedHTTPServer { _ in .send(.http("200 OK")) }
        let base = try await server.start()
        defer { server.stop() }
        let session = URLSession.sourceSites(.ephemeral)
        let storage = try #require(session.configuration.httpCookieStorage)
        let stored = try #require(HTTPCookie(properties: [
            .domain: "127.0.0.1", .path: "/", .name: "stored", .value: "1",
        ]))
        storage.setCookie(stored)

        var own = post(base)
        own.setValue("mine=2", forHTTPHeaderField: "Cookie")
        _ = try await BoundedResponseLoader.load(own, session: session)
        _ = try await BoundedResponseLoader.load(post(base), session: session)

        #expect(server.requests.map { $0.headers["cookie"] } == ["mine=2", "stored=1"])
    }

    @Test("a declared body past the limit is refused")
    func oversizedBodyIsRefused() async throws {
        let server = try ScriptedHTTPServer { _ in .send(.http("200 OK", body: Data(repeating: 0x61, count: 1_000))) }
        let base = try await server.start()
        defer { server.stop() }

        await #expect {
            _ = try await BoundedResponseLoader.load(post(base), session: URLSession.sourceSites(.ephemeral), limit: 100)
        } throws: { error in
            if case FetchError.responseTooLarge(let bytes, let limit) = error { return bytes == 1_000 && limit == 100 }
            return false
        }
    }

    @Test("a server that never answers times out after the request's timeout")
    func silentServerTimesOut() async throws {
        let server = try ScriptedHTTPServer { _ in .silent }
        let base = try await server.start()
        defer { server.stop() }
        var request = post(base)
        request.timeoutInterval = 1

        await #expect {
            _ = try await BoundedResponseLoader.load(request, session: URLSession.sourceSites(.ephemeral))
        } throws: { error in
            (error as? URLError)?.code == .timedOut
        }
    }

    @Test("cancelling a data task ends it as URLSession's would")
    func cancelledTaskReportsCancelled() async throws {
        let server = try ScriptedHTTPServer { _ in .silent }
        let base = try await server.start()
        defer { server.stop() }

        let code: URLError.Code? = await withCheckedContinuation { continuation in
            let task = BoundedResponseLoader.dataTask(
                with: post(base), session: URLSession.sourceSites(.ephemeral), transport: "test"
            ) { _, _, error in
                continuation.resume(returning: (error as? URLError)?.code)
            }
            #expect(task is SingleWriteHTTPExchange)
            task.resume()
            task.cancel()
        }
        #expect(code == .cancelled)
    }

    @Test("only cleartext requests with a body take this path")
    func routing() throws {
        let session = URLSession.sourceSites(.ephemeral)
        let http = try #require(URL(string: "http://www.oneceng.com/modules/article/search.php"))
        let https = try #require(URL(string: "https://www.oneceng.com/modules/article/search.php"))
        #expect(SingleWriteHTTPExchange.handles(post(http), on: session))
        #expect(!SingleWriteHTTPExchange.handles(post(https), on: session))
        #expect(!SingleWriteHTTPExchange.handles(post(http, body: Data()), on: session))
        var get = post(http)
        get.httpMethod = "GET"
        #expect(!SingleWriteHTTPExchange.handles(get, on: session))
        #expect(!SingleWriteHTTPExchange.handles(URLRequest(url: http), on: session))

        // A protocol installed on the session gets the request, as URLSession would give it.
        let stubbed = URLSessionConfiguration.ephemeral
        stubbed.protocolClasses = [ClaimingURLProtocol.self] + (stubbed.protocolClasses ?? [])
        #expect(!SingleWriteHTTPExchange.handles(post(http), on: URLSession(configuration: stubbed)))
    }

    @Test("the body follows the header block in the same buffer; header values cannot break lines")
    func requestBytesLayout() throws {
        let url = try #require(URL(string: "http://example.test:8080/s.php?q=%E4%B8%AD"))
        var request = post(url)
        request.setValue("a\r\nX-Injected: 1", forHTTPHeaderField: "X-Note")
        request.setValue("999", forHTTPHeaderField: "Content-Length")
        let bytes = SingleWriteHTTPExchange.requestBytes(for: request, session: URLSession.sourceSites(.ephemeral))
        let text = String(decoding: bytes, as: UTF8.self)

        #expect(text.hasPrefix("POST /s.php?q=%E4%B8%AD HTTP/1.1\r\nHost: example.test:8080\r\n"))
        #expect(text.hasSuffix("\r\n\r\n" + String(decoding: Self.form, as: UTF8.self)))
        #expect(text.contains("\r\nContent-Length: \(Self.form.count)\r\n"))
        #expect(!text.contains("Content-Length: 999"))
        #expect(!text.contains("\r\nX-Injected: 1\r\n"))

        // URLSession names a body it was given no type for as a form (measured 2026-11-09).
        var untyped = request
        untyped.setValue(nil, forHTTPHeaderField: "Content-Type")
        let untypedText = String(
            decoding: SingleWriteHTTPExchange.requestBytes(for: untyped, session: URLSession.sourceSites(.ephemeral)),
            as: UTF8.self
        )
        #expect(untypedText.contains("\r\nContent-Type: application/x-www-form-urlencoded\r\n"))
    }

    // MARK: Helpers

    /// An RFC 1952 member around Compression's raw DEFLATE.
    private static func gzip(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var member = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
        member.append(deflated)
        for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] {
            withUnsafeBytes(of: value.littleEndian) { member.append(contentsOf: $0) }
        }
        return member
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0 ..< 8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

private final class ClaimingURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

private extension Data {
    /// A response with `Content-Length` framing and `Connection: close`.
    static func http(_ status: String, headers: [(String, String)] = [], body: Data = Data()) -> Data {
        http(status, headers: headers + [("Content-Length", String(body.count))], rawBody: body)
    }

    static func http(_ status: String, headers: [(String, String)], rawBody: Data) -> Data {
        var head = "HTTP/1.1 \(status)\r\n"
        for (name, value) in headers + [("Connection", "close")] { head += "\(name): \(value)\r\n" }
        var bytes = Data((head + "\r\n").utf8)
        bytes.append(rawBody)
        return bytes
    }
}

/// An HTTP server on 127.0.0.1 that reads one request per connection, records it with what the
/// connection's first read held, and answers as `answer` says.
private final class ScriptedHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let firstRead: Data
        let raw: Data
        let line: String
        /// Names lowercased.
        let headers: [String: String]
        let body: Data

        var method: String { String(line.split(separator: " ").first ?? "") }
    }

    enum Reply: Sendable {
        case send(Data)
        case silent
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "ScriptedHTTPServer")
    private let answer: @Sendable (Request) -> Reply
    private let log = OSAllocatedUnfairLock(initialState: [Request]())
    private let open = OSAllocatedUnfairLock(initialState: [NWConnection]())

    init(answer: @escaping @Sendable (Request) -> Reply) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.answer = answer
    }

    var requests: [Request] { log.withLock { $0 } }

    /// The server's base URL once it listens.
    func start() async throws -> URL {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                let result: Result<URL, any Error>?
                switch state {
                case .ready:
                    result = listener.port.flatMap { URL(string: "http://127.0.0.1:\($0.rawValue)/") }
                        .map { .success($0) } ?? .failure(URLError(.cannotConnectToHost))
                case .failed(let error):
                    result = .failure(error)
                default:
                    result = nil
                }
                guard let result, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.newConnectionHandler = { [self] connection in serve(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        for connection in open.withLock({ $0 }) { connection.cancel() }
    }

    private func serve(_ connection: NWConnection) {
        open.withLock { $0.append(connection) }
        connection.start(queue: queue)
        read(connection, buffer: Data(), first: nil)
    }

    private func read(_ connection: NWConnection, buffer: Data, first: Data?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
            var buffer = buffer
            var first = first
            if let data, !data.isEmpty {
                buffer.append(data)
                if first == nil { first = data }
            }
            if let request = Self.parse(buffer, first: first ?? Data()) {
                log.withLock { $0.append(request) }
                if case .send(let bytes) = answer(request) {
                    connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
                }
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            read(connection, buffer: buffer, first: first)
        }
    }

    /// The request in `buffer`, once all of it has arrived.
    private static func parse(_ buffer: Data, first: Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let line = lines.removeFirst()
        var headers: [String: String] = [:]
        for field in lines {
            guard let colon = field.firstIndex(of: ":") else { continue }
            headers[field[..<colon].lowercased()] = field[field.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        let raw = Data(buffer[..<(bodyStart + length)])
        return Request(
            firstRead: first, raw: raw, line: line, headers: headers,
            body: Data(buffer[bodyStart ..< bodyStart + length])
        )
    }
}
