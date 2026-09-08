import Foundation
import Testing
@testable import yuedu_app

@Suite(.serialized)
struct TXTLocationMigrationTests {
    @Test(arguments: [String.Encoding.utf8, .utf16LittleEndian])
    func mergedBodyAndTitleUseSourceCoordinates(encoding: String.Encoding) throws {
        let firstTitle = "第1章 開始"
        let falseTitle = "第一篇：測試"
        let before = "　前文😀。\r\n"
        let after = "　後文𠮷。\r\n"
        let text = firstTitle + "\r\n" + before + falseTitle + "\r\n" + after
        func size(_ value: String) throws -> Int { try #require(value.data(using: encoding)).count }
        let file = TXTMappedTextFile(data: try #require(text.data(using: encoding)), encoding: encoding)
        let firstStart = try size(firstTitle + "\r\n")
        let falseStart = try size(firstTitle + "\r\n" + before)
        let secondStart = try size(firstTitle + "\r\n" + before + falseTitle + "\r\n")
        let old = [TXTMappedChapterIndex(index: 0, title: firstTitle, byteRange: firstStart..<falseStart),
                   TXTMappedChapterIndex(index: 1, title: falseTitle, byteRange: secondStart..<file.byteCount)]
        let new = [TXTMappedChapterIndex(index: 0, title: firstTitle, byteRange: firstStart..<file.byteCount)]
        let body = "前文😀。\n第一篇：測試\n後文𠮷。\n"
        let oldRendered = falseTitle + "\n後文𠮷。\n"
        let newRendered = firstTitle + "\n" + body
        let mapping = try TXTLocationMigration(file: file, oldIndexes: old, newIndexes: new)
        let start = try mapping.map(.init(spineIndex: 1, charOffset: 0), oldRendered: oldRendered, newRendered: newRendered)
        #expect(start == .init(spineIndex: 0, charOffset: (newRendered as NSString).range(of: falseTitle).location))
        let offset = (oldRendered as NSString).range(of: "𠮷").location
        let mapped = try mapping.map(.init(spineIndex: 1, charOffset: offset), oldRendered: oldRendered, newRendered: newRendered)
        #expect(mapped.charOffset == (newRendered as NSString).range(of: "𠮷").location)
        let end = try mapping.map(.init(spineIndex: 1, charOffset: offset + 2), oldRendered: oldRendered, newRendered: newRendered)
        #expect(end.charOffset - mapped.charOffset == 2)
    }

    @Test func invalidOldIndexIsRejected() throws {
        let file = TXTMappedTextFile(data: Data("正文".utf8), encoding: .utf8)
        let invalid = [TXTMappedChapterIndex(index: 0, title: "Title", byteRange: 0..<999)]
        #expect(throws: (any Error).self) {
            try TXTLocationMigration(file: file, oldIndexes: invalid, newIndexes: invalid)
        }
    }

    @Test func rewrittenBodyMustNotBeMappedAsUnmodifiedSource() throws {
        let text = "原文\n其他\n"
        let file = TXTMappedTextFile(data: Data(text.utf8), encoding: .utf8)
        let old = [TXTMappedChapterIndex(index: 0, title: "Title", byteRange: 0..<Data("原文\n".utf8).count)]
        let new = [TXTMappedChapterIndex(index: 0, title: "Title", byteRange: 0..<file.byteCount)]
        let mapping = try TXTLocationMigration(file: file, oldIndexes: old, newIndexes: new)
        #expect(throws: TXTLocationMigration.Failure.self) {
            try mapping.map(.init(spineIndex: 0, charOffset: 7), oldRendered: "Title\n改寫的文字\n", newRendered: "Title\n原文\n其他\n")
        }
    }
}
