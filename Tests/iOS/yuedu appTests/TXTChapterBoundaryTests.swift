import Foundation
import Testing
@testable import yuedu_app

@Suite(.serialized)
struct TXTChapterBoundaryTests {
    @Test(arguments: [String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian])
    func embeddedPartsStayInBody(encoding: String.Encoding) throws {
        let text = "第1章 開始\r\n　正文介紹一本功法，只有兩篇。\r\n　第一篇：人仙篇！\r\n　第二篇：地仙篇。\r\n　接著修煉。\r\n第2章 繼續\r\n　正文。"
        let mapped = TXTMappedTextFile(data: try #require(text.data(using: encoding)), encoding: encoding)
        let indexes = TXTChapterParser.parseMappedChapterIndexes(mapped, bookTitle: "Test")
        #expect(indexes.map(\.title) == ["第1章 開始", "第2章 繼續"])
        let body = TXTChapterParser.chapterText(mapped, byteRange: try #require(indexes.first).byteRange)
        #expect(body.contains("第一篇：人仙篇！"))
        #expect(body.contains("第二篇：地仙篇。"))
        #expect(indexes.map(\.title) == TXTChapterParser.parseChapterIndexes(text, bookTitle: "Test").map(\.title))
    }

    @Test func structuralVolumesAndEmptyPrimaryChaptersRemain() {
        let text = "第一卷 開始\n第1章 空章\n第2章 正文\n內容。\n\n第二卷 繼續\n第3章 新章\n內容。"
        let expected = ["第一卷 開始", "第1章 空章", "第2章 正文", "第二卷 繼續", "第3章 新章"]
        let memory = TXTChapterParser.parseChapterIndexes(text, bookTitle: "Test")
        let file = TXTMappedTextFile(data: Data(text.utf8), encoding: .utf8)
        let mapped = TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: "Test")
        #expect(memory.map(\.title) == expected)
        #expect(mapped.map(\.title) == expected)
        #expect(memory.first { $0.title == "第1章 空章" }?.contentRange.length == 0)
        #expect(mapped.first { $0.title == "第1章 空章" }?.byteRange.isEmpty == true)
    }

    @Test func primaryPartsRemainSupported() {
        let text = "第一篇 開始\n正文。\n第二篇 繼續\n正文。"
        let file = TXTMappedTextFile(data: Data(text.utf8), encoding: .utf8)
        #expect(TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: "Test").map(\.title) == ["第一篇 開始", "第二篇 繼續"])
        #expect(TXTChapterParser.parseChapterIndexes(text, bookTitle: "Test").map(\.title) == ["第一篇 開始", "第二篇 繼續"])
    }

    @Test func laterPrimaryHeadingsAreNotFrozenOutByTheSample() {
        let text = "第一篇：說明\n內容。\n第二篇：附記\n"
            + String(repeating: "普通前言，不是標題。\n", count: 25_000)
            + "第1章 開始\n正文。\n第2章 繼續\n正文。"
        let file = TXTMappedTextFile(data: Data(text.utf8), encoding: .utf8)
        let mapped = TXTChapterParser.parseMappedChapterIndexes(file, bookTitle: "Test")
        let memory = TXTChapterParser.parseChapterIndexes(text, bookTitle: "Test")
        #expect(mapped.suffix(2).map(\.title) == ["第1章 開始", "第2章 繼續"])
        #expect(mapped.suffix(2).map(\.title) == memory.suffix(2).map(\.title))
    }
}
