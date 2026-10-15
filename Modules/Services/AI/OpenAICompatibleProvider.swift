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
    static let firstByteTimeout: TimeInterval = 60

    private static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = firstByteTimeout
        configuration.timeoutIntervalForResource = 300
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

    /// DeepSeek's output allowance. Its models write up to 384K tokens
    /// (https://api-docs.deepseek.com/quick_start/pricing) and bill only what they write, so a
    /// thinking answer gets room to finish instead of 16,384 tokens it could spend thinking. A
    /// service whose ceiling is unknown keeps the request's: some refuse a larger one outright.
    static let deepSeekOutputTokens = 65_536

    // MARK: - Wire format

    /// Typed rather than an untyped dictionary, so a field can't be misspelled into silence.
    private struct ChatRequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        /// `nil` is left out of the body, and the service uses its own default.
        let temperature: Double?
        let maxTokens: Int
        let topP: Double?
        let stream: Bool?
        struct Thinking: Encodable { let type: String }
        let thinking: Thinking?
        let reasoningEffort: String?

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, stream, thinking
            case reasoningEffort = "reasoning_effort"
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

    func makeURLRequest(
        for request: LLMGenerationRequest,
        model: String,
        stream: Bool
    ) throws -> URLRequest {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // DeepSeek thinks by default, at high, and max_tokens covers the thinking as well as
        // the answer (https://api-docs.deepseek.com/guides/thinking_mode). Every model on its
        // endpoint is sent the feature's choice: one the list of model names missed thought at
        // high whatever the feature asked.
        let deepSeek = endpoint.host?.lowercased() == "api.deepseek.com"
        let effort = request.reasoningEffort ?? .high
        // Anthropic's compatibility endpoint passes temperature and top_p on to Claude, and
        // Claude refuses them: the two together 400 on every Claude 4 model, any value 400s on
        // Opus 4.7 and later, Opus 5 and Fable, anything but the default on Sonnet 5. So every
        // request to the Anthropic preset failed, the connection test too. Claude gets neither
        // and runs at its defaults; every other service is sent exactly what it was before.
        let sendsSampling = endpoint.host?.lowercased() != "api.anthropic.com"
        let body = ChatRequestBody(
            model: model,
            messages: request.messages.map {
                ChatRequestBody.Message(role: $0.role.rawValue, content: $0.content)
            },
            temperature: sendsSampling ? request.temperature ?? 0.2 : nil,
            maxTokens: deepSeek ? max(request.maxTokens ?? 0, Self.deepSeekOutputTokens)
                : request.maxTokens ?? LLMGenerationRequest.defaultMaxTokens,
            topP: sendsSampling ? request.topP ?? 1.0 : nil,
            stream: stream ? true : nil,
            thinking: deepSeek ? .init(type: effort == .off ? "disabled" : "enabled") : nil,
            reasoningEffort: deepSeek && effort != .off ? effort.rawValue : nil
        )
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    // MARK: - Generation

    func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
        let useModel = model ?? defaultModel
        if endpoint.host?.lowercased() == "api.deepseek.com" {
            return try await generateDeepSeek(request, model: useModel)
        }
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

    private struct GenerationChunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
            let finish_reason: String?
        }
        let model: String?
        let choices: [Choice]?
        let usage: LLMUsage?
    }

    /// Reasoning may take longer than a non-streaming request's idle deadline. Receive the
    /// provider's SSE activity throughout generation, retaining only final text and usage.
    private func generateDeepSeek(_ request: LLMGenerationRequest, model: String) async throws -> LLMRawResponse {
        do {
            let wire = try makeURLRequest(for: request, model: model, stream: true)
            let (bytes, response) = try await session.bytes(for: wire)
            guard let http = response as? HTTPURLResponse else { throw LLMError.networkError(localized("非 HTTP 回應")) }
            AIDiagnostics.current?.event("http", ["status": "\(http.statusCode)", "transport": "sse"])
            guard (200...299).contains(http.statusCode) else {
                if http.statusCode == 401 { throw LLMError.unauthorized }
                if http.statusCode == 429 { throw LLMError.rateLimited }
                var data = Data()
                for try await byte in bytes { data.append(byte); if data.count >= 4096 { break } }
                throw LLMError.providerError(Self.extractErrorMessage(from: data) ?? "HTTP \(http.statusCode)")
            }
            var content = "", servedModel = model
            var usage: LLMUsage?, reason: String?
            var done = false
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if LLMStreamDecoding.isDone(line) { done = true; break }
                guard let payload = LLMStreamDecoding.payload(ofDataLine: line), !payload.isEmpty else { continue }
                guard let chunk = try? JSONDecoder().decode(GenerationChunk.self, from: Data(payload.utf8)),
                      chunk.choices != nil else { throw LLMError.providerError(localized("回應解析失敗")) }
                if let text = chunk.choices?.first?.delta?.content { content += text }
                if let finish = chunk.choices?.first?.finish_reason { reason = finish }
                if let value = chunk.usage { usage = value }
                if let value = chunk.model { servedModel = value }
            }
            guard done else { throw LLMError.networkError(localized("串流回應在完成標記前中斷")) }
            return .init(content: content, provider: identifier, model: servedModel, finishReason: reason, usage: usage, httpStatus: http.statusCode)
        } catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as LLMError { throw error }
        catch { throw LLMError.networkError(error.localizedDescription) }
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
                        try LLMStreamDecoding.validateFinish(from: line)
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
