import Foundation
import ReadiumZIPFoundation
import Testing
@testable import yuedu_app

/// Only run against the dedicated acceptance library. These tests add unique
/// fixture books and never delete or edit pre-existing books in that library.
@Suite("Live Calibre writing acceptance", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["YUEDU_LIVE_CALIBRE_URL"] != nil))
@MainActor
struct LiveCalibreWritingTests {
    @Test("native file upload, duplicate refusal, metadata edit and server readback", arguments: ["epub", "txt"])
    func uploadAndEdit(_ ext: String) async throws {
        let context = try Context()
        defer { context.cleanup() }
        let title = "Yuedu acceptance " + UUID().uuidString
        let file: URL
        if ext == "epub" {
            var entries = EPUBTestFixtures.proseSmoke().entries
            let original = try #require(entries["OPS/package.opf"].flatMap { String(data: $0, encoding: .utf8) })
            entries["OPS/package.opf"] = Data(original.replacingOccurrences(of: "Prose", with: title).utf8)
            let archive = try await EPUBTestFixtures.makeArchive(entries: entries)
            defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }
            file = context.root.appendingPathComponent(title + ".epub")
            try FileManager.default.copyItem(at: archive, to: file)
        } else {
            file = context.root.appendingPathComponent(title + ".txt")
            try Data((title + "\n\n唯一驗收文字，測試書籍上傳。\n").utf8).write(to: file)
        }
        let capabilities = try await context.service.capabilities(connectionID: context.connection.id)
        #expect(capabilities.canUpload && capabilities.canEditMetadata)
        let result = try await context.service.upload(fileURL: file, connectionID: context.connection.id)
        let bookID = try #require(result.bookID)
        #expect(bookID != 1)
        let resource = try #require(result.resourceURL)
        let format = RemoteLibraryFormat(url: resource, fileExtension: ext, mimeType: ext == "epub" ? "application/epub+zip" : "text/plain")
        let item = RemoteLibraryItem(id: "acceptance-" + UUID().uuidString, connectionID: context.connection.id, title: title, formats: [format])
        let locator = try CalibreBookLocator(item: item, connection: context.connection)
        let before = try await context.metadata(locator)
        #expect((before["title"] as? String)?.contains(title) == true)
        let (downloaded, response) = try await context.http.data(for: URLRequest(url: resource))
        try RemoteLibraryHTTPClient.validate(response)
        if ext == "epub" {
            // Calibre content.py embeds current metadata into served EPUB copies;
            // compare the chapter payload, not ZIP bytes that it rewrites.
            let servedFile = context.root.appendingPathComponent("served.epub")
            try downloaded.write(to: servedFile)
            let archive = try await Archive(url: servedFile, accessMode: .read)
            let entry = try #require(try await archive.get("OPS/chapter1.xhtml"))
            let chapterFile = context.root.appendingPathComponent("chapter.xhtml")
            _ = try await archive.extract(entry, to: chapterFile)
            #expect(try Data(contentsOf: chapterFile) == EPUBTestFixtures.proseSmoke().entries["OPS/chapter1.xhtml"])
        } else {
            #expect(downloaded == (try Data(contentsOf: file)))
        }

        await #expect(throws: RemoteLibraryWriteError.duplicateBook) {
            try await context.service.upload(fileURL: file, connectionID: context.connection.id)
        }

        let readings = BookStore(metadataFileURL: context.root.appendingPathComponent("readings.json"))
        var record = ReadingBook(title: title, source: ext == "epub" ? "local_epub" : "local", contentFilename: "acceptance." + ext)
        record.isInBookshelf = false
        record.currentPosition = 0.25
        record.bookmarks = [Bookmark(chapterIndex: 0, chapterTitle: "Test", position: CoreTextReadingPosition(spineIndex: 0, charOffset: 4), note: "Keep", excerpt: "Test", date: Date())]
        record.remoteSource = RemoteBookReference(connectionID: item.connectionID, entryID: item.id, format: format)
        readings.saveReadingBook(record)
        let updatedTitle = title + " updated"
        try await context.service.updateMetadata(item: item, title: updatedTitle, authors: ["Yuedu Acceptance", "Second Author"], readingStore: readings)
        let after = try await context.metadata(locator)
        #expect(after["title"] as? String == updatedTitle)
        #expect(after["authors"] as? [String] == ["Yuedu Acceptance", "Second Author"])
        let updated = try #require(readings.readingBook(id: record.id))
        #expect(updated.title == updatedTitle)
        #expect(updated.currentPosition == record.currentPosition)
        #expect(updated.bookmarks == record.bookmarks)
        #expect(updated.remoteSource == record.remoteSource)
        #expect(readings.books.isEmpty)
        print("[LiveCalibreWriting] format=\(ext) bookID=\(bookID) upload/duplicate/edit/readback/local-identity=PASS")
    }

    @Test("incorrect credentials fail without beginning an upload")
    func invalidCredentials() async throws {
        let context = try Context(passwordOverride: "wrong-" + UUID().uuidString)
        defer { context.cleanup() }
        do {
            _ = try await context.service.capabilities(connectionID: context.connection.id)
            Issue.record("Invalid credentials must not authenticate")
        } catch {
            guard case OPDSError.authenticationFailed = error else { throw error }
        }
    }

    @Test("a read-only Calibre account refuses mutation",
          .enabled(if: ProcessInfo.processInfo.environment["YUEDU_LIVE_CALIBRE_READONLY_USER"] != nil))
    func readOnlyAccount() async throws {
        let environment = ProcessInfo.processInfo.environment
        let context = try Context(usernameOverride: try #require(environment["YUEDU_LIVE_CALIBRE_READONLY_USER"]),
                                  passwordOverride: try #require(environment["YUEDU_LIVE_CALIBRE_READONLY_PASSWORD"]))
        defer { context.cleanup() }
        let file = context.root.appendingPathComponent("Forbidden-" + UUID().uuidString + ".txt")
        try Data("This upload must be denied.".utf8).write(to: file)
        await #expect(throws: RemoteLibraryWriteError.permissionDenied) {
            try await context.service.upload(fileURL: file, connectionID: context.connection.id)
        }
    }

    @MainActor
    private final class Context {
        let root: URL
        let connections: OPDSCatalogStore
        let connection: OPDSCatalog
        let service: RemoteLibraryWritingService
        let http: RemoteLibraryHTTPClient

        init(usernameOverride: String? = nil, passwordOverride: String? = nil) throws {
            let environment = ProcessInfo.processInfo.environment
            root = FileManager.default.temporaryDirectory.appendingPathComponent("LiveCalibreWrite-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            connections = OPDSCatalogStore(storageDirectory: root, importLegacyWebDAV: false)
            connection = connections.add(name: "Writing acceptance", url: try #require(environment["YUEDU_LIVE_CALIBRE_URL"]),
                username: usernameOverride ?? environment["YUEDU_LIVE_CALIBRE_USER"],
                password: passwordOverride ?? environment["YUEDU_LIVE_CALIBRE_PASSWORD"], kind: .calibre)
            service = RemoteLibraryWritingService(store: connections)
            http = connections.httpClient(for: connection)
        }

        func metadata(_ locator: CalibreBookLocator) async throws -> [String: Any] {
            let url = try locator.address.endpoint(["ajax", "book", String(locator.bookID), locator.libraryID])
            let (data, response) = try await http.data(for: URLRequest(url: url))
            try RemoteLibraryHTTPClient.validate(response)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }

        func cleanup() {
            connections.remove(connection)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
