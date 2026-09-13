import Foundation

/// Presents an open book to the chunker, whatever format it came from.
///
/// One adapter for every format is the whole point of `AIChunkableContent`: EPUB, TXT, PDF
/// text and online chapters all arrive here as `(title, plain text)` per chapter, and nothing
/// above this line knows the difference.
///
/// Progress is derived from cumulative character counts rather than chapter index, because a
/// book whose first chapter is a 200-character preface and whose second is 40,000 characters
/// would otherwise report the reader as 50% through after the preface — and progress is what
/// the spoiler boundary is measured in.
struct AIBookContentAdapter: AIChunkableContent {
    let chunkBookID: UUID
    let chunkSections: [AIChunkableSection]

    /// Character count of every chapter, and the running total before it.
    private let sectionLengths: [Int]
    private let sectionOffsets: [Int]
    private let totalLength: Int

    init(bookID: UUID, chapters: [BookChapter], textForChapter: (Int) -> String?) {
        self.chunkBookID = bookID
        var sections: [AIChunkableSection] = []
        var lengths: [Int] = []
        var offsets: [Int] = []
        var running = 0
        for (index, chapter) in chapters.enumerated() {
            // Prefer the laid-out text; fall back to the stored content for chapters the
            // reader has not rendered yet.
            let text = textForChapter(index) ?? chapter.content
            sections.append(
                AIChunkableSection(
                    id: "\(index)",
                    title: chapter.title.isEmpty ? nil : chapter.title,
                    text: text
                )
            )
            offsets.append(running)
            lengths.append(text.count)
            running += text.count
        }
        self.chunkSections = sections
        self.sectionLengths = lengths
        self.sectionOffsets = offsets
        self.totalLength = running
    }

    func chunkLocation(sectionIndex: Int, characterOffset: Int) -> AIChunkLocation? {
        guard chunkSections.indices.contains(sectionIndex) else { return nil }
        let clamped = min(max(characterOffset, 0), sectionLengths[sectionIndex])
        let progress = totalLength > 0
            ? Double(sectionOffsets[sectionIndex] + clamped) / Double(totalLength)
            : 0
        // `sectionIndex` is the spine index by construction, and `charOffset` counts from the
        // start of that chapter — the same pair `CoreTextReadingPosition` uses, so a citation
        // can be handed straight to the reader.
        return AIChunkLocation(spineIndex: sectionIndex, charOffset: clamped, progress: progress)
    }

    /// Identity of the text this adapter presents.
    ///
    /// Part of the index identity, so an index built while only five chapters were laid out
    /// is rebuilt once the rest of the book has been gathered instead of being reused.
    var contentFingerprint: String {
        "\(chunkSections.count)/\(chunkSections.filter { !$0.text.isEmpty }.count)/\(totalLength)"
    }

    /// Chapter titles for citation display, keyed the way chunks record their section.
    var sectionTitleByID: [String: String] {
        var titles: [String: String] = [:]
        for section in chunkSections {
            guard let title = section.title else { continue }
            titles[section.id] = title
        }
        return titles
    }

    /// Reading progress for a position, on the same scale the chunks use — this is what gets
    /// passed as the spoiler ceiling.
    func progress(forSpine spineIndex: Int, charOffset: Int) -> Double {
        chunkLocation(sectionIndex: spineIndex, characterOffset: charOffset)?.progress ?? 0
    }
}
