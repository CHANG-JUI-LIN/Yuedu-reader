import Foundation
import Testing
@testable import yuedu_app

@Suite("AI provider base layer")
struct AIProviderTests {

    // MARK: - SSE decoding

    @Test("a content delta is read out of a chat-completion chunk")
    func readsContentDelta() {
        let line = #"data: {"choices":[{"delta":{"content":"你"}}]}"#
        #expect(LLMStreamDecoding.contentDelta(from: line) == "你")
    }

    /// The protocol's first chunk carries only the role, heartbeats are comments, and `[DONE]`
    /// is the terminator. None of them is text the reader should see.
    @Test("non-content lines yield nothing")
    func ignoresNonContentLines() {
        #expect(LLMStreamDecoding.contentDelta(from: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#) == nil)
        #expect(LLMStreamDecoding.contentDelta(from: "data: [DONE]") == nil)
        #expect(LLMStreamDecoding.contentDelta(from: ": keep-alive") == nil)
        #expect(LLMStreamDecoding.contentDelta(from: "event: message") == nil)
        #expect(LLMStreamDecoding.contentDelta(from: "") == nil)
        #expect(LLMStreamDecoding.contentDelta(from: #"data: {"choices":[{"delta":{"content":""}}]}"#) == nil)
    }

    @Test("the completion marker is recognised whatever the spacing")
    func recognisesDone() {
        #expect(LLMStreamDecoding.isDone("data: [DONE]"))
        #expect(LLMStreamDecoding.isDone("data:[DONE]"))
        #expect(!LLMStreamDecoding.isDone(#"data: {"choices":[]}"#))
    }

    @Test func tokenLimitSSEIsNotSuccessfulEvenWithDoneMarker() throws {
        #expect(throws: LLMError.incompleteOutput) {
            try LLMStreamDecoding.validateFinish(from: #"data: {"choices":[{"delta":{},"finish_reason":"length"}]}"#)
        }
        #expect(throws: LLMError.filteredOutput) {
            try LLMStreamDecoding.validateFinish(from: #"data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}"#)
        }
        try LLMStreamDecoding.validateFinish(from: #"data: {"choices":[{"delta":{},"finish_reason":"stop"}]}"#)
    }

    @Test func deepSeekThinkingUsesVisibleTotalBudgetAndOtherEndpointsStayCompatible() throws {
        let request = LLMGenerationRequest(messages: [.init(role: .user, content: "fixture")], maxTokens: AIQuestionBudget().maximumOutputTokens)
        for host in ["api.deepseek.com", "fixture.invalid"] {
            let provider = OpenAICompatibleProvider(endpoint: URL(string: "https://\(host)/v1/chat/completions")!, apiKey: "fixture", defaultModel: "deepseek-flash")
            let wire = try provider.makeURLRequest(for: request, model: "deepseek-flash", stream: false)
            let body = try #require(try JSONSerialization.jsonObject(with: wire.httpBody!) as? [String: Any])
            // DeepSeek's allowance is raised to 64K (AIReasoningBudgetTests); others keep the request's.
            #expect(body["max_tokens"] as? Int == (host == "api.deepseek.com" ? OpenAICompatibleProvider.deepSeekOutputTokens : 16_384))
            #expect((body["thinking"] != nil) == (host == "api.deepseek.com"))
            #expect(body["reasoning_effort"] as? String == (host == "api.deepseek.com" ? "high" : nil))
        }
    }

    /// Claude refuses temperature with top_p (every Claude 4 model), any temperature (Opus 4.7
    /// and later, Opus 5, Fable) or a non-default one (Sonnet 5), so every request to the
    /// Anthropic preset came back 400. Other services must keep exactly what they were sent.
    @Test func anthropicGetsNoSamplingParametersAndOtherServicesKeepThem() throws {
        let request = LLMGenerationRequest(messages: [.init(role: .user, content: "fixture")], temperature: 0.2, topP: 1)
        for (host, sendsSampling) in [("api.anthropic.com", false), ("API.Anthropic.com", false),
                                      ("api.deepseek.com", true), ("api.openai.com", true), ("openrouter.ai", true)] {
            let provider = OpenAICompatibleProvider(endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
                                                    apiKey: "fixture", defaultModel: "fixture")
            let wire = try provider.makeURLRequest(for: request, model: "fixture", stream: false)
            let body = try #require(try JSONSerialization.jsonObject(with: wire.httpBody!) as? [String: Any])
            #expect((body["temperature"] as? Double) == (sendsSampling ? 0.2 : nil))
            #expect((body["top_p"] as? Double) == (sendsSampling ? 1 : nil))
            #expect(body["max_tokens"] as? Int == (host == "api.deepseek.com" ? OpenAICompatibleProvider.deepSeekOutputTokens
                                                  : LLMGenerationRequest.defaultMaxTokens))
        }
    }

    @Test func structuredExtractionCanBoundThinkingWithoutDisablingIt() throws {
        let provider = OpenAICompatibleProvider(endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!, apiKey: "fixture", defaultModel: "deepseek-flash")
        let request = LLMGenerationRequest(messages: [.init(role: .user, content: "fixture")], maxTokens: 16_384, reasoningEffort: .low)
        let wire = try provider.makeURLRequest(for: request, model: "deepseek-flash", stream: false)
        let body = try #require(try JSONSerialization.jsonObject(with: wire.httpBody!) as? [String: Any])
        #expect(body["reasoning_effort"] as? String == "low")
        #expect((body["thinking"] as? [String: String])?["type"] == "enabled")
    }

    @Test func reasoningUsageCanBeDiagnosedWithoutRetainingReasoningText() throws {
        let wire = Data(#"{"prompt_tokens":20,"completion_tokens":100,"total_tokens":120,"completion_tokens_details":{"reasoning_tokens":80}}"#.utf8)
        let usage = try JSONDecoder().decode(LLMUsage.self, from: wire)
        #expect(usage.completionTokensDetails?.reasoningTokens == 80)
        #expect(usage.completionTokens == 100)
    }

    @Test func deepSeekGenerationCollectsFinalTextAndUsageFromSSE() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeepSeekGenerationFixture.self]
        let provider = OpenAICompatibleProvider(endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!, apiKey: "fixture", defaultModel: "deepseek-flash", configuration: configuration)
        let raw = try await provider.generate(.init(messages: [.init(role: .user, content: "fixture")]))
        try raw.validateCompletion()
        #expect(raw.content == "Complete answer")
        #expect(raw.finishReason == "stop")
        #expect(raw.usage?.completionTokensDetails?.reasoningTokens == 80)
        #expect(!raw.content.contains("private reasoning"))
    }

    // MARK: - Error sanitising

    /// A misconfigured proxy that echoes the request would otherwise print the user's own API
    /// key back at them inside an alert.
    @Test("credentials and URLs never survive into a user-visible error")
    func redactsSecretsFromProviderErrors() {
        let message = OpenAICompatibleProvider.sanitizedProviderMessage(
            "Invalid key sk-abcdef0123456789 with Bearer abc.def123 at https://proxy.example/v1"
        )
        let text = try! #require(message)
        #expect(!text.contains("sk-abcdef0123456789"))
        #expect(!text.contains("abc.def123"))
        #expect(!text.contains("proxy.example"))
        #expect(text.contains("<redacted>"))
    }

    @Test("an untrusted error body is flattened and capped")
    func boundsProviderErrors() {
        let message = OpenAICompatibleProvider.sanitizedProviderMessage(
            "line\u{0}one\nline\ttwo " + String(repeating: "x", count: 400)
        )
        let text = try! #require(message)
        #expect(text.count <= 240)
        #expect(!text.contains("\n"))
        #expect(!text.contains("\u{0}"))
        #expect(message != nil)
        #expect(OpenAICompatibleProvider.sanitizedProviderMessage("   ") == nil)
    }

    @Test("an error body without a message leaves the caller with the status code")
    func returnsNilForUnparseableErrorBody() {
        #expect(OpenAICompatibleProvider.extractErrorMessage(from: Data("not json".utf8)) == nil)
        #expect(OpenAICompatibleProvider.extractErrorMessage(from: Data(#"{"ok":true}"#.utf8)) == nil)
        #expect(
            OpenAICompatibleProvider.extractErrorMessage(from: Data(#"{"error":{"message":"bad model"}}"#.utf8))
                == "bad model"
        )
    }

    // MARK: - Streaming dispatch

    /// Ported from ChatBook, which shipped this exact regression test: a `model:` default
    /// argument declared on the protocol extension binds *statically* to the extension, so a
    /// provider's real streaming implementation gets silently bypassed and every answer arrives
    /// in one lump. The single-argument overload is what keeps dispatch dynamic.
    @Test("calling stream without a model still reaches the provider's own implementation")
    func streamStaysDynamicallyDispatched() async throws {
        let provider = StreamingSpyProvider()
        var received: [String] = []
        for try await delta in provider.stream(Self.probeRequest) {
            received.append(delta)
        }
        #expect(received == ["a", "b"])
        #expect(provider.streamCalled)
        #expect(!provider.generateCalled)
    }

    /// A backend with no streaming endpoint is a legal provider; it just arrives all at once.
    @Test("a provider without streaming falls back to one-shot generation")
    func nonStreamingProviderFallsBack() async throws {
        let provider = OneShotProvider()
        var received: [String] = []
        for try await delta in provider.stream(Self.probeRequest) {
            received.append(delta)
        }
        #expect(received == ["whole answer"])
    }

    // MARK: - Configuration

    @Test("a corrupt stored configuration throws instead of silently using the default endpoint")
    @MainActor
    func corruptConfigurationThrows() throws {
        let defaults = try #require(UserDefaults(suiteName: "ai.config.\(UUID().uuidString)"))
        let store = AIProviderStore(defaults: defaults, key: "cfg")
        #expect(try store.load() == nil)

        defaults.set(Data("not a configuration".utf8), forKey: "cfg")
        #expect(throws: AIProviderStore.LoadError.corruptedConfiguration) { try store.load() }

        // And it must not be mistaken for "no key yet" either.
        let result = AIProviderAssembly.makeProvider(store: store, apiKey: "sk-test")
        guard case let .failure(reason) = result else {
            Issue.record("expected corrupted configuration to block provider assembly")
            return
        }
        #expect(reason == .corruptedConfiguration)
    }

    @Test("assembly reports exactly why it could not build a provider")
    @MainActor
    func assemblyReportsWhy() throws {
        let defaults = try #require(UserDefaults(suiteName: "ai.config.\(UUID().uuidString)"))
        let store = AIProviderStore(defaults: defaults, key: "cfg")

        #expect(AIProviderAssembly.makeProvider(store: store, apiKey: nil).failureReason == .noAPIKey)
        #expect(AIProviderAssembly.makeProvider(store: store, apiKey: "").failureReason == .noAPIKey)
        #expect(AIProviderAssembly.makeProvider(store: store, apiKey: "sk-test").failureReason == .notConfigured)

        store.save(AIProviderConfiguration(endpoint: "not a url at all", defaultModel: "m"))
        #expect(AIProviderAssembly.makeProvider(store: store, apiKey: "sk-test").failureReason == .invalidEndpoint)

        store.save(AIProviderConfiguration(endpoint: "https://example.com/v1/chat/completions", defaultModel: "m"))
        #expect(AIProviderAssembly.makeProvider(store: store, apiKey: "sk-test").failureReason == nil)
    }

    @Test("a blank or schemeless endpoint is not a URL")
    func endpointValidation() {
        #expect(AIProviderConfiguration(endpoint: "  ", defaultModel: "m").endpointURL == nil)
        #expect(AIProviderConfiguration(endpoint: "example.com/v1", defaultModel: "m").endpointURL == nil)
        #expect(AIProviderConfiguration(endpoint: " https://example.com/v1 ", defaultModel: "m").endpointURL != nil)
    }

    /// The probe has to use the same message shape as real requests: endpoints that accept a
    /// bare user turn but reject a system role are common, and testing without one would pass
    /// here and fail on the user's first question.
    @Test("the connection probe sends a system message as well as a user message")
    func connectionProbeIncludesSystemRole() async {
        let spy = ProbeSpyProvider()
        _ = await AIConnectionTest.run(
            endpoint: "https://example.com/v1/chat/completions",
            apiKey: "sk-test",
            model: "gpt-4o-mini",
            providerFactory: { _, _, _ in spy }
        )
        let roles = spy.observedRoles
        #expect(roles.contains(.system))
        #expect(roles.contains(.user))
    }

    @Test("the probe refuses obviously incomplete settings before spending a request")
    func connectionProbeValidatesFirst() async {
        let spy = ProbeSpyProvider()
        let factory: (URL, String, String) -> any LLMProviding = { _, _, _ in spy }

        for outcome in await [
            AIConnectionTest.run(endpoint: "https://e.com/v1", apiKey: "  ", model: "m", providerFactory: factory),
            AIConnectionTest.run(endpoint: "nonsense", apiKey: "sk", model: "m", providerFactory: factory),
            AIConnectionTest.run(endpoint: "https://e.com/v1", apiKey: "sk", model: " ", providerFactory: factory),
        ] {
            guard case .failure = outcome else {
                Issue.record("expected incomplete settings to fail before a request: \(outcome)")
                continue
            }
        }
        #expect(spy.observedRoles.isEmpty)
    }

    // MARK: - Fixtures

    private static let probeRequest = LLMGenerationRequest(
        messages: [LLMMessage(role: .user, content: "hi")]
    )

    private final class StreamingSpyProvider: LLMProviding, @unchecked Sendable {
        let identifier = "spy"
        let defaultModel = "spy-model"
        private(set) var streamCalled = false
        private(set) var generateCalled = false

        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            generateCalled = true
            return LLMRawResponse(content: "should not be used", provider: identifier, model: defaultModel)
        }

        func stream(_ request: LLMGenerationRequest, model: String?) -> AsyncThrowingStream<String, Error> {
            streamCalled = true
            return AsyncThrowingStream { continuation in
                continuation.yield("a")
                continuation.yield("b")
                continuation.finish()
            }
        }
    }

    private struct OneShotProvider: LLMProviding {
        let identifier = "one-shot"
        let defaultModel = "one-shot-model"
        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            LLMRawResponse(content: "whole answer", provider: identifier, model: defaultModel)
        }
    }

    private final class ProbeSpyProvider: LLMProviding, @unchecked Sendable {
        let identifier = "probe"
        let defaultModel = "probe-model"
        private(set) var observedRoles: [LLMRole] = []

        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            observedRoles = request.messages.map(\.role)
            return LLMRawResponse(content: "OK", provider: identifier, model: defaultModel)
        }
    }
}

private extension Result where Success == any LLMProviding, Failure == AIProviderAssembly.Unavailable {
    var failureReason: AIProviderAssembly.Unavailable? {
        guard case let .failure(reason) = self else { return nil }
        return reason
    }
}

private final class DeepSeekGenerationFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.deepseek.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let events = [
            #"data: {"model":"deepseek-flash","choices":[{"delta":{"reasoning_content":"private reasoning"},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"content":"Complete "},"finish_reason":null}]}"#,
            #"data: {"choices":[{"delta":{"content":"answer"},"finish_reason":"stop"}],"usage":{"completion_tokens":100,"completion_tokens_details":{"reasoning_tokens":80}}}"#,
            "data: [DONE]"
        ]
        for event in events { client?.urlProtocol(self, didLoad: Data((event + "\n\n").utf8)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
