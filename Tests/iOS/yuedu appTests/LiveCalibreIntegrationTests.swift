@testable import YueduCoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Opt-in acceptance against the installed Calibre Content server. The URL is
/// supplied in the test run configuration; ordinary unit runs never use a LAN.
@Suite("Live Calibre acceptance", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["YUEDU_LIVE_CALIBRE_URL"] != nil))
@MainActor
struct LiveCalibreIntegrationTests {
    @Test("real catalog browsing, search, CoreText reading, resume, shelf and offline copy")
    func installedCalibreReadingLifecycle() async throws {
        let address = try #require(ProcessInfo.processInfo.environment["YUEDU_LIVE_CALIBRE_URL"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let connections = OPDSCatalogStore(storageDirectory: root, importLegacyWebDAV: false)
        let connection = connections.add(name: "Calibre acceptance", url: address,
            username: ProcessInfo.processInfo.environment["YUEDU_LIVE_CALIBRE_USER"],
            password: ProcessInfo.processInfo.environment["YUEDU_LIVE_CALIBRE_PASSWORD"], kind: .calibre)
        defer { connections.remove(connection) }
        let client = connections.client(for: connection)
        let feed = try await client.fetchFeed(try #require(URL(string: connection.url)))
        #expect(!feed.entries.isEmpty)
        let navigationURL = try #require(feed.entries.first(where: \.isNavigation)?.navigationURL)
        let catalog = try await client.fetchFeed(navigationURL)
        let matchingEntry = catalog.entries.first { $0.acquisitions.contains { $0.importExtension == "epub" } }
        let entry = try #require(matchingEntry)
        let search = try #require(feed.search)
        let searchURL = try #require(try await client.searchFeedURL(search: search, query: entry.title))
        let found = try await client.fetchFeed(searchURL, isSearch: true)
        #expect(found.entries.contains { $0.id == entry.id })
        let emptyURL = try #require(try await client.searchFeedURL(search: search, query: "yuedu_no_such_book_9f7e"))
        #expect(try await client.fetchFeed(emptyURL, isSearch: true).entries.isEmpty)
        let acquisition = try #require(entry.acquisitions.first { $0.importExtension == "epub" })
        let format = RemoteLibraryFormat(url: acquisition.url, fileExtension: "epub", mimeType: acquisition.type)
        let item = RemoteLibraryItem(id: entry.id, connectionID: connection.id, title: entry.title,
            author: entry.author, summary: entry.summary, coverURL: entry.displayCoverURL, formats: [format])
        let metadata = root.appendingPathComponent("books.json")
        let store = BookStore(metadataFileURL: metadata)
        let service = RemoteLibraryService(connections: connections, cache: RemoteLibraryCache(root: root.appendingPathComponent("cache")))
        let book = try await service.read(item: item, format: format, store: store)
        defer { service.release(bookID: book.id) }
        #expect(store.books.isEmpty)
        #expect(book.remoteSource?.offlineFilename == nil)
        let publication = try #require(service.publication(bookID: book.id))
        #expect(!publication.chapters.isEmpty)
        let builder = EPUBAttributedStringBuilder(session: publication, renderSize: CGSize(width: 320, height: 480))
        let chapter = try await builder.buildChapter(at: 0, settings: EPUBTestFixtures.renderSettings(),
            themeTextColor: .black, themeBackgroundColor: .white)
        let layout = await CoreTextPaginator().paginate(spineIndex: 0, attrStr: chapter.attributedString,
            renderSize: CGSize(width: 320, height: 480), fontSize: 17, contentInsets: .zero, writingMode: .horizontal)
        #expect(!layout.pageRanges.isEmpty)
        let bookmark = Bookmark(chapterIndex: 0, chapterTitle: "Calibre", position: CoreTextReadingPosition(spineIndex: 0, charOffset: 4),
            note: "Acceptance", excerpt: "Calibre", date: Date())
        store.addBookmark(bookId: book.id, bookmark: bookmark)
        store.updatePosition(bookId: book.id, position: 0.25, forceSave: true)
        service.release(bookID: book.id)
        let reopened = BookStore(metadataFileURL: metadata)
        let resumed = try await service.read(item: item, format: format, store: reopened)
        #expect(resumed.id == book.id)
        #expect(resumed.currentPosition == 0.25)
        #expect(resumed.bookmarks == [bookmark])
        let added = try service.addToShelf(item: item, format: format, store: reopened)
        #expect(added.id == book.id)
        #expect(added.bookmarks == [bookmark])
        let downloaded = try await service.downloadOffline(item: item, format: format, store: reopened)
        let offline = try #require(downloaded.remoteSource?.offlineFilename)
        defer { try? FileManager.default.removeItem(at: StorageLocations.bookFile(offline)) }
        #expect(service.hasOfflineCopy(downloaded))
        service.release(bookID: book.id)
        connections.remove(connection)
        let offlineBook = try await service.prepare(bookID: book.id, store: reopened)
        #expect(offlineBook.id == book.id)
        #expect(service.publication(bookID: book.id) != nil)
        print("[LiveCalibre] title=\(entry.title) chapters=\(publication.chapters.count) firstPageCount=\(layout.pageRanges.count) browse/search/read/resume/shelf/offline=PASS")
    }
}
