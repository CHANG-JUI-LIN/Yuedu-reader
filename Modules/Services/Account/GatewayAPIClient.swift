import Foundation

struct GatewayRequest {
    var method: String
    var path: String
    var query: [URLQueryItem] = []
    var headers: [String: String] = [:]
    var body: Data?
    /// Adds `Authorization: Bearer <idToken>` when a token is supplied.
    var authenticated: Bool = false

    init(method: String, path: String, query: [URLQueryItem] = [], authenticated: Bool = false) {
        self.method = method
        self.path = path
        self.query = query
        self.authenticated = authenticated
    }

    func jsonBody<T: Encodable>(_ value: T) throws -> GatewayRequest {
        var copy = self
        copy.body = try JSONEncoder().encode(value)
        copy.headers["Content-Type"] = "application/json"
        return copy
    }
}

final class GatewayAPIClient: Sendable {
    static let shared = GatewayAPIClient()

    private let session: URLSession
    /// Uploads and downloads: same stall limit, but a whole transfer may take minutes.
    private let transferSession: URLSession
    private let baseURLProvider: @Sendable () -> URL?

    init(
        session: URLSession? = nil,
        baseURLProvider: @escaping @Sendable () -> URL? = { GatewayConfiguration.baseURL }
    ) {
        if let session {
            self.session = session
            self.transferSession = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)

            let transfers = URLSessionConfiguration.ephemeral
            transfers.timeoutIntervalForRequest = 60
            transfers.timeoutIntervalForResource = 15 * 60
            transfers.waitsForConnectivity = false
            self.transferSession = URLSession(configuration: transfers)
        }
        self.baseURLProvider = baseURLProvider
    }

    func send<T: Decodable & Sendable>(
        _ request: GatewayRequest,
        as type: T.Type = T.self,
        idToken: String? = nil
    ) async throws -> T {
        let data = try await sendForData(request, idToken: idToken)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            AppLogger.network("gateway decode failed for \(request.path)", error: error)
            throw GatewayAPIError.invalidResponse
        }
    }

    @discardableResult
    func sendVoid(_ request: GatewayRequest, idToken: String? = nil) async throws -> Data {
        try await sendForData(request, idToken: idToken)
    }

    func sendForData(_ request: GatewayRequest, idToken: String? = nil) async throws -> Data {
        let urlRequest = try urlRequest(for: request, idToken: idToken)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw GatewayAPIError.transport(error)
        } catch {
            throw GatewayAPIError.transport(URLError(.unknown))
        }
        try Self.check(response, data: data)
        return data
    }

    /// Sends a file as the request body, streamed from disk. Uses the transfer
    /// session: a 50 MB 回饋中心 video from the mainland outlasts the JSON
    /// session's 60-second resource limit.
    func upload(_ request: GatewayRequest, fromFile fileURL: URL) async throws -> Data {
        let urlRequest = try urlRequest(for: request, idToken: nil)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transferSession.upload(for: urlRequest, fromFile: fileURL)
        } catch let error as URLError {
            throw GatewayAPIError.transport(error)
        } catch {
            throw GatewayAPIError.transport(URLError(.unknown))
        }
        try Self.check(response, data: data)
        return data
    }

    /// Downloads a response body to a temporary file the caller owns.
    func download(_ request: GatewayRequest) async throws -> URL {
        let urlRequest = try urlRequest(for: request, idToken: nil)
        let fileURL: URL
        let response: URLResponse
        do {
            (fileURL, response) = try await transferSession.download(for: urlRequest)
        } catch let error as URLError {
            throw GatewayAPIError.transport(error)
        } catch {
            throw GatewayAPIError.transport(URLError(.unknown))
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = (try? Data(contentsOf: fileURL)) ?? Data()
            try? FileManager.default.removeItem(at: fileURL)
            try Self.check(response, data: body)
            throw GatewayAPIError.invalidResponse
        }
        return fileURL
    }

    private func urlRequest(for request: GatewayRequest, idToken: String?) throws -> URLRequest {
        guard let baseURL = baseURLProvider() else {
            throw GatewayAPIError.notConfigured
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw GatewayAPIError.notConfigured
        }
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
            + request.path
        if !request.query.isEmpty {
            components.queryItems = request.query
        }
        guard let url = components.url else {
            throw GatewayAPIError.notConfigured
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (field, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        if request.authenticated, let idToken {
            urlRequest.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        }
        return urlRequest
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GatewayAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw classifyFailure(data: data, status: http.statusCode)
        }
    }

    /// Classifies a non-2xx response. A structured Gateway error is preserved;
    /// an unstructured 5xx (reverse proxy HTML page, gateway crash) is treated
    /// as a connectivity failure so route fallback can engage, while a 4xx that
    /// does not match the contract stays an invalid response.
    static func classifyFailure(data: Data, status: Int) -> GatewayAPIError {
        if let parsed = serverError(from: data, status: status) { return parsed }
        if status >= 500 {
            return .transport(URLError(.badServerResponse))
        }
        return .invalidResponse
    }

    private static func serverError(from data: Data, status: Int) -> GatewayAPIError? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let errorObject = object["error"] as? [String: Any],
            let code = errorObject["code"] as? String,
            let message = errorObject["message"] as? String
        else {
            return nil
        }
        // Scalars only: every reader takes a string or a number out of `details`, and an
        // error must be `Sendable` to cross the async boundary it is thrown across.
        let wireDetails = errorObject["details"] as? [String: Any] ?? [:]
        let details = wireDetails.compactMapValues { value -> (any Sendable)? in
            switch value {
            case let string as String: return string
            case let number as Int: return number
            case let number as Double: return number
            default: return nil
            }
        }
        return .server(code: code, message: message, status: status, details: details)
    }
}
