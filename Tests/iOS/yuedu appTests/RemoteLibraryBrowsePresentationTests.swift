import Foundation
import Testing
@testable import yuedu_app

@Suite("Remote library browsing presentation")
@MainActor
struct RemoteLibraryBrowsePresentationTests {
    @Test("Opening a result freezes metadata independently from later search updates")
    func selectedResultRetainsSnapshot() throws {
        var entry = OPDSEntry(id: "book-7", title: "Selected Book", author: "Author", summary: "<p>First summary</p>")
        entry.acquisitions = [OPDSAcquisition(url: try #require(URL(string: "https://example.com/book.epub")),
                                            type: "application/epub+zip", rel: "http://opds-spec.org/acquisition")]
        let route = RemoteLibraryBookRoute(entry: entry, connectionID: "catalog-1")
        entry.title = "A new search result"
        entry.summary = "Replacement"
        entry.acquisitions = []

        #expect(route.item.title == "Selected Book")
        #expect(route.item.summary == "First summary")
        #expect(route.item.formats.count == 1)
        #expect(route.item.connectionID == "catalog-1")
    }

    @Test("Source introductions are bounded and stripped of HTML before entering the detail view")
    func introductionIsSafeForDetailLayout() {
        let intro = "<p>" + String(repeating: "Chapter ", count: 10_000) + "</p>"
        let entry = OPDSEntry(id: "long", title: String(repeating: "T", count: 1000), summary: intro)
        let route = RemoteLibraryBookRoute(entry: entry, connectionID: "catalog")

        #expect(route.item.title.count == 500)
        #expect((route.item.summary?.count ?? 0) <= OnlineBookDetailPresentationPolicy.maximumIntroCharacters + 1)
        #expect(route.item.summary?.contains("<p>") == false)
    }

    @Test("Folder search filters the current listing without modifying its order or entries")
    func folderSearchPreservesListing() throws {
        let entries = [
            WebDAVBrowseClient.Entry(url: try #require(URL(string: "https://example.com/dav/fiction/")), name: "Fiction", isDirectory: true, size: 0),
            WebDAVBrowseClient.Entry(url: try #require(URL(string: "https://example.com/dav/river.epub")), name: "River.epub", isDirectory: false, size: 600),
            WebDAVBrowseClient.Entry(url: try #require(URL(string: "https://example.com/dav/river-notes.md")), name: "River notes.md", isDirectory: false, size: 100),
        ]

        let result = RemoteLibraryBrowsePresentation.filtered(entries, query: "  RIVER  ")
        #expect(result.map(\.name) == ["River.epub", "River notes.md"])
        #expect(entries.count == 3)
        #expect(RemoteLibraryBrowsePresentation.filtered(entries, query: "  ") == entries)
        #expect(RemoteLibraryBrowsePresentation.filtered(entries, query: "absent").isEmpty)
    }

    @Test("A WebDAV selection can describe a book using listing metadata alone")
    func webDAVSnapshotUsesListingMetadata() throws {
        let url = try #require(URL(string: "https://example.com/dav/%E7%AD%86%E8%A8%98.markdown"))
        let entry = WebDAVBrowseClient.Entry(url: url, name: "筆記.markdown", isDirectory: false, size: 1024)
        let route = RemoteLibraryBookRoute(entry: entry, connectionID: "dav")
        let format = try #require(route.item.formats.first)

        #expect(route.item.title == "筆記")
        #expect(route.item.author == nil)
        #expect(route.item.coverURL == nil)
        #expect(format.url == url)
        #expect(format.fileExtension == "md")
        #expect(format.mimeType == "text/markdown")
        #expect(format.size == 1024)
        #expect(format.isSupported)
    }

    @Test("EPUB is initially selected while every offered format remains selectable")
    func defaultFormatSelectionKeepsAlternatives() throws {
        let baseURL = try #require(URL(string: "https://example.com/book"))
        let formats = [
            RemoteLibraryFormat(url: baseURL.appendingPathExtension("mobi"), fileExtension: "mobi", mimeType: "application/x-mobipocket-ebook"),
            RemoteLibraryFormat(url: baseURL.appendingPathExtension("pdf"), fileExtension: "pdf", mimeType: "application/pdf"),
            RemoteLibraryFormat(url: baseURL.appendingPathExtension("epub"), fileExtension: "epub", mimeType: "application/epub+zip"),
        ]
        let item = RemoteLibraryItem(id: "book", connectionID: "catalog", title: "Book", formats: formats)
        #expect(RemoteLibraryBrowsePresentation.preferredFormat(in: item)?.fileExtension == "epub")
        #expect(item.formats == formats)
        #expect(item.formats.first?.isSupported == false)
    }
}
