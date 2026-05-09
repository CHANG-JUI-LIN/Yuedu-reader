import Foundation
import Testing
@testable import yuedu_app

@Suite("TXTFileReader")
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

    private func writeTemporaryTXT(data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("txt")
        try data.write(to: url)
        return url
    }
}
