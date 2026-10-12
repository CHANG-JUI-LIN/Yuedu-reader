import Foundation
import Testing
@testable import yuedu_app

/// Unified library 5f-4d: a detail page shows a shelf copy's own title and author first
/// (decision 32), through `MetadataResolver`.
struct CopyMetadataTests {
    private let context = SourceRecordContext(bookSourceURL: { _ in nil }, connectionKind: { _ in nil }, webDAVRoot: { _ in nil })

    private func resolve(_ book: ReadingBook, decisions: [WorkDecision] = []) -> CopyMetadata {
        CopyMetadata.resolve(copy: book, record: SourceRecord.derived(from: book, context: context), decisions: decisions)
    }

    @Test func theCopysOwnTitleAndAuthor() {
        let book = ReadingBook(title: "書架上的名字", author: "甲、乙", source: "local", contentFilename: "a.epub")
        let shown = resolve(book)
        #expect(shown.title == "書架上的名字")
        #expect(shown.author == "甲、乙")
    }

    @Test func anOverrideComesFirst() {
        let book = ReadingBook(title: "書架上的名字", author: "甲", source: "local", contentFilename: "a.epub")
        let override = WorkDecision.override(anchor: .copy(book.id), field: .title, value: .text("讀者改的"), decidedAt: Date())
        #expect(resolve(book, decisions: [override]).title == "讀者改的")
    }

    /// A copy with no title decides nothing: the page shows its source's.
    @Test func anEmptyValueIsNotShown() {
        let book = ReadingBook(title: "  ", author: "", source: "local", contentFilename: "a.epub")
        let shown = resolve(book)
        #expect(shown.title == nil)
        #expect(shown.author == nil)
    }
}
