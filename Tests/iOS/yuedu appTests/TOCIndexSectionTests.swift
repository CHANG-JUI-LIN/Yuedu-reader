import Foundation
import Testing
@testable import yuedu_app

/// The 目錄's section index (feedback #160): blocks of at least 100 chapters, at most about
/// 20 entries, labelled by the first chapter's number in the order shown.
struct TOCIndexSectionTests {
    private func chapters(_ count: Int) -> [BookChapter] {
        (0..<count).map { BookChapter(index: $0, title: "第\($0 + 1)章", content: "") }
    }

    @Test("a short 目錄 is one block with no index entry")
    func shortTOCHasNoIndex() {
        let sections = TOCIndexSection.sections(of: chapters(80))
        #expect(sections.count == 1)
        #expect(sections[0].label == nil)
        #expect(sections[0].chapters.count == 80)
    }

    @Test("1200 chapters: blocks of 100 labelled 1, 101, …")
    func blocksOfAHundred() {
        let sections = TOCIndexSection.sections(of: chapters(1_200))
        #expect(sections.count == 12)
        #expect(sections.map(\.label) == stride(from: 1, through: 1_101, by: 100).map { "\($0)" })
        #expect(sections.flatMap(\.chapters).count == 1_200)
    }

    @Test("a very long 目錄 keeps the index to about 20 entries")
    func longTOCStaysReadable() {
        let sections = TOCIndexSection.sections(of: chapters(5_000))
        #expect(sections.count <= TOCIndexSection.maximumEntries)
        #expect(sections.flatMap(\.chapters).count == 5_000)
    }

    @Test("倒序 labels the blocks from the last chapter down")
    func descendingLabels() {
        let sections = TOCIndexSection.sections(of: Array(chapters(250).reversed()))
        #expect(sections.map(\.label) == ["250", "150", "50"])
    }
}
