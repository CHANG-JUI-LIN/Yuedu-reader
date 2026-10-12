import Combine
import Foundation
import Testing
@testable import yuedu_app

/// 作品詳情's 目錄 (2026-10-13): read from the reading copy by the reader's own paths, without
/// opening the copy, and without tearing down a library session a reader still reads.
@MainActor
@Suite(.serialized)
struct WorkTableOfContentsTests {
    private final class Positions: ReadingPositionStore, @unchecked Sendable {
        let lock = NSLock()
        var value: CoreTextReadingPosition?
        init(_ position: CoreTextReadingPosition? = nil) { value = position }
        func save(_ position: CoreTextReadingPosition, for bookId: String) async { lock.withLock { value = position } }
        func load(for bookId: String) async -> CoreTextReadingPosition? { loadSync(for: bookId) }
        func loadSync(for bookId: String) -> CoreTextReadingPosition? { lock.withLock { value } }
        func flush(for bookId: String) async {}
    }

    /// A library that serves `copy` from a local EPUB, as a range session would.
    private final class Library: RemoteLibraryServing {
        let copy: ReadingBook
        let session: PublicationSession
        var released = 0
        init(copy: ReadingBook, session: PublicationSession) { self.copy = copy; self.session = session }
        var failurePublisher: AnyPublisher<RemoteLibraryReadFailure, Never> { Empty().eraseToAnyPublisher() }
        func book(for item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) -> ReadingBook? { copy }
        func readingCopy(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) throws -> ReadingBook { copy }
        func addToShelf(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) throws -> ReadingBook { copy }
        func downloadOffline(item: RemoteLibraryItem, format: RemoteLibraryFormat, store: BookStore) async throws -> ReadingBook { copy }
        func prepare(bookID: UUID, store: BookStore) async throws -> ReadingBook { copy }
        func publication(bookID: UUID) -> PublicationSession? { session }
        func hasOfflineCopy(_ book: ReadingBook) -> Bool { false }
        func release(bookID: UUID) { released += 1 }
    }

    private func store() throws -> BookStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("work-toc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return BookStore(metadataFileURL: directory.appendingPathComponent("books.json"))
    }

    private func epub() async throws -> URL {
        try await EPUBTestFixtures.makeArchive(entries: [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
              <rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles>
            </container>
            """.utf8),
            "OPS/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">urn:uuid:work-toc</dc:identifier>
                <dc:title>ホノルル</dc:title>
                <dc:language>ja</dc:language>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
                <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
                <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
              </manifest>
              <spine><itemref idref="cover"/><itemref idref="ch1"/><itemref idref="ch2"/></spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data(EPUBTestFixtures.xhtml(title: "Nav", body: """
            <nav epub:type="toc"><ol><li><a href="ch1.xhtml">一</a></li><li><a href="ch2.xhtml">二</a></li><li><a href="ch2.xhtml#later">三</a></li></ol></nav>
            """).utf8),
            "OPS/cover.xhtml": Data(EPUBTestFixtures.xhtml(title: "表紙", body: "<p>表紙</p>").utf8),
            "OPS/ch1.xhtml": Data(EPUBTestFixtures.xhtml(title: "一", body: "<p>本文一</p>").utf8),
            "OPS/ch2.xhtml": Data(EPUBTestFixtures.xhtml(title: "二", body: #"<p>本文二</p><h2 id="later">三</h2><p>本文三</p>"#).utf8),
        ])
    }

    @Test("a copy's 目錄 is its EPUB's table of contents, at its spine items, and leaves the copy unread")
    func epubChapters() async throws {
        let store = try store()
        let book = try await store.importEpub(url: try await epub(), isInBookshelf: false)
        defer { store.delete(bookId: book.id) }
        let library = Library(copy: book, session: try await PublicationSession.open(sourceURL: try await epub()))

        let chapters = try #require(try await WorkTableOfContents.chapters(of: book, store: store, remoteLibrary: library,
                                                                           positions: Positions()))
        #expect(chapters.map(\.title) == ["一", "二", "三"])
        #expect(chapters.map(\.index) == [1, 2, 2], "a position opens the spine item the entry points at")
        #expect(library.released == 0, "a copy on this device holds no library session")

        let after = try #require(store.readingBook(id: book.id))
        #expect(!after.isInBookshelf)
        #expect(after.lastOpenedDate == nil)
        #expect(ReaderShelvePrompt.copy(book.id, in: store) == nil, "a copy made ahead of reading is not asked about")
        #expect(!store.books.contains { $0.id == book.id }, "nor is it in 繼續閱讀")
    }

    private func remoteCopy() -> ReadingBook {
        var book = ReadingBook(title: "Remote", author: "Author", source: "local_epub", contentFilename: "remote.epub")
        book.isInBookshelf = false
        let format = RemoteLibraryFormat(url: URL(string: "https://library.example/book.epub")!,
                                         fileExtension: "epub", mimeType: "application/epub+zip")
        book.remoteSource = RemoteBookReference(connectionID: "library", entryID: "1", format: format)
        return book
    }

    @Test("a library's copy is released once read, as its last reader releases it")
    func releasesTheLibrarySession() async throws {
        let book = remoteCopy()
        let library = Library(copy: book, session: try await PublicationSession.open(sourceURL: try await epub()))
        let chapters = try await WorkTableOfContents.chapters(of: book, store: try store(), remoteLibrary: library,
                                                              positions: Positions())
        #expect(chapters?.count == 3)
        #expect(library.released == 1)
        #expect(!ReadingResourceUsage.shared.isInUse(bookID: book.id))
    }

    @Test("a library's copy a reader reads keeps its session")
    func keepsAReadersSession() async throws {
        let book = remoteCopy()
        let reader = UUID()
        ReadingResourceUsage.shared.retain(bookID: book.id, ownerID: reader)
        defer { ReadingResourceUsage.shared.release(bookID: book.id, ownerID: reader) }
        let library = Library(copy: book, session: try await PublicationSession.open(sourceURL: try await epub()))
        _ = try await WorkTableOfContents.chapters(of: book, store: try store(), remoteLibrary: library, positions: Positions())
        #expect(library.released == 0)
        #expect(ReadingResourceUsage.shared.isInUse(bookID: book.id))
    }

    private func txtCopy(in store: BookStore) throws -> ReadingBook {
        let filename = "work-toc-\(UUID().uuidString).txt"
        try Data("第1章 開始\n正文。\n第2章 繼續\n正文。\n".utf8).write(to: StorageLocations.bookFile(filename))
        var book = ReadingBook(title: "Test", author: "Test", contentFilename: filename)
        book.isInBookshelf = false
        store.saveReadingBook(book)
        return book
    }

    private func cleanUp(_ book: ReadingBook) {
        TXTChapterParser.deleteCachedIndexes(bookId: book.id)
        try? FileManager.default.removeItem(at: StorageLocations.bookFile(book.contentFilename))
    }

    @Test("an unread TXT's 目錄 publishes its index, so a chapter's position is one its reader opens")
    func txtPublishesItsIndex() async throws {
        let store = try store()
        let book = try txtCopy(in: store)
        defer { cleanUp(book) }
        let positions = Positions()
        let library = Library(copy: book, session: try await PublicationSession.open(sourceURL: try await epub()))

        let chapters = try #require(try await WorkTableOfContents.chapters(of: book, store: store, remoteLibrary: library,
                                                                           positions: positions))
        #expect(chapters.map(\.title) == ["第1章 開始", "第2章 繼續"])
        #expect(chapters.map(\.index) == [0, 1])

        // As 目錄's chapter opens it: the reader finds the index and keeps the position.
        await positions.save(CoreTextReadingPosition(spineIndex: 1, charOffset: 0), for: book.id.uuidString)
        let preparation = try TXTReaderPreparationService.prepare(url: StorageLocations.bookFile(book.contentFilename),
                                                                  bookId: book.id, bookTitle: book.title)
        #expect(preparation.cachedChapterIndexes?.count == 2)
        let opened = try await TXTReaderIndexMigrationService.complete(preparation, store: store, positions: positions,
                                                                       settings: EPUBTestFixtures.renderSettings())
        #expect(opened.restoredPosition == CoreTextReadingPosition(spineIndex: 1, charOffset: 0))
    }

    @Test("a TXT read before it had an index waits on its reader")
    func txtWithAPositionWaits() async throws {
        let store = try store()
        let book = try txtCopy(in: store)
        defer { cleanUp(book) }
        let library = Library(copy: book, session: try await PublicationSession.open(sourceURL: try await epub()))
        let chapters = try await WorkTableOfContents.chapters(
            of: book, store: store, remoteLibrary: library,
            positions: Positions(CoreTextReadingPosition(spineIndex: 0, charOffset: 3)))
        #expect(chapters == nil)
    }

    @Test("a PDF has no 目錄")
    func pdfHasNone() {
        var book = ReadingBook(title: "PDF", author: "", source: "local_pdf", contentFilename: "a.pdf")
        book.contentPipelineKind = .fixedPage
        #expect(!WorkTableOfContents.lists(book))
        #expect(!WorkTableOfContents.lists(ReadingBook(title: "MD", author: "", source: "local", contentFilename: "a.md")))
    }
}
