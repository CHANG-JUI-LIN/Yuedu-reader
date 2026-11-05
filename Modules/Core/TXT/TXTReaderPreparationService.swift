import Foundation

struct TXTReaderPreparation: Sendable {
    let mappedTextFile: TXTMappedTextFile
    let cachedChapterIndexes: [TXTMappedChapterIndex]?
    let previousChapterIndexes: [TXTMappedChapterIndex]?
    /// The cache version `previousChapterIndexes` came from: v5/v6 rendered without Aozora
    /// markup removal, v7 with it (an index built from other chapter rules).
    let previousIndexVersion: Int?
    /// The chapter rules this book is indexed with; their fingerprint keys the cache.
    let ruleSet: TXTTocRuleSet
    let previewText: String
    let bookId: UUID
    let bookTitle: String
    let fileSize: Int
    let fingerprint: String
    let encoding: String.Encoding
}

/// Owns the TXT first-open pipeline so the reader view only coordinates two
/// presentation phases: a bounded preview, then the canonical full index.
enum TXTReaderPreparationService {
    static func prepare(
        url: URL,
        bookId: UUID,
        bookTitle: String,
        ruleSet: TXTTocRuleSet = TXTTocRuleStore.currentRuleSet()
    ) throws -> TXTReaderPreparation {
        let mappedTextFile = try TXTFileReader.readMappedTextFile(url: url)
        let fileSize = mappedTextFile.byteCount
        let fingerprint = TXTFileReader.fileFingerprint(data: mappedTextFile.data)
        let encoding = mappedTextFile.encoding
        let snapshot = try TXTChapterParser.cachedIndexesForMigration(
            bookId: bookId,
            fileSize: fileSize,
            fingerprint: fingerprint,
            encoding: encoding
        )
        // Current only when built by this version from these rules. An index from other rules
        // (edited in 設定, or the hard-coded patterns before them, with no fingerprint) is
        // re-split like a v5/v6 one: its chapter numbers are what saved locations refer to.
        let isCurrent = snapshot.map {
            $0.version == TXTChapterParser.indexVersion && $0.rulesFingerprint == ruleSet.fingerprint
        } ?? false
        let cached = isCurrent ? snapshot?.indexes : nil
        let previous = isCurrent ? nil : snapshot?.indexes

        let previewText: String
        if cached == nil, previous == nil {
            previewText = try SourcePerfTrace.span(
                "txt.preview",
                "bytes=\(fileSize) limit=\(TXTInitialPreviewPlanner.maximumByteCount)"
            ) {
                try decodedPreview(from: mappedTextFile)
            }
        } else {
            previewText = ""
        }

        return TXTReaderPreparation(
            mappedTextFile: mappedTextFile,
            cachedChapterIndexes: cached,
            previousChapterIndexes: previous,
            previousIndexVersion: isCurrent ? nil : snapshot?.version,
            ruleSet: ruleSet,
            previewText: previewText,
            bookId: bookId,
            bookTitle: bookTitle,
            fileSize: fileSize,
            fingerprint: fingerprint,
            encoding: encoding
        )
    }

    /// Builds a candidate index without publishing it. Only the transactional
    /// migration service may replace a persisted index after validating locations.
    static func buildChapterIndexes(
        for preparation: TXTReaderPreparation
    ) -> [TXTMappedChapterIndex] {
        if let cached = preparation.cachedChapterIndexes {
            return cached
        }

        let indexes = SourcePerfTrace.span(
            "txt.index",
            "bytes=\(preparation.fileSize) encoding=\(preparation.encoding.rawValue)"
        ) {
            TXTChapterParser.parseMappedChapterIndexes(
                preparation.mappedTextFile,
                bookTitle: preparation.bookTitle,
                rules: preparation.ruleSet
            )
        }
        return indexes
    }

    private static func decodedPreview(
        from mappedTextFile: TXTMappedTextFile
    ) throws -> String {
        let count = TXTInitialPreviewPlanner.byteCount(
            fileByteCount: mappedTextFile.byteCount,
            encoding: mappedTextFile.encoding
        )
        guard count > 0 else { return "" }

        let data = mappedTextFile.data
        let step = mappedTextFile.encoding == .utf16LittleEndian
            || mappedTextFile.encoding == .utf16BigEndian
            ? 2
            : 1
        let maximumTrim = min(step == 2 ? 6 : 4, count)
        var upperBound = count

        while upperBound > 0, count - upperBound <= maximumTrim {
            if let decoded = TXTTextDecoder.decode(
                Data(data.prefix(upperBound)),
                as: mappedTextFile.encoding
            ) {
                guard decoded.unicodeScalars.first == "\u{FEFF}" else {
                    return decoded
                }
                return String(decoded.unicodeScalars.dropFirst())
            }
            upperBound -= step
        }

        AppLogger.error("TXT preview decode failed", context: [
            "encoding": mappedTextFile.encoding.rawValue, "bytes": count,
        ])
        throw TXTFileReaderError.encodingNotSupported
    }
}
