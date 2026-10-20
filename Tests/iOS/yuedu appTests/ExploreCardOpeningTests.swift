import Foundation
import Testing
@testable import yuedu_app

/// Feedback #24: what a card on 探索's home opens.
@Suite("Explore card opening")
struct ExploreCardOpeningTests {
    private func copy(_ id: UUID) -> WorkDetailRoute {
        WorkDetailRoute(record: SourceRecord(key: .copy(id), title: "三體", authors: ["劉慈欣"], language: nil,
                                             contentKind: .text, identifiers: [], copyID: id,
                                             acquisitions: [.openCopy(id)]),
                        summary: WorkSummary(title: "三體", authors: ["劉慈欣"], cover: nil, blurb: nil, language: nil,
                                             contentKind: .text),
                        opening: .copy(id))
    }

    @Test("a shelf copy on 繼續閱讀 or 書架 opens its reader")
    func continueReadingOpensReader() {
        let id = UUID()
        #expect(ExplorePush.card(copy(id), in: .continueReading) == .reader(PublicLibraryReaderRoute(bookID: id)))
        #expect(ExplorePush.card(copy(id), in: .bookshelf) == .reader(PublicLibraryReaderRoute(bookID: id)))
    }

    @Test("every other card opens 作品詳情 first, a shelf copy elsewhere too")
    func otherCardsOpenWorkDetail() {
        let shelved = copy(UUID())
        #expect(ExplorePush.card(shelved, in: .related) == .work(shelved))
        let gutenberg = WorkDetailRoute(.gutenberg(GutenbergBook(id: 1, title: "三體", author: "劉慈欣")))
        #expect(ExplorePush.card(gutenberg, in: .continueReading) == .work(gutenberg))
    }
}
