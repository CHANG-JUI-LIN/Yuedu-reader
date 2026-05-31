import Foundation
import Testing
@testable import yuedu_app

@Suite("Manga chapter list items")
struct MangaChapterListItemTests {

    @Test("chapter refs map to selection indices and display titles")
    func refsMapToSelectionIndicesAndTitles() {
        let refs = [
            OnlineChapterRef(index: 42, title: "第 42 話", url: "https://example.com/42"),
            OnlineChapterRef(index: 99, title: "番外篇", url: "https://example.com/99")
        ]

        let items = MangaChapterListItem.items(from: refs)

        #expect(items.count == 2)
        #expect(items[0].index == 0)
        #expect(items[0].title == "第 42 話")
        #expect(items[1].index == 1)
        #expect(items[1].title == "番外篇")
    }

    @Test("empty chapter titles fall back to localized chapter numbers")
    func emptyTitlesUseLocalizedFallback() {
        let refs = [
            OnlineChapterRef(index: 7, title: "   ", url: "https://example.com/7")
        ]

        let items = MangaChapterListItem.items(from: refs)

        #expect(items.map(\.title) == [String(format: localized("第 %d 章"), 1)])
    }
}
