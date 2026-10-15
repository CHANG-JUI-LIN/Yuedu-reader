//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// Sources/ChatBookCore/Assistant/LLMProvider.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
import Foundation

/// A turn's author, mirroring the OpenAI chat protocol every BYOK endpoint speaks.
enum LLMRole: String, Codable, Hashable, Sendable {
    case system
    case user
    case assistant
}

/// One message in a conversation.
struct LLMMessage: Codable, Hashable, Sendable {
    let role: LLMRole
    let content: String

    init(role: LLMRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// A generation request. The caller places retrieved text in data messages; the provider stays a transport.
/// How hard a thinking model thinks before it answers. `off` turns thinking off: the
/// mechanical features (翻譯, 查詞, 書架整理, chapter digests, 人物 extraction) ask for it, as
/// thinking only makes them slower and eats the output allowance (maintainer, 2026-10-15).
enum LLMReasoningEffort: String, Sendable { case off, low, high, max }

struct LLMGenerationRequest: Sendable {
    /// The output budget — reasoning plus answer — of a request that sets none, the same a
    /// question's answer gets. It was 1024: a 整章翻譯 batch of 2,000 characters cannot fit
    /// in that, nor can a thinking model's reasoning, so every batch came back `length`, shown
    /// as 「AI 回覆被截斷」. 查詞, summary digests and 書架整理 sent no budget either.
    static let defaultMaxTokens = 16_384

    let messages: [LLMMessage]
    let maxTokens: Int?
    let temperature: Double?
    let topP: Double?
    let reasoningEffort: LLMReasoningEffort?

    init(
        messages: [LLMMessage],
        maxTokens: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        reasoningEffort: LLMReasoningEffort? = nil
    ) {
        self.messages = messages
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.topP = topP
        self.reasoningEffort = reasoningEffort
    }
}

/// What the endpoint said, plus who said it — kept for provenance on every stored answer.
struct LLMRawResponse: Sendable {
    let content: String
    let provider: String
    let model: String

    let finishReason: String?
    let usage: LLMUsage?
    let httpStatus: Int?

    init(content: String, provider: String, model: String, finishReason: String? = nil, usage: LLMUsage? = nil, httpStatus: Int? = nil) {
        self.finishReason = finishReason
        self.usage = usage
        self.httpStatus = httpStatus
        self.content = content
        self.provider = provider
        self.model = model
    }
}

struct LLMUsage: Codable, Sendable {
    struct CompletionDetails: Codable, Sendable {
        let reasoningTokens: Int?
        enum CodingKeys: String, CodingKey { case reasoningTokens = "reasoning_tokens" }
    }
    var completionTokensDetails: CompletionDetails? = nil
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens", completionTokens = "completion_tokens", totalTokens = "total_tokens"
        case completionTokensDetails = "completion_tokens_details"
    }
}

extension LLMRawResponse {
    func validateCompletion() throws {
        if finishReason == "length" { throw LLMError.incompleteOutput }
        if finishReason == "content_filter" { throw LLMError.filteredOutput }
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.emptyOutput }
    }
}

/// Where an answer got a claim from: the chunk, the quoted evidence, and a reading position
/// the reader can actually jump to.
///
/// The position is Yuedu's own `(spineIndex, charOffset)` rather than a global page index —
/// pages shift when chapters load, so a page number would not survive the trip.
struct LLMCitation: Codable, Hashable, Sendable {
    let chunkID: String
    var sourceVersion: String? = nil
    var coordinateUnit: String? = nil
    let quote: String
    let spineIndex: Int
    let charOffset: Int
    /// Chapter title for display, when the index could resolve one.
    let sectionTitle: String?

    init(chunkID: String, quote: String, spineIndex: Int, charOffset: Int, sectionTitle: String? = nil) {
        self.chunkID = chunkID
        self.quote = quote
        self.spineIndex = spineIndex
        self.charOffset = charOffset
        self.sectionTitle = sectionTitle
    }
}

/// A finished answer with its citations and provenance.
///
/// `hasEvidence == false` means retrieval found nothing — the UI must say so rather than
/// present an unsourced answer as if it came from the book.
struct LLMGenerationResult: Sendable {
    let content: String
    let citations: [LLMCitation]
    let provider: String
    let model: String
    let promptVersion: String
    let hasEvidence: Bool
    var selfAssessment: AISelfAssessment? = nil
    var provenance: AIChatProvenance? = nil
    var notices: [String] = []

    init(
        content: String,
        citations: [LLMCitation],
        provider: String,
        model: String,
        promptVersion: String,
        hasEvidence: Bool
    ) {
        self.content = content
        self.citations = citations
        self.provider = provider
        self.model = model
        self.promptVersion = promptVersion
        self.hasEvidence = hasEvidence
    }
}

/// Classified so the UI can say what the user should do about it, rather than surfacing a
/// raw `URLError` number.
enum LLMError: Error, Sendable, Equatable, LocalizedError {
    case incompleteOutput
    case filteredOutput
    case emptyOutput
    case invalidSchema
    case unauthorized
    case rateLimited
    case networkError(String)
    case providerError(String)

    var errorDescription: String? {
        switch self {
        case .incompleteOutput: return localized("AI 回覆被截斷，未儲存本次結果")
        case .filteredOutput: return localized("AI 服務未提供完整回覆")
        case .emptyOutput: return localized("AI 回覆為空，未儲存本次結果")
        case .invalidSchema: return localized("AI 回覆格式錯誤，未儲存本次結果")
        case .unauthorized:
            return localized("API Key 無效或已過期")
        case .rateLimited:
            return localized("請求過於頻繁，請稍後再試")
        case let .networkError(detail):
            return String(format: localized("網路錯誤：%@"), detail)
        case let .providerError(detail):
            return String(format: localized("AI 服務返回錯誤：%@"), detail)
        }
    }
}

/// A language-model backend.
///
/// Deliberately small and transport-shaped: the agentic loop, retrieval and prompt building
/// all sit above it. That is what keeps a future Apple backend — `FoundationModels` exposes
/// `LanguageModel` / `LanguageModelExecutor` as conformable protocols from iOS 27 — a matter
/// of adding one conformance rather than rewriting the assistant.
protocol LLMProviding: Sendable {
    /// Stable identifier for provenance and display, e.g. `"openai-compatible"`.
    var identifier: String { get }
    /// Model used when a request does not name one.
    var defaultModel: String { get }
    /// One-shot generation. Transport failures arrive as `LLMError`.
    func generate(_ request: LLMGenerationRequest, model: String?) async throws -> LLMRawResponse
    /// Incremental generation. Yields non-empty content deltas in arrival order; terminating
    /// the stream cancels the underlying task.
    func stream(_ request: LLMGenerationRequest, model: String?) -> AsyncThrowingStream<String, Error>
}

extension LLMProviding {
    func generate(_ request: LLMGenerationRequest) async throws -> LLMRawResponse {
        try await generate(request, model: nil)
    }

    /// Non-streaming backends are legal: this yields the whole answer once.
    ///
    /// Callers must reach `stream` through the single-argument overload below or pass `model:`
    /// explicitly. A default argument declared *here* would bind statically to this extension
    /// and silently bypass a concrete provider's real streaming implementation — there is a
    /// regression test for exactly that.
    func stream(_ request: LLMGenerationRequest, model: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let raw = try await self.generate(request, model: model)
                    try raw.validateCompletion()
                    continuation.yield(raw.content)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func stream(_ request: LLMGenerationRequest) -> AsyncThrowingStream<String, Error> {
        stream(request, model: nil)
    }
}
