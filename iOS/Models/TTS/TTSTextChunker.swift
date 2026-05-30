import Foundation

/// Splits narration text into speakable chunks shared by the HTTP and system TTS engines.
/// Breaks on sentence terminators or once a chunk reaches `targetChunkLength`, and folds
/// punctuation-only fragments back into the previous chunk so every chunk has spoken content.
enum TTSTextChunker {
    static func split(_ text: String, targetChunkLength: Int) -> [String] {
        var result: [String] = []
        var buffer = ""
        let terminators = CharacterSet(charactersIn: "。！？!?；;…\n")

        for scalar in text.unicodeScalars {
            buffer.unicodeScalars.append(scalar)
            let shouldBreak = terminators.contains(scalar) || buffer.count >= targetChunkLength
            if shouldBreak {
                appendChunk(buffer, to: &result)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        appendChunk(buffer, to: &result)
        return result
    }

    private static func appendChunk(_ text: String, to result: inout [String]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard containsSpeakableContent(trimmed) else {
            if let lastIndex = result.indices.last {
                result[lastIndex] += trimmed
            }
            return
        }
        result.append(trimmed)
    }

    private static func containsSpeakableContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
        }
    }
}
