import Foundation
import ReadiumShared
import Testing
@testable import yuedu_app

@Suite("Remote library writing", .serialized)
@MainActor
struct RemoteLibraryWritingTests {
    @Test("native Calibre addresses preserve proxy prefixes and encode library and filename segments once")
    func nativeAddressAndLocator() throws {
        let connection = OPDSCatalog(name: "Calibre", url: "https://books.example/proxy/opds?library_id=Main", kind: .calibre)
        let address = try CalibreServerAddress(connectionURL: connection.url)
        let endpoint = try address.endpoint(["cdb", "add-book", "job", "n", "中文 100% &?.epub", "中文書庫"])
        #expect(endpoint.path == "/proxy/cdb/add-book/job/n/中文 100% &?.epub/中文書庫")
        #expect(endpoint.query == nil)
        #expect(endpoint.absoluteString.contains("%25"))
        let resource = RemoteLibraryFormat(url: URL(string: "https://books.example/proxy/get/EPUB/42/中文書庫")!, fileExtension: "epub", mimeType: "application/epub+zip")
        let locator = try CalibreBookLocator(reference: RemoteBookReference(connectionID: connection.id, entryID: "urn:uuid:a", format: resource), connection: connection)
        #expect(locator.bookID == 42)
        #expect(locator.libraryID == "中文書庫")
        #expect(locator.format == "EPUB")
        #expect(locator.address == address)
        let other = RemoteLibraryFormat(url: URL(string: "https://other.example/proxy/get/EPUB/42/Main")!, fileExtension: "epub", mimeType: "application/epub+zip")
        #expect(throws: RemoteLibraryWriteError.invalidDestination) {
            try CalibreBookLocator(reference: RemoteBookReference(connectionID: connection.id, entryID: "same", format: other), connection: connection)
        }
    }

    @Test("capabilities recognize only native Calibre and do not probe writes")
    func capabilitiesDoNotWrite() async throws {
        let context = try Context(kind: .calibre)
        defer { context.cleanup() }
        let supported = try await context.service.capabilities(connectionID: context.connection.id)
        #expect(supported.canUpload && supported.canEditMetadata)
        #expect(supported.permissionRequiresServerCheck)
        #expect(!supported.canCreateFolder)
        #expect(context.http.requests.allSatisfy { ($0.httpMethod ?? "GET") == "GET" })
        context.http.handler = { _ in (404, Data()) }
        let unsupported = try await context.service.capabilities(connectionID: context.connection.id)
        #expect(!unsupported.canUpload && unsupported.unsupportedReasonKey != nil)
        context.http.handler = { _ in (403, Data()) }
        await #expect(throws: RemoteLibraryWriteError.permissionDenied) {
            try await context.service.capabilities(connectionID: context.connection.id)
        }
        let standard = try Context(kind: .opds)
        defer { standard.cleanup() }
        #expect(try await !standard.service.capabilities(connectionID: standard.connection.id).canUpload)
        #expect(standard.http.requests.isEmpty)
    }

    @Test("Calibre upload sends raw file bytes into the selected library without duplicate permission")
    func nativeUpload() async throws {
        let context = try Context(kind: .calibre)
        defer { context.cleanup() }
        let bytes = Data("唯一書名\n正文。".utf8)
        let file = context.root.appendingPathComponent("中文 100% &.txt")
        try bytes.write(to: file)
        context.http.handler = { request in
            if request.httpMethod != "POST" { return Context.libraryResponse }
            #expect(request.url?.path.hasPrefix("/proxy/cdb/add-book/") == true)
            #expect(request.url?.path.hasSuffix("/n/中文 100% &.txt/中文書庫") == true)
            #expect(request.httpBody == bytes)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
            return (200, Data(#"{"book_id":73,"title":"新書","authors":["作者"]}"#.utf8))
        }
        let observer = ChangeCounter(connectionID: context.connection.id)
        defer { observer.stop() }
        let result = try await context.service.upload(fileURL: file, connectionID: context.connection.id,
            directoryURL: URL(string: "https://books.example/proxy/opds/navcatalog/Otitle?library_id=中文書庫")!)
        #expect(result.bookID == 73)
        #expect(result.resourceURL?.path == "/proxy/get/TXT/73/中文書庫")
        #expect(context.http.uploadCount == 1)
        #expect(observer.count == 1)
    }

    @Test("duplicate and uncertain Calibre uploads neither retry nor publish success")
    func duplicateAndUncertainUploads() async throws {
        let context = try Context(kind: .calibre)
        defer { context.cleanup() }
        let file = context.root.appendingPathComponent("book.txt")
        try Data("Book\nContents".utf8).write(to: file)
        let observer = ChangeCounter(connectionID: context.connection.id)
        defer { observer.stop() }
        for (body, error) in [(#"{"duplicates":[{"title":"Book","authors":["Author"]}]}"#, RemoteLibraryWriteError.duplicateBook), ("{}", .invalidResponse)] {
            context.http.handler = { request in
                request.httpMethod == "POST" ? (200, Data(body.utf8)) : Context.libraryResponse
            }
            let before = context.http.uploadCount
            await #expect(throws: error) {
                try await context.service.upload(fileURL: file, connectionID: context.connection.id)
            }
            #expect(context.http.uploadCount == before + 1)
        }
        for cancelled in [false, true] {
            context.http.handler = { request in
                if request.httpMethod == "POST" {
                    if cancelled { throw CancellationError() }
                    throw URLError(.timedOut)
                }
                return Context.libraryResponse
            }
            let before = context.http.uploadCount
            do {
                _ = try await context.service.upload(fileURL: file, connectionID: context.connection.id)
                Issue.record("An uncertain upload must fail without automatic retry")
            } catch {
                if cancelled { #expect(error is CancellationError) }
                else { #expect((error as? URLError)?.code == .timedOut) }
            }
            #expect(context.http.uploadCount == before + 1)
        }
        #expect(observer.count == 0)
    }

    @Test("a missing selected library never silently uploads into the default library")
    func unknownSelectedLibrary() async throws {
        let context = try Context(kind: .calibre)
        defer { context.cleanup() }
        let file = context.root.appendingPathComponent("book.txt")
        try Data("Book".utf8).write(to: file)
        await #expect(throws: RemoteLibraryWriteError.invalidDestination) {
            try await context.service.upload(fileURL: file, connectionID: context.connection.id,
                directoryURL: URL(string: "https://books.example/proxy/opds?library_id=Removed")!)
        }
        #expect(context.http.uploadCount == 0)
    }

    @Test("metadata changes update all local formats and preserve unshelved identity, progress and bookmarks")
    func metadataReconciliation() async throws {
        let context = try Context(kind: .calibre)
        defer { context.cleanup() }
        let item = context.item()
        let original = context.record(item: item)
        let pdfItem = RemoteLibraryItem(id: item.id, connectionID: item.connectionID, title: item.title,
            formats: [RemoteLibraryFormat(url: URL(string: "https://books.example/proxy/get/PDF/42/Main")!, fileExtension: "pdf", mimeType: "application/pdf")])
        let pdfRecord = context.record(item: pdfItem)
        context.http.handler = { request in
            guard request.httpMethod == "POST" else { return Context.libraryResponse }
            #expect(request.url?.path == "/proxy/cdb/set-fields/42/Main")
            let json = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let changes = json["changes"] as! [String: Any]
            #expect(Set(changes.keys) == ["title", "authors"])
            #expect(changes["title"] as? String == "New title")
            #expect(changes["authors"] as? [String] == ["First", "Second"])
            #expect(json["loaded_book_ids"] as? [Int] == [42])
            return (200, Data(#"{"42":{"title":"New title","authors":["First","Second"]}}"#.utf8))
        }
        try await context.service.updateMetadata(item: item, title: " New title ", authors: [" First ", "Second"], readingStore: context.readings)
        let updated = try #require(context.readings.readingBook(id: original.id))
        #expect(updated.title == "New title" && updated.author == "First, Second")
        #expect(updated.currentPosition == original.currentPosition)
        #expect(updated.bookmarks == original.bookmarks)
        #expect(updated.remoteSource == original.remoteSource)
        #expect(!updated.isInBookshelf)
        #expect(context.readings.readingBook(id: pdfRecord.id)?.title == "New title")
        #expect(context.readings.readingBook(id: pdfRecord.id)?.remoteSource == pdfRecord.remoteSource)
        #expect(Set(context.invalidations.ids) == [original.id, pdfRecord.id])
        let reopened = BookStore(metadataFileURL: context.metadataURL)
        #expect(reopened.readingBook(id: original.id)?.title == "New title")
    }

    @Test("WebDAV creates only new destinations and rename preserves local reading records")
    func webDAVWrites() async throws {
        let context = try Context(kind: .webDAV)
        defer { context.cleanup() }
        let directory = URL(string: "https://books.example/dav/books/Folder/")!
        let file = context.root.appendingPathComponent("book.txt")
        try Data("書籍".utf8).write(to: file)
        context.http.handler = { request in
            switch request.httpMethod {
            case "PUT": #expect(request.value(forHTTPHeaderField: "If-None-Match") == "*")
            case "MOVE":
                #expect(request.value(forHTTPHeaderField: "Overwrite") == "F")
                #expect(request.value(forHTTPHeaderField: "Destination")?.contains("renamed.txt") == true)
            case "MKCOL": #expect(request.url?.path.hasSuffix("/新資料夾") == true || request.url?.path.hasSuffix("/新資料夾/") == true)
            default: Issue.record("Unexpected request method")
            }
            return (201, Data())
        }
        let uploaded = try await context.service.upload(fileURL: file, connectionID: context.connection.id, directoryURL: directory)
        #expect(uploaded.resourceURL?.path == "/dav/books/Folder/book.txt")
        _ = try await context.service.createFolder(name: "新資料夾", connectionID: context.connection.id, directoryURL: directory)
        let item = context.item()
        let original = context.record(item: item)
        let renamed = try await context.service.move(item: item, toName: "renamed.txt", readingStore: context.readings)
        let record = try #require(context.readings.readingBook(id: original.id))
        #expect(record.remoteSource?.entryID == renamed.absoluteString)
        #expect(record.remoteSource?.format.url == renamed)
        #expect(record.remoteSource?.offlineFilename == original.remoteSource?.offlineFilename)
        #expect(record.remoteSource?.cachedFilename == original.remoteSource?.cachedFilename)
        #expect(record.remoteSource?.version == original.remoteSource?.version)
        #expect(record.currentPosition == original.currentPosition && record.bookmarks == original.bookmarks)
        #expect(context.readings.readingBooks.count == 1)
        #expect(context.readings.books.isEmpty)
        #expect(context.invalidations.ids == [original.id])
    }

    @Test("write failures and unsafe WebDAV paths leave local records and notifications unchanged")
    func failureAndContainment() async throws {
        let context = try Context(kind: .webDAV)
        defer { context.cleanup() }
        let item = context.item()
        let original = context.record(item: item)
        let observer = ChangeCounter(connectionID: context.connection.id)
        defer { observer.stop() }
        for (status, error) in [(412, RemoteLibraryWriteError.alreadyExists), (403, .permissionDenied), (302, .redirectRejected), (207, .invalidResponse)] {
            context.http.handler = { _ in (status, Data()) }
            await #expect(throws: error) { try await context.service.move(item: item, toName: "rename.txt", readingStore: context.readings) }
        }
        #expect(context.readings.readingBook(id: original.id)?.remoteSource == original.remoteSource)
        #expect(observer.count == 0)
        #expect(context.invalidations.ids.isEmpty)
        let count = context.http.requests.count
        for destination in ["https://other.example/dav/books/book.txt", "https://books.example/dav/books-other/book.txt", "https://books.example/dav/books/%2e%2e/book.txt", "https://books.example/dav/books/%2foutside/book.txt"] {
            await #expect(throws: RemoteLibraryWriteError.invalidDestination) {
                try await context.service.move(itemURL: item.formats[0].url, to: URL(string: destination)!, connectionID: context.connection.id)
            }
        }
        await #expect(throws: RemoteLibraryWriteError.invalidName) {
            try await context.service.createFolder(name: "../bad", connectionID: context.connection.id, directoryURL: URL(string: context.connection.url)!)
        }
        #expect(context.http.requests.count == count)
    }

    @MainActor
    private final class Context {
        nonisolated static let libraryResponse = (200, Data(#"{"library_map":{"Main":"Main","中文書庫":"Chinese"},"default_library":"Main"}"#.utf8))
        let root: URL
        let metadataURL: URL
        let connections: OPDSCatalogStore
        let connection: OPDSCatalog
        let readings: BookStore
        let http: WritingFixtureTransport
        let service: RemoteLibraryWritingService
        let invalidations = WritingInvalidationRecorder()

        init(kind: RemoteLibraryKind) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryWriting-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            metadataURL = root.appendingPathComponent("books.json")
            try Data("[]".utf8).write(to: metadataURL)
            readings = BookStore(metadataFileURL: metadataURL)
            connections = OPDSCatalogStore(storageDirectory: root, importLegacyWebDAV: false)
            connection = connections.add(name: "Fixture", url: kind == .webDAV ? "https://books.example/dav/books/" : "https://books.example/proxy/opds", username: nil, password: nil, kind: kind)
            let transport = WritingFixtureTransport()
            transport.handler = { _ in Self.libraryResponse }
            http = transport
            let recorder = invalidations
            service = RemoteLibraryWritingService(store: connections, transportFactory: { _ in transport },
                invalidateReadingResources: { recorder.ids.append($0) })
        }

        func item() -> RemoteLibraryItem {
            let url = URL(string: connection.kind == .webDAV ? "https://books.example/dav/books/book.txt" : "https://books.example/proxy/get/TXT/42/Main")!
            return RemoteLibraryItem(id: connection.kind == .webDAV ? url.absoluteString : "urn:uuid:fixture", connectionID: connection.id, title: "Book", formats: [RemoteLibraryFormat(url: url, fileExtension: "txt", mimeType: "text/plain")])
        }

        func record(item: RemoteLibraryItem) -> ReadingBook {
            var book = ReadingBook(title: item.title, source: "local", contentFilename: UUID().uuidString + ".txt")
            book.isInBookshelf = false
            book.currentPosition = 0.375
            book.bookmarks = [Bookmark(chapterIndex: 0, chapterTitle: "Chapter", position: CoreTextReadingPosition(spineIndex: 0, charOffset: 12), note: "Keep", excerpt: "Text", date: Date())]
            book.remoteSource = RemoteBookReference(connectionID: item.connectionID, entryID: item.id, format: item.formats[0], version: "old-version", cachedFilename: "remote-cache/keep", offlineFilename: "offline-keep.txt")
            readings.saveReadingBook(book)
            return book
        }

        func cleanup() {
            connections.remove(connection)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private final class WritingInvalidationRecorder {
    var ids: [UUID] = []
}

private final class WritingFixtureTransport: RemoteLibraryTransport {
    var handler: ((URLRequest) throws -> (Int, Data))?
    var requests: [URLRequest] = []
    var uploadCount = 0

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        requests.append(request)
        let (status, data) = try handler!(request)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
    func upload(for request: URLRequest, fromFile fileURL: URL) async throws -> (Data, HTTPURLResponse) {
        uploadCount += 1
        var request = request
        request.httpBody = try Data(contentsOf: fileURL)
        return try await data(for: request)
    }
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    func stream(request: any HTTPRequestConvertible, consume: @escaping (Data, Double?) -> HTTPResult<Void>) async -> HTTPResult<HTTPResponse> { .failure(.other(URLError(.unsupportedURL))) }
}

private final class ChangeCounter: @unchecked Sendable {
    var count = 0
    private var token: NSObjectProtocol?
    init(connectionID: String) {
        token = NotificationCenter.default.addObserver(forName: .remoteLibraryDidChange, object: nil, queue: nil) { [weak self] notification in
            if notification.userInfo?["connectionID"] as? String == connectionID { self?.count += 1 }
        }
    }
    func stop() { if let token { NotificationCenter.default.removeObserver(token) }; token = nil }
    deinit { stop() }
}
