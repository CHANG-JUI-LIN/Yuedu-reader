//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// App/AI/LLM/OpenAICompatibleProvider.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
import Foundation

/// Any endpoint that speaks OpenAI's `/v1/chat/completions` — the official API, a self-hosted
/// model, or a domestic proxy.
///
/// BYOK: `apiKey` is injected from the Keychain by the caller and never reaches UserDefaults,
/// logs, or synced data.
final class OpenAICompatibleProvider: LLMProviding, @unchecked Sendable {
    nonisolated let identifier = "openai-compatible"
    let defaultModel: String

    private let endpoint: URL
    private let apiKey: String
    private let session: URLSession

    /// Read-idle timeout. A proxy that returns `200` and then says nothing — a hung gateway, a
    /// wrong model name answering with non-SSE, a half-open connection — would otherwise leave
    /// `for try await line in bytes.lines` blocked forever and the UI spinning. Only silence
    /// after the response arrives trips it, so a long answer streaming token by token is fine.
    static let firstByteTimeout: TimeInterval = 20

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = firstByteTimeout
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    // Spelled out rather than `Self.defaultSession`: Swift forbids a covariant `Self` in a
    // default argument.
    init(
        endpoint: URL,
        apiKey: String,
        defaultModel: String,
        session: URLSession = OpenAICompatibleProvider.defaultSession
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.defaultModel = defaultModel
        self.session = session
    }

    convenience init(
        endpoint: URL,
        apiKey: String,
        defaultModel: String,
        configuration: URLSessionConfiguration
    ) {
        self.init(
            endpoint: endpoint,
            apiKey: apiKey,
            defaultModel: defaultModel,
            session: URLSession(configuration: configuration)
        )
    }

    // MARK: - Wire format

    /// Typed rather than an untyped dictionary, so a field can't be misspelled into silence.
    private struct ChatRequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        let topP: Double
        let stream: Bool?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream
            case maxTokens = "max_tokens"
            case topP = "top_p"
        }
    }

    private struct ChatResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
            let finish_reason: String?
        }
        let choices: [Choice]?
        let model: String?
        let usage: LLMUsage?
    }

    private struct ProviderErrorBody: Decodable {
        struct Nested: Decodable { let message: String? }
        let error: Nested?
        let message: String?
    }

    private func makeURLRequest(
        for request: LLMGenerationRequest,
        model: String,
        stream: Bool
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ChatRequestBody(
            model: model,
            messages: request.messages.map {
                ChatRequestBody.Message(role: $0.role.rawValue, content: $0.content)
            },
            temperature: request.temperature ?? 0.2,
            maxTokens: request.maxTokens ?? 1024,
            topP: request.topP ?? 1.0,
            stream: stream ? true : nil
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    // MARK: - Generation

    func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
        let useModel = model ?? defaultModel
        let urlRequest = try makeURLRequest(for: request, model: useModel, stream: false)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LLMError.networkError(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.networkError(localized("非 HTTP 回應"))
        }
        AIDiagnostics.current?.event("http", ["status": "\(http.statusCode)"])
        switch http.statusCode {
        case 200...299:
            guard let body = try? JSONDecoder().decode(ChatResponseBody.self, from: data),
                  let content = body.choices?.first?.message?.content
            else {
                throw LLMError.providerError(localized("回應解析失敗"))
            }
            return LLMRawResponse(content: content, provider: identifier, model: body.model ?? useModel,
                finishReason: body.choices?.first?.finish_reason, usage: body.usage, httpStatus: http.statusCode)
        case 401:
            throw LLMError.unauthorized
        case 429:
            throw LLMError.rateLimited
        default:
            throw LLMError.providerError(
                Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)"
            )
        }
    }

    /// Streaming via SSE. Cancelling the stream cancels the URLSession task.
    func stream(
        _ request: LLMGenerationRequest,
        model: String?
    ) -> AsyncThrowingStream<String, Error> {
        let useModel = model ?? defaultModel
        guard let urlRequest = try? makeURLRequest(for: request, model: useModel, stream: true) else {
            return AsyncThrowingStream {
                $0.finish(throwing: LLMError.providerError(localized("請求序列化失敗")))
            }
        }
        // Bound to a `let` before capture: Swift 6 reads a captured `var URLRequest` as a
        // data race.
        let sendableRequest = urlRequest

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: sendableRequest)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.finish(throwing: LLMError.networkError(localized("非 HTTP 回應")))
                        return
                    }
                    switch http.statusCode {
                    case 200...299:
                        break
                    case 401:
                        continuation.finish(throwing: LLMError.unauthorized)
                        return
                    case 429:
                        continuation.finish(throwing: LLMError.rateLimited)
                        return
                    default:
                        // Read a little of the error body for a message, capped so a
                        // misconfigured proxy cannot stream megabytes into an alert.
                        var errorBody = Data()
                        for try await byte in bytes {
                            errorBody.append(byte)
                            if errorBody.count > 4_096 { break }
                        }
                        continuation.finish(
                            throwing: LLMError.providerError(
                                Self.extractErrorMessage(from: errorBody) ?? "HTTP \(http.statusCode)"
                            )
                        )
                        return
                    }
                    var receivedDone = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if LLMStreamDecoding.isDone(line) {
                            receivedDone = true
                            break
                        }
                        if let delta = LLMStreamDecoding.contentDelta(from: line) {
                            continuation.yield(delta)
                        }
                    }
                    // A stream that ends without `[DONE]` was cut off. Finishing normally here
                    // would present a truncated answer as a complete one, so this is a hard
                    // error — deliberately not a retry, and deliberately not silence.
                    guard receivedDone else {
                        continuation.finish(
                            throwing: LLMError.networkError(localized("串流回應在完成標記前中斷"))
                        )
                        return
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                } catch let error as URLError where error.code == .cancelled {
                    continuation.finish(throwing: CancellationError())
                } catch let error as LLMError {
                    continuation.finish(throwing: error)
                } catch {
                    continuation.finish(throwing: LLMError.networkError(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Error bodies

    /// Prefers OpenAI's `{"error":{"message":…}}`, then a top-level `message`; `nil` leaves the
    /// caller with the bare status code rather than echoing an untrusted body.
    static func extractErrorMessage(from data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(ProviderErrorBody.self, from: data) else {
            return nil
        }
        if let message = body.error?.message, !message.isEmpty {
            return sanitizedProviderMessage(message)
        }
        if let message = body.message, !message.isEmpty {
            return sanitizedProviderMessage(message)
        }
        return nil
    }

    /// A provider's error text is untrusted input that ends up in the UI. Control characters
    /// are flattened, credentials and URLs redacted, and the whole thing capped — a proxy that
    /// echoes the request would otherwise print the user's own API key back at them.
    static func sanitizedProviderMessage(_ message: String) -> String? {
        let flattened = message.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        var normalized = flattened
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        for pattern in [
            #"(?i)bearer\s+[a-z0-9._~+\-/]+=*"#,
            #"(?i)\bsk-[a-z0-9_-]{8,}\b"#,
            #"https?://[^\s]+"#,
        ] {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: "<redacted>",
                options: .regularExpression
            )
        }
        guard !normalized.isEmpty else { return nil }
        return String(normalized.prefix(240))
    }
}
