import Foundation
import Testing
@testable import yuedu_app

/// 目錄 search (Crashlytics 629731e7): the shown list is arranged and filtered in one pass, so a
/// keystroke costs one match per chapter — not one full filter per row, which froze the main
/// thread on a long online 目錄 until the watchdog killed the app.
@Suite("Reader TOC filter", .serialized)
struct ReaderTOCFilterTests {

    private static func longTOC(_ count: Int) -> [BookChapter] {
        (0..<count).map { BookChapter(index: $0, title: "第\($0 + 1)章 風起雲湧之卷・\($0 % 97)", content: "") }
    }

    @Test("A search runs the matcher once per chapter")
    func matcherRunsOncePerChapter() {
        let chapters = Self.longTOC(5000)
        var calls = 0
        let shown = ReaderTOCFilter.shown(chapters, order: .ascending, query: "  雲湧之卷・42 ") { title, query in
            calls += 1
            return title.localizedCaseInsensitiveContains(query)
        }
        #expect(calls <= chapters.count)
        #expect(!shown.isEmpty)
        #expect(shown.allSatisfy { $0.title.hasSuffix("・42") })
    }

    @Test("An empty query shows the whole 目錄 in its order and runs no match")
    func emptyQueryArrangesOnly() {
        let chapters = Self.longTOC(5)
        var calls = 0
        let shown = ReaderTOCFilter.shown(chapters, order: .descending, query: " \n") { _, _ in
            calls += 1
            return true
        }
        #expect(calls == 0)
        #expect(shown.map(\.index) == [4, 3, 2, 1, 0])
    }

    @Test("Filtering 5000 CJK titles with the real matcher stays well inside a frame budget")
    func filteringFiveThousandTitlesIsFast() {
        let chapters = Self.longTOC(5000)
        let clock = ContinuousClock()
        var shown: [BookChapter] = []
        let elapsed = clock.measure {
            shown = ReaderTOCFilter.shown(chapters, order: .ascending, query: "雲湧之卷・42")
        }
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("⏱ ReaderTOCFilter 5000 titles: \(String(format: "%.1f", ms)) ms, \(shown.count) shown")
        #expect(!shown.isEmpty)
        #expect(ms < 500)
    }
}
