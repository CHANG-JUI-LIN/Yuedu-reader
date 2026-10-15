import Foundation
import Testing
@testable import yuedu_app

/// Each AI feature asks for the thinking it needs (maintainer, 2026-10-15): mechanical work —
/// 翻譯, 查詞, 書架整理, chapter digests, 人物 extraction, the connection probe — runs with
/// thinking off; 問書 and the summaries' reduce steps think at high. DeepSeek thinks at high by
/// default, and `max_tokens` covers the thinking as well as the answer, so every feature that
/// asked for nothing thought hard: slow, and cut off at 16,384 tokens as 「AI 回覆被截斷」.
@Suite("AI reasoning and output budget")
struct AIReasoningBudgetTests {
    private func body(_ request: LLMGenerationRequest, host: String, model: String = "deepseek-flash") throws -> [String: Any] {
        let provider = OpenAICompatibleProvider(endpoint: URL(string: "https://\(host)/v1/chat/completions")!,
                                                apiKey: "fixture", defaultModel: model)
        let wire = try provider.makeURLRequest(for: request, model: model, stream: false)
        return try #require(try JSONSerialization.jsonObject(with: wire.httpBody!) as? [String: Any])
    }

    private func request(maxTokens: Int? = nil, effort: LLMReasoningEffort? = nil) -> LLMGenerationRequest {
        LLMGenerationRequest(messages: [.init(role: .user, content: "fixture")], maxTokens: maxTokens, reasoningEffort: effort)
    }

    // MARK: - The wire

    @Test("thinking off turns DeepSeek's thinking off and sends no effort")
    func offDisablesThinking() throws {
        for model in ["deepseek-flash", "deepseek-v4-pro", "deepseek-next"] {
            let sent = try body(request(effort: .off), host: "api.deepseek.com", model: model)
            #expect((sent["thinking"] as? [String: String])?["type"] == "disabled")
            #expect(sent["reasoning_effort"] == nil)
        }
        let high = try body(request(effort: .high), host: "api.deepseek.com", model: "deepseek-next")
        #expect((high["thinking"] as? [String: String])?["type"] == "enabled")
        #expect(high["reasoning_effort"] as? String == "high")
    }

    @Test("another service is sent neither thinking nor effort, whatever the feature asked")
    func otherServicesUnchanged() throws {
        for effort in [LLMReasoningEffort.off, .low, .high] {
            let sent = try body(request(effort: effort), host: "api.openai.com", model: "gpt-fixture")
            #expect(sent["thinking"] == nil)
            #expect(sent["reasoning_effort"] == nil)
        }
    }

    @Test("DeepSeek's output allowance is at least 64K, a larger request's kept; others keep theirs")
    func outputCeiling() throws {
        #expect(try body(request(), host: "api.deepseek.com")["max_tokens"] as? Int == OpenAICompatibleProvider.deepSeekOutputTokens)
        #expect(try body(request(maxTokens: 8_192), host: "api.deepseek.com")["max_tokens"] as? Int
                == OpenAICompatibleProvider.deepSeekOutputTokens)
        #expect(try body(request(maxTokens: 200_000), host: "api.deepseek.com")["max_tokens"] as? Int == 200_000)
        #expect(OpenAICompatibleProvider.deepSeekOutputTokens == 65_536)
        #expect(try body(request(), host: "api.openai.com")["max_tokens"] as? Int == LLMGenerationRequest.defaultMaxTokens)
        #expect(try body(request(maxTokens: 8_192), host: "api.openai.com")["max_tokens"] as? Int == 8_192)
    }

    // MARK: - Each feature

    @Test("翻譯, 查詞 and 書架整理 run with thinking off")
    func mechanicalFeaturesDoNotThink() throws {
        let translation = try AIChapterTranslation.request([.init(range: NSRange(location: 0, length: 2), terminator: nil, key: "原文")], bookTitle: nil, language: .traditionalChinese)
        #expect(translation.reasoningEffort == .off)
        let lookup = AIWordLookup.request(term: "詞", context: "上下文", bookTitle: nil, language: .traditionalChinese)
        #expect(lookup.reasoningEffort == .off)
        let organizer = try AIBookshelfOrganizer.request(books: [.init(id: UUID(), title: "書", author: "作者")],
                                                          existingGroups: [], language: .traditionalChinese)
        #expect(organizer.reasoningEffort == .off)
    }

    @Test("chapter digests do not think; the summaries made from them think at high")
    func summaries() {
        #expect(AIBookSummaryPrompt.digestEffort == .off)
        let reduce = AIBookSummaryPrompt.reduceRequest(scope: "全書", heading: "全書", items: ["第一章"], language: .traditionalChinese)
        #expect(reduce.reasoningEffort == .high)
    }

    @Test("問書's answers think at high")
    func questionsThink() async throws {
        #expect(AIQuestionEvidence.reasoningEffort == .high)
        let provider = RecordingProvider(replies: [#"{"action":"retrieve","query":"張若塵"}"#,
                                                   #"{"action":"finish","answer":"答案","citations":[]}"#])
        _ = try await AIAgenticAssistant.run(task: "測試", index: AIBookRetrievalIndex(bookID: UUID(), chunks: []),
                                             provider: provider, scope: 1.0, maxSteps: 3)
        let efforts = provider.requests.map(\.reasoningEffort)
        #expect(!efforts.isEmpty)
        #expect(efforts.allSatisfy { $0 == .high })
    }

    @Test("the connection probe does not think")
    func probe() async {
        let provider = RecordingProvider(replies: ["OK"])
        _ = await AIConnectionTest.run(endpoint: "https://example.com/v1/chat/completions", apiKey: "sk-test",
                                       model: "fixture", providerFactory: { _, _, _ in provider })
        #expect(provider.requests.map(\.reasoningEffort) == [.off])
    }

    private final class RecordingProvider: LLMProviding, @unchecked Sendable {
        let identifier = "recording"
        let defaultModel = "recording-model"
        private var replies: [String]
        private(set) var requests: [LLMGenerationRequest] = []

        init(replies: [String]) { self.replies = replies }

        func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse {
            requests.append(request)
            let reply = replies.isEmpty ? #"{"action":"finish","answer":"答案"}"# : replies.removeFirst()
            return LLMRawResponse(content: reply, provider: identifier, model: defaultModel)
        }
    }
}
