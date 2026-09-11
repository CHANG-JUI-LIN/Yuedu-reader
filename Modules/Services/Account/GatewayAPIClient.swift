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

final class GatewayAPIClient {
    static let shared = GatewayAPIClient()

    private let session: URLSession
    private let baseURLProvider: () -> URL?

    init(
        session: URLSession? = nil,
        baseURLProvider: @escaping () -> URL? = { GatewayConfiguration.baseURL }
    ) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 60
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
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

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw GatewayAPIError.transport(error)
        } catch {
            throw GatewayAPIError.transport(URLError(.unknown))
        }

        guard let http = response as? HTTPURLResponse else {
            throw GatewayAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.classifyFailure(data: data, status: http.statusCode)
        }
        return data
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
        let details = errorObject["details"] as? [String: Any] ?? [:]
        return .server(code: code, message: message, status: status, details: details)
    }
}
