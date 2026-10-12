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

    // MARK: The description (5f-4d-2, decision 33)

    private func onlineBook() -> ReadingBook {
        var book = ReadingBook(title: "線上書", author: "作者", source: "https://source.example/book/1", contentFilename: "")
        book.isOnline = true
        book.bookSourceId = UUID()
        book.bookInfoURL = "https://source.example/book/1"
        return book
    }

    private let sourceContext = SourceRecordContext(bookSourceURL: { _ in "https://source.example" }, connectionKind: { _ in nil },
                                                    webDAVRoot: { _ in nil })

    private func intro(_ book: ReadingBook, sidecar: [MetadataValue] = [], live: String? = nil) -> CopyMetadata.Intro? {
        CopyMetadata.resolve(copy: book, record: SourceRecord.derived(from: book, context: sourceContext), decisions: [],
                             sidecar: sidecar, liveIntro: live).intro
    }

    @Test func theReadersOwnDescriptionComesFirst() throws {
        var book = onlineBook()
        book.customIntro = "  讀者寫的  "
        let shown = try #require(intro(book, live: "<usehtml><button onclick='x'>書源的</button></usehtml>"))
        #expect(shown.text == "讀者寫的")
        #expect(shown.isEdited)
        #expect(!shown.isSourcesOwn, "The reader's text never runs a source's actions")
    }

    @Test func theSourcesLiveDescriptionIsItsOwn() throws {
        let book = onlineBook()
        let record = SourceRecord.derived(from: book, context: sourceContext)
        let stored = MetadataValue(field: .intro, value: .text("舊的"), provider: record.key.instance, sourceItem: record.key,
                                   fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
        let shown = try #require(intro(book, sidecar: [stored], live: "書源剛給的"))
        #expect(shown.text == "書源剛給的", "The page's live value is the place's newest")
        #expect(shown.isSourcesOwn)
        #expect(!shown.isEdited)
        #expect(intro(book, sidecar: [stored])?.isSourcesOwn == false, "A stored value is not the page's source")
    }

    @Test func theCopysOwnFileComesBeforeItsSource() throws {
        let book = onlineBook()
        let own = MetadataValue(field: .intro, value: .text("檔案裡的"), provider: .localLibrary, sourceItem: nil,
                                fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
        let shown = try #require(intro(book, sidecar: [own], live: "書源的"))
        #expect(shown.text == "檔案裡的")
        #expect(!shown.isSourcesOwn)
    }

    @Test func noDescriptionIsNil() {
        #expect(intro(onlineBook(), live: "  ") == nil)
    }

    @Test func aBookNeverEditedEncodesWithoutTheField() throws {
        var book = ReadingBook(title: "書", author: "", contentFilename: "a.txt")
        #expect(!String(decoding: try JSONEncoder().encode(book), as: UTF8.self).contains("customIntro"))
        book.customIntro = "讀者寫的"
        #expect(try JSONDecoder().decode(ReadingBook.self, from: JSONEncoder().encode(book)).customIntro == "讀者寫的")
    }

    // MARK: Gutenberg records stored before d7aa65ab

    private func gutenbergIntro(_ text: String) -> MetadataValue {
        let instance = SourceInstanceKey(type: .gutenberg, id: PublicLibraryID.gutenberg.rawValue)
        return MetadataValue(field: .intro, value: .text(text), provider: instance,
                             sourceItem: SourceItemKey(instance: instance, item: "1342"), fetchedAt: Date(timeIntervalSinceReferenceDate: 0))
    }

    @Test func aStoredGutenbergRecordIsCutToItsSummary() {
        let flattened = "This edition had all images removed. Title: Pride and Prejudice Credits: Chuck Greif "
            + "Summary: \"Pride and Prejudice\" by Jane Austen is a novel. (This is an automatically generated summary.) "
            + "Reading Level: Reading ease score: 69.2. Author: Austen, Jane EBook No.: 1342 Downloads: 189689 Rights: Public domain in the USA."
        let other = MetadataValue(field: .language, value: .texts(["en"]), provider: .localLibrary, sourceItem: nil, fetchedAt: .distantPast)
        let repaired = BookStore.repairingGutenbergRecords([gutenbergIntro(flattened), other])
        #expect(repaired.count == 2)
        #expect(repaired.first?.value == .text("\"Pride and Prejudice\" by Jane Austen is a novel. (This is an automatically generated summary.)"))
        #expect(repaired.last == other)
    }

    @Test func aStoredGutenbergRecordWithoutASummaryIsDropped() {
        let record = "This edition has images. LoC No.: 20007446 Author: Tappan, Eva March EBook No.: 79765 Downloads: 0"
        #expect(BookStore.repairingGutenbergRecords([gutenbergIntro(record)]).isEmpty)
    }

    @Test func aGutenbergSummaryIsLeftAlone() {
        let summary = gutenbergIntro("A novel published in 1813.")
        #expect(BookStore.repairingGutenbergRecords([summary]) == [summary])
    }
}
