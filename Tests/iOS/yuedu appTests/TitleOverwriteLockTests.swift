import Foundation
import ReadiumShared
import Testing
@testable import yuedu_app

/// Unified library 1d: the three automatic paths that overwrite a copy's title and author
/// (design §8.2). Without a lock they behave as before 1d; with one, the title stays.
@Suite("Title overwrite locks", .serialized)
@MainActor
struct TitleOverwriteLockTests {
    // MARK: - Online refresh

    @Test("unlocked: a forced online refresh takes the detail page's title and author")
    func onlineRefreshUnlocked() async throws {
        try await withOnlineBook { store, book, fetcher in
            let refreshed = try await store.refreshOnlineBookMetadata(bookId: book.id, forceInfoRefresh: true, bookSourceFetcher: fetcher)
            #expect(refreshed.title == "新書名")
            #expect(refreshed.author == "新作者")
            #expect(refreshed.onlineChapters?.count == 2)
            #expect(store.readingBook(id: book.id)?.title == "新書名")
        }
    }

    @Test("locked: a forced refresh keeps the title, and the rest of the refresh lands")
    func onlineRefreshLocked() async throws {
        try await withOnlineBook { store, book, fetcher in
            store.workDecisions.record(.lock(anchor: .copy(book.id), field: .title, value: nil, decidedAt: Date()))
            let before = logIDs()
            let refreshed = try await store.refreshOnlineBookMetadata(bookId: book.id, forceInfoRefresh: true, bookSourceFetcher: fetcher)

            #expect(refreshed.title == "舊書名")
            #expect(refreshed.author == "新作者", "only the locked field stays")
            #expect(refreshed.onlineChapters?.count == 2)
            #expect(refreshed.tocURL == "https://title-lock.example/toc")
            #expect(newLines(since: before, containing: "locked title kept", book.id).count >= 1)
            #expect(newLines(since: before, containing: "舊書名", book.id).isEmpty, "the log names the copy, not the title")
        }
    }

    @Test("a locked title still shows a manual edit, and a refresh after it keeps the edit")
    func manualEditUnderLock() async throws {
        try await withOnlineBook { store, book, fetcher in
            store.workDecisions.record(.lock(anchor: .copy(book.id), field: .title, value: nil, decidedAt: Date()))
            store.updateBook(bookId: book.id, title: "我改的書名", author: "")
            let edited = try #require(store.readingBook(id: book.id))
            let resolved = MetadataResolver.resolve(.title, anchor: .copy(book.id), copySource: .localLibrary,
                                                    copyValue: .text(edited.title), values: [], decisions: store.workDecisions.decisions)
            #expect(resolved?.value == .text("我改的書名"))

            let refreshed = try await store.refreshOnlineBookMetadata(bookId: book.id, forceInfoRefresh: true, bookSourceFetcher: fetcher)
            #expect(refreshed.title == "我改的書名")
        }
    }

    // MARK: - Calibre write-back

    @Test("unlocked: a Calibre metadata edit retitles every local format of that book")
    func calibreUnlocked() async throws {
        let context = try WritingContext(kind: .calibre)
        defer { context.cleanup() }
        let epub = context.record(format: "epub")
        let pdf = context.record(format: "pdf")
        try await context.service.updateMetadata(item: context.item(format: "epub"), title: "New title", authors: ["First", "Second"], readingStore: context.store)

        for copy in [epub, pdf] {
            #expect(context.store.readingBook(id: copy.id)?.title == "New title")
            #expect(context.store.readingBook(id: copy.id)?.author == "First, Second")
        }
    }

    @Test("locked: the server keeps the edit, and only the locked copy keeps its title")
    func calibreLocked() async throws {
        let context = try WritingContext(kind: .calibre)
        defer { context.cleanup() }
        let epub = context.record(format: "epub")
        let pdf = context.record(format: "pdf")
        context.store.workDecisions.record(.lock(anchor: .copy(epub.id), field: .title, value: nil, decidedAt: Date()))
        let before = logIDs()
        try await context.service.updateMetadata(item: context.item(format: "epub"), title: "New title", authors: ["First", "Second"], readingStore: context.store)

        #expect(context.store.readingBook(id: epub.id)?.title == "Book")
        #expect(context.store.readingBook(id: epub.id)?.author == "First, Second", "the author was not locked")
        #expect(context.store.readingBook(id: pdf.id)?.title == "New title")
        #expect(context.transport.posts == 1, "the edit reached the server")
        #expect(newLines(since: before, containing: "locked title kept", epub.id).count == 1)
    }

    // MARK: - WebDAV rename

    @Test("unlocked: a WebDAV rename retitles the copy after the new file name")
    func webDAVUnlocked() async throws {
        let context = try WritingContext(kind: .webDAV)
        defer { context.cleanup() }
        let copy = context.record(format: "txt")
        let renamed = try await context.service.move(item: context.item(format: "txt"), toName: "renamed.txt", readingStore: context.store)

        let updated = try #require(context.store.readingBook(id: copy.id))
        #expect(updated.title == "renamed")
        #expect(updated.remoteSource?.format.url == renamed)
    }

    @Test("locked: the copy follows the renamed file and keeps its title")
    func webDAVLocked() async throws {
        let context = try WritingContext(kind: .webDAV)
        defer { context.cleanup() }
        let copy = context.record(format: "txt")
        context.store.workDecisions.record(.lock(anchor: .copy(copy.id), field: .title, value: nil, decidedAt: Date()))
        let before = logIDs()
        let renamed = try await context.service.move(item: context.item(format: "txt"), toName: "renamed.txt", readingStore: context.store)

        let updated = try #require(context.store.readingBook(id: copy.id))
        #expect(updated.title == "Book")
        #expect(updated.remoteSource?.format.url == renamed)
        #expect(newLines(since: before, containing: "locked title kept", copy.id).count == 1)
    }

    // MARK: - Helpers

    private func logIDs() -> Set<UUID> {
        Set(DiagnosticLog.shared.snapshot().map(\.id))
    }

    /// Lines written since `before` that mention both `text` and the copy: an id difference,
    /// since the snapshot's count and timestamps cannot tell new lines from old.
    private func newLines(since before: Set<UUID>, containing text: String, _ copy: UUID) -> [String] {
        DiagnosticLog.shared.snapshot()
            .filter { !before.contains($0.id) && $0.message.contains(text) && $0.message.contains(copy.uuidString) }
            .map(\.message)
    }

    private func withOnlineBook(_ body: (BookStore, ReadingBook, RetitlingFetcher) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TitleLocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = BookSource(bookSourceUrl: "https://title-lock.example", bookSourceName: "測試書源")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.sources = [source]
        defer { BookSourceStore.shared.sources = previousSources }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        let book = store.addOnlineBook(name: "舊書名", author: "舊作者", sourceId: source.id,
                                       bookInfoURL: "https://title-lock.example/book", tocURL: "https://title-lock.example/toc", chapters: [])
        defer {
            store.delete(bookId: book.id)
            store.waitForQueuedWrites()
        }
        try await body(store, book, RetitlingFetcher(source: source))
    }
}

/// A book source whose detail page names the book differently from the shelf.
private final class RetitlingFetcher: BookSourceFetching {
    let source: BookSource
    init(source: BookSource) { self.source = source }

    func fetchBookInfoPackage(url: String, source: BookSource, runtimeVariables: [String: String]?, knownBook: OnlineBook?) async throws -> BookInfoPackage {
        BookInfoPackage(sourceId: source.id, sourceName: source.bookSourceName, bookURL: url, name: "新書名", author: "新作者",
                        intro: "", coverUrl: "", tocUrl: "https://title-lock.example/toc", wordCount: "", lastChapter: "", kind: "",
                        runtimeVariables: nil, rawHTMLFilename: nil, savedAt: Date())
    }

    func fetchTOCPackage(tocUrl: String, source: BookSource, runtimeVariables: [String: String]?,
                         onFirstPageReady: (([OnlineChapterRef]) -> Void)?, forceRefresh: Bool) async throws -> TOCPackage {
        TOCPackage(sourceId: source.id, sourceName: source.bookSourceName, tocURL: tocUrl, runtimeVariables: nil, chapters: [
            OnlineChapterRef(index: 0, title: "第 1 章", url: "https://title-lock.example/c1"),
            OnlineChapterRef(index: 1, title: "第 2 章", url: "https://title-lock.example/c2"),
        ], rawHTMLFilename: nil, savedAt: Date())
    }

    func isChapterCached(bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?) -> Bool { false }
    func clearChapterCache(bookId: UUID, chapterIndex: Int) {}
    func clearAllChapterCache(bookId: UUID) {}
    func search(query: String, in source: BookSource) async throws -> [OnlineBook] { [] }
    func loadChapterPackageSync(bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?) -> ChapterPackage? { nil }
    func loadNormalizedChapterHTMLSync(bookId: UUID, chapterIndex: Int, expectedSourceURL: String?, expectedTOCTitle: String?) -> String? { nil }
}

/// A Calibre or WebDAV connection whose server accepts every write.
@MainActor
private final class WritingContext {
    let root: URL
    let connections: OPDSCatalogStore
    let connection: OPDSCatalog
    let store: BookStore
    let service: RemoteLibraryWritingService
    let transport: AcceptingTransport

    init(kind: RemoteLibraryKind) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TitleLocksWriting-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = BookStore(metadataFileURL: root.appendingPathComponent("books_meta.json"))
        connections = OPDSCatalogStore(storageDirectory: root, importLegacyWebDAV: false)
        connection = connections.add(name: "Fixture", url: kind == .webDAV ? "https://books.example/dav/books/" : "https://books.example/proxy/opds",
                                     username: nil, password: nil, kind: kind)
        let transport = AcceptingTransport()
        self.transport = transport
        service = RemoteLibraryWritingService(store: connections, transportFactory: { _ in transport }, invalidateReadingResources: { _ in })
    }

    func item(format: String) -> RemoteLibraryItem {
        let url = URL(string: connection.kind == .webDAV
            ? "https://books.example/dav/books/book.\(format)"
            : "https://books.example/proxy/get/\(format.uppercased())/42/Main")!
        return RemoteLibraryItem(id: connection.kind == .webDAV ? url.absoluteString : "urn:uuid:fixture", connectionID: connection.id,
                                 title: "Book", formats: [RemoteLibraryFormat(url: url, fileExtension: format, mimeType: "application/octet-stream")])
    }

    @discardableResult
    func record(format: String) -> ReadingBook {
        let item = item(format: format)
        var book = ReadingBook(title: "Book", author: "Old Author", source: "local", contentFilename: "\(UUID().uuidString).\(format)")
        book.isInBookshelf = false
        book.remoteSource = RemoteBookReference(connectionID: item.connectionID, entryID: item.id, format: item.formats[0])
        store.saveReadingBook(book)
        return book
    }

    func cleanup() {
        store.waitForQueuedWrites()
        connections.remove(connection)
        try? FileManager.default.removeItem(at: root)
    }
}

private final class AcceptingTransport: RemoteLibraryTransport {
    var posts = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body: Data
        let status: Int
        switch request.httpMethod {
        case "POST":
            posts += 1
            status = 200
            body = Data(#"{"42":{"title":"New title","authors":["First","Second"]}}"#.utf8)
        case "MOVE":
            status = 201
            body = Data()
        default:
            status = 200
            body = Data(#"{"library_map":{"Main":"Main"},"default_library":"Main"}"#.utf8)
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) { try await data(for: request) }
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    func stream(request: any HTTPRequestConvertible, consume: @escaping (Data, Double?) -> HTTPResult<Void>) async -> HTTPResult<HTTPResponse> {
        .failure(.other(URLError(.unsupportedURL)))
    }
}
