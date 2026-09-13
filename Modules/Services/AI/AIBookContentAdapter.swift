import Foundation

/// An immutable local source snapshot. Missing chapters remain manifest entries, not evidence.
struct AIBookContentAdapter: AIChunkableContent {
    let chunkBookID: UUID
    let chunkSections: [AIChunkableSection]
    let manifest: AISourceManifest
    private(set) var readingPositionVerified = false
    private(set) var readingBoundary: AIReadingBoundary?
    let contentFingerprint: String
    let acquisitionMilliseconds: Double?
    private let sectionLengths: [Int]
    private let sectionOffsets: [Int]
    private let totalLength: Int
    var sourceVersion: String? { contentFingerprint }

    init(bookID: UUID, chapters: [BookChapter],
         transformationVersion: String = "chapterPlainText.v1",
         missingStatus: [Int: AISourceManifest.Availability] = [:],
         acquisitionMilliseconds: Double? = nil,
         readingPosition: (spine: Int, utf16Offset: Int)? = nil,
         renderedText: String? = nil,
         textForChapter: (Int) -> String?) {
        chunkBookID = bookID
        self.acquisitionMilliseconds = acquisitionMilliseconds
        var sections: [AIChunkableSection] = []
        var entries: [AISourceManifest.Chapter] = []
        var lengths: [Int] = [], offsets: [Int] = []
        var running = 0
        for (index, chapter) in chapters.enumerated() {
            let supplied = textForChapter(index) ?? (chapter.content.isEmpty ? nil : chapter.content)
            let text = supplied ?? ""
            let available = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            // BookChapter.id is reconstructed on open; href is stable, order is the fallback.
            let id = chapter.href.isEmpty ? "\(chapter.index)" : chapter.href
            sections.append(.init(id: id, title: chapter.title.isEmpty ? nil : chapter.title, text: available ? text : ""))
            entries.append(.init(id: id, order: index, titleDigest: AISourceManifest.digest(chapter.title),
                status: available ? .available : (missingStatus[index] ?? (supplied == nil ? .notDownloaded : .extractionFailed)),
                digest: available ? AISourceManifest.digest(text) : nil, utf16Length: available ? text.utf16.count : 0))
            offsets.append(running)
            lengths.append(available ? text.utf16.count : 0)
            running += lengths.last!
        }
        chunkSections = sections
        manifest = .init(transformationVersion: transformationVersion, chapters: entries)
        contentFingerprint = manifest.identifier
        sectionLengths = lengths
        sectionOffsets = offsets
        totalLength = running
        if let position = readingPosition, sections.indices.contains(position.spine) {
            readingBoundary = .init(sourceVersion: contentFingerprint, sectionID: sections[position.spine].id,
                spineIndex: position.spine, utf16Offset: AITextCoordinates.sourceBoundaryOffset(
                    source: sections[position.spine].text, rendered: renderedText, renderedOffset: position.utf16Offset))
            readingPositionVerified = renderedText == sections[position.spine].text || (readingBoundary?.utf16Offset ?? 0) > 0
        } else { readingBoundary = nil }
    }

    func atReadingPosition(spine: Int, renderedOffset: Int, renderedText: String?) -> Self {
        var snapshot = self
        guard chunkSections.indices.contains(spine) else { snapshot.readingBoundary = nil; snapshot.readingPositionVerified = false; return snapshot }
        snapshot.readingBoundary = .init(sourceVersion: contentFingerprint, sectionID: chunkSections[spine].id,
            spineIndex: spine, utf16Offset: AITextCoordinates.sourceBoundaryOffset(source: chunkSections[spine].text,
                rendered: renderedText, renderedOffset: renderedOffset))
        snapshot.readingPositionVerified = renderedText == chunkSections[spine].text || (snapshot.readingBoundary?.utf16Offset ?? 0) > 0
        return snapshot
    }

    /// Chunker input is Character-based; published coordinates are source UTF-16.
    func chunkLocation(sectionIndex: Int, characterOffset: Int) -> AIChunkLocation? {
        guard chunkSections.indices.contains(sectionIndex) else { return nil }
        let offset = AITextCoordinates.characterToUTF16(characterOffset, in: chunkSections[sectionIndex].text)
        return location(spine: sectionIndex, utf16Offset: offset)
    }
    private func location(spine: Int, utf16Offset: Int) -> AIChunkLocation? {
        guard chunkSections.indices.contains(spine) else { return nil }
        let offset = min(max(0, utf16Offset), sectionLengths[spine])
        return .init(spineIndex: spine, charOffset: offset,
            progress: totalLength > 0 ? Double(sectionOffsets[spine] + offset) / Double(totalLength) : 0)
    }
    var sectionTitleByID: [String: String] {
        Dictionary(chunkSections.compactMap { section in section.title.map { (section.id, $0) } }, uniquingKeysWith: { first, _ in first })
    }
    func progress(forSpine spineIndex: Int, charOffset: Int) -> Double {
        location(spine: spineIndex, utf16Offset: charOffset)?.progress ?? 0
    }
    func boundary(wholeBook: Bool = false) -> AIReadingBoundary {
        var boundary = readingBoundary ?? .init(sourceVersion: contentFingerprint,
            sectionID: chunkSections.first?.id ?? "", spineIndex: 0, utf16Offset: 0)
        boundary.wholeBook = wholeBook
        return boundary
    }
    func sections(in boundary: AIReadingBoundary) -> [AIChunkableSection] {
        guard boundary.sourceVersion == contentFingerprint else { return [] }
        return chunkSections.enumerated().compactMap { index, section in
            if boundary.wholeBook || index < boundary.spineIndex { return section }
            guard index == boundary.spineIndex else { return nil }
            return .init(id: section.id, title: section.title,
                text: AITextCoordinates.prefix(section.text, throughUTF16: boundary.utf16Offset))
        }
    }
}
