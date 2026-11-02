import Foundation
import Testing
@testable import yuedu_app

/// 目錄's 正序／倒序 (回饋 #37): the order rows are shown in, the row a 目錄 opens on, and the
/// per-book memory.
@Suite("Chapter list order", .serialized)
struct ChapterListOrderTests {

    private static func chapter(_ index: Int, _ title: String, level: Int = 0) -> BookChapter {
        BookChapter(index: index, title: title, content: "", level: level)
    }

    private static func titles(_ chapters: [BookChapter]) -> [String] {
        chapters.map(\.title)
    }

    // MARK: Ordering

    @Test("正序 shows the 目錄 as it is")
    func ascendingKeepsOrder() {
        let chapters = (0..<4).map { Self.chapter($0, "c\($0)") }
        #expect(Self.titles(ChapterListOrder.ascending.arranged(chapters, level: \.level))
            == ["c0", "c1", "c2", "c3"])
    }

    @Test("倒序 reverses a flat 目錄 and leaves every chapter's index alone")
    func descendingReversesFlatList() {
        let chapters = (0..<4).map { Self.chapter($0, "c\($0)") }
        let shown = ChapterListOrder.descending.arranged(chapters, level: \.level)
        #expect(Self.titles(shown) == ["c3", "c2", "c1", "c0"])
        #expect(shown.map(\.index) == [3, 2, 1, 0])
    }

    @Test("倒序 keeps each volume above its own chapters")
    func descendingKeepsVolumesAboveChapters() {
        let chapters = [
            Self.chapter(0, "v1"),
            Self.chapter(1, "v1c1", level: 1),
            Self.chapter(2, "v1c2", level: 1),
            Self.chapter(3, "v2"),
            Self.chapter(4, "v2c1", level: 1),
            Self.chapter(5, "v2c1s1", level: 2),
            Self.chapter(6, "v2c2", level: 1),
        ]
        #expect(Self.titles(ChapterListOrder.descending.arranged(chapters, level: \.level))
            == ["v2", "v2c2", "v2c1", "v2c1s1", "v1", "v1c2", "v1c1"])
    }

    @Test("倒序 of a 目錄 that skips a level keeps every chapter, under the nearest heading")
    func descendingToleratesSkippedLevels() {
        let chapters = [
            Self.chapter(0, "front", level: 2),
            Self.chapter(1, "v1"),
            Self.chapter(2, "v1c1", level: 3),
            Self.chapter(3, "v1c2", level: 1),
        ]
        let shown = ChapterListOrder.descending.arranged(chapters, level: \.level)
        #expect(Self.titles(shown) == ["v1", "v1c2", "v1c1", "front"])
        #expect(Set(shown.map(\.index)) == Set(chapters.map(\.index)))
    }

    @Test("作品詳情's rows keep their offset into the list in 倒序")
    func detailRowsKeepOffsets() {
        let refs = [
            OnlineChapterRef(index: 10, title: "一", url: ""),
            OnlineChapterRef(index: 11, title: "", url: ""),
            OnlineChapterRef(index: 12, title: "三", url: ""),
        ]
        let rows = BookDetailChapterListSheet.rows(refs, order: .descending)
        #expect(rows.map(\.offset) == [2, 1, 0])
        #expect(rows.map(\.element.index) == [12, 11, 10])
        // The empty title still reads 「第 2 章」, its place in the book, not its row.
        let untitled = rows[1]
        #expect(BookDetailChapterTitle.display(untitled.element, offset: untitled.offset)
            == String(format: localized("第 %d 章"), 2))
    }

    // MARK: Scroll target

    @Test("the 目錄 opens on the current chapter in both orders")
    func scrollTargetInBothOrders() {
        let chapters = [
            Self.chapter(0, "v1"),
            Self.chapter(1, "v1c1", level: 1),
            Self.chapter(2, "v2"),
            Self.chapter(3, "v2c1", level: 1),
        ]
        for order in ChapterListOrder.allCases {
            let shown = order.arranged(chapters, level: \.level)
            let row = ReaderTOCScrollTarget.row(currentIndex: 1, in: shown)
            #expect(row == 1, "\(order)")
            #expect(shown.contains { $0.index == row && $0.title == "v1c1" }, "\(order)")
        }
    }

    @Test("no scroll target when the shown list does not have the current chapter")
    func noScrollTargetWhenFilteredOut() {
        let shown = ChapterListOrder.descending.arranged([Self.chapter(0, "a"), Self.chapter(2, "c")])
        #expect(ReaderTOCScrollTarget.row(currentIndex: 1, in: shown) == nil)
    }

    // MARK: Per-book memory

    @Test("倒序 is remembered per book, and a book without an id remembers nothing")
    func remembersPerBook() throws {
        let suite = "ChapterListOrderTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let book = UUID()
        let other = UUID()

        #expect(ChapterListOrder.stored(for: book, defaults: defaults) == .ascending)

        ChapterListOrder.store(.descending, for: book, defaults: defaults)
        ChapterListOrder.store(.descending, for: book, defaults: defaults)
        #expect(ChapterListOrder.stored(for: book, defaults: defaults) == .descending)
        #expect(ChapterListOrder.stored(for: other, defaults: defaults) == .ascending)
        #expect(defaults.stringArray(forKey: ChapterListOrder.descendingBooksKey) == [book.uuidString])

        ChapterListOrder.store(.ascending, for: book, defaults: defaults)
        #expect(ChapterListOrder.stored(for: book, defaults: defaults) == .ascending)

        ChapterListOrder.store(.descending, for: nil, defaults: defaults)
        #expect(ChapterListOrder.stored(for: nil, defaults: defaults) == .ascending)
        #expect(defaults.stringArray(forKey: ChapterListOrder.descendingBooksKey) == [])
    }
}
