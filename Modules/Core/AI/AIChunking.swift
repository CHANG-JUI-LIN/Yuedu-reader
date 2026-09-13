//
// Derived from ChatBook (https://github.com/bsnmldb/ChatBook),
// Sources/ChatBookCore/Text/Chunking.swift — Apache License 2.0.
// See NOTICE at the repository root.
//
import Foundation

/// Where a chunk sits in the book, in the only coordinates Yuedu treats as stable.
///
/// `(spineIndex, charOffset)`, never a global page index — CLAUDE.md's first critical
/// convention, because pages shift as chapters load. Offsets are source UTF-16; progress is UI-only.
struct AIChunkLocation: Codable, Hashable, Sendable {
    let spineIndex: Int
    let charOffset: Int
    let progress: Double

    init(spineIndex: Int, charOffset: Int, progress: Double) {
        self.spineIndex = spineIndex
        self.charOffset = charOffset
        self.progress = min(max(progress, 0), 1)
    }
}

/// One retrievable slice of a book.
struct AIContentChunk: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var sourceVersion: String? = nil
    var bookID: UUID
    var sectionID: String
    var ordinal: Int
    var text: String
    var start: AIChunkLocation
    var end: AIChunkLocation
    var progressStart: Double
    var progressEnd: Double

    init(
        id: String,
        bookID: UUID,
        sectionID: String,
        ordinal: Int,
        text: String,
        start: AIChunkLocation,
        end: AIChunkLocation
    ) {
        self.id = id
        self.bookID = bookID
        self.sectionID = sectionID
        self.ordinal = ordinal
        self.text = text
        self.start = start
        self.end = end
        self.progressStart = start.progress
        self.progressEnd = max(start.progress, end.progress)
    }
}

/// A chapter reduced to what chunking needs: a stable id, plain text, and a title for display.
struct AIChunkableSection: Sendable, Hashable {
    let id: String
    let title: String?
    let text: String

    init(id: String, title: String? = nil, text: String) {
        self.id = id
        self.title = title
        self.text = text
    }
}

/// Anything that can be sliced for retrieval, with the book format factored out.
///
/// This is the seam: EPUB, TXT and online chapters each get one adapter, and the chunker,
/// the index and every feature above them stay untouched.
protocol AIChunkableContent: Sendable {
    /// Stable book id — chunk ids are built from it and the index is stored per book.
    var chunkBookID: UUID { get }
    var sourceVersion: String? { get }
    /// Ordered chapters. Empty ones are skipped.
    var chunkSections: [AIChunkableSection] { get }
    /// A reading position for an offset inside a chapter. Returning `nil` declares that this
    /// position cannot be navigated back to, and the chunk is dropped rather than cited with
    /// a location that goes nowhere.
    func chunkLocation(sectionIndex: Int, characterOffset: Int) -> AIChunkLocation?
}

extension AIChunkableContent {
    var sourceVersion: String? { nil }
}

/// Splits a book into overlapping chunks along natural boundaries.
///
/// Recursive within a chapter (paragraph → sentence → clause → hard cut) and never across
/// chapters, because a chunk spanning two chapters cites a position in neither.
struct AIPublicationChunker: Sendable {
    var maximumCharacters: Int
    var overlapCharacters: Int
    /// Floor for the **final** chunk of a chapter. A trailing sliver retrieves badly, so it is
    /// folded back into the chunk before it — letting that one exceed `maximumCharacters` by
    /// at most `minimumCharacters` is the cheaper trade. `0` disables folding.
    var minimumCharacters: Int

    /// Encoded into the index identifier: change this and every stored index is rebuilt
    /// instead of being queried with chunks that were cut a different way.
    static let version = "recursive.utf16.v3"

    init(maximumCharacters: Int = 800, overlapCharacters: Int = 120, minimumCharacters: Int = 0) {
        precondition(maximumCharacters > 0)
        precondition(overlapCharacters >= 0 && overlapCharacters < maximumCharacters)
        precondition(
            minimumCharacters >= 0 && minimumCharacters < maximumCharacters,
            "minimumCharacters must be < maximumCharacters, or no chunk can satisfy both bounds"
        )
        self.maximumCharacters = maximumCharacters
        self.overlapCharacters = overlapCharacters
        self.minimumCharacters = minimumCharacters
    }

    func chunks(from content: any AIChunkableContent) -> [AIContentChunk] {
        var result: [AIContentChunk] = []
        var ordinal = 0
        for (sectionIndex, section) in content.chunkSections.enumerated() where !section.text.isEmpty {
            let (sectionChunks, nextOrdinal) = chunks(
                inSectionAt: sectionIndex,
                content: content,
                startingOrdinal: ordinal
            )
            result.append(contentsOf: sectionChunks)
            ordinal = nextOrdinal
        }
        return result
    }

    /// One chapter at a time, so an index build can embed as it goes rather than holding the
    /// whole of a 10 MB web novel in memory before the first vector is computed.
    ///
    /// `startingOrdinal` keeps ids identical to what `chunks(from:)` produces, which is what
    /// lets a rebuild reuse vectors it already has.
    func chunks(
        inSectionAt sectionIndex: Int,
        content: any AIChunkableContent,
        startingOrdinal: Int
    ) -> (chunks: [AIContentChunk], nextOrdinal: Int) {
        let section = content.chunkSections[sectionIndex]
        var result: [AIContentChunk] = []
        var ordinal = startingOrdinal
        guard !section.text.isEmpty else { return ([], ordinal) }
        let bookID = content.chunkBookID
        let units = Self.leafUnits(of: section.text, maximum: maximumCharacters)
        let spans = Self.mergedSpans(
            units: units,
            maximum: maximumCharacters,
            overlap: overlapCharacters,
            minimum: minimumCharacters
        )
        let characters = Array(section.text)
        for span in spans {
            let chunkText = String(characters[span.start..<span.end])
            guard !chunkText.isEmpty,
                  let start = content.chunkLocation(sectionIndex: sectionIndex, characterOffset: span.start),
                  let end = content.chunkLocation(sectionIndex: sectionIndex, characterOffset: span.end)
            else { continue }
            result.append(
                AIContentChunk(
                    id: "\(bookID.uuidString):\(section.id):\(ordinal)",
                    bookID: bookID,
                    sectionID: section.id,
                    ordinal: ordinal,
                    text: chunkText,
                    start: start,
                    end: end
                )
            )
            result[result.count - 1].sourceVersion = content.sourceVersion
            ordinal += 1
        }
        return (result, ordinal)
    }

    // MARK: - Recursive splitting inside one chapter

    /// Coarse to fine. Each level splits on its own separators; a piece that still exceeds the
    /// maximum is handed to the next level, and a level with no separators present falls
    /// through without splitting anything.
    private static let separators: [[Character]] = [
        ["\n"],
        ["。", "！", "？", ".", "!", "?"],
        ["，", ",", "；", ";"],
    ]

    private struct Span { let start: Int; let end: Int }

    private static func leafUnits(of text: String, maximum: Int) -> [Span] {
        guard !text.isEmpty else { return [] }
        return split(Array(text), maximum: maximum, level: 0)
    }

    private static func split(_ characters: [Character], maximum: Int, level: Int) -> [Span] {
        if characters.count <= maximum { return [Span(start: 0, end: characters.count)] }
        if level >= separators.count {
            // Out of separators: cut on the limit itself.
            var spans: [Span] = []
            var offset = 0
            while offset < characters.count {
                let end = min(offset + maximum, characters.count)
                spans.append(Span(start: offset, end: end))
                offset = end
            }
            return spans
        }
        let separatorSet = Set(separators[level])
        var segments: [Span] = []
        var segmentStart = 0
        for (offset, character) in characters.enumerated() where separatorSet.contains(character) {
            // The separator belongs to the piece it ends.
            segments.append(Span(start: segmentStart, end: offset + 1))
            segmentStart = offset + 1
        }
        if segmentStart < characters.count {
            segments.append(Span(start: segmentStart, end: characters.count))
        }
        guard segments.count > 1 else { return split(characters, maximum: maximum, level: level + 1) }
        var out: [Span] = []
        for segment in segments {
            let piece = Array(characters[segment.start..<segment.end])
            let inner = split(piece, maximum: maximum, level: level + 1)
            out.append(contentsOf: inner.map {
                Span(start: segment.start + $0.start, end: segment.start + $0.end)
            })
        }
        return out
    }

    // MARK: - Greedy merge with overlap

    /// Packs leaf units greedily up to `maximum`, then starts the next chunk far enough back
    /// to carry roughly `overlap` characters of context — on unit boundaries, since the
    /// recursive split already put those in sensible places.
    private static func mergedSpans(units: [Span], maximum: Int, overlap: Int, minimum: Int) -> [Span] {
        guard !units.isEmpty else { return [] }
        var out: [Span] = []
        var i = 0
        while i < units.count {
            var j = i
            while j + 1 < units.count, units[j + 1].end - units[i].start <= maximum { j += 1 }
            out.append(Span(start: units[i].start, end: units[j].end))
            if j == i {
                i = j + 1 // A single unit filled the chunk; nothing to overlap with.
            } else if j + 1 >= units.count {
                i = j + 1 // At the end — carrying back here would just repeat the tail.
            } else {
                // Walk back from j while the carried span still fits the overlap budget, so
                // the next chunk opens with as much context as it can hold.
                var k = j
                while k > i + 1, units[j].end - units[k - 1].start <= overlap { k -= 1 }
                i = (units[j].end - units[k].start <= overlap && k > i) ? k : j + 1
            }
        }
        if minimum > 0 {
            // Loop rather than a single check: several chapters end in a run of short lines.
            while out.count >= 2, (out[out.count - 1].end - out[out.count - 1].start) < minimum {
                let tail = out.removeLast()
                let previous = out.removeLast()
                out.append(Span(start: previous.start, end: tail.end))
            }
        }
        return out
    }
}
