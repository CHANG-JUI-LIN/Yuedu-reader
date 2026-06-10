import Foundation

/// Splits narration text into speakable chunks shared by the HTTP and system TTS engines.
/// Breaks on sentence terminators or once a chunk reaches `targetChunkLength`, and folds
/// punctuation-only fragments back into the previous chunk so every chunk has spoken content.
enum TTSTextChunker {
    static func split(_ text: String, targetChunkLength: Int) -> [String] {
        splitWithRanges(text, targetChunkLength: targetChunkLength).map(\.text)
    }

    static func splitWithRanges(_ text: String, targetChunkLength: Int) -> [TTSChunkRange] {
        var result: [TTSChunkRange] = []
        var buffer = ""
        let terminators = CharacterSet(charactersIn: "。！？!?；;…\n")
        var bufferStart = text.startIndex

        var index = text.startIndex
        while index < text.endIndex {
            let nextIndex = text.index(after: index)
            let character = text[index]
            buffer.append(character)
            let shouldBreak = character.unicodeScalars.contains(where: terminators.contains)
                || buffer.count >= targetChunkLength
            if shouldBreak {
                appendChunk(in: bufferStart..<nextIndex, source: text, to: &result)
                buffer.removeAll(keepingCapacity: true)
                bufferStart = nextIndex
            }
            index = nextIndex
        }

        appendChunk(in: bufferStart..<text.endIndex, source: text, to: &result)
        return result
    }

    private static func appendChunk(
        in range: Range<String.Index>,
        source: String,
        to result: inout [TTSChunkRange]
    ) {
        guard range.lowerBound < range.upperBound else { return }

        var start = range.lowerBound
        var end = range.upperBound
        while start < end, source[start].unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) {
            start = source.index(after: start)
        }
        while start < end {
            let previous = source.index(before: end)
            guard source[previous].unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains) else {
                break
            }
            end = previous
        }

        guard start < end else { return }
        let trimmed = String(source[start..<end])
        guard !trimmed.isEmpty else { return }
        let sourceRange = NSRange(start..<end, in: source)
        guard containsSpeakableContent(trimmed) else {
            if let lastIndex = result.indices.last {
                let last = result[lastIndex]
                let unionStart = min(last.sourceRange.location, sourceRange.location)
                let unionEnd = max(
                    last.sourceRange.location + last.sourceRange.length,
                    sourceRange.location + sourceRange.length
                )
                result[lastIndex] = TTSChunkRange(
                    text: last.text + trimmed,
                    sourceRange: NSRange(location: unionStart, length: unionEnd - unionStart)
                )
            }
            return
        }
        result.append(TTSChunkRange(text: trimmed, sourceRange: sourceRange))
    }

    private static func containsSpeakableContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.letters.contains(scalar)
                || CharacterSet.decimalDigits.contains(scalar)
        }
    }
}
