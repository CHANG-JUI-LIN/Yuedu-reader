import Foundation
import Testing
@testable import yuedu_app

@Suite("MOBI file")
struct MOBIFileTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/MOBI")

    private static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtures.appendingPathComponent(name))
    }

    /// Absolute byte offset of record `index`, read from the PalmDB record table.
    private static func recordOffset(_ data: Data, _ index: Int) -> Int {
        let entry = 78 + index * 8
        return data[entry..<(entry + 4)].reduce(0) { $0 << 8 | Int($1) }
    }

    // MARK: - Fixtures

    @Test("the format, not the extension, decides the kind", arguments: [
        ("features.mobi", MOBIFile.Kind.mobi6),
        ("features-uncompressed.mobi", .mobi6),
        ("features.azw3", .kf8),
        ("features-combo.mobi", .kf8),
        ("vertical-zh.mobi", .mobi6),
        ("vertical-zh.azw3", .kf8),
        ("gutenberg-11-kindle.mobi", .mobi6),
        ("gutenberg-11-kf8.azw3", .kf8),
    ])
    func kind(name: String, kind: MOBIFile.Kind) throws {
        let file = try MOBIFile(data: Self.fixture(name))
        #expect(file.kind == kind)
    }

    @Test("a combo file is read from the KF8 part after its BOUNDARY record")
    func comboReadsKF8Part() throws {
        let file = try MOBIFile(data: Self.fixture("features-combo.mobi"))
        #expect(file.partStart > 0)
        #expect(try file.record(file.partStart - 1) == Data("BOUNDARY".utf8))
        #expect(file.headers.version == 8)
        // Resources stay counted from record 0's base, where the shared images are.
        #expect(try file.cover()?.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
    }

    @Test("decompressed text is exactly as long as the PalmDOC header says", arguments: [
        "features.mobi", "features-uncompressed.mobi", "features.azw3", "features-combo.mobi",
        "vertical-zh.mobi", "vertical-zh.azw3", "gutenberg-11-kindle.mobi", "gutenberg-11-kf8.azw3",
    ])
    func textLengthMatchesHeader(name: String) throws {
        let file = try MOBIFile(data: Self.fixture(name))
        #expect(try file.text().count == Int(file.headers.textLength))
    }

    @Test("a KF8 file's last flow ends where its text ends", arguments: [
        "features.azw3", "features-combo.mobi", "vertical-zh.azw3", "gutenberg-11-kf8.azw3",
    ])
    func lastFlowEndsAtTextLength(name: String) throws {
        let file = try MOBIFile(data: Self.fixture(name))
        let kf8 = try #require(file.headers.kf8)
        let fdst = MOBIByteReader(try file.partRecord(Int(kf8.fdstIndex)), record: nil)
        #expect(try fdst.magic(at: 0) == "FDST")
        let entries = Int(try fdst.uint32(at: 8))
        let lastEnd = try fdst.uint32(at: 12 + (entries - 1) * 8 + 4)
        #expect(lastEnd == file.headers.textLength)
    }

    @Test("PalmDOC output equals the same book stored uncompressed")
    func palmDOCMatchesStoredText() throws {
        let compressed = try MOBIFile(data: Self.fixture("features.mobi"))
        let stored = try MOBIFile(data: Self.fixture("features-uncompressed.mobi"))
        #expect(compressed.headers.compression == 2)
        #expect(stored.headers.compression == 1)
        #expect(try compressed.text() == stored.text())
    }

    @Test("CJK characters cut by record boundaries come out whole", arguments: [
        "vertical-zh.mobi", "vertical-zh.azw3",
    ])
    func multibyteTrailerIsRemoved(name: String) throws {
        let file = try MOBIFile(data: Self.fixture(name))
        #expect(file.headers.extraRecordDataFlags & 1 == 1)
        #expect(file.headers.textRecordCount > 1)
        // Strict decoding fails on any byte the multibyte entry left behind.
        let text = try #require(String(data: file.text(), encoding: .utf8))
        #expect(text.contains("第二章　潮汐"))
        #expect(text.contains("今夜燈火未曾熄滅"))
    }

    @Test("metadata comes from EXTH")
    func metadataFromEXTH() throws {
        let metadata = try MOBIFile(data: Self.fixture("features.azw3")).metadata
        #expect(metadata.title == "The Lantern Keeper's Almanac")
        #expect(metadata.authors == ["Mira Holt", "Daniel Ashe"])
        #expect(metadata.publisher == "Yuedu Test Fixtures")
        #expect(metadata.language == "en")
        #expect(metadata.description == "A small book written for the MOBI importer tests.")
        #expect(metadata.subjects == ["Lighthouses", "Almanacs"])
        #expect(metadata.isbn == "9780000000002")
        #expect(!metadata.fixedLayout)
    }

    @Test("a vertical Chinese book keeps its title, author and page direction")
    func verticalChineseMetadata() throws {
        let metadata = try MOBIFile(data: Self.fixture("vertical-zh.azw3")).metadata
        #expect(metadata.title == "守燈人手記")
        #expect(metadata.authors == ["林知秋"])
        #expect(metadata.language == "zh")
        #expect(metadata.pageProgressionDirection == "rtl")
    }

    @Test("both Gutenberg Kindle downloads carry the book's title, author and cover", arguments: [
        "gutenberg-11-kindle.mobi", "gutenberg-11-kf8.azw3",
    ])
    func gutenbergMetadata(name: String) throws {
        let file = try MOBIFile(data: Self.fixture(name))
        #expect(file.metadata.title == "Alice's Adventures in Wonderland")
        #expect(file.metadata.authors == ["Lewis Carroll"])
        #expect(try file.cover()?.prefix(3) == Data([0xFF, 0xD8, 0xFF]))
    }

    // MARK: - Refusals

    @Test("a file with DRM is refused before its text is read")
    func encryptedIsRefused() throws {
        var data = try Self.fixture("features.azw3")
        data[Self.recordOffset(data, 0) + 13] = 2
        #expect(throws: MOBIError.encrypted(2)) { try MOBIFile(data: data) }
    }

    @Test("a combo file whose KF8 part has DRM is refused")
    func encryptedKF8PartIsRefused() throws {
        var data = try Self.fixture("features-combo.mobi")
        let partStart = try MOBIFile(data: data).partStart
        data[Self.recordOffset(data, partStart) + 13] = 1
        #expect(throws: MOBIError.encrypted(1)) { try MOBIFile(data: data) }
    }

    @Test("a combo file whose KF8 part lacks its skeleton index throws instead of reading MOBI 6")
    func brokenKF8PartThrows() throws {
        var data = try Self.fixture("features-combo.mobi")
        let partStart = try MOBIFile(data: data).partStart
        let skeletonField = Self.recordOffset(data, partStart) + 0xFC
        data.replaceSubrange(skeletonField..<(skeletonField + 4), with: [0xFF, 0xFF, 0xFF, 0xFF])
        #expect(throws: MOBIError.missingMOBIHeader(record: partStart)) { try MOBIFile(data: data) }
    }

    @Test("HUFF/CDIC is refused until a sample has been tested")
    func huffCDICIsRefused() throws {
        var data = try Self.fixture("features.azw3")
        let record0 = Self.recordOffset(data, 0)
        data[record0] = 0x44  // 17480 = "DH"
        data[record0 + 1] = 0x48
        #expect(throws: MOBIError.unknownCompression(17480)) { try MOBIFile(data: data) }
    }

    @Test("a file cut short fails on the first record it lost")
    func truncatedFileThrows() throws {
        let data = try Self.fixture("features.azw3")
        let cut = data.prefix(Self.recordOffset(data, 3) + 10)
        let file = try MOBIFile(data: cut)
        #expect(throws: MOBIError.truncatedRecord(3)) { try file.text() }
    }

    @Test("an EPUB is not a MOBI file")
    func epubIsNotMOBI() throws {
        let data = try Self.fixture("features.epub")
        #expect(!MOBIFile.isMOBI(data))
        #expect(throws: MOBIError.notMOBI) { try MOBIFile(data: data) }
    }

    // MARK: - Synthetic files (what Calibre never writes)

    /// A one-text-record MOBI 6 file with a header shorter than 0xE4, so its
    /// extra-record-data flags must be ignored, and no EXTH block.
    static func shortHeaderFile(text: [UInt8], encoding: UInt32, title: [UInt8], locale: UInt32) -> Data {
        func u16(_ value: Int) -> [UInt8] { [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)] }
        func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(value >> (24 - 8 * $0) & 0xFF) } }

        var header = [UInt8](repeating: 0, count: 0x100)
        header.replaceSubrange(0..<2, with: u16(1))                              // no compression
        header.replaceSubrange(4..<8, with: u32(UInt32(text.count)))
        header.replaceSubrange(8..<10, with: u16(1))                             // one text record
        header.replaceSubrange(10..<12, with: u16(4096))
        header.replaceSubrange(16..<20, with: Array("MOBI".utf8))
        header.replaceSubrange(20..<24, with: u32(0xE0))
        header.replaceSubrange(24..<28, with: u32(2))
        header.replaceSubrange(28..<32, with: u32(encoding))
        header.replaceSubrange(36..<40, with: u32(6))
        header.replaceSubrange(0x54..<0x58, with: u32(0x100))
        header.replaceSubrange(0x58..<0x5C, with: u32(UInt32(title.count)))
        header.replaceSubrange(0x5C..<0x60, with: u32(locale))
        header.replaceSubrange(0x6C..<0x70, with: u32(2))
        header.replaceSubrange(0xF0..<0xF4, with: [0xFF, 0xFF, 0xFF, 0xFF])     // not flags: past the header
        let record0 = header + title

        var file = [UInt8](repeating: 0, count: 78)
        file.replaceSubrange(0..<4, with: Array("Test".utf8))
        file.replaceSubrange(60..<68, with: Array("BOOKMOBI".utf8))
        file.replaceSubrange(76..<78, with: u16(2))
        let first = 78 + 2 * 8 + 2
        file += u32(UInt32(first)) + u32(0)
        file += u32(UInt32(first + record0.count)) + u32(1)
        file += [0, 0]
        return Data(file + record0 + text)
    }

    @Test("a short header's late fields are not read from the bytes after it, whatever its version")
    func shortHeaderLateFields() throws {
        // A title long enough to reach past 0x108, where the NCX and KF8 fields
        // would be, and a version of 8.
        let text = Array("Text".utf8)
        let data = Self.shortHeaderFile(text: text, encoding: 65001,
                                        title: Array(String(repeating: "Title ", count: 10).utf8), locale: 9)
        var record = Data(data[(78 + 2 * 8 + 2) ..< (data.count - text.count)])
        record.replaceSubrange(36 ..< 40, with: [0, 0, 0, 8])
        let headers = try MOBIHeaders(record: record, index: 0)
        #expect(record.count > 0x108)
        #expect(headers.version == 8)
        #expect(headers.kf8 == nil)
        #expect(headers.ncxIndex == MOBIHeaders.nullIndex)
    }

    @Test("a cp1252 file decodes as a browser would, undefined bytes included")
    func cp1252ShortHeader() throws {
        // "Café — €" then 0x81, which windows-1252 leaves undefined.
        let text: [UInt8] = [0x43, 0x61, 0x66, 0xE9, 0x20, 0x97, 0x20, 0x80, 0x81]
        let data = Self.shortHeaderFile(text: text, encoding: 1252,
                                        title: [0x4E, 0x61, 0xEF, 0x76, 0x65],  // "Naïve"
                                        locale: 12 | 2 << 10)
        let file = try MOBIFile(data: data)
        #expect(file.kind == .mobi6)
        #expect(file.headers.encoding == .cp1252)
        #expect(file.headers.extraRecordDataFlags == 0)
        #expect(file.headers.ncxIndex == MOBIHeaders.nullIndex)
        #expect(file.headers.exth == nil)
        #expect(file.headers.encoding.decode(try file.text()) == "Café — €\u{81}")
        #expect(file.metadata.title == "Naïve")
        #expect(file.metadata.language == "fr-BE")
        #expect(file.metadata.authors.isEmpty)
        #expect(file.metadata.coverResource == nil)
    }

    @Test("an encoding the format does not define is refused")
    func unknownEncodingIsRefused() {
        let data = Self.shortHeaderFile(text: Array("x".utf8), encoding: 932, title: [], locale: 0)
        #expect(throws: MOBIError.unsupportedEncoding(932)) { try MOBIFile(data: data) }
    }

    // MARK: - PalmDOC and trailing entries

    @Test("PalmDOC literals, space pairs and overlapping back-references")
    func palmDOCOpcodes() throws {
        // "a", then distance 1 length 5 (copies the bytes it writes), then " b",
        // a 3-byte literal run and a zero byte.
        let input = Data([0x61, 0x80, 0x0A, 0xE2, 0x03, 0x78, 0x79, 0x7A, 0x00])
        let output = try PalmDOCDecompressor.decompress(input, record: 1)
        #expect(output == Data("aaaaaa bxyz".utf8) + Data([0x00]))
    }

    @Test("corrupt PalmDOC data throws instead of reading past the record", arguments: [
        [UInt8]([0x80, 0x0A]),          // a back-reference before any output
        [0x61, 0x80, 0x12],             // distance 2 with one byte written
        [0x04, 0x61, 0x62],             // a 4-byte literal run with 2 bytes left
        [0x61, 0x80],                   // a pair cut off by the record's end
    ])
    func corruptPalmDOC(bytes: [UInt8]) {
        #expect(throws: MOBIError.corruptText(record: 7)) {
            try PalmDOCDecompressor.decompress(Data(bytes), record: 7)
        }
    }

    @Test("trailing entries are stripped from the end inward, multibyte last")
    func trailingEntries() throws {
        // Two continuation bytes of a cut character and their count byte, then a
        // 3-byte entry whose size byte (0x83) counts itself.
        let record = Data("hello".utf8) + Data([0xE4, 0xB8, 0x02]) + Data([0xAA, 0xBB, 0x83])
        let stripped = try MOBITrailingEntries(flags: 0b11).strip(record, index: 1)
        #expect(stripped == Data("hello".utf8))
    }

    @Test("an entry size spread over two 7-bit groups")
    func trailingEntryMultiByteSize() throws {
        // 200 = 0b1_1001000: groups 0x01 (first, top bit set) and 0x48.
        let record = Data("text".utf8) + Data(repeating: 0xEE, count: 198) + Data([0x81, 0x48])
        let stripped = try MOBITrailingEntries(flags: 0b10).strip(record, index: 1)
        #expect(stripped == Data("text".utf8))
    }

    @Test("a trailing entry larger than its record is corrupt")
    func trailingEntryTooLarge() {
        let record = Data([0x61, 0x62, 0x90])  // claims 16 bytes
        #expect(throws: MOBIError.corruptText(record: 4)) {
            try MOBITrailingEntries(flags: 0b10).strip(record, index: 4)
        }
    }
}
