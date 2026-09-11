import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Run only against the explicitly configured, isolated authenticated library.
/// Ordinary tests never send a write to a user's server.
@Suite("Live Calibre progress", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["YUEDU_LIVE_CALIBRE_URL"] != nil))
@MainActor
struct LiveCalibreProgressTests {
    @Test("real CoreText offset uploads a Calibre DOM CFI and the authenticated API returns it")
    func realReadingPositionRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        let address = try #require(environment["YUEDU_LIVE_CALIBRE_URL"])
        let username = try #require(environment["YUEDU_LIVE_CALIBRE_USER"])
        let password = try #require(environment["YUEDU_LIVE_CALIBRE_PASSWORD"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaultsName = "LiveCalibreProgress-" + root.lastPathComponent
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let connections = OPDSCatalogStore(storageDirectory: root, importLegacyWebDAV: false)
        var connection = connections.add(name: "Calibre progress acceptance", url: address,
            username: username, password: password, kind: .calibre)
        connection.syncProgress = true
        connections.update(connection, password: nil)
        defer { connections.remove(connection) }
        let client = connections.client(for: connection)
        let feed = try await client.fetchFeed(try #require(URL(string: connection.url)))
        let search = try #require(feed.search)
        let searchURL = try #require(try await client.searchFeedURL(search: search, query: "Quick Start Guide"))
        let found = try await client.fetchFeed(searchURL, isSearch: true)
        let entry = try #require(found.entries.first { $0.title == "Quick Start Guide" })
        let acquisition = try #require(entry.acquisitions.first { $0.importExtension == "epub" })
        let format = RemoteLibraryFormat(url: acquisition.url, fileExtension: "epub", mimeType: acquisition.type)
        let item = RemoteLibraryItem(id: entry.id, connectionID: connection.id, title: entry.title,
                                    author: entry.author, formats: [format])
        let store = BookStore(metadataFileURL: root.appendingPathComponent("books.json"))
        let reader = RemoteLibraryService(connections: connections,
            cache: RemoteLibraryCache(root: root.appendingPathComponent("cache")))
        var book = try await reader.read(item: item, format: format, store: store)
        defer { reader.release(bookID: book.id) }
        let publication = try #require(reader.publication(bookID: book.id))
        let index = try #require(publication.chapters.firstIndex { $0.href.hasSuffix("text/internal_titlepage.xhtml") })
        let builder = EPUBAttributedStringBuilder(session: publication, renderSize: CGSize(width: 320, height: 480))
        let chapter = try await builder.buildChapter(at: index, settings: EPUBTestFixtures.renderSettings(),
            themeTextColor: .black, themeBackgroundColor: .white)
        let text = chapter.attributedString.string
        let phrase = (text as NSString).range(of: "Fourth Edition")
        #expect(phrase.location != NSNotFound)
        guard phrase.location != NSNotFound else { return }
        let offset = phrase.location + 7 // Beginning of "Edition", inside a real DOM text node.
        book.currentPosition = 0.23
        let reference = try #require(book.remoteSource)
        let locator = try CalibreBookLocator(reference: reference, connection: connection)
        let annotationsURL = try locator.address.endpoint(["book-get-annotations", locator.libraryID,
                                                          "\(locator.bookID)-EPUB"])
        let http = connections.httpClient(for: connection)
        let (beforeData, beforeResponse) = try await http.data(for: URLRequest(url: annotationsURL))
        try RemoteLibraryHTTPClient.validate(beforeResponse)
        let beforePayload = try #require(try JSONSerialization.jsonObject(with: beforeData) as? [String: [String: Any]])
        let beforeMap = beforePayload["\(locator.bookID):EPUB"]?["annotations_map"] as? [String: Any] ?? [:]
        let service = CalibreProgressService(connections: connections,
            storageDirectory: root.appendingPathComponent("progress"), defaults: defaults)
        await service.save(book: book, session: publication,
            position: CoreTextReadingPosition(spineIndex: index, charOffset: offset), renderedText: text)
        try #require(service.state(for: book.id) == .synced)

        let getURL = try locator.address.endpoint(["book-get-last-read-position", locator.libraryID,
                                                  "\(locator.bookID)-EPUB"])
        let (data, response) = try await connections.httpClient(for: connection).data(for: URLRequest(url: getURL))
        try RemoteLibraryHTTPClient.validate(response)
        let payload = try #require(try JSONSerialization.jsonObject(with: data) as? [String: [[String: Any]]])
        let returned = try #require(payload["\(locator.bookID):EPUB"]?.first {
            ($0["device"] as? String) == defaults.string(forKey: "calibre_progress_device_id")
        })
        let cfi = try #require(returned["cfi"] as? String)
        // Actual Calibre prepared spine[1], HTML/body/h2/text(), UTF-16 offset 7.
        try #require(cfi == "epubcfi(/4/2/4/4/1:7)")
        #expect(returned["pos_frac"] as? Double == 0.23)
        #expect(returned["user"] as? String == username)
        #expect(returned["format"] as? String == "EPUB")
        #expect(store.books.isEmpty)
        let (annotationData, annotationResponse) = try await http.data(for: URLRequest(url: annotationsURL))
        try RemoteLibraryHTTPClient.validate(annotationResponse)
        let annotations = try #require(try JSONSerialization.jsonObject(with: annotationData) as? [String: [String: Any]])
        let afterMap = try #require(annotations["\(locator.bookID):EPUB"]?["annotations_map"] as? [String: Any])
        // Native 9.14 deliberately filters last-read from annotation persistence.
        // Keep those APIs untouched; this contract is the web reader position.
        let beforeOtherAnnotations = try JSONSerialization.data(withJSONObject: beforeMap, options: .sortedKeys)
        let afterOtherAnnotations = try JSONSerialization.data(withJSONObject: afterMap, options: .sortedKeys)
        #expect(beforeOtherAnnotations == afterOtherAnnotations)
        print("[LiveCalibreProgress] CoreText=(\(index),\(offset)) cfi=\(cfi) target=Edition pos_frac=0.23 webReaderRoundTrip=PASS annotationsUnchanged=PASS")
    }
}
