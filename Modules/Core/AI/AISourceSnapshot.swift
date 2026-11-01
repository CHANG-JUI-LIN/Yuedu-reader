import CryptoKit
import Foundation

/// Digests the exact UTF-8 bytes; chapter order and extraction status are part of identity.
struct AISourceManifest: Codable, Hashable, Sendable {
    enum Availability: String, Codable, Sendable {
        case available, notDownloaded, extractionFailed, unsupported
    }
    struct Chapter: Codable, Hashable, Sendable {
        let id: String
        let order: Int
        let titleDigest: String
        let status: Availability
        let digest: String?
        let utf16Length: Int
    }
    let transformationVersion: String
    let chapters: [Chapter]
    var identifier: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding this fixed value-only schema cannot fail.
        return Self.digest((try! encoder.encode(self)))
    }
    static func digest(_ text: String) -> String { digest(Data(text.utf8)) }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Offsets are UTF-16 boundaries in the indexed source, never percentages or layout offsets.
struct AIReadingBoundary: Codable, Hashable, Sendable {
    let sourceVersion: String
    let sectionID: String
    let spineIndex: Int
    let utf16Offset: Int
    var wholeBook = false
    let coordinateUnit: String = "sourceUTF16"

    // Keep encoding the fixed unit while decoding always uses the constant above.
    // Explicit keys preserve the existing on-disk format and decoding behavior.
    private enum CodingKeys: String, CodingKey {
        case sourceVersion, sectionID, spineIndex, utf16Offset, wholeBook, coordinateUnit
    }

    func contains(_ chunk: AIContentChunk) -> Bool {
        guard chunk.sourceVersion == sourceVersion else { return false }
        return allows(chunk.end)
    }
    func allows(_ end: AIChunkLocation) -> Bool {
        wholeBook || end.spineIndex < spineIndex ||
            (end.spineIndex == spineIndex && end.charOffset <= utf16Offset)
    }
    func contains(_ earlier: AIReadingBoundary) -> Bool {
        sourceVersion == earlier.sourceVersion &&
            (wholeBook || (!earlier.wholeBook && allows(.init(spineIndex: earlier.spineIndex, charOffset: earlier.utf16Offset, progress: 0))))
    }
}

/// Exact matches only. No fuzzy guess can authorize a spoiler boundary or citation jump.
enum AITextCoordinates {
    static func characterToUTF16(_ offset: Int, in text: String) -> Int {
        text.index(text.startIndex, offsetBy: max(0, min(offset, text.count))).utf16Offset(in: text)
    }
    static func prefix(_ text: String, throughUTF16 offset: Int) -> String {
        var end = text.startIndex
        for index in text.indices {
            let next = text.index(after: index)
            guard next.utf16Offset(in: text) <= offset else { break }
            end = next
        }
        return String(text[..<end])
    }
    static func uniqueRange(of quote: String, in text: String) -> Range<String.Index>? {
        guard !quote.isEmpty, let range = text.range(of: quote, options: .literal),
              text.indices.contains(range.lowerBound),
              range.upperBound == text.endIndex || text.indices.contains(range.upperBound)
        else { return nil }
        // Search from the next source character, not the end of the first match:
        // overlapping occurrences (e.g. "aa" in "aaa") are ambiguous too.
        let next = text.index(after: range.lowerBound)
        guard text.range(of: quote, options: .literal, range: next..<text.endIndex) == nil else { return nil }
        return range
    }
    private struct Unit {
        let start: Int
        let end: Int
        let normalizedOffset: Int
    }
    private struct AlignedText {
        let text: String
        let units: [Unit]
        init(_ original: String) {
            var text = "", units: [Unit] = []
            var offset = 0, normalizedOffset = 0
            for scalar in original.unicodeScalars {
                let count = scalar.utf16.count
                // A picture's U+FFFC is the reader's, not the book text's.
                if !CharacterSet.whitespacesAndNewlines.contains(scalar), scalar != "\u{FFFC}" {
                    units.append(.init(start: offset, end: offset + count, normalizedOffset: normalizedOffset))
                    text.unicodeScalars.append(scalar)
                    normalizedOffset += count
                }
                offset += count
            }
            self.text = text; self.units = units
        }
    }
    /// Align the complete chapter body, allowing only whitespace differences and a unique
    /// renderer-added title prefix/suffix. Repeated paragraphs retain their exact occurrence.
    /// Different or ambiguously repeated chapter bodies deliberately have no map.
    private static func alignment(from: String, to: String) -> (input: AlignedText, output: AlignedText, shift: Int)? {
        let input = AlignedText(from), output = AlignedText(to)
        guard !input.units.isEmpty, !output.units.isEmpty else { return nil }
        if input.text.utf16.elementsEqual(output.text.utf16) { return (input, output, 0) }
        if let range = uniqueRange(of: input.text, in: output.text),
           let index = output.units.firstIndex(where: { $0.normalizedOffset == range.lowerBound.utf16Offset(in: output.text) }) {
            return (input, output, index)
        }
        if let range = uniqueRange(of: output.text, in: input.text),
           let index = input.units.firstIndex(where: { $0.normalizedOffset == range.lowerBound.utf16Offset(in: input.text) }) {
            return (input, output, -index)
        }
        return nil
    }
    static func mappedRange(_ range: NSRange, from: String, to: String) -> NSRange? {
        guard range.location >= 0, range.length > 0, range.location <= Int.max - range.length,
              let inputRange = Range(range, in: from), NSRange(inputRange, in: from) == range,
              from.indices.contains(inputRange.lowerBound),
              inputRange.upperBound == from.endIndex || from.indices.contains(inputRange.upperBound) else { return nil }
        if from.utf16.elementsEqual(to.utf16) { return range }
        guard let map = alignment(from: from, to: to),
              let first = map.input.units.firstIndex(where: { $0.start >= range.location && $0.end <= NSMaxRange(range) }),
              let last = map.input.units.lastIndex(where: { $0.start >= range.location && $0.end <= NSMaxRange(range) }),
              map.output.units.indices.contains(first + map.shift), map.output.units.indices.contains(last + map.shift) else { return nil }
        let start = map.output.units[first + map.shift].start
        let end = map.output.units[last + map.shift].end
        let result = NSRange(location: start, length: end - start)
        guard let outputRange = Range(result, in: to), to.indices.contains(outputRange.lowerBound),
              outputRange.upperBound == to.endIndex || to.indices.contains(outputRange.upperBound) else { return nil }
        return result
    }

    /// When extraction and layout differ, a unique literal quote verifies the destination.
    /// This fallback can be removed once every builder supplies a source-to-layout map.
    static func citationOffset(_ citation: LLMCitation, sourceVersion: String, sourceText: String, renderedText: String) -> Int? {
        guard citation.sourceVersion == sourceVersion, citation.coordinateUnit == "sourceUTF16" else { return nil }
        guard citation.charOffset >= 0, citation.charOffset <= Int.max - citation.quote.utf16.count else { return nil }
        let range = NSRange(location: citation.charOffset, length: citation.quote.utf16.count)
        guard let swiftRange = Range(range, in: sourceText), String(sourceText[swiftRange]) == citation.quote else { return nil }
        if let mapped = mappedRange(range, from: sourceText, to: renderedText) { return mapped.location }
        return uniqueRange(of: citation.quote, in: renderedText)?.lowerBound.utf16Offset(in: renderedText)
    }
    /// Conservatively excludes the current chapter when no verified mapping exists.
    static func sourceBoundaryOffset(source: String, rendered: String?, renderedOffset: Int) -> Int {
        guard let rendered else { return 0 }
        if source.utf16.elementsEqual(rendered.utf16) { return prefix(source, throughUTF16: renderedOffset).utf16.count }
        if let map = alignment(from: rendered, to: source),
           let last = map.input.units.lastIndex(where: { $0.end <= renderedOffset }) {
            let index = last + map.shift
            if index < 0 { return 0 }
            if index >= map.output.units.count { return source.utf16.count }
            return prefix(source, throughUTF16: map.output.units[index].end).utf16.count
        }
        let read = prefix(rendered, throughUTF16: renderedOffset)
        let anchor = String(read.suffix(80))
        guard anchor.count >= 16, let range = uniqueRange(of: anchor, in: source) else { return 0 }
        return range.upperBound.utf16Offset(in: source)
    }
}

struct AILocalChapterText: Sendable {
    let text: String?
    let status: AISourceManifest.Availability
    static func extracted(_ text: String?) -> Self {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .init(text: nil, status: .extractionFailed)
        }
        return .init(text: text, status: .available)
    }
}
