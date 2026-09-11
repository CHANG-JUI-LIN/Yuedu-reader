import Foundation
import Testing
@testable import yuedu_app

@Suite("Remote library connections", .serialized)
struct RemoteLibraryConnectionTests {
    @Test("legacy OPDS JSON defaults to OPDS and retains identity")
    func legacyOPDS() throws {
        let data = Data(#"{"id":"legacy-id","name":"Saved","url":"https://example.com/opds","username":"reader"}"#.utf8)
        let catalog = try JSONDecoder().decode(OPDSCatalog.self, from: data)
        #expect(catalog.id == "legacy-id")
        #expect(catalog.kind == .opds)
        #expect(catalog.username == "reader")
        #expect(try JSONDecoder().decode(OPDSCatalog.self, from: JSONEncoder().encode(catalog)) == catalog)
    }

    @Test("Calibre base URLs preserve proxy prefix and library query")
    func normalizedURLs() {
        #expect(OPDSCatalog.normalizedURL(" https://example.com/proxy/?library=main ", kind: .calibre)?.absoluteString == "https://example.com/proxy/opds?library=main")
        #expect(OPDSCatalog.normalizedURL("https://example.com/proxy/opds/nav?library=one", kind: .calibre)?.absoluteString == "https://example.com/proxy/opds/nav?library=one")
        #expect(OPDSCatalog.normalizedURL("https://example.com/dav?token=x", kind: .webDAV)?.absoluteString == "https://example.com/dav/?token=x")
        #expect(OPDSCatalog.normalizedURL("file:///tmp/books", kind: .opds) == nil)
        #expect(OPDSCatalog.normalizedURL("https:///", kind: .opds) == nil)
        #expect(OPDSCatalog.normalizedURL("https://user:pass@example.com", kind: .opds) == nil)
    }

    @Test("WebDAV migration copies once and later edits do not change sync settings")
    func legacyWebDAVCopy() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "remote-library-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        defaults.set("https://example.com/dav", forKey: "webdav_url")
        defaults.set("sync-user", forKey: "webdav_username")
        defaults.set("sync-password", forKey: "webdav_password")
        let store = OPDSCatalogStore(storageDirectory: directory, defaults: defaults)
        var connection = try #require(store.connections.first)
        defer { store.remove(connection) }
        #expect(store.connections.count == 1)
        #expect(connection.kind == .webDAV)
        #expect(store.password(for: connection) == "sync-password")
        connection.url = "https://other.example/library"
        connection.username = "library-user"
        store.update(connection, password: "library-password")
        #expect(defaults.string(forKey: "webdav_url") == "https://example.com/dav")
        #expect(defaults.string(forKey: "webdav_username") == "sync-user")
        #expect(defaults.string(forKey: "webdav_password") == "sync-password")
        let reopened = OPDSCatalogStore(storageDirectory: directory, defaults: defaults)
        #expect(reopened.connections.count == 1)
        #expect(reopened.connections.first?.id == connection.id)
        let saved = try String(contentsOf: directory.appendingPathComponent("opds_catalogs.json"), encoding: .utf8)
        #expect(!saved.contains("library-password"))
        #expect(!saved.contains("sync-password"))
        #expect(!saved.contains("library-user"))
        #expect(!saved.contains("sync-user"))
        #expect(reopened.connections.first?.username == "library-user")
    }

    @Test("WebDAV handles namespaces, encoded names and failed properties")
    func webDAVListing() throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/%E4%B8%AD%E6%96%87.epub</d:href><d:propstat><d:prop><d:displayname>中文.epub</d:displayname><d:getcontentlength>400</d:getcontentlength><d:getetag>v1</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat><d:propstat><d:prop><d:displayname/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/folder/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/dav/denied.epub</d:href><d:propstat><d:prop/><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat></d:response>
        </d:multistatus>
        """
        let entries = try WebDAVBrowseClient.parseListing(data: Data(xml.utf8), collectionURL: URL(string: "https://example.com/dav/")!)
        #expect(entries.count == 2)
        #expect(entries[0].isDirectory)
        #expect(entries[1].name == "中文.epub")
        #expect(entries[1].size == 400)
        #expect(entries[1].etag == "v1")
        #expect(entries[1].isImportableBook)
        #expect(throws: OPDSError.self) {
            try WebDAVBrowseClient.parseListing(data: Data("<html/>".utf8), collectionURL: URL(string: "https://example.com/dav/")!)
        }
    }
    @Test("iCloud excludes remote caches and unshelved files but includes explicit shelf downloads")
    func binarySyncExcludesCache() {
        var book = ReadingBook(title: "Remote", source: "local_epub", contentFilename: "__remote_cache__/book.epub")
        let format = RemoteLibraryFormat(url: URL(string: "https://example.com/book.epub")!, fileExtension: "epub", mimeType: "application/epub+zip")
        book.remoteSource = RemoteBookReference(connectionID: "connection", entryID: "entry", format: format)
        book.remoteSource?.cachedFilename = book.contentFilename
        #expect(ICloudSyncManager.syncableContentFilename(for: book) == nil)
        book.remoteSource?.offlineFilename = "owned.epub"
        #expect(ICloudSyncManager.syncableContentFilename(for: book) == "owned.epub")
        book.isInBookshelf = false
        #expect(ICloudSyncManager.syncableContentFilename(for: book) == nil)
    }

    @Test("WebDAV backup excludes unshelved records and automatic cache pointers")
    func webDAVBackupScope() throws {
        var shelf = ReadingBook(title: "Shelf", source: "local_epub", contentFilename: "__remote_cache__/device/book.epub")
        let format = RemoteLibraryFormat(url: URL(string: "https://example.com/book.epub")!, fileExtension: "epub", mimeType: "application/epub+zip")
        shelf.remoteSource = RemoteBookReference(connectionID: "connection", entryID: "entry", format: format)
        shelf.remoteSource?.cachedFilename = shelf.contentFilename
        var readingOnly = ReadingBook(title: "Not on shelf", source: "local", contentFilename: "reading.txt")
        readingOnly.isInBookshelf = false
        let payload = try WebDAVManager.bookshelfBackupData(from: JSONEncoder().encode([shelf, readingOnly]))
        let books = try JSONDecoder().decode([ReadingBook].self, from: payload)
        #expect(books.count == 1)
        #expect(books.first?.id == shelf.id)
        #expect(books.first?.remoteSource?.format.url == format.url)
        #expect(books.first?.remoteSource?.cachedFilename == nil)
        #expect(books.first?.contentFilename == "")
        #expect(throws: DecodingError.self) { try WebDAVManager.bookshelfBackupData(from: Data("invalid".utf8)) }
    }

    @Test("shelf cover resolves the same authenticated connection session")
    func shelfCoverSession() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OPDSCatalogStore(storageDirectory: directory, importLegacyWebDAV: false)
        let connection = store.add(name: "Catalog", url: "https://example.com/opds", username: "reader", password: "secret")
        defer { store.remove(connection) }
        var book = ReadingBook(title: "Shelf", source: "local_epub", contentFilename: "")
        let format = RemoteLibraryFormat(url: URL(string: "https://example.com/book.epub")!, fileExtension: "epub", mimeType: "application/epub+zip")
        book.remoteSource = RemoteBookReference(connectionID: connection.id, entryID: "book", format: format)
        #expect(BookCoverLoader.remoteSession(for: book, connections: store) === store.httpClient(for: connection).session)
        let original = BookCoverLoader.remoteSession(for: book, connections: store)
        store.update(connection, password: "changed")
        #expect(BookCoverLoader.remoteSession(for: book, connections: store) !== original)
    }

    @Test("legacy OPDS usernames migrate into Keychain without losing login")
    func legacyUsernameMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = OPDSCatalog(name: "Legacy", url: "https://example.com/opds", username: "legacy-login")
        let url = directory.appendingPathComponent("opds_catalogs.json")
        try JSONEncoder().encode([original]).write(to: url)
        let store = OPDSCatalogStore(storageDirectory: directory, importLegacyWebDAV: false)
        defer { store.remove(original) }
        #expect(store.connections.first?.username == "legacy-login")
        #expect(KeychainHelper.load(account: "opds_user_\(original.id)") == "legacy-login")
        #expect(!(try String(contentsOf: url, encoding: .utf8)).contains("legacy-login"))
        let reopened = OPDSCatalogStore(storageDirectory: directory, importLegacyWebDAV: false)
        #expect(reopened.connections.first?.username == "legacy-login")
        store.remove(original)
        #expect(KeychainHelper.load(account: "opds_user_\(original.id)") == nil)
    }

}
