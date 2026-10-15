import Foundation

/// AI 查詞: a word or short phrase explained in the sentence it was read in.
///
/// Unlike AI 解釋 it does not open the assistant: one request, answered on a card, with the
/// selection's own sentence as the only book text sent.
enum AIWordLookup {
    /// Selections up to this many characters get 查詞 in the selection menu, in place of 解釋.
    static let maximumCharacters = 20
    /// How much of the paragraph before the selection is sent along with it.
    static let leadingContext = 200
    /// How far past the selection to look for the end of its sentence.
    static let trailingContext = 120
    static let promptVersion = "wordLookup.v1"

    static func isCandidate(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximumCharacters && !trimmed.contains(where: \.isNewline)
    }

    /// The selection with what leads up to it in its paragraph, ending with the sentence that
    /// holds it — nothing further down the page, which the reader may not have read yet.
    static func context(in text: String, range: NSRange) -> String {
        let string = text as NSString
        guard range.location >= 0, range.length >= 0, NSMaxRange(range) <= string.length else { return "" }
        let paragraph = string.paragraphRange(for: range)
        var start = max(paragraph.location, range.location - leadingContext)
        if start > paragraph.location {
            // Step forward out of a character the limit cut through, staying within the limit.
            let sequence = string.rangeOfComposedCharacterSequence(at: start)
            if sequence.location < start { start = min(NSMaxRange(sequence), range.location) }
        }
        let paragraphEnd = NSMaxRange(paragraph)
        let searchEnd = min(paragraphEnd, NSMaxRange(range) + trailingContext)
        var end = searchEnd
        var index = NSMaxRange(range)
        while index < searchEnd {
            let character = string.rangeOfComposedCharacterSequence(at: index)
            if sentenceEnds.contains(string.substring(with: character)) {
                end = NSMaxRange(character)
                // Keep the closing quotes that belong to the sentence.
                while end < paragraphEnd {
                    let next = string.rangeOfComposedCharacterSequence(at: end)
                    guard closingMarks.contains(string.substring(with: next)) else { break }
                    end = NSMaxRange(next)
                }
                break
            }
            index = NSMaxRange(character)
        }
        return string.substring(with: NSRange(location: start, length: max(0, end - start)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let sentenceEnds: Set<String> = ["。", "！", "？", "!", "?", ".", "…", "；", ";"]
    private static let closingMarks: Set<String> = ["」", "』", "”", "’", "\"", "'", "）", ")", "》", "…", "。", "！", "？", "!", "?"]

    static func systemPrompt(language: AIAnswerLanguage) -> String {
        """
        你是閱讀器裡的查詞助手。讀者在書中選了一個詞或短語，請依上下文說明。
        用\(language.promptName)回答，輸出 Markdown，依序：
        - 開頭一段直接說明它在這段文字裡的意思；有指代、雙關或特殊語氣時一併說明。選取的是外文時，先給翻譯。
        - 「## \(localized("讀音"))」：中文給漢語拼音，外文給音標或假名；沒有把握就省略這一節。
        - 「## \(localized("釋義"))」：列出常見義項，標明這裡用的是哪一個。
        - 「## \(localized("例句"))」：一到兩個自然的例句。
        - 「## \(localized("出處與背景"))」：只有成語、典故、專有名詞或文化背景時才寫。
        只依上下文推斷書中用法，不要透露本書後續情節；上下文不足以判斷時直接說明。不要重複題目，不要寫開場白。
        """
    }

    static func request(term: String, context: String, bookTitle: String?, language: AIAnswerLanguage) -> LLMGenerationRequest {
        var lines: [String] = []
        if let bookTitle, !bookTitle.isEmpty { lines.append("書名：\(bookTitle)") }
        lines.append("選取：\(term)")
        lines.append("上下文：\(context.isEmpty ? term : context)")
        return LLMGenerationRequest(messages: [
            LLMMessage(role: .system, content: systemPrompt(language: language)),
            LLMMessage(role: .user, content: lines.joined(separator: "\n")),
        ], temperature: 0.3, reasoningEffort: .off)
    }
}
