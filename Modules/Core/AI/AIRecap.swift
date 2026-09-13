//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// App/Assistant/Recap/RecapModel.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
import Foundation

/// 前情提要 — what happened up to where the reader is.
///
/// Chapter-agnostic on purpose: a serialised web novel whose "chapters" are arbitrary and a
/// book with none at all both work, because the recap is built from retrieved passages under
/// the progress ceiling rather than from the last N chapters.
struct AIRecap: Sendable, Equatable, Codable {
    let text: String
    /// Reading progress when this was generated — half of the reuse decision.
    let progress: Double
    let generatedAt: Date
    let provider: String
    let model: String
    let promptVersion: String

    static let currentPromptVersion = "yuedu.recap.v1"

    /// Reuse thresholds.
    ///
    /// Regenerating a recap costs the user money on their own API key, so a recap is reused
    /// unless the reader has actually moved: 5% of the book is roughly a chapter or two of a
    /// long novel, and a day is long enough that "remind me where I was" is a fresh question
    /// even if nothing was read.
    static let reuseProgressDelta = 0.05
    static let reuseTimeDelta: TimeInterval = 24 * 60 * 60

    /// Whether a stored recap can stand in for one at `progress`.
    ///
    /// A prompt-version change never reuses: the old text was produced under different rules,
    /// and presenting it as the current recipe's output would hide the change.
    static func canReuse(
        _ stored: AIRecap?,
        atProgress progress: Double,
        now: Date = Date()
    ) -> Bool {
        guard let stored,
              !stored.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              stored.promptVersion == currentPromptVersion
        else { return false }
        // Reading backwards is not a reason to regenerate: the recap already covers it.
        let progressDelta = progress - stored.progress
        guard progressDelta < reuseProgressDelta else { return false }
        return now.timeIntervalSince(stored.generatedAt) < reuseTimeDelta
    }

    static let task = """
    根據提供的已讀片段，寫一段「前情提要」，幫讀者想起讀到哪裡了。
    要求：150–300 字繁體中文；連貫敘述，不要列點、不要引用標記；只依據提供的已讀片段，不要編造；絕對不要提到讀者還沒讀到的後續。
    """

    static func systemPrompt(for chunks: [AIContentChunk]) -> String {
        let passages = chunks
            .map(\.text)
            .joined(separator: "\n\n")
        return """
        你是閱讀助手。

        \(task)

        已讀片段：
        \(passages)
        """
    }

    static func request(chunks: [AIContentChunk], bookTitle: String) -> LLMGenerationRequest {
        LLMGenerationRequest(
            messages: [
                LLMMessage(role: .system, content: systemPrompt(for: chunks)),
                // The title is data, not part of the instructions.
                LLMMessage(
                    role: .user,
                    content: String(format: localized("請為《%@》寫前情提要。"), bookTitle)
                ),
            ],
            maxTokens: 700,
            temperature: 0.3,
            topP: 1.0
        )
    }

    /// Builds a recap from passages already filtered to the reader's progress.
    ///
    /// - Important: `chunks` must come through `AISpoilerSafeFilter`. This does not re-filter,
    ///   because there would then be two places that decide what "already read" means.
    static func generate(
        chunks: [AIContentChunk],
        bookTitle: String,
        progress: Double,
        provider: any LLMProviding,
        now: Date = Date()
    ) async throws -> AIRecap? {
        guard !chunks.isEmpty else { return nil }
        let raw = try await provider.generate(request(chunks: chunks, bookTitle: bookTitle))
        let text = AISelfAssessment.userVisibleText(raw.content)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return AIRecap(
            text: text,
            progress: progress,
            generatedAt: now,
            provider: raw.provider,
            model: raw.model,
            promptVersion: currentPromptVersion
        )
    }
}
