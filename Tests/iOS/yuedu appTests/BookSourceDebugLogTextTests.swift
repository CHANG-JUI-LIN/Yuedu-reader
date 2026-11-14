import Foundation
import Testing
@testable import yuedu_app

/// What 調試 puts on the pasteboard (FB-194): the run's log as plain text, so it can be handed
/// to someone — or to an AI — outside the app.
struct BookSourceDebugLogTextTests {
    private let longSummary = String(repeating: "很長的摘要，畫面上只顯示兩行。", count: 40)
    private let longDetail = (1...200).map { "<p>第 \($0) 段正文</p>" }.joined(separator: "\n")

    @Test func oneEntryCarriesItsWholeSummaryAndDetail() {
        let entry = DebugLogEntry(level: .success, step: "正文", summary: longSummary, detail: longDetail)

        let text = entry.plainText

        #expect(text.contains("正文"))
        #expect(text.contains(longSummary))
        #expect(text.contains(longDetail))
    }

    @Test func anEntryWithoutDetailEndsAtItsSummary() {
        let entry = DebugLogEntry(level: .info, step: "請求", summary: "GET https://example.com/1.html")

        #expect(entry.plainText.hasSuffix("GET https://example.com/1.html"))
    }

    @Test func theLevelIsWrittenInWords() {
        // The row shows the level as a colour and an emoji; neither survives a paste.
        let entry = DebugLogEntry(level: .error, step: "正文", summary: "規則沒有取到內容")

        #expect(entry.plainText.contains("[error]"))
    }

    @Test func theWholeLogKeepsItsOrder() throws {
        let entries = [
            DebugLogEntry(level: .info, step: "請求", summary: "第一筆"),
            DebugLogEntry(level: .pipeline, step: "規則", summary: "第二筆", detail: "div#content@html"),
            DebugLogEntry(level: .warning, step: "淨化", summary: "第三筆"),
            DebugLogEntry(level: .success, step: "正文", summary: "第四筆", detail: longDetail),
        ]

        let text = DebugLogEntry.plainText(of: entries)

        let positions = try ["第一筆", "第二筆", "第三筆", "第四筆"].map { marker in
            try #require(text.range(of: marker)).lowerBound
        }
        #expect(positions == positions.sorted())
        #expect(text.contains("div#content@html"))
        #expect(text.contains(longDetail))
        // Entries are told apart by a blank line.
        #expect(text.components(separatedBy: "\n\n").count == entries.count)
    }

    @Test func anEmptyLogIsEmptyText() {
        #expect(DebugLogEntry.plainText(of: []).isEmpty)
    }
}
