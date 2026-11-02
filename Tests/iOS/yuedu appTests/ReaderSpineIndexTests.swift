import Testing
@testable import yuedu_app

/// An EPUB's `chapters` in the reader is its 目錄, while reading positions, `currentChapterIndex`
/// and the scroll slider count spine items. The converted vertical book's spine is longer than its
/// TOC on both sides: a cover before 第一章, and the table of contents Calibre appends after 第二章.
/// Bounding a spine index by the TOC left that book's 下一章 off at 第一章 (spine 1), its scroll
/// slider on spines 0 and 1, and narration ending at 第二章.
@Suite("Spine indices are bounded by the spine, not the TOC")
@MainActor
struct ReaderSpineIndexTests {
    private static func book() async throws -> (toc: [BookChapter], spine: [BookChapter]) {
        let session = try await PublicationSession.open(
            sourceURL: try await BookWritingModesTests.converted("vertical-zh.azw3"))
        return (ReaderTOCChapterMapper.chapters(from: session.tocEntries, session: session), session.readingChapters)
    }

    @Test("the converted book has two TOC entries, on spines 1 and 2, and four spine items")
    func bookShape() async throws {
        let book = try await Self.book()
        #expect(book.toc.map(\.index) == [1, 2])
        #expect(book.spine.count == 4)
    }

    @Test("the scroll slider reaches every spine item, and lands on the one it shows")
    func scrollSliderReachesEverySpine() async throws {
        let count = try await Self.book().spine.count
        for spine in 0..<count {
            let value = ReaderView.scrollSliderProgress(forSpine: spine, spineCount: count)
            #expect(ReaderView.scrollSliderSpine(forProgress: value, spineCount: count) == spine)
        }
        #expect(ReaderView.scrollSliderSpine(forProgress: 1, spineCount: count) == 3)
        #expect(ReaderView.scrollSliderSpine(forProgress: 0.5, spineCount: count) == 2)
    }

    @Test("a one-item book keeps the slider at its start")
    func oneItemSlider() {
        #expect(ReaderView.scrollSliderSpine(forProgress: 1, spineCount: 1) == 0)
        #expect(ReaderView.scrollSliderProgress(forSpine: 0, spineCount: 1) == 0)
    }

    @Test("narration goes on past the TOC's last entry, to the last spine item")
    func narrationGoesPastTheTOC() async throws {
        let book = try await Self.book()
        let count = book.spine.count
        let next = { (spine: Int) in
            ReaderView.narratableChapter(from: spine, direction: 1, spineCount: count) { _ in false }
        }
        #expect(next(1) == 2)
        #expect(next(2) == 3)
        #expect(next(3) == nil)
    }

    @Test("a spine item after the TOC's last entry reads under that entry; one before the first under none")
    func titlesOutsideTheTOC() async throws {
        let book = try await Self.book()
        let entry = { (spine: Int) in
            ReaderTOCSelection.currentChapter(in: book.toc, currentSpineIndex: spine, currentCharOffset: 0) { _ in 0 }
        }
        try #require(book.toc.count == 2)
        let (first, second) = (book.toc[0], book.toc[1])
        #expect(entry(3)?.id == second.id)
        #expect(entry(2)?.id == second.id)
        #expect(entry(1)?.id == first.id)
        #expect(entry(0) == nil)
    }
}
