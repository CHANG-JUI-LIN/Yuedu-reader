import Foundation

struct TXTReaderPreparation: Sendable {
    let mappedTextFile: TXTMappedTextFile
    let cachedChapterIndexes: [TXTMappedChapterIndex]?
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
        bookTitle: String
    ) throws -> TXTReaderPreparation {
        let mappedTextFile = try TXTFileReader.readMappedTextFile(url: url)
        let fileSize = mappedTextFile.byteCount
        let fingerprint = TXTFileReader.fileFingerprint(data: mappedTextFile.data)
        let encoding = mappedTextFile.encoding
        let cached = TXTChapterParser.loadCachedIndexes(
            bookId: bookId,
            fileSize: fileSize,
            fingerprint: fingerprint,
            encoding: encoding
        )

        let previewText: String
        if cached == nil {
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
            previewText: previewText,
            bookId: bookId,
            bookTitle: bookTitle,
            fileSize: fileSize,
            fingerprint: fingerprint,
            encoding: encoding
        )
    }

    static func completeChapterIndexes(
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
                bookTitle: preparation.bookTitle
            )
        }
        TXTChapterParser.saveCachedIndexes(
            indexes,
            bookId: preparation.bookId,
            fileSize: preparation.fileSize,
            fingerprint: preparation.fingerprint,
            encoding: preparation.encoding
        )
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
            if let decoded = String(
                data: data.prefix(upperBound),
                encoding: mappedTextFile.encoding
            ) {
                guard decoded.unicodeScalars.first == "\u{FEFF}" else {
                    return decoded
                }
                return String(decoded.unicodeScalars.dropFirst())
            }
            upperBound -= step
        }

        throw TXTFileReaderError.encodingNotSupported
    }
}
