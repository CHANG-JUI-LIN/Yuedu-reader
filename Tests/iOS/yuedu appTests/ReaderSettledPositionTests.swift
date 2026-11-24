import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 回饋中心 #247: a book with a module's 段評 reopened on 6/16 after being left on 7/16. The
/// reopen lays the chapter out before the comments are in; the page holding the saved place
/// starts earlier than it, and that start, once the comments arrive, is on the page before.
@MainActor
@Suite("Reader settled position", .serialized)
struct ReaderSettledPositionTests {
    private static let renderSize = CGSize(width: 375, height: 667)
    private static let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 17)]

    /// Eighty paragraphs, a 熱評 card of a few lines and a bubble on every one of them.
    private static func chapter() -> (plain: NSAttributedString, decorations: ReaderTranslationLayout.Decorations) {
        let sentence = "他推開門，走進長夜，風從身後追上來，吹亂了燈火與他的影子。"
        let text = (0..<80).map { "　　第\($0)段。" + String(repeating: sentence, count: 3) }.joined(separator: "\n") + "\n"
        var decorations = ReaderTranslationLayout.Decorations()
        for index in 0..<80 {
            decorations.paragraphs[index] = .init(
                trailing: NSAttributedString(string: "①", attributes: attributes),
                below: [NSAttributedString(string: "【熱評】" + String(repeating: "這一段寫得真好，讀了好幾遍。", count: 3) + "\n",
                                           attributes: attributes)])
        }
        return (NSAttributedString(string: text, attributes: attributes), decorations)
    }

    private static func layout(_ text: NSAttributedString, translation: ReaderTranslationLayout? = nil) async -> CoreTextPaginator.ChapterLayout {
        var layout = await CoreTextPaginator().paginate(spineIndex: 0, attrStr: LayoutShared(text).wrappedValue, renderSize: renderSize, fontSize: 17)
        layout.translation = translation
        return layout
    }

    private static func page(of position: CoreTextReadingPosition, in layout: CoreTextPaginator.ChapterLayout) -> Int? {
        CoreTextReadingPositionMapper.pageIndex(for: position, layouts: [0: layout], spinePageOffsets: [0])
    }

    private static func pageStart(_ page: Int, in layout: CoreTextPaginator.ChapterLayout) -> CoreTextReadingPosition {
        layout.readingPosition(atDisplay: Int(layout.pageRanges[page].location))
    }

    @Test("a book reopened before its comments arrive is on the saved page once they do")
    func reopenBeforeCommentsArrive() async throws {
        let chapter = Self.chapter()
        let spliced = try #require(ReaderTranslationLayout.splice(chapter.plain, mode: .off, decorations: chapter.decorations) { _ in nil })
        let decorated = await Self.layout(spliced.display, translation: spliced.layout)
        let plain = await Self.layout(chapter.plain)
        try #require(decorated.pageRanges.count >= 12)

        // Left on a later page of the chapter with the comments shown: its start is the saved place.
        let left = try #require((6..<decorated.pageRanges.count - 1).first { page in
            let saved = Self.pageStart(page, in: decorated)
            guard saved.translationOffset == nil, let reopened = Self.page(of: saved, in: plain) else { return false }
            return Self.pageStart(reopened, in: plain) != saved
        })
        let saved = Self.pageStart(left, in: decorated)

        // Reopened: laid out without the comments, on the page that holds the saved place.
        let reopenedPage = try #require(Self.page(of: saved, in: plain))
        let reopenedStart = Self.pageStart(reopenedPage, in: plain)
        #expect(reopenedStart.charOffset < saved.charOffset)
        #expect(Self.page(of: reopenedStart, in: decorated) == left - 1,
                "the page start the reopen settled on is a page earlier once the comments are in")

        // The app put that page up for the saved place: the reader is still at the saved place.
        let settled = ReaderSettledPosition.resolve(
            pageStart: reopenedStart, held: saved, readerDriven: false, isPlaceholder: false,
            pageIndex: { Self.page(of: $0, in: plain) })
        #expect(settled == saved)
        #expect(settled.flatMap { Self.page(of: $0, in: decorated) } == left, "the comments arrive and the page is the one left")

        // Another chapter landing re-publishes the same page: still the saved place.
        let republished = ReaderSettledPosition.resolve(
            pageStart: reopenedStart, held: settled, readerDriven: false, isPlaceholder: false,
            pageIndex: { Self.page(of: $0, in: plain) })
        #expect(republished == saved)

        // The relayout with the comments puts up the saved place's own page, whose start it is.
        let relaid = ReaderSettledPosition.resolve(
            pageStart: Self.pageStart(left, in: decorated), held: republished, readerDriven: false, isPlaceholder: false,
            pageIndex: { Self.page(of: $0, in: decorated) })
        #expect(relaid == saved)
    }

    /// A page of nothing but comment cards shares its offset with the text page after it; the
    /// saved place says which it is (`translationOffset`). At the reopen that page is not there
    /// and the place shows on the text page at its offset; the comments arrive and it is on the
    /// cards' page again.
    @Test("a book left on a page of comment cards is back on it once they arrive")
    func reopenOnPageOfCards() async throws {
        let chapter = Self.chapter()
        let spliced = try #require(ReaderTranslationLayout.splice(chapter.plain, mode: .off, decorations: chapter.decorations) { _ in nil })
        let decorated = await Self.layout(spliced.display, translation: spliced.layout)
        let plain = await Self.layout(chapter.plain)

        let left = try #require((1..<decorated.pageRanges.count).first { Self.pageStart($0, in: decorated).translationOffset != nil },
                                "the fixture has a page that starts among the cards")
        let saved = Self.pageStart(left, in: decorated)
        let reopenedPage = try #require(Self.page(of: saved, in: plain))
        let reopenedStart = Self.pageStart(reopenedPage, in: plain)
        #expect(reopenedStart != saved)

        let settled = ReaderSettledPosition.resolve(
            pageStart: reopenedStart, held: saved, readerDriven: false, isPlaceholder: false,
            pageIndex: { Self.page(of: $0, in: plain) })
        #expect(settled == saved, "the reopen keeps the place among the cards, not the text page's start")
        #expect(settled.flatMap { Self.page(of: $0, in: decorated) } == left)
    }

    @Test("a turn the reader makes, a page elsewhere, a placeholder and the chapter's end take the page's start")
    func pageStartWhenNotTheSamePlace() async throws {
        let chapter = Self.chapter()
        let plain = await Self.layout(chapter.plain)
        let index: (CoreTextReadingPosition) -> Int? = { Self.page(of: $0, in: plain) }
        let start = Self.pageStart(4, in: plain)
        let midPage = CoreTextReadingPosition(spineIndex: 0, charOffset: start.charOffset + 10)
        #expect(index(midPage) == 4)

        #expect(ReaderSettledPosition.resolve(pageStart: start, held: midPage, readerDriven: true, isPlaceholder: false,
                                              pageIndex: index) == start, "the reader turned: where the page starts")
        #expect(ReaderSettledPosition.resolve(pageStart: start, held: midPage, readerDriven: false, isPlaceholder: true,
                                              pageIndex: index) == start)
        let elsewhere = Self.pageStart(2, in: plain)
        #expect(ReaderSettledPosition.resolve(pageStart: start, held: elsewhere, readerDriven: false, isPlaceholder: false,
                                              pageIndex: index) == start, "held on another page: the page shown")
        let otherChapter = CoreTextReadingPosition(spineIndex: 1, charOffset: start.charOffset + 10)
        #expect(ReaderSettledPosition.resolve(pageStart: start, held: otherChapter, readerDriven: false, isPlaceholder: false,
                                              pageIndex: index) == start)
        let last = Self.pageStart(plain.pageRanges.count - 1, in: plain)
        #expect(ReaderSettledPosition.resolve(pageStart: last, held: .init(spineIndex: 0, charOffset: .max), readerDriven: false,
                                              isPlaceholder: false, pageIndex: index) == last, "the chapter's end is not a place")
        #expect(ReaderSettledPosition.resolve(pageStart: start, held: nil, readerDriven: false, isPlaceholder: false,
                                              pageIndex: index) == start)

        // A spread shows the page after too.
        let onSecond = CoreTextReadingPosition(spineIndex: 0, charOffset: Self.pageStart(5, in: plain).charOffset + 10)
        #expect(ReaderSettledPosition.resolve(pageStart: start, held: onSecond, readerDriven: false, isPlaceholder: false,
                                              pageCount: 2, pageIndex: index) == onSecond)
        #expect(ReaderSettledPosition.resolve(pageStart: start, held: onSecond, readerDriven: false, isPlaceholder: false,
                                              pageIndex: index) == start)
    }
}
