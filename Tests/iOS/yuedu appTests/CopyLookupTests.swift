import Foundation
import Testing
@testable import yuedu_app

/// Unified library 2c: a browse item finds its copies by the key 1a derives for it, without a
/// scan per row.
@MainActor
@Suite("Copy lookup", .serialized)
struct CopyLookupTests {
    @Test("OPDS, WebDAV, Gutenberg and Aozora copies are found by their browse item's key")
    func findsEachKind() throws {
        let context = try Context()
        defer { context.cleanup() }
        let opds = context.connections.add(name: "OPDS", url: "https://opds.example/feed", username: nil, password: nil, kind: .opds)
        let dav = context.connections.add(name: "DAV", url: "https://dav.example/books/", username: nil, password: nil, kind: .webDAV)

        var entry = OPDSEntry(id: "urn:uuid:entry-1", title: "三體")
        entry.acquisitions = [OPDSAcquisition(url: URL(string: "https://opds.example/a.epub")!, type: "application/epub+zip", rel: "http://opds-spec.org/acquisition")]
        let opdsCopy = context.remoteCopy(connectionID: opds.id, entryID: entry.id, onShelf: true)

        // The copy keeps the absolute URL; the browse key is the path below the root.
        let file = URL(string: "https://dav.example/books/Fiction/%E4%B8%89%E9%AB%94.epub")!
        let davCopy = context.remoteCopy(connectionID: dav.id, entryID: file.absoluteString, onShelf: false, offline: "offline.epub")
        let davEntry = WebDAVBrowseClient.Entry(url: file, name: "三體.epub", isDirectory: false, size: 10)

        let gutenberg = GutenbergBook(id: 1342, title: "Pride and Prejudice", author: "Jane Austen")
        let gutenbergCopy = context.remoteCopy(connectionID: PublicLibraryID.gutenberg.rawValue, entryID: "https://www.gutenberg.org/ebooks/1342.opds", onShelf: true)

        var aozoraBook = ReadingBook(title: "吾輩は猫である", author: "夏目漱石", source: "local_epub", contentFilename: "neko.epub")
        aozoraBook.aozora = AozoraBookSource(originalFilename: "neko.txt", sourceEncoding: String.Encoding.shiftJIS.rawValue, catalogWorkID: "000789")
        context.store.saveReadingBook(aozoraBook)
        let work = try #require(AozoraCatalog.decode(AozoraCatalogTests.fixture).works.first)
        var matchingWork = work
        matchingWork.id = "000789"

        let lookup = context.store.copyLookup(connections: context.connections)
        let opdsKey = SourceRecord.derived(from: entry, connectionID: opds.id, connectionKind: .opds).key
        #expect(lookup.copies(for: opdsKey).map(\.id) == [opdsCopy.id])
        #expect(lookup.status(for: opdsKey) == .onShelf)

        let davKey = try #require(SourceRecord.derived(from: davEntry, connectionID: dav.id, root: URL(string: "https://dav.example/books/")!)).key
        #expect(lookup.copies(for: davKey).map(\.id) == [davCopy.id])
        #expect(lookup.status(for: davKey) == .downloaded, "an unlisted record with an offline file is downloaded, not on the shelf")

        #expect(lookup.copies(for: SourceRecord.derived(from: gutenberg).key).map(\.id) == [gutenbergCopy.id])
        #expect(lookup.copies(for: SourceRecord.derived(from: matchingWork).key).map(\.id) == [aozoraBook.id])
        #expect(lookup.copies(for: .copy(aozoraBook.id)).map(\.id) == [aozoraBook.id])
        #expect(lookup.copies(connectionID: dav.id, entryID: file.absoluteString).map(\.id) == [davCopy.id])
        #expect(lookup.status(for: SourceItemKey(instance: SourceInstanceKey(type: .opds, id: opds.id), item: "urn:uuid:other")) == nil)
    }

    @Test("a change to the shelf or to the connections rebuilds the lookup")
    func rebuilds() throws {
        let context = try Context()
        defer { context.cleanup() }
        let opds = context.connections.add(name: "OPDS", url: "https://opds.example/feed", username: nil, password: nil, kind: .opds)
        let key = SourceItemKey(instance: SourceInstanceKey(type: .opds, id: opds.id), item: "urn:1")
        #expect(context.store.copyLookup(connections: context.connections).copies(for: key).isEmpty)

        let copy = context.remoteCopy(connectionID: opds.id, entryID: "urn:1", onShelf: true)
        #expect(context.store.copyLookup(connections: context.connections).copies(for: key).map(\.id) == [copy.id])

        var changed = opds
        changed.kind = .calibre
        context.connections.update(changed, password: nil)
        let calibreKey = SourceItemKey(instance: SourceInstanceKey(type: .calibre, id: opds.id), item: "urn:1")
        #expect(context.store.copyLookup(connections: context.connections).copies(for: calibreKey).map(\.id) == [copy.id])
    }

    @Test("10,000 copies build once per change")
    func scale() throws {
        let context = try Context()
        defer { context.cleanup() }
        let opds = context.connections.add(name: "OPDS", url: "https://opds.example/feed", username: nil, password: nil, kind: .opds)
        let books = (0..<10_000).map { index -> ReadingBook in
            var book = ReadingBook(title: "書 \(index)", author: "作者", source: "local", contentFilename: "\(index).epub")
            book.remoteSource = RemoteBookReference(connectionID: opds.id, entryID: "urn:\(index)",
                format: RemoteLibraryFormat(url: URL(string: "https://opds.example/\(index).epub")!, fileExtension: "epub", mimeType: "application/epub+zip"))
            return book
        }
        context.store.books = books
        let clock = ContinuousClock()
        var lookup: CopyLookup?
        let first = clock.measure { lookup = context.store.copyLookup(connections: context.connections) }
        let second = clock.measure { _ = context.store.copyLookup(connections: context.connections) }
        print("⏱ copyLookup 10000 copies: build \(first), memoized read \(second)")
        #expect(lookup?.copies(for: SourceItemKey(instance: SourceInstanceKey(type: .opds, id: opds.id), item: "urn:9999")).count == 1)
        #expect(second < first)
    }

    @MainActor
    private final class Context {
        let folder: URL
        let store: BookStore
        let connections: OPDSCatalogStore

        init() throws {
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("CopyLookup-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
            connections = OPDSCatalogStore(storageDirectory: folder, importLegacyWebDAV: false)
        }

        @discardableResult
        func remoteCopy(connectionID: String, entryID: String, onShelf: Bool, offline: String? = nil) -> ReadingBook {
            var book = ReadingBook(title: "Remote", author: "A", source: "local", contentFilename: "\(UUID().uuidString).epub")
            book.isInBookshelf = onShelf
            book.remoteSource = RemoteBookReference(connectionID: connectionID, entryID: entryID,
                format: RemoteLibraryFormat(url: URL(string: "https://example.com/book.epub")!, fileExtension: "epub", mimeType: "application/epub+zip"),
                offlineFilename: offline)
            store.saveReadingBook(book)
            return book
        }

        func cleanup() {
            store.waitForQueuedWrites()
            try? FileManager.default.removeItem(at: folder)
        }
    }
}
