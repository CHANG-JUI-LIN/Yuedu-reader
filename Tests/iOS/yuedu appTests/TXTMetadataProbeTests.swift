import Foundation
import Testing
@testable import yuedu_app

@Suite("TXTMetadataProbe", .serialized)
struct TXTMetadataProbeTests {

    @Test("detects Traditional Chinese title and author labels")
    func detectsTraditionalChineseLabels() throws {
        let url = try writeTemporaryTXT("書名：射鵰英雄傳\n作者：金庸\n第一章 風雪驚變")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "fallback")

        #expect(metadata.title == "射鵰英雄傳")
        #expect(metadata.author == "金庸")
    }

    @Test("detects Simplified Chinese metadata labels")
    func detectsSimplifiedChineseLabels() throws {
        let url = try writeTemporaryTXT("书名: 三体\n作者: 刘慈欣\n第一章")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "fallback")

        #expect(metadata.title == "三体")
        #expect(metadata.author == "刘慈欣")
    }

    @Test("detects English metadata labels")
    func detectsEnglishLabels() throws {
        let url = try writeTemporaryTXT("Title: Pride and Prejudice\nAuthor: Jane Austen\nChapter 1")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "fallback")

        #expect(metadata.title == "Pride and Prejudice")
        #expect(metadata.author == "Jane Austen")
    }

    @Test("uses line before standalone author credit as title")
    func detectsStandaloneAuthorCredit() throws {
        let url = try writeTemporaryTXT("射鵰英雄傳\n金庸 著\n第一章 風雪驚變")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "fallback")

        #expect(metadata.title == "射鵰英雄傳")
        #expect(metadata.author == "金庸")
    }

    @Test("falls back to filename and nil author when metadata is absent")
    func fallsBackWhenMetadataIsAbsent() throws {
        let url = try writeTemporaryTXT("第一章\n這裡只有正文。")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "檔名書名")

        #expect(metadata.title == "檔名書名")
        #expect(metadata.author == nil)
    }

    @Test("rejects a long body line as an inferred title")
    func rejectsLongBodyLineAsTitle() throws {
        let longBody = String(repeating: "這是一段正文內容，", count: 20)
        let url = try writeTemporaryTXT("\(longBody)\n王小明 著\n第一章")

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "安全檔名")

        #expect(metadata.title == "安全檔名")
        #expect(metadata.author == "王小明")
    }

    @Test("decodes GB18030 metadata using TXTFileReader rules")
    func decodesGB18030Metadata() throws {
        let text = "书名：活着\n作者：余华\n第一章"
        let data = try #require(text.data(using: TXTFileReader.gb18030Encoding))
        let url = try writeTemporaryTXT(data)

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "fallback")

        #expect(metadata.title == "活着")
        #expect(metadata.author == "余华")
    }

    @Test("ignores metadata beyond the bounded sample")
    func ignoresMetadataBeyondSampleBoundary() throws {
        var data = Data(repeating: 0x61, count: TXTMetadataProbe.maximumSampleBytes)
        data.append(Data("\n作者：不應讀到\n".utf8))
        let url = try writeTemporaryTXT(data)

        let metadata = try TXTMetadataProbe.probe(url: url, fallbackTitle: "邊界測試")

        #expect(metadata.title == "邊界測試")
        #expect(metadata.author == nil)
    }

    @Test("BookStore imports the original TXT and inferred metadata")
    func bookStoreImportsOriginalTXTAndMetadata() async throws {
        let sourceData = Data("書名：邊城\n作者：沈從文\n\n第一章\n原始內容保持不變。".utf8)
        let sourceURL = try writeTemporaryTXT(sourceData)
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let store = BookStore(metadataFileURL: metadataURL)

        let book = try await store.importTxt(url: sourceURL)
        let importedURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(book.contentFilename)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: importedURL)
            try? FileManager.default.removeItem(at: metadataURL)
        }

        #expect(book.title == "邊城")
        #expect(book.author == "沈從文")
        #expect(book.contentPipelineKind == .txt)
        #expect(book.contentFilename.hasSuffix(".txt"))
        #expect(try Data(contentsOf: importedURL) == sourceData)
    }

    @Test("BookStore keeps GB18030 bytes while decoded content remains readable")
    func bookStoreKeepsGB18030BytesAndReadableContent() async throws {
        let text = "书名：活着\n作者：余华\n\n第一章\n原始内容保持不变。"
        let sourceData = try #require(text.data(using: TXTFileReader.gb18030Encoding))
        let sourceURL = try writeTemporaryTXT(sourceData)
        let metadataURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let store = BookStore(metadataFileURL: metadataURL)

        let book = try await store.importTxt(url: sourceURL)
        let importedURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent(book.contentFilename)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: importedURL)
            try? FileManager.default.removeItem(at: metadataURL)
        }

        #expect(book.title == "活着")
        #expect(book.author == "余华")
        #expect(try Data(contentsOf: importedURL) == sourceData)
        #expect(store.content(for: book) == text)
    }

    private func writeTemporaryTXT(_ text: String) throws -> URL {
        try writeTemporaryTXT(Data(text.utf8))
    }

    private func writeTemporaryTXT(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try data.write(to: url)
        return url
    }
}
