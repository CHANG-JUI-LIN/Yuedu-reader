import Foundation
import Testing
@testable import yuedu_app

@Suite("TXTFileReader", .serialized)
struct TXTFileReaderTests {

    @Test("sample-based detection picks GB18030 before reading the full file")
    func sampledDetectionPicksGB18030() throws {
        let text = "第一章 測試\n中文內容"
        let data = try #require(text.data(using: TXTFileReader.gb18030Encoding))
        let url = try writeTemporaryTXT(data: data)

        let encoding = try TXTFileReader.detectEncodingBySampling(url: url)

        #expect(encoding == TXTFileReader.gb18030Encoding)
        #expect(try TXTFileReader.readTextFile(url: url) == text)
    }

    @Test("sample-based detection honors UTF-16 little endian BOM")
    func sampledDetectionHonorsUTF16LEBOM() throws {
        let text = "第一章 UTF16"
        var data = Data([0xFF, 0xFE])
        data.append(try #require(text.data(using: .utf16LittleEndian)))
        let url = try writeTemporaryTXT(data: data)

        let encoding = try TXTFileReader.detectEncodingBySampling(url: url)

        #expect(encoding == .utf16LittleEndian)
        #expect(try TXTFileReader.readTextFile(url: url) == text)
    }

    @Test("TXT persistence preserves original GB18030 bytes")
    func persistencePreservesOriginalGB18030Bytes() throws {
        let text = "書名：測試\n作者：作者\n第一章 正文"
        let data = try #require(text.data(using: TXTFileReader.gb18030Encoding))
        let sourceURL = try writeTemporaryTXT(data: data)
        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: destinationURL)
        }

        try TXTFilePersistence.persistOriginal(
            source: sourceURL,
            destination: destinationURL
        )

        #expect(try Data(contentsOf: destinationURL) == data)
        #expect(try TXTFileReader.readTextFile(url: destinationURL) == text)
    }

    @Test("large GB18030 chapter index stays below the first-open budget")
    func largeGB18030ChapterIndexStaysBelowBudget() throws {
        let chapterCount = 200
        let bodyLine = "　普通正文內容，用來模擬大型小說的段落。\r\n"
        var text = ""
        text.reserveCapacity(22 * 1024 * 1024)
        for chapter in 1...chapterCount {
            text += "第\(chapter)章 測試章節\r\n"
            for _ in 0..<1_000 {
                text += bodyLine
            }
        }
        let data = try #require(text.data(using: TXTFileReader.gb18030Encoding))
        let url = try writeTemporaryTXT(data: data)
        defer { try? FileManager.default.removeItem(at: url) }
        let mapped = try TXTFileReader.readMappedTextFile(url: url)

        let start = ProcessInfo.processInfo.systemUptime
        let indexes = TXTChapterParser.parseMappedChapterIndexes(
            mapped,
            bookTitle: "大型測試"
        )
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - start) * 1_000

        #expect(indexes.count == chapterCount)
        #expect(elapsedMs < 500, "GB18030 index took \(elapsedMs) ms")
    }

    @Test("Big5 mapped indexing keeps chapter detection")
    func big5MappedIndexingKeepsChapterDetection() throws {
        let big5Encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)
            )
        )
        let text = "第一章 開始\r\n　這是正文。\r\n第二章 繼續\r\n　另一段正文。"
        let data = try #require(text.data(using: big5Encoding))
        let mapped = TXTMappedTextFile(data: data, encoding: big5Encoding)

        let indexes = TXTChapterParser.parseMappedChapterIndexes(
            mapped,
            bookTitle: "Big5 測試"
        )

        #expect(indexes.map(\.title) == ["第一章 開始", "第二章 繼續"])
    }

    @Test("UTF-16 mapped indexing keeps every chapter")
    func utf16MappedIndexingKeepsEveryChapter() throws {
        let text = "第一章 開始\r\n　這是正文。\r\n第二章 繼續\r\n　另一段正文。"
        var data = Data([0xFF, 0xFE])
        data.append(try #require(text.data(using: .utf16LittleEndian)))
        let mapped = TXTMappedTextFile(data: data, encoding: .utf16LittleEndian)

        let indexes = TXTChapterParser.parseMappedChapterIndexes(
            mapped,
            bookTitle: "UTF-16 測試"
        )

        #expect(indexes.map(\.title) == ["第一章 開始", "第二章 繼續"])
        #expect(
            TXTChapterParser.chapterText(
                mapped,
                byteRange: indexes[0].byteRange
            ).contains("這是正文")
        )
    }

    @Test("UTF-16 block indexes remain code-unit aligned")
    func utf16BlockIndexesRemainCodeUnitAligned() throws {
        let text = String(repeating: "普通正文內容，沒有章節標題。\r\n", count: 2_000)
        var data = Data([0xFF, 0xFE])
        data.append(try #require(text.data(using: .utf16LittleEndian)))
        let mapped = TXTMappedTextFile(data: data, encoding: .utf16LittleEndian)

        let indexes = TXTChapterParser.parseMappedChapterIndexes(
            mapped,
            bookTitle: "UTF-16 長文"
        )

        #expect(indexes.count > 1)
        #expect(indexes.allSatisfy {
            $0.byteRange.lowerBound.isMultiple(of: 2)
                && $0.byteRange.upperBound.isMultiple(of: 2)
        })
        #expect(
            TXTChapterParser.chapterText(
                mapped,
                byteRange: indexes[1].byteRange
            ).contains("普通正文內容")
        )
    }

    private func writeTemporaryTXT(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try data.write(to: url)
        return url
    }
}
