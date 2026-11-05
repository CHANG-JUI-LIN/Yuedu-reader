import Foundation

/// Remaps rendered UTF-16 locations through source coordinates. A location is resolved to
/// the source line it sits on (identified by where that line ends in the file, which every
/// index agrees on) and its column, then found again in whichever new chapter holds that
/// line, as body text or as its heading. Text comparisons verify each chapter's rendering
/// at a source-selected offset; they never search the book for an arbitrary matching quote
/// (which could occur in multiple chapters).
struct TXTLocationMigration {
    enum Failure: Error {
        case invalidIndex, missingSourceIdentity, unsupportedTextTransform, invalidPosition
    }

    /// Where a location is in the file, whatever index it was read through.
    struct SourceAnchor: Equatable {
        /// The byte where the location's line ends (its line break, or the chapter's end).
        let lineEnd: Int
        /// UTF-16 offset into the line's trimmed text.
        let column: Int
        /// The location was before a chapter's heading text (the title's leading spacer, a
        /// chapter's very start): it stays at its chapter's start when it lands on a heading.
        let atChapterStart: Bool
    }

    let file: TXTMappedTextFile
    let oldIndexes: [TXTMappedChapterIndex]
    let newIndexes: [TXTMappedChapterIndex]
    /// Whether the old rendering ran Aozora markup removal: v7 indexes did, v5/v6 did not.
    let oldParsesAozoraMarkup: Bool

    init(file: TXTMappedTextFile, oldIndexes: [TXTMappedChapterIndex], newIndexes: [TXTMappedChapterIndex],
         oldParsesAozoraMarkup: Bool = false) throws {
        for indexes in [oldIndexes, newIndexes] {
            var previousEnd = 0
            for (ordinal, entry) in indexes.enumerated() {
                guard entry.index == ordinal, entry.byteRange.lowerBound >= previousEnd,
                      entry.byteRange.upperBound <= file.byteCount else { throw Failure.invalidIndex }
                previousEnd = entry.byteRange.upperBound
            }
            guard !indexes.isEmpty else { throw Failure.invalidIndex }
        }
        self.file = file
        self.oldIndexes = oldIndexes
        self.newIndexes = newIndexes
        self.oldParsesAozoraMarkup = oldParsesAozoraMarkup
    }

    /// The new chapter with the same source and title as an old one, whose locations carry
    /// over unchanged when their rendering is unchanged too.
    func identicalChapter(for oldIndex: Int) -> Int? {
        guard oldIndexes.indices.contains(oldIndex) else { return nil }
        let old = oldIndexes[oldIndex]
        return newIndexes.first { $0.byteRange == old.byteRange && $0.title == old.title }?.index
    }

    func map(_ position: CoreTextReadingPosition, oldRendered: String, newRendered: String) throws -> CoreTextReadingPosition {
        let anchor = try anchor(for: position, oldRendered: oldRendered)
        return try self.position(for: anchor, in: try destination(for: anchor), newRendered: newRendered)
    }

    // MARK: - Old location → source

    func anchor(for position: CoreTextReadingPosition, oldRendered: String) throws -> SourceAnchor {
        guard oldIndexes.indices.contains(position.spineIndex) else { throw Failure.invalidPosition }
        let old = oldIndexes[position.spineIndex]
        let offset = position.charOffset
        let rendered = oldRendered as NSString
        guard offset >= 0, offset <= rendered.length else { throw Failure.invalidPosition }
        let lines = try paragraphLines(in: old.byteRange)
        let body = lines.map { $0.text + "\n" }.joined()
        let projection = oldParsesAozoraMarkup ? AozoraMarkupParser.parse(body) : nil
        let renderedBody = projection?.plainText ?? body
        // Rendering can introduce title markers or remove/rewrite body content.
        // Only use the source projection when the actual builder proves it.
        guard oldRendered.hasSuffix(renderedBody) else { throw Failure.unsupportedTextTransform }
        let titleLength = rendered.length - (renderedBody as NSString).length

        if offset >= titleLength, !(offset == 0 && lines.isEmpty) {
            let displayed = offset - titleLength
            let source = projection?.sourceOffset(forDisplayedOffset: displayed) ?? displayed
            var start = 0
            for line in lines {
                let length = (line.text as NSString).length
                if source <= start + length {
                    return SourceAnchor(lineEnd: line.end, column: source - start, atChapterStart: false)
                }
                start += length + 1
            }
            // At the very end of the body (after its last line break).
            let last = try lastLine(lines)
            return SourceAnchor(lineEnd: last.end, column: (last.text as NSString).length, atChapterStart: false)
        }

        // In the heading: its source line, when the title was read from one.
        let titleRange = Self.range(of: old.title, in: rendered.substring(to: titleLength))
        if let heading = headingLine(before: old.byteRange.lowerBound, after: gapStart(of: position.spineIndex, in: oldIndexes)),
           let inLine = heading.text.range(of: old.title).map({ NSRange($0, in: heading.text).location }) {
            let titleOffset = titleRange.map { min(max(0, offset - $0.location), $0.length) } ?? 0
            return SourceAnchor(lineEnd: heading.end, column: inLine + titleOffset,
                                atChapterStart: offset == 0 || (titleRange.map { offset < $0.location } ?? true))
        }
        // A synthesized title (Preface, Section N, a split chapter's (2)): its body's start.
        if let first = lines.first {
            return SourceAnchor(lineEnd: first.end, column: 0, atChapterStart: true)
        }
        return SourceAnchor(lineEnd: old.byteRange.lowerBound, column: 0, atChapterStart: true)
    }

    // MARK: - Source → new location

    /// The new chapter that holds an anchor's line, in its body or as its heading.
    func destination(for anchor: SourceAnchor) throws -> Int {
        // The last chapter whose heading starts at or before the line end.
        var low = 0, high = newIndexes.count - 1, found = -1
        while low <= high {
            let mid = (low + high) / 2
            if gapStart(of: mid, in: newIndexes) <= anchor.lineEnd {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard found >= 0 else { throw Failure.missingSourceIdentity }
        // A line ending exactly where an empty chapter's heading begins belongs before it.
        while found > 0, gapStart(of: found, in: newIndexes) == anchor.lineEnd,
              newIndexes[found - 1].byteRange.upperBound >= anchor.lineEnd,
              !newIndexes[found - 1].byteRange.isEmpty {
            found -= 1
        }
        return found
    }

    func position(for anchor: SourceAnchor, in destination: Int, newRendered: String) throws -> CoreTextReadingPosition {
        let new = newIndexes[destination]
        let rendered = newRendered as NSString
        let lines = try paragraphLines(in: new.byteRange)
        let body = lines.map { $0.text + "\n" }.joined()
        let projection = AozoraMarkupParser.parse(body)
        guard newRendered.hasSuffix(projection.plainText) else { throw Failure.unsupportedTextTransform }
        let titleLength = rendered.length - (projection.plainText as NSString).length

        let mapped: Int
        if anchor.lineEnd < new.byteRange.lowerBound || (lines.isEmpty && anchor.lineEnd <= new.byteRange.lowerBound) {
            // The line is this chapter's heading.
            let titleRange = Self.range(of: new.title, in: rendered.substring(to: titleLength))
            if anchor.atChapterStart || titleRange == nil {
                mapped = 0
            } else if let titleRange,
                      let heading = headingLine(before: new.byteRange.lowerBound, after: gapStart(of: destination, in: newIndexes)),
                      let inLine = heading.text.range(of: new.title).map({ NSRange($0, in: heading.text).location }) {
                mapped = titleRange.location + min(max(0, anchor.column - inLine), titleRange.length)
            } else {
                mapped = 0
            }
        } else {
            var start = 0
            var resolved: Int?
            for line in lines {
                let length = (line.text as NSString).length
                if line.end == anchor.lineEnd {
                    resolved = start + min(anchor.column, length)
                    break
                }
                if line.end > anchor.lineEnd {
                    // A line split mid-way by an old size cut (no line break within the cut's
                    // lookahead) has no common end: land on the start of the line holding it.
                    resolved = start
                    break
                }
                start += length + 1
            }
            mapped = titleLength + projection.displayedOffset(forSourceOffset: resolved ?? (body as NSString).length)
        }
        guard mapped >= 0, mapped <= rendered.length else { throw Failure.invalidPosition }
        return .init(spineIndex: destination, charOffset: mapped)
    }

    /// A title's UTF-16 range in a rendered heading, as the reader's offsets count.
    private static func range(of title: String, in heading: String) -> NSRange? {
        let found = (heading as NSString).range(of: title)
        return found.location == NSNotFound ? nil : found
    }

    // MARK: - Source lines

    /// One paragraph as the builder renders it, and where its source line ends.
    struct Line {
        let text: String
        let end: Int
    }

    /// The range's paragraphs, line by line, proven equal to the builder's own paragraph
    /// split of the whole range (which also strips HTML; such text is not mapped).
    func paragraphLines(in range: Range<Int>) throws -> [Line] {
        var lines: [Line] = []
        var lineStart = range.lowerBound
        var cursor = range.lowerBound
        let step = isUTF16 ? 2 : 1
        func emit(_ end: Int) {
            for paragraph in TXTChapterParser.paragraphsForChapterContent(file.string(in: lineStart..<end)) {
                lines.append(Line(text: paragraph.trimmingCharacters(in: .whitespacesAndNewlines), end: end))
            }
        }
        while cursor + step <= range.upperBound {
            let unit = codeUnit(at: cursor)
            guard unit == 0x0A || unit == 0x0D else {
                cursor += step
                continue
            }
            emit(cursor)
            cursor += step
            if unit == 0x0D, cursor + step <= range.upperBound, codeUnit(at: cursor) == 0x0A {
                cursor += step
            }
            lineStart = cursor
        }
        if lineStart < range.upperBound { emit(range.upperBound) }
        let whole = TXTChapterParser.paragraphsForChapterContent(file.string(in: range))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard whole == lines.map(\.text) else { throw Failure.unsupportedTextTransform }
        return lines
    }

    /// Where a chapter's heading region begins: the previous chapter's end.
    private func gapStart(of index: Int, in indexes: [TXTMappedChapterIndex]) -> Int {
        index == 0 ? 0 : indexes[index - 1].byteRange.upperBound
    }

    /// The last non-blank line between a chapter's heading region start and its body.
    private func headingLine(before bodyStart: Int, after regionStart: Int) -> Line? {
        // A heading is one short line; a bounded window keeps a long Preface from being read.
        let step = isUTF16 ? 2 : 1
        var windowStart = max(regionStart, bodyStart - 2048)
        if isUTF16, (windowStart - regionStart) % 2 != 0 { windowStart += 1 }
        let lines = (try? paragraphLinesUnverified(in: windowStart..<bodyStart, step: step)) ?? []
        // The window's first line may be cut mid-way (and mid-character) unless it starts the region.
        let complete = windowStart == regionStart ? lines : Array(lines.dropFirst())
        return complete.last
    }

    private func paragraphLinesUnverified(in range: Range<Int>, step: Int) throws -> [Line] {
        var lines: [Line] = []
        var lineStart = range.lowerBound
        var cursor = range.lowerBound
        while cursor + step <= range.upperBound {
            let unit = codeUnit(at: cursor)
            if unit == 0x0A || unit == 0x0D {
                let text = file.string(in: lineStart..<cursor).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append(Line(text: text, end: cursor)) }
                lineStart = cursor + step
            }
            cursor += step
        }
        if lineStart < range.upperBound {
            let text = file.string(in: lineStart..<range.upperBound).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { lines.append(Line(text: text, end: range.upperBound)) }
        }
        return lines
    }

    private func lastLine(_ lines: [Line]) throws -> Line {
        guard let last = lines.last else { throw Failure.invalidPosition }
        return last
    }

    private var isUTF16: Bool {
        file.encoding == .utf16LittleEndian || file.encoding == .utf16BigEndian
    }

    private func codeUnit(at offset: Int) -> UInt16 {
        let data = file.data
        guard isUTF16 else { return UInt16(data[data.startIndex + offset]) }
        let first = UInt16(data[data.startIndex + offset]), second = UInt16(data[data.startIndex + offset + 1])
        return file.encoding == .utf16LittleEndian ? first | (second << 8) : (first << 8) | second
    }
}
