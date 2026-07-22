import Darwin
import Foundation

struct TXTChapterIndex: Equatable {
    let index: Int
    let title: String
    let contentRange: NSRange

    var sourceHref: String { String(index) }
}

struct TXTMappedChapterIndex: Equatable {
    let index: Int
    let title: String
    let byteRange: Range<Int>

    var sourceHref: String { String(index) }
}

enum TXTChapterParser {
    private struct TXTChapterIndexCache: Codable {
        let version: Int
        let fileSize: Int
        let fingerprint: String
        let encodingRawValue: UInt
        let indexes: [CodableChapterIndex]
    }

    private struct CodableChapterIndex: Codable {
        let index: Int
        let title: String
        let lower: Int
        let upper: Int
    }

    struct ParsedChapter {
        let title: String
        let paragraphs: [String]
    }

    private static func sanitizedTitle(_ title: String) -> String {
        let cleaned = ReaderHTMLUtilities.displayText(fromHTMLFragment: title)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? title.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    static func parseUnifiedChapters(_ text: String, bookTitle: String) -> [UnifiedChapter] {
        parseChapters(text, bookTitle: bookTitle)
            .enumerated()
            .map { index, chapter in
                UnifiedChapter(
                    index: index,
                    title: chapter.title,
                    paragraphs: chapter.paragraphs,
                    sourceHref: nil
                )
            }
    }

    static func parseChapterIndexes(_ text: String, bookTitle: String) -> [TXTChapterIndex] {
        let nsText = text as NSString
        let totalLength = nsText.length
        guard totalLength > 0 else {
            return [TXTChapterIndex(index: 0, title: sanitizedTitle(bookTitle), contentRange: NSRange(location: 0, length: 0))]
        }

        let titleMatches = detectTitleMatches(in: text)
        if !titleMatches.isEmpty {
            var indexes: [TXTChapterIndex] = []

            let firstTitleStart = titleMatches[0].range.location
            if firstTitleStart > 0 {
                let prefaceRange = NSRange(location: 0, length: firstTitleStart)
                if hasReadableContent(in: nsText, range: prefaceRange) {
                    indexes.append(
                        TXTChapterIndex(
                            index: indexes.count,
                            title: "Preface",
                            contentRange: prefaceRange
                        )
                    )
                }
            }

            for (i, match) in titleMatches.enumerated() {
                let end = i + 1 < titleMatches.count
                    ? titleMatches[i + 1].range.location
                    : totalLength
                let rawStart = match.range.location + match.range.length
                let start = skipLeadingWhitespace(in: nsText, from: rawStart, upperBound: end)
                guard end >= start else { continue }
                let chapterRange = NSRange(location: start, length: end - start)
                indexes.append(
                    TXTChapterIndex(
                        index: indexes.count,
                        title: sanitizedTitle(match.title),
                        contentRange: chapterRange
                    )
                )
            }

            if indexes.isEmpty {
                return [TXTChapterIndex(index: 0, title: sanitizedTitle(bookTitle), contentRange: NSRange(location: 0, length: totalLength))]
            }
            return indexes
        }

        return splitIntoBlockIndexes(text, blockSize: 3000, bookTitle: bookTitle)
    }

    static func parseMappedChapterIndexes(_ mappedTextFile: TXTMappedTextFile, bookTitle: String) -> [TXTMappedChapterIndex] {
        let totalBytes = mappedTextFile.byteCount
        guard totalBytes > 0 else {
            return [TXTMappedChapterIndex(index: 0, title: sanitizedTitle(bookTitle), byteRange: 0..<0)]
        }

        let titleMatches = detectMappedTitleMatches(in: mappedTextFile)
        if !titleMatches.isEmpty {
            var indexes: [TXTMappedChapterIndex] = []

            let firstTitleStart = titleMatches[0].lineByteRange.lowerBound
            if firstTitleStart > 0 {
                let prefaceRange = 0..<firstTitleStart
                if hasReadableBytes(in: mappedTextFile.data, range: prefaceRange) {
                    indexes.append(
                        TXTMappedChapterIndex(
                            index: indexes.count,
                            title: "Preface",
                            byteRange: prefaceRange
                        )
                    )
                }
            }

            for i in titleMatches.indices {
                let end = i + 1 < titleMatches.count
                    ? titleMatches[i + 1].lineByteRange.lowerBound
                    : totalBytes
                let rawStart = titleMatches[i].lineByteRange.upperBound
                let start = skipLeadingWhitespaceBytes(
                    in: mappedTextFile,
                    from: rawStart,
                    upperBound: end
                )
                guard start <= end else { continue }
                indexes.append(
                    TXTMappedChapterIndex(
                        index: indexes.count,
                        title: sanitizedTitle(titleMatches[i].title),
                        byteRange: start..<end
                    )
                )
            }

            if indexes.isEmpty {
                return [TXTMappedChapterIndex(index: 0, title: sanitizedTitle(bookTitle), byteRange: 0..<totalBytes)]
            }
            return splittingOverlongChapters(indexes, mappedTextFile: mappedTextFile)
        }

        return splitIntoMappedBlockIndexes(mappedTextFile, blockBytes: 12 * 1024, bookTitle: bookTitle)
    }

    /// Chapters above this size get split into "標題(1)(2)…" pieces (Legado
    /// splitLongChapter idea, threshold matches its 100KB): a regex mis-split or
    /// a genuinely huge chapter otherwise dominates progress granularity, TTS
    /// chapter units, and single-chapter layout cost.
    private static let maxChapterBytesBeforeSplit = 100 * 1024

    private static func splittingOverlongChapters(
        _ indexes: [TXTMappedChapterIndex],
        mappedTextFile: TXTMappedTextFile
    ) -> [TXTMappedChapterIndex] {
        guard indexes.contains(where: { $0.byteRange.count > maxChapterBytesBeforeSplit }) else {
            return indexes
        }
        var result: [TXTMappedChapterIndex] = []
        for chapter in indexes {
            guard chapter.byteRange.count > maxChapterBytesBeforeSplit else {
                result.append(
                    TXTMappedChapterIndex(
                        index: result.count,
                        title: chapter.title,
                        byteRange: chapter.byteRange
                    )
                )
                continue
            }
            let upper = chapter.byteRange.upperBound
            var cursor = chapter.byteRange.lowerBound
            var piece = 0
            let firstPieceResultIndex = result.count
            while cursor < upper {
                var end = min(cursor + maxChapterBytesBeforeSplit, upper)
                if end < upper {
                    // Extend to the next line break so pieces split between paragraphs.
                    let lookaheadLimit = min(upper, end + 1024)
                    if let lineBreak = nextLineBreak(
                        in: mappedTextFile,
                        from: end,
                        upperBound: lookaheadLimit
                    ) {
                        end = lineBreak
                    }
                }
                if end <= cursor { end = min(cursor + 1, upper) }
                piece += 1
                result.append(
                    TXTMappedChapterIndex(
                        index: result.count,
                        title: "\(chapter.title)(\(piece))",
                        byteRange: cursor..<end
                    )
                )
                cursor = end
                cursor = skipLineBreaks(
                    in: mappedTextFile,
                    from: cursor,
                    upperBound: upper
                )
            }
            // The newline lookahead can swallow the remainder: a single-piece
            // "split" keeps its original title.
            if piece == 1 {
                let only = result[firstPieceResultIndex]
                result[firstPieceResultIndex] = TXTMappedChapterIndex(
                    index: only.index,
                    title: chapter.title,
                    byteRange: only.byteRange
                )
            }
        }
        return result
    }

    static func loadCachedIndexes(bookId: UUID, fileSize: Int, fingerprint: String, encoding: String.Encoding) -> [TXTMappedChapterIndex]? {
        let cacheURL = Self.cacheURL(for: bookId)
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(TXTChapterIndexCache.self, from: data),
              cache.version == 5,
              cache.fileSize == fileSize,
              cache.fingerprint == fingerprint,
              cache.encodingRawValue == encoding.rawValue
        else { return nil }
        return cache.indexes.map {
            TXTMappedChapterIndex(index: $0.index, title: sanitizedTitle($0.title), byteRange: $0.lower..<$0.upper)
        }
    }

    static func saveCachedIndexes(_ indexes: [TXTMappedChapterIndex], bookId: UUID, fileSize: Int, fingerprint: String, encoding: String.Encoding) {
        let cacheDir = cacheDirectoryURL()
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let codable = indexes.map { CodableChapterIndex(index: $0.index, title: $0.title, lower: $0.byteRange.lowerBound, upper: $0.byteRange.upperBound) }
        // v5: overlong chapters are auto-split into "(1)(2)…" pieces; older
        // cached lists don't have the split and must re-parse.
        let cache = TXTChapterIndexCache(version: 5, fileSize: fileSize, fingerprint: fingerprint, encodingRawValue: encoding.rawValue, indexes: codable)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: Self.cacheURL(for: bookId))
    }

    static func deleteCachedIndexes(bookId: UUID) {
        try? FileManager.default.removeItem(at: Self.cacheURL(for: bookId))
    }

    private static func cacheDirectoryURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("txt_chapter_cache", isDirectory: true)
    }

    private static func cacheURL(for bookId: UUID) -> URL {
        cacheDirectoryURL().appendingPathComponent("\(bookId.uuidString).json")
    }

    private static let chapterPatterns: [NSRegularExpression] = {
        let patterns: [String] = [
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+章[^\\n]*",
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+[節节][^\\n]*",
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+卷[^\\n]*",
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+回[^\\n]*",
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+篇[^\\n]*",
            "^\\s*第[零一二三四五六七八九十百千萬万\\d]+部[^\\n]*",
            "^\\s*卷[零一二三四五六七八九十百千萬万\\d]+[^\\n]*",
            "^\\s*Chapter\\s*\\d+[^\\n]*",
            "^\\s*CHAPTER\\s*\\d+[^\\n]*",
            "^\\s*Part\\s*\\d+[^\\n]*",
            "^\\s*PART\\s*\\d+[^\\n]*",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .anchorsMatchLines) }
    }()

    private static let specialTitlePattern: NSRegularExpression? = {
        let titles = [
            "序章", "序言", "序幕", "前言", "引子", "引言", "楔子",
            "尾聲", "尾声", "終章", "终章", "後記", "后记",
            "番外", "後序", "后序", "結語", "结语",
            "Prologue", "Epilogue", "Preface", "Introduction",
        ]
        let pattern = "^\\s*(" + titles.joined(separator: "|") + ")[^\\n]*$"
        return try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines, .caseInsensitive])
    }()

    static func parseChapters(_ text: String, bookTitle: String) -> [ParsedChapter] {
        let indexes = parseChapterIndexes(text, bookTitle: bookTitle)
        return indexes.map { idx in
            let body = chapterText(text, range: idx.contentRange)
            return ParsedChapter(
                title: sanitizedTitle(idx.title),
                paragraphs: splitIntoParagraphs(body)
            )
        }
    }

    static func chapterText(_ text: String, range: NSRange) -> String {
        let nsText = text as NSString
        let safe = safeRange(range, in: nsText)
        guard safe.length > 0 else { return "" }
        return nsText.substring(with: safe)
    }

    static func chapterText(_ mappedTextFile: TXTMappedTextFile, byteRange: Range<Int>) -> String {
        mappedTextFile.string(in: byteRange)
    }

    static func paragraphsForChapterContent(_ text: String) -> [String] {
        splitIntoParagraphs(text)
    }

    private static func splitIntoBlocks(_ text: String, blockSize: Int, bookTitle: String) -> [ParsedChapter] {
        let paragraphs = splitIntoParagraphs(text)
        if paragraphs.isEmpty {
            return [ParsedChapter(title: sanitizedTitle(bookTitle), paragraphs: [text])]
        }

        var chapters: [ParsedChapter] = []
        var current: [String] = []
        var currentSize = 0
        var chapterNum = 0

        for paragraph in paragraphs {
            current.append(paragraph)
            currentSize += paragraph.count
            if currentSize >= blockSize {
                chapterNum += 1
                chapters.append(ParsedChapter(title: "Section \(chapterNum)", paragraphs: current))
                current.removeAll(keepingCapacity: true)
                currentSize = 0
            }
        }

        if !current.isEmpty {
            chapterNum += 1
            let title = chapterNum == 1 ? sanitizedTitle(bookTitle) : "Section \(chapterNum)"
            chapters.append(ParsedChapter(title: title, paragraphs: current))
        }

        return chapters
    }

    private static func splitIntoBlockIndexes(_ text: String, blockSize: Int, bookTitle: String) -> [TXTChapterIndex] {
        let nsText = text as NSString
        let totalLength = nsText.length
        guard totalLength > 0 else {
            return [TXTChapterIndex(index: 0, title: sanitizedTitle(bookTitle), contentRange: NSRange(location: 0, length: 0))]
        }

        var result: [TXTChapterIndex] = []
        var cursor = 0
        while cursor < totalLength {
            var end = min(cursor + blockSize, totalLength)
            if end < totalLength {
                let tailLen = min(256, totalLength - end)
                let tail = nsText.substring(with: NSRange(location: end, length: tailLen))
                if let lineBreak = tail.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    let distance = tail.distance(from: tail.startIndex, to: lineBreak)
                    end += distance
                }
            }
            let range = NSRange(location: cursor, length: max(0, end - cursor))
            let title = result.isEmpty ? sanitizedTitle(bookTitle) : "Section \(result.count + 1)"
            result.append(TXTChapterIndex(index: result.count, title: title, contentRange: range))
            cursor = max(end, cursor + 1)
        }
        return result
    }

    private struct TitleMatch {
        let range: NSRange
        let title: String
    }

    private struct MappedTitleMatch {
        let lineByteRange: Range<Int>
        let title: String
    }

    private static func detectTitleMatches(in text: String) -> [TitleMatch] {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var selected: [TitleMatch] = []
        var singleMatchFallback: [TitleMatch] = []

        for regex in chapterPatterns {
            let results = regex.matches(in: text, range: fullRange)
            let mapped = results.compactMap { match -> TitleMatch? in
                let raw = nsText.substring(with: match.range)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return TitleMatch(range: match.range, title: sanitizedTitle(trimmed))
            }
            if mapped.count == 1, singleMatchFallback.isEmpty {
                singleMatchFallback = mapped
            }
            if results.count >= 2 {
                selected = mapped
                break
            }
        }

        if selected.isEmpty, !singleMatchFallback.isEmpty {
            selected = singleMatchFallback
        }

        if let specialRegex = specialTitlePattern {
            let special = specialRegex.matches(in: text, range: fullRange).compactMap { match -> TitleMatch? in
                let raw = nsText.substring(with: match.range)
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return TitleMatch(range: match.range, title: sanitizedTitle(trimmed))
            }
            selected.append(contentsOf: special)
        }

        if selected.isEmpty { return [] }

        selected.sort {
            if $0.range.location == $1.range.location {
                return $0.range.length < $1.range.length
            }
            return $0.range.location < $1.range.location
        }

        var deduped: [TitleMatch] = []
        var seenLocations = Set<Int>()
        for item in selected where !seenLocations.contains(item.range.location) {
            deduped.append(item)
            seenLocations.insert(item.range.location)
        }
        return deduped
    }

    /// First characters accepted by `chapterPatterns` and `specialTitlePattern`.
    /// Encoding them once lets the mapped parser reject body lines before it
    /// allocates a String or runs regexes, including GB18030 and Big5 books.
    private static let titleStartCharacters = [
        "C", "c", "P", "p", "E", "e", "I", "i",
        "第", "卷", "序", "楔", "前", "引", "尾", "終", "终",
        "後", "后", "番", "結", "结",
    ]

    private struct EncodedTitleStartMatcher {
        private let titlePrefixes: [UInt8: [[UInt8]]]
        private let whitespacePrefixes: [UInt8: [[UInt8]]]

        init(encoding: String.Encoding) {
            titlePrefixes = Self.makePrefixTable(
                strings: TXTChapterParser.titleStartCharacters,
                encoding: encoding
            )
            whitespacePrefixes = Self.makePrefixTable(
                strings: [" ", "\t", "\u{000B}", "\u{000C}", "\u{3000}", "\u{00A0}", "\u{FEFF}"],
                encoding: encoding
            )
        }

        func lineMayBeTitle(
            bytes: UnsafeBufferPointer<UInt8>,
            range: Range<Int>
        ) -> Bool {
            var cursor = range.lowerBound
            while cursor < range.upperBound,
                  let width = matchingPrefixWidth(
                    in: whitespacePrefixes,
                    bytes: bytes,
                    at: cursor,
                    upperBound: range.upperBound
                  ) {
                cursor += width
            }
            guard cursor < range.upperBound else { return false }
            return matchingPrefixWidth(
                in: titlePrefixes,
                bytes: bytes,
                at: cursor,
                upperBound: range.upperBound
            ) != nil
        }

        private func matchingPrefixWidth(
            in table: [UInt8: [[UInt8]]],
            bytes: UnsafeBufferPointer<UInt8>,
            at offset: Int,
            upperBound: Int
        ) -> Int? {
            guard let candidates = table[bytes[offset]] else { return nil }
            for candidate in candidates where offset + candidate.count <= upperBound {
                var matches = true
                for index in candidate.indices where bytes[offset + index] != candidate[index] {
                    matches = false
                    break
                }
                if matches { return candidate.count }
            }
            return nil
        }

        private static func makePrefixTable(
            strings: [String],
            encoding: String.Encoding
        ) -> [UInt8: [[UInt8]]] {
            var table: [UInt8: [[UInt8]]] = [:]
            for string in strings {
                guard let data = string.data(using: encoding, allowLossyConversion: false),
                      let first = data.first,
                      !data.isEmpty
                else { continue }
                table[first, default: []].append(Array(data))
            }
            for key in table.keys {
                table[key]?.sort { $0.count > $1.count }
            }
            return table
        }
    }

    /// Sample window for rule selection (Legado getTocRule idea): within the
    /// first 512KB every pattern competes; past it, the winning pattern is
    /// locked and the remainder of the file only runs the winner (+ volume
    /// patterns when the winner is chapter-level) instead of all 11.
    private static let patternSampleByteLimit = 512 * 1024

    /// Selection mirror of the final pass: first bucket with ≥2 matches wins.
    /// nil = no winner yet → keep testing every pattern.
    private static func lockedPatternIndices(fromBuckets buckets: [[MappedTitleMatch]]) -> [Int]? {
        guard let winner = buckets.indices.first(where: { buckets[$0].count >= 2 }) else {
            return nil
        }
        let chapterLevelIndexes: Set<Int> = [0, 1, 3]
        let volumeLevelIndexes: [Int] = [2, 4, 5, 6]
        if chapterLevelIndexes.contains(winner) {
            return [winner] + volumeLevelIndexes
        }
        return [winner]
    }

    private static func detectMappedTitleMatches(in mappedTextFile: TXTMappedTextFile) -> [MappedTitleMatch] {
        // Allocate one bucket per chapterPattern
        var buckets: [[MappedTitleMatch]] = Array(repeating: [], count: chapterPatterns.count)
        var specialMatches: [MappedTitleMatch] = []

        let titleMatcher = EncodedTitleStartMatcher(encoding: mappedTextFile.encoding)

        // nil while sampling (or when no rule has won yet) → test all patterns.
        var lockedIndices: [Int]? = nil

        enumerateMappedTitleLines(in: mappedTextFile, matcher: titleMatcher) { lineByteRange, decodeLine in
            // Past the sample window, try to lock the winning pattern. Locking
            // mid-file is safe: buckets frozen below 2 matches can never win the
            // final "first with ≥2" selection, so the outcome is unchanged.
            if lockedIndices == nil, lineByteRange.lowerBound >= patternSampleByteLimit {
                lockedIndices = lockedPatternIndices(fromBuckets: buckets)
            }

            // Decode the line and test patterns
            let lineText = decodeLine()
            let nsLine = lineText as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)

            for i in lockedIndices ?? Array(chapterPatterns.indices) {
                let regex = chapterPatterns[i]
                guard let match = regex.firstMatch(in: lineText, range: fullRange),
                      let range = Range(match.range, in: lineText) else { continue }
                let title = String(lineText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { continue }
                buckets[i].append(MappedTitleMatch(lineByteRange: lineByteRange, title: sanitizedTitle(title)))
            }

            if let specialRegex = specialTitlePattern {
                guard let match = specialRegex.firstMatch(in: lineText, range: fullRange),
                      let range = Range(match.range, in: lineText) else { return }
                let title = String(lineText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                specialMatches.append(MappedTitleMatch(lineByteRange: lineByteRange, title: sanitizedTitle(title)))
            }
        }

        // First pattern with >=2 matches wins; track which bucket index won
        var selected: [MappedTitleMatch] = []
        var singleMatchFallback: [MappedTitleMatch] = []
        var selectedBucketIndex: Int? = nil
        var fallbackBucketIndex: Int? = nil

        for (i, bucket) in buckets.enumerated() {
            if bucket.count == 1, singleMatchFallback.isEmpty {
                singleMatchFallback = bucket
                fallbackBucketIndex = i
            }
            if bucket.count >= 2 {
                selected = bucket
                selectedBucketIndex = i
                break
            }
        }

        if selected.isEmpty, !singleMatchFallback.isEmpty {
            selected = singleMatchFallback
            selectedBucketIndex = fallbackBucketIndex
        }

        // chapterPatterns index mapping:
        //   0=第X章 (Chapter)  1=第X節 (Section)  2=第X卷 (Volume)  3=第X回 (Chapter)
        //   4=第X篇 (Part)  5=第X部 (Book)  6=卷X (Volume)
        // If the winning pattern is chapter-level (e.g. 章/節/回),
        // also include volume-level matches (e.g. 卷/篇/部) as structural markers.
        let chapterLevelIndexes: Set<Int> = [0, 1, 3]
        let volumeLevelIndexes: Set<Int> = [2, 4, 5, 6]
        if let idx = selectedBucketIndex, chapterLevelIndexes.contains(idx) {
            for vi in volumeLevelIndexes {
                selected.append(contentsOf: buckets[vi])
            }
        }

        selected.append(contentsOf: specialMatches)

        if selected.isEmpty { return [] }

        selected.sort {
            if $0.lineByteRange.lowerBound == $1.lineByteRange.lowerBound {
                return $0.lineByteRange.count < $1.lineByteRange.count
            }
            return $0.lineByteRange.lowerBound < $1.lineByteRange.lowerBound
        }

        var deduped: [MappedTitleMatch] = []
        var seenStart = Set<Int>()
        for item in selected where !seenStart.contains(item.lineByteRange.lowerBound) {
            deduped.append(item)
            seenStart.insert(item.lineByteRange.lowerBound)
        }
        return deduped
    }

    private static func skipLeadingWhitespace(in text: NSString, from start: Int, upperBound: Int) -> Int {
        guard start < upperBound else { return min(start, upperBound) }
        var cursor = max(0, start)
        let limit = max(cursor, upperBound)
        while cursor < limit {
            let scalar = UnicodeScalar(text.character(at: cursor))
            if scalar == "\n" || scalar == "\r" || scalar == "\t" || scalar == " " || scalar == "\u{3000}" {
                cursor += 1
                continue
            }
            break
        }
        return cursor
    }

    private static func skipLeadingWhitespaceBytes(
        in mappedTextFile: TXTMappedTextFile,
        from start: Int,
        upperBound: Int
    ) -> Int {
        let data = mappedTextFile.data
        guard start < upperBound else { return min(start, upperBound) }
        var cursor = max(0, start)
        let limit = max(cursor, upperBound)

        if mappedTextFile.encoding == .utf16LittleEndian
            || mappedTextFile.encoding == .utf16BigEndian {
            let isLittleEndian = mappedTextFile.encoding == .utf16LittleEndian
            while cursor + 1 < limit {
                let first = UInt16(data[cursor])
                let second = UInt16(data[cursor + 1])
                let unit = isLittleEndian
                    ? first | (second << 8)
                    : (first << 8) | second
                guard unit == 0x0020 || unit == 0x0009
                    || unit == 0x000A || unit == 0x000D || unit == 0x3000
                else { break }
                cursor += 2
            }
            return cursor
        }

        while cursor < limit {
            let byte = data[cursor]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                cursor += 1
                continue
            }
            if cursor + 2 < limit,
               data[cursor] == 0xE3,
               data[cursor + 1] == 0x80,
               data[cursor + 2] == 0x80 {
                cursor += 3
                continue
            }
            break
        }
        return cursor
    }

    private static func hasReadableContent(in text: NSString, range: NSRange) -> Bool {
        let safe = safeRange(range, in: text)
        guard safe.length > 0 else { return false }
        let raw = text.substring(with: safe)
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasReadableBytes(in data: Data, range: Range<Int>) -> Bool {
        let lower = max(0, min(range.lowerBound, data.count))
        let upper = max(lower, min(range.upperBound, data.count))
        guard lower < upper else { return false }

        var i = lower
        while i < upper {
            let byte = data[i]
            if byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D {
                return true
            }
            i += 1
        }
        return false
    }

    private static func nextLineBreak(
        in mappedTextFile: TXTMappedTextFile,
        from start: Int,
        upperBound: Int
    ) -> Int? {
        let data = mappedTextFile.data
        let limit = min(max(0, upperBound), data.count)
        var cursor = min(max(0, start), limit)

        if mappedTextFile.encoding == .utf16LittleEndian
            || mappedTextFile.encoding == .utf16BigEndian {
            if !cursor.isMultiple(of: 2) { cursor += 1 }
            while cursor + 1 < limit {
                let unit = utf16CodeUnit(
                    in: data,
                    at: cursor,
                    littleEndian: mappedTextFile.encoding == .utf16LittleEndian
                )
                if unit == 0x000A || unit == 0x000D { return cursor }
                cursor += 2
            }
            return nil
        }

        while cursor < limit {
            if data[cursor] == 0x0A || data[cursor] == 0x0D { return cursor }
            cursor += 1
        }
        return nil
    }

    private static func skipLineBreaks(
        in mappedTextFile: TXTMappedTextFile,
        from start: Int,
        upperBound: Int
    ) -> Int {
        let data = mappedTextFile.data
        let limit = min(max(0, upperBound), data.count)
        var cursor = min(max(0, start), limit)

        if mappedTextFile.encoding == .utf16LittleEndian
            || mappedTextFile.encoding == .utf16BigEndian {
            while cursor + 1 < limit {
                let unit = utf16CodeUnit(
                    in: data,
                    at: cursor,
                    littleEndian: mappedTextFile.encoding == .utf16LittleEndian
                )
                guard unit == 0x000A || unit == 0x000D else { break }
                cursor += 2
            }
            return cursor
        }

        while cursor < limit, data[cursor] == 0x0A || data[cursor] == 0x0D {
            cursor += 1
        }
        return cursor
    }

    private static func utf16CodeUnit(
        in data: Data,
        at offset: Int,
        littleEndian: Bool
    ) -> UInt16 {
        let first = UInt16(data[offset])
        let second = UInt16(data[offset + 1])
        return littleEndian
            ? first | (second << 8)
            : (first << 8) | second
    }

    private static func splitIntoMappedBlockIndexes(_ mappedTextFile: TXTMappedTextFile, blockBytes: Int, bookTitle: String) -> [TXTMappedChapterIndex] {
        let total = mappedTextFile.data.count
        guard total > 0 else {
            return [TXTMappedChapterIndex(index: 0, title: sanitizedTitle(bookTitle), byteRange: 0..<0)]
        }

        var result: [TXTMappedChapterIndex] = []
        var cursor = 0
        while cursor < total {
            var end = min(cursor + blockBytes, total)
            if end < total {
                let lookaheadLimit = min(total, end + 1024)
                if let lineBreak = nextLineBreak(
                    in: mappedTextFile,
                    from: end,
                    upperBound: lookaheadLimit
                ) {
                    end = lineBreak
                }
            }

            if end <= cursor {
                end = min(cursor + 1, total)
            }

            let title = result.isEmpty ? sanitizedTitle(bookTitle) : "Section \(result.count + 1)"
            result.append(
                TXTMappedChapterIndex(
                    index: result.count,
                    title: title,
                    byteRange: cursor..<end
                )
            )

            cursor = end
            cursor = skipLineBreaks(
                in: mappedTextFile,
                from: cursor,
                upperBound: total
            )
        }

        return result
    }

    /// Enumerates only possible title lines. Raw-pointer traversal avoids the
    /// per-byte `Data` subscript overhead, while the encoding-aware matcher
    /// rejects ordinary GB18030/Big5/UTF-8 body lines before String allocation.
    private static func enumerateMappedTitleLines(
        in mappedTextFile: TXTMappedTextFile,
        matcher: EncodedTitleStartMatcher,
        _ body: (Range<Int>, () -> String) -> Void
    ) {
        let data = mappedTextFile.data
        data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard !bytes.isEmpty else { return }

            func emitCandidate(_ range: Range<Int>) {
                guard range.count <= 200,
                      matcher.lineMayBeTitle(bytes: bytes, range: range)
                else { return }
                body(range, {
                    let line = mappedTextFile.string(in: range)
                    guard line.unicodeScalars.first == "\u{FEFF}" else { return line }
                    return String(line.unicodeScalars.dropFirst())
                })
            }

            if mappedTextFile.encoding == .utf16LittleEndian
                || mappedTextFile.encoding == .utf16BigEndian {
                let isLittleEndian = mappedTextFile.encoding == .utf16LittleEndian
                func codeUnit(at offset: Int) -> UInt16 {
                    let first = UInt16(bytes[offset])
                    let second = UInt16(bytes[offset + 1])
                    return isLittleEndian
                        ? first | (second << 8)
                        : (first << 8) | second
                }

                var lineStart = 0
                var cursor = 0
                while cursor + 1 < bytes.count {
                    let unit = codeUnit(at: cursor)
                    guard unit == 0x000A || unit == 0x000D else {
                        cursor += 2
                        continue
                    }

                    emitCandidate(lineStart..<cursor)
                    cursor += 2
                    if unit == 0x000D,
                       cursor + 1 < bytes.count,
                       codeUnit(at: cursor) == 0x000A {
                        cursor += 2
                    }
                    lineStart = cursor
                }
                if lineStart < bytes.count {
                    emitCandidate(lineStart..<bytes.count)
                }
                return
            }

            // TXT files consistently use LF/CRLF or legacy CR line endings.
            // Pick the delimiter once; searching for an absent second delimiter
            // on every line turns an LF-only book into an O(n²) scan.
            let delimiter: Int32 = memchr(bytes.baseAddress!, 0x0A, bytes.count) == nil
                ? 0x0D
                : 0x0A
            var lineStart = 0
            var cursor = 0
            while cursor < bytes.count {
                let remaining = bytes.count - cursor
                let searchStart = bytes.baseAddress!.advanced(by: cursor)
                guard let found = memchr(searchStart, delimiter, remaining) else {
                    emitCandidate(lineStart..<bytes.count)
                    return
                }
                let delimiterPointer = found.assumingMemoryBound(to: UInt8.self)
                let delimiterOffset = bytes.baseAddress!.distance(to: delimiterPointer)
                let lineEnd = delimiter == 0x0A
                    && delimiterOffset > lineStart
                    && bytes[delimiterOffset - 1] == 0x0D
                    ? delimiterOffset - 1
                    : delimiterOffset

                emitCandidate(lineStart..<lineEnd)
                cursor = delimiterOffset + 1
                lineStart = cursor
            }
        }
    }

    private static func safeRange(_ range: NSRange, in text: NSString) -> NSRange {
        let cappedStart = max(0, min(range.location, text.length))
        let cappedEnd = max(cappedStart, min(range.location + range.length, text.length))
        let normalized = NSRange(location: cappedStart, length: cappedEnd - cappedStart)
        guard normalized.length > 0 else { return normalized }
        return text.rangeOfComposedCharacterSequences(for: normalized)
    }

    private static func splitIntoParagraphs(_ text: String) -> [String] {
        var cleaned = text
        let hasHTML = cleaned.range(of: "<(?:p|div|br|span|h[1-6]|li|section|article)[\\s>/]", options: .regularExpression) != nil

        if hasHTML {
            cleaned = cleaned.replacingOccurrences(of: "<(script|style|noscript)[^>]*>[\\s\\S]*?</\\1>", with: "", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: "</(?:p|div|li|blockquote|section|article|dt|dd|figcaption|pre|header|footer)>", with: "\n", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: "</h[1-6]>", with: "\n", options: .regularExpression)
            cleaned = cleaned.replacingOccurrences(of: "</tr>", with: "\n", options: .caseInsensitive)
            cleaned = cleaned.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            cleaned = decodeHTMLEntities(cleaned)
        }

        cleaned = cleaned.replacingOccurrences(of: "\r\n", with: "\n")
        cleaned = cleaned.replacingOccurrences(of: "\r", with: "\n")

        return cleaned
            .components(separatedBy: "\n")
            .map {
                $0.trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\u{3000}"))
            }
            .filter { !$0.isEmpty }
    }

    private static func decodeHTMLEntities(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&ensp;", with: " ")
        result = result.replacingOccurrences(of: "&emsp;", with: " ")
        result = result.replacingOccurrences(of: "&thinsp;", with: "")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")

        if let hexRegex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);") {
            let nsResult = result as NSString
            let matches = hexRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let hexRange = Range(match.range(at: 1), in: result),
                      let codePoint = UInt32(result[hexRange], radix: 16),
                      let scalar = Unicode.Scalar(codePoint),
                      let fullRange = Range(match.range, in: result)
                else { continue }
                result.replaceSubrange(fullRange, with: String(scalar))
            }
        }

        if let decRegex = try? NSRegularExpression(pattern: "&#(\\d+);") {
            let nsResult = result as NSString
            let matches = decRegex.matches(in: result, range: NSRange(location: 0, length: nsResult.length))
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let decRange = Range(match.range(at: 1), in: result),
                      let codePoint = UInt32(result[decRange]),
                      let scalar = Unicode.Scalar(codePoint),
                      let fullRange = Range(match.range, in: result)
                else { continue }
                result.replaceSubrange(fullRange, with: String(scalar))
            }
        }

        return result
    }
}

struct TXTBookParser: BookParser {
    func parse(url: URL) async throws -> ParsedBookDocument {
        let text = try TXTFileReader.readTextFile(url: url)
            .filter { ch in
                if ch == "\n" || ch == "\r" || ch == "\t" { return true }
                return !ch.isASCII || ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isWhitespace
            }
        let title = url.deletingPathExtension().lastPathComponent
        let chapters = TXTChapterParser.parseChapters(text, bookTitle: title)
            .map { chapter in
                let trimmedTitle = chapter.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = chapter.paragraphs
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedTitle.isEmpty { return body }
                if body.isEmpty { return trimmedTitle }
                return trimmedTitle + "\n" + body
            }
            .filter { !$0.isEmpty }
        let author = TXTMetadataProbe.infer(
            from: String(text.prefix(TXTMetadataProbe.maximumMetadataCharacters)),
            fallbackTitle: title
        ).author ?? "Unknown Author"
        return ParsedBookDocument(title: title, author: author, chapters: chapters)
    }
}
