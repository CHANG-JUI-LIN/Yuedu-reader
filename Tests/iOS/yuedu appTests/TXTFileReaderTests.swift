import Foundation
import CoreGraphics
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

    @Test("uncached reader preparation exposes a bounded preview before full indexing")
    func uncachedReaderPreparationExposesBoundedPreview() throws {
        let text = String(repeating: "普通正文內容，先顯示再建立完整索引。\n", count: 20_000)
        let data = try #require(text.data(using: .utf8))
        let url = try writeTemporaryTXT(data: data)
        let bookId = UUID()
        defer {
            try? FileManager.default.removeItem(at: url)
            TXTChapterParser.deleteCachedIndexes(bookId: bookId)
        }

        let preparation = try TXTReaderPreparationService.prepare(
            url: url,
            bookId: bookId,
            bookTitle: "預覽測試"
        )

        #expect(preparation.cachedChapterIndexes == nil)
        #expect(!preparation.previewText.isEmpty)
        #expect(
            preparation.previewText.lengthOfBytes(using: .utf8)
                <= TXTInitialPreviewPlanner.maximumByteCount
        )

        let indexes = TXTReaderPreparationService.buildChapterIndexes(
            for: preparation
        )
        #expect(indexes.count > 1)
        #expect(
            TXTChapterParser.loadCachedIndexes(
                bookId: bookId,
                fileSize: preparation.fileSize,
                fingerprint: preparation.fingerprint,
                encoding: preparation.encoding
            ) == nil
        )
    }

    @Test("real codec fixtures round-trip through every local TXT entry", arguments: [
        "aozora-cp932", "aozora-euc-jp", "simplified-gbk", "simplified-gb18030",
        "traditional-big5", "korean-euc-kr", "aozora-neko-jijo",
    ])
    func codecFixturesRoundTrip(name: String) throws {
        let encodings: [String: CFStringEncodings] = [
            "aozora-cp932": .dosJapanese, "aozora-euc-jp": .EUC_JP, "aozora-neko-jijo": .dosJapanese,
            "simplified-gbk": .GB_18030_2000, "simplified-gb18030": .GB_18030_2000,
            "traditional-big5": .big5, "korean-euc-kr": .EUC_KR,
        ]
        let expectedEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(try #require(encodings[name]).rawValue)))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TXTEncodings/" + name)
        let data = try Data(contentsOf: fixture.appendingPathExtension("txt"))
        let expected = try String(contentsOf: fixture.appendingPathExtension("utf8"), encoding: .utf8)
        let url = try writeTemporaryTXT(data: data)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TXTFileReader.detectEncodingBySampling(url: url) == expectedEncoding)
        #expect(try TXTFileReader.readTextFile(url: url) == expected)
        let mapped = try TXTFileReader.readMappedTextFile(url: url)
        #expect(mapped.encoding == expectedEncoding)
        #expect(mapped.string(in: 0..<data.count) == expected)
        let prefix = try TXTFileReader.readPrefix(url: url, maxByteCount: 129)
        #expect(expected.hasPrefix(prefix))
        #expect(!prefix.contains("�"))
        let destination = url.deletingPathExtension().appendingPathExtension("copy.txt")
        defer { try? FileManager.default.removeItem(at: destination) }
        try TXTFilePersistence.persistOriginal(source: url, destination: destination)
        #expect(try Data(contentsOf: destination) == data)
        #expect(try TXTFileReader.readTextFile(url: destination) == expected)
    }

    @Test("ASCII front matter does not dilute Japanese evidence")
    func japaneseAfterASCIIFrontMatter() throws {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        let text = String(repeating: "ASCII preface\n", count: 1_000)
            + String(repeating: "私は日本語の本を読み、漢字《かんじ》を学びます。\n", count: 200)
        let data = try #require(text.data(using: encoding))
        let url = try writeTemporaryTXT(data: data)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TXTFileReader.detectEncodingBySampling(url: url) == encoding)
        #expect(try TXTFileReader.readTextFile(url: url) == text)
    }

    @Test("UTF-8 and BOM-less UTF-16 preserve existing content", arguments: [
        String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian,
    ])
    func unicodeWithoutBOM(encoding: String.Encoding) throws {
        let text = "第一章 Unicode\n" + String(repeating: "中文、日本語、한국어。\n", count: 200)
        let url = try writeTemporaryTXT(data: try #require(text.data(using: encoding)))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TXTFileReader.detectEncodingBySampling(url: url) == encoding)
        #expect(try TXTFileReader.readTextFile(url: url) == text)
    }

    @Test("UTF-16 big endian BOM is honored")
    func sampledDetectionHonorsUTF16BEBOM() throws {
        let text = "第一章 UTF16\n日本語。"
        var data = Data([0xFE, 0xFF])
        data.append(try #require(text.data(using: .utf16BigEndian)))
        let url = try writeTemporaryTXT(data: data)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TXTFileReader.detectEncodingBySampling(url: url) == .utf16BigEndian)
        #expect(try TXTFileReader.readTextFile(url: url) == text)
    }

    @Test("sampling tolerates a cut through a UTF-8 scalar")
    func truncatedUTF8Sample() throws {
        let text = String(repeating: "日本語の本を読みます。", count: 20_000) + "𠀀"
        let url = try writeTemporaryTXT(data: Data(text.utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TXTFileReader.detectEncodingBySampling(url: url) == .utf8)
        let prefix = try TXTFileReader.readPrefix(url: url, maxByteCount: 8192)
        #expect(text.hasPrefix(prefix))
        #expect(!prefix.contains("�"))
    }

    @Test("low-confidence invalid bytes fail instead of producing garbage")
    func lowConfidenceIsReported() throws {
        let url = try writeTemporaryTXT(data: Data([0xFF, 0x01, 0xFF, 0x02, 0xFF, 0x03, 0xFF]))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: TXTFileReaderError.self) {
            try TXTFileReader.readMappedTextFile(url: url)
        }
    }

    @Test("fixed sample cuts preserve multibyte sequences", arguments: [
        "aozora-cp932", "aozora-euc-jp", "simplified-gb18030", "traditional-big5",
    ])
    func truncatedLegacySamples(name: String) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TXTEncodings/" + name)
        let original = try Data(contentsOf: fixture.appendingPathExtension("txt"))
        let text = try String(contentsOf: fixture.appendingPathExtension("utf8"), encoding: .utf8)
        var data = Data()
        while data.count <= 512 * 1024 + 10 { data.append(original) }
        let url = try writeTemporaryTXT(data: data)
        defer { try? FileManager.default.removeItem(at: url) }
        let fullText = String(repeating: text, count: data.count / original.count)
        let mapped = try TXTFileReader.readMappedTextFile(url: url)
        #expect(mapped.string(in: 0..<data.count) == fullText)
        for count in (512 * 1024 - 3)...(512 * 1024 + 3) {
            let prefix = try TXTFileReader.readPrefix(url: url, maxByteCount: count)
            #expect(fullText.hasPrefix(prefix))
            #expect(!prefix.contains("�"))
        }
    }

    private func writeTemporaryTXT(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try data.write(to: url)
        return url
    }
}
