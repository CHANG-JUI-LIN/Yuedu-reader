import Foundation
import Network
import Combine

class LanWebServer: ObservableObject {
    static let shared = LanWebServer()

    @Published var isRunning: Bool = false
    @Published var localIPAddress: String = ""
    @Published var accessPIN: String = ""

    let port: UInt16 = 1122

    /// Set from the view layer (environment object has no singleton)
    var bookStore: BookStore?

    private var listener: NWListener?
    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        accessPIN = String(format: "%06d", Int.random(in: 0..<1_000_000))
        do {
            let nwPort = NWEndpoint.Port(rawValue: port)!
            let listener = try NWListener(using: .tcp, on: nwPort)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.localIPAddress = self?.getLocalIPAddress() ?? ""
                    case .failed, .cancelled:
                        self?.isRunning = false
                        self?.localIPAddress = ""
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            listener.start(queue: .global(qos: .userInitiated))
        } catch {
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        DispatchQueue.main.async {
            self.isRunning = false
            self.localIPAddress = ""
        }
    }

    // MARK: - Network helpers

    func getLocalIPAddress() -> String {
        var address = ""
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        var ptr = firstAddr
        while true {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, 0, NI_NUMERICHOST
                    )
                    address = String(cString: hostname)
                    break
                }
            }
            guard let next = interface.ifa_next else { break }
            ptr = next
        }
        return address
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        receiveAll(connection: connection) { [weak self] data in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            let requestStr = String(data: data, encoding: .utf8) ?? ""
            let (method, path, body, reqHeaders, queryItems) = self.parseHTTPRequest(requestStr, rawData: data)

            if path != "/health" && !self.isAuthorized(queryItems: queryItems, headers: reqHeaders) {
                let unauthorizedBody = Data(#"{"error":"unauthorized","hint":"append ?pin=YOUR_PIN to the URL"}"#.utf8)
                let header = "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(unauthorizedBody.count)\r\n\r\n"
                var resp = (header.data(using: .utf8) ?? Data())
                resp.append(unauthorizedBody)
                connection.send(content: resp, completion: .contentProcessed { _ in connection.cancel() })
                return
            }

            let result = self.handleRequest(method: method, path: path, body: body)
            let statusText: String
            switch result.status {
            case 200: statusText = "OK"
            case 401: statusText = "Unauthorized"
            case 404: statusText = "Not Found"
            default:  statusText = "Bad Request"
            }
            let bodyData = result.body
            let header = "HTTP/1.1 \(result.status) \(statusText)\r\n" +
                "Content-Type: \(result.contentType)\r\n" +
                "Content-Length: \(bodyData.count)\r\n" +
                "Access-Control-Allow-Origin: *\r\n" +
                "\r\n"
            var responseData = (header.data(using: .utf8) ?? Data())
            responseData.append(bodyData)
            connection.send(content: responseData, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func receiveAll(
        connection: NWConnection,
        buffer: Data = Data(),
        completion: @escaping (Data?) -> Void
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { completion(nil); return }
            guard let chunk = data, !chunk.isEmpty else {
                completion(isComplete ? buffer : nil)
                return
            }
            var accumulated = buffer
            accumulated.append(chunk)

            // Guard: reject requests larger than 10 MB to prevent DoS
            let maxBufferSize = 10 * 1024 * 1024
            if accumulated.count > maxBufferSize {
                completion(nil)
                return
            }

            let headerDelimiter = Data("\r\n\r\n".utf8)
            guard let delimRange = accumulated.range(of: headerDelimiter) else {
                self.receiveAll(connection: connection, buffer: accumulated, completion: completion)
                return
            }

            let headerPart = accumulated[..<delimRange.lowerBound]
            let headerStr = String(data: headerPart, encoding: .utf8) ?? ""
            let contentLength = self.parseContentLength(from: headerStr)
            let bodyStart = delimRange.upperBound
            let receivedBodyLength = accumulated.count - bodyStart

            if receivedBodyLength >= contentLength {
                completion(accumulated)
            } else {
                self.receiveAll(connection: connection, buffer: accumulated, completion: completion)
            }
        }
    }

    private func parseContentLength(from headers: String) -> Int {
        let lines = headers.lowercased().components(separatedBy: "\r\n")
        for line in lines {
            if line.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value) ?? 0
            }
        }
        return 0
    }

    private func isAuthorized(queryItems: [URLQueryItem], headers: [String: String]) -> Bool {
        // Note: String == is not constant-time. For a 6-digit LAN-only PIN,
        // timing attacks are impractical given typical LAN jitter (>1ms vs nanosecond differences).
        if let pin = queryItems.first(where: { $0.name == "pin" })?.value, pin == accessPIN { return true }
        let authHeader = headers["authorization"] ?? ""
        return authHeader == "Bearer \(accessPIN)"
    }

    private func parseHTTPRequest(_ text: String, rawData: Data) -> (method: String, path: String, body: Data?, headers: [String: String], queryItems: [URLQueryItem]) {
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return ("GET", "/", nil, [:], []) }
        let parts = requestLine.components(separatedBy: " ")
        let method = parts.count > 0 ? parts[0] : "GET"
        let rawPath = parts.count > 1 ? parts[1] : "/"

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty else { break }
            if let colonIdx = line.firstIndex(of: ":") {
                let key = String(line[..<colonIdx])
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers[key.lowercased()] = value
            }
        }

        var path = rawPath
        var queryItems: [URLQueryItem] = []
        if let comps = URLComponents(string: rawPath) {
            path = comps.path
            queryItems = comps.queryItems ?? []
        }

        var body: Data? = nil
        let delimData = Data("\r\n\r\n".utf8)
        if let delimRange = rawData.range(of: delimData) {
            let bodyData = rawData[delimRange.upperBound...]
            if !bodyData.isEmpty { body = Data(bodyData) }
        }
        return (method, path, body, headers, queryItems)
    }

    // MARK: - Request routing

    private func handleRequest(method: String, path: String, body: Data?) -> (status: Int, contentType: String, body: Data) {
        let jsonType = "application/json; charset=utf-8"
        let encoder = JSONEncoder()

        // GET /health
        if method == "GET" && path == "/health" {
            let payload = #"{"status":"ok"}"#
            return (200, jsonType, Data(payload.utf8))
        }

        // GET / — book list
        if method == "GET" && path == "/" {
            let books = bookStore?.books ?? []
            let dtos = books.map { BookDTO(book: $0) }
            let data = (try? encoder.encode(dtos)) ?? Data("[]".utf8)
            return (200, jsonType, data)
        }

        // GET /book/:id — single book
        if method == "GET" && path.hasPrefix("/book/") {
            let idStr = String(path.dropFirst("/book/".count))
            if let uuid = UUID(uuidString: idStr),
               let book = bookStore?.books.first(where: { $0.id == uuid }) {
                let dto = BookDetailDTO(book: book)
                let data = (try? encoder.encode(dto)) ?? Data("{}".utf8)
                return (200, jsonType, data)
            }
            return (404, jsonType, Data(#"{"error":"not found"}"#.utf8))
        }

        // GET /api/sources — book source list
        if method == "GET" && path == "/api/sources" {
            let sources = BookSourceStore.shared.sources
            let dtos = sources.map { SourceDTO(source: $0) }
            let data = (try? encoder.encode(dtos)) ?? Data("[]".utf8)
            return (200, jsonType, data)
        }

        return (404, jsonType, Data(#"{"error":"not found"}"#.utf8))
    }
}

// MARK: - Lightweight DTOs for JSON serialisation

private struct BookDTO: Encodable {
    let id: String
    let title: String
    let author: String
    let coverUrl: String?
    let isOnline: Bool

    init(book: ReadingBook) {
        self.id = book.id.uuidString
        self.title = book.title
        self.author = book.author
        self.coverUrl = book.coverImagePath
        self.isOnline = book.isOnline
    }
}

private struct BookDetailDTO: Encodable {
    let id: String
    let title: String
    let author: String
    let coverUrl: String?
    let isOnline: Bool
    let source: String
    let currentPosition: Double

    init(book: ReadingBook) {
        self.id = book.id.uuidString
        self.title = book.title
        self.author = book.author
        self.coverUrl = book.coverImagePath
        self.isOnline = book.isOnline
        self.source = book.source
        self.currentPosition = book.currentPosition
    }
}

private struct SourceDTO: Encodable {
    let bookSourceName: String
    let bookSourceUrl: String
    let enabled: Bool

    init(source: BookSource) {
        self.bookSourceName = source.bookSourceName
        self.bookSourceUrl = source.bookSourceUrl
        self.enabled = source.enabled
    }
}
