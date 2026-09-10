import CoreText
import Testing
import UIKit
@testable import yuedu_app

@Suite("Embedded font identity", .serialized)
@MainActor
struct EmbeddedFontIdentityTests {
    @Test func privateIdentityPreservesGlyphsAndMetrics() throws {
        let original = try fixture()
        let isolated = try #require(EmbeddedTrueTypeFontIdentity.namespaced(original, digest: "fixture"))
        let first = try font(original), second = try font(isolated)
        #expect(CTFontCopyPostScriptName(second) as String == "YueduEmbedded-fixture")
        for tag in [kCTFontTableCmap, kCTFontTableGlyf, kCTFontTableLoca, kCTFontTableHmtx] {
            #expect(table(first, tag) == table(second, tag))
        }
        #expect(CTFontGetGlyphCount(first) == CTFontGetGlyphCount(second))
        #expect(CTFontGetUnitsPerEm(first) == CTFontGetUnitsPerEm(second))
    }

    @Test func sameNameAndCmapCannotSubstituteDifferentMetrics() throws {
        let original = try fixture()
        let firstBytes = try #require(EmbeddedTrueTypeFontIdentity.namespaced(original, digest: "collision-fixture"))
        var modified = [UInt8](original)
        let tableCount = Int(modified[4]) << 8 | Int(modified[5])
        var changed = false
        for index in 0..<tableCount {
            let record = 12 + 16 * index
            if String(bytes: modified[record..<(record + 4)], encoding: .ascii) == "hmtx" {
                let offset = modified[(record + 8)..<(record + 12)].reduce(0) { $0 << 8 | Int($1) }
                modified[offset + 1] ^= 1
                changed = true
            }
        }
        #expect(changed)
        // Rebuild checksums while deliberately keeping an identical font name.
        let secondBytes = try #require(EmbeddedTrueTypeFontIdentity.namespaced(Data(modified), digest: "collision-fixture"))
        let service = CoreTextFontRegistrationService()
        let first = try #require(service.registerFont(data: firstBytes, alias: "book-one", existingTempURL: nil))
        let second = try #require(service.registerFont(data: secondBytes, alias: "book-two", existingTempURL: nil))
        #expect(first.postScriptName != second.postScriptName)
        let loadedFirst = try #require(UIFont(name: first.postScriptName, size: 24)) as CTFont
        let loadedSecond = try #require(UIFont(name: second.postScriptName, size: 24)) as CTFont
        #expect(table(loadedFirst, kCTFontTableCmap) == table(loadedSecond, kCTFontTableCmap))
        #expect(table(loadedFirst, kCTFontTableHmtx) == table(try font(firstBytes), kCTFontTableHmtx))
        #expect(table(loadedSecond, kCTFontTableHmtx) == table(try font(secondBytes), kCTFontTableHmtx))
        #expect(table(loadedFirst, kCTFontTableHmtx) != table(loadedSecond, kCTFontTableHmtx))
        let reused = try #require(service.registerFont(data: secondBytes, alias: "reopened-book", existingTempURL: nil))
        #expect(reused.postScriptName == second.postScriptName)
    }

    @Test func malformedTableDirectoryIsRejected() {
        #expect(EmbeddedTrueTypeFontIdentity.namespaced(Data(), digest: "invalid") == nil)
        #expect(EmbeddedTrueTypeFontIdentity.namespaced(
            Data([0,1,0,0,255,255,0,0,0,0,0,0]), digest: "invalid") == nil)
    }

    private func fixture() throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Ahem.ttf"))
    }
    private func font(_ data: Data) throws -> CTFont {
        let provider = try #require(CGDataProvider(data: data as CFData))
        return CTFontCreateWithGraphicsFont(try #require(CGFont(provider)), 24, nil, nil)
    }
    private func table<T: BinaryInteger>(_ font: CTFont, _ tag: T) -> Data? {
        CTFontCopyTable(font, CTFontTableTag(tag), []).map { $0 as Data }
    }
}
