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
    /// When extraction and layout differ, a unique literal quote verifies the destination.
    /// This fallback can be removed once every builder supplies a source-to-layout map.
    static func citationOffset(_ citation: LLMCitation, sourceVersion: String, sourceText: String, renderedText: String) -> Int? {
        guard citation.sourceVersion == sourceVersion, citation.coordinateUnit == "sourceUTF16" else { return nil }
        if sourceText == renderedText {
            let range = NSRange(location: citation.charOffset, length: citation.quote.utf16.count)
            guard let swiftRange = Range(range, in: sourceText), String(sourceText[swiftRange]) == citation.quote else { return nil }
            return citation.charOffset
        }
        return uniqueRange(of: citation.quote, in: renderedText)?.lowerBound.utf16Offset(in: renderedText)
    }
    /// Conservatively excludes the current chapter when no verified mapping exists.
    static func sourceBoundaryOffset(source: String, rendered: String?, renderedOffset: Int) -> Int {
        guard let rendered else { return 0 }
        if source == rendered { return prefix(source, throughUTF16: renderedOffset).utf16.count }
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
