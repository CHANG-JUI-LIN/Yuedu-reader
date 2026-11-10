import Foundation
import Network
import os

/// HTTP on 127.0.0.1 for WebView and transport tests: each request's path goes to `route`, which
/// answers with a body after a delay, with a status and headers of its own, or never. Counts the
/// requests per path.
final class LoopbackPageServer: @unchecked Sendable {
    enum Reply: Sendable {
        case body(Data, type: String, after: DispatchTimeInterval)
        /// The request is read and never answered, as a long-poll that outlives the page.
        case never
        /// `status` with `headers` — a `Set-Cookie`, a `Location` — and `body`, answered at once.
        case answer(status: Int, headers: [String: String], body: Data)

        static func html(_ page: String, after delay: DispatchTimeInterval = .seconds(0)) -> Reply {
            .body(Data(page.utf8), type: "text/html; charset=utf-8", after: delay)
        }

        static func text(_ text: String, after delay: DispatchTimeInterval = .seconds(0)) -> Reply {
            .body(Data(text.utf8), type: "text/plain; charset=utf-8", after: delay)
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "LoopbackPageServer")
    private let route: @Sendable (String) -> Reply
    private let counts = OSAllocatedUnfairLock(initialState: [String: Int]())
    private let open = OSAllocatedUnfairLock(initialState: [NWConnection]())

    init(route: @escaping @Sendable (String) -> Reply) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.route = route
    }

    /// How many requests asked for a path starting with `prefix`.
    func requests(startingWith prefix: String) -> Int {
        counts.withLock { $0.filter { $0.key.hasPrefix(prefix) }.values.reduce(0, +) }
    }

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
        read(connection, buffer: Data())
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                counts.withLock { $0[path, default: 0] += 1 }
                respond(route(path), on: connection)
                return
            }
            if isComplete || error != nil { connection.cancel(); return }
            read(connection, buffer: buffer)
        }
    }

    private func respond(_ reply: Reply, on connection: NWConnection) {
        switch reply {
        case .never:
            return
        case .body(let body, let type, let delay):
            let send = {
                var head = Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
                head.append(body)
                connection.send(content: head, completion: .contentProcessed { _ in connection.cancel() })
            }
            queue.asyncAfter(deadline: .now() + delay, execute: send)
        case .answer(let status, let headers, let body):
            var lines = ["HTTP/1.1 \(status) Status"]
            lines += headers.map { "\($0.key): \($0.value)" }
            lines += ["Content-Length: \(body.count)", "Cache-Control: no-store", "Connection: close", "", ""]
            var message = Data(lines.joined(separator: "\r\n").utf8)
            message.append(body)
            connection.send(content: message, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
