import Foundation
import Testing
@testable import yuedu_app

/// Zip entry names written without the UTF-8 flag: macOS `zip` (UTF-8 bytes) and Windows
/// (the system code page). They used to decode as CP437, so 「01 第1章.mp3」 became
/// 「01 τ¼¼1τ½á.mp3」 in an audiobook's chapter list.
struct ZipEntryNamesTests {
    private static func encoding(_ cf: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
    }

    private static let gbk = encoding(.GB_18030_2000)
    private static let big5 = encoding(.big5_HKSCS_1999)

    @Test("UTF-8 names without the flag read as UTF-8")
    func utf8WithoutFlag() {
        let names = ["01 第1章 序幕.mp3", "cover.jpg"]
        let decoded = ZipEntryNames.decode(rawNames: names.map { Data($0.utf8) })
        #expect(decoded.names == names)
        #expect(decoded.legacyEncoding == nil)
    }

    @Test("GBK names from a Simplified Chinese Windows read as GBK")
    func gbkNames() {
        let names = ["01 第1章 序幕.mp3", "02 第2章 风起.mp3", "03 第3章 云涌.mp3"]
        let decoded = ZipEntryNames.decode(rawNames: names.map { $0.data(using: Self.gbk)! })
        #expect(decoded.names == names)
        #expect(decoded.legacyEncoding == Self.gbk)
    }

    @Test("Big5 names from a Traditional Chinese Windows read as Big5")
    func big5Names() {
        let names = ["01 第1章 序幕.mp3", "02 第2章 風起.mp3", "第1集.mp3"]
        let decoded = ZipEntryNames.decode(rawNames: names.map { $0.data(using: Self.big5)! })
        #expect(decoded.names == names)
        #expect(decoded.legacyEncoding == Self.big5)
    }

    @Test("names no CJK code page reads stay CP437, as the format says")
    func cp437Names() {
        // 「Café」 in CP437: é is 0x82, followed by a byte no CJK code page accepts after it.
        let raw = Data("Caf".utf8) + Data([0x82]) + Data(".mp3".utf8)
        let decoded = ZipEntryNames.decode(rawNames: [raw, Data("02.mp3".utf8)])
        #expect(decoded.names == ["Café.mp3", "02.mp3"])
        #expect(decoded.legacyEncoding == ZipEntryNames.codePage437)
    }

    @Test("an audiobook zip with GBK names and no UTF-8 flag lists its chapters readably")
    func audiobookArchiveWithGBKNames() async throws {
        let names = ["書/01 第1章 序幕.mp3", "書/02 第2章 风起.mp3"]
        let url = try Self.writeStoredZip(entries: names.map { ($0.data(using: Self.gbk)!, Data("audio".utf8)) })
        defer { try? FileManager.default.removeItem(at: url) }

        let paths = try await LocalAudiobookArchive.audioEntryPaths(in: url)
        #expect(paths == names)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let chapters = try await LocalAudiobookArchive.extractAudioEntries(from: url, to: directory)
        #expect(chapters.map(\.filename) == ["000.mp3", "001.mp3"])
        #expect(try Data(contentsOf: directory.appendingPathComponent("001.mp3")) == Data("audio".utf8))
        #expect(chapters.map(\.title).allSatisfy { $0.contains("第") })
    }

    /// A stored (uncompressed) zip whose names are the given bytes, with general-purpose
    /// bit 11 off — what Windows and macOS `zip` write. ZIPFoundation itself always writes
    /// UTF-8 names, so it cannot make this fixture.
    private static func writeStoredZip(entries: [(name: Data, contents: Data)]) throws -> URL {
        var body = Data()
        var directory = Data()
        for (name, contents) in entries {
            let offset = UInt32(body.count)
            let crc = crc32(contents)
            body.append(le32(0x0403_4B50))
            body.append(le16(10)); body.append(le16(0)); body.append(le16(0))  // version, flags, stored
            body.append(le16(0)); body.append(le16(0x21))                      // time, date
            body.append(le32(crc)); body.append(le32(UInt32(contents.count))); body.append(le32(UInt32(contents.count)))
            body.append(le16(UInt16(name.count))); body.append(le16(0))
            body.append(name); body.append(contents)

            directory.append(le32(0x0201_4B50))
            directory.append(le16(20)); directory.append(le16(10)); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0x21))
            directory.append(le32(crc)); directory.append(le32(UInt32(contents.count))); directory.append(le32(UInt32(contents.count)))
            directory.append(le16(UInt16(name.count))); directory.append(le16(0)); directory.append(le16(0))
            directory.append(le16(0)); directory.append(le16(0)); directory.append(le32(0))
            directory.append(le32(offset))
            directory.append(name)
        }
        var zip = body
        zip.append(directory)
        zip.append(le32(0x0605_4B50))
        zip.append(le16(0)); zip.append(le16(0))
        zip.append(le16(UInt16(entries.count))); zip.append(le16(UInt16(entries.count)))
        zip.append(le32(UInt32(directory.count))); zip.append(le32(UInt32(body.count)))
        zip.append(le16(0))

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try zip.write(to: url)
        return url
    }

    private static func le16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    private static func le32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1))) }
        }
        return ~crc
    }
}
