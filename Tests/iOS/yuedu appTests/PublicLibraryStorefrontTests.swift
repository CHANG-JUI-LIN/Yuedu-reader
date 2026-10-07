import Foundation
import Testing
@testable import yuedu_app

@Suite("Public library storefront", .serialized)
@MainActor
struct PublicLibraryStorefrontTests {
    private func fixture(_ name: String) throws -> OPDSFeed {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Gutenberg/\(name).xml")
        return try OPDSClient.parseFeed(data: Data(contentsOf: url),
            feedURL: URL(string: "https://www.gutenberg.org/ebooks/\(name).opds")!)
    }

    @Test func preservesIndividualAuthorsAndTheirCatalogLinks() throws {
        let feed = try fixture("1342")
        let detail = try GutenbergBookDetail(feed: feed)
        #expect(detail.authors.count == 1)
        #expect(detail.authors.first?.name == "Austen, Jane")
        #expect(detail.authors.first?.url.absoluteString == "https://www.gutenberg.org/ebooks/author/68.opds")
        #expect(detail.item.title == "Pride and Prejudice")
        #expect(detail.item.formats.first?.url.path.contains(".epub3") == true)
        #expect(Set(detail.item.formats.map(\.id)).count == detail.item.formats.count)
        #expect(detail.item.alternateURL == feed.alternateURL)
    }

    @Test func authorNamesContainingCommasAreNotSplit() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>one</id><title>Book</title>
        <author><name>Last, First</name></author><author><name>Other, Person</name></author>
        <link rel="http://opds-spec.org/acquisition" href="https://www.gutenberg.org/book.epub" type="application/epub+zip"/>
        <link rel="related" type="application/atom+xml" title="By Last, First…" href="https://www.gutenberg.org/ebooks/author/1.opds"/>
        <link rel="related" type="application/atom+xml" title="By Other, Person…" href="https://www.gutenberg.org/ebooks/author/2.opds"/>
        <link rel="related" type="application/atom+xml" title="On fiction…" href="https://www.gutenberg.org/ebooks/subject/3.opds"/>
        </entry></feed>
        """
        let feed = try OPDSClient.parseFeed(data: Data(xml.utf8), feedURL: URL(string: PublicLibrary.gutenberg.url)!)
        let detail = try GutenbergBookDetail(feed: feed)
        #expect(detail.authors.map(\.name) == ["Last, First", "Other, Person"])
        #expect(detail.authors.map(\.url.lastPathComponent) == ["1.opds", "2.opds"])
    }

    @Test func listBookSnapshotsDoNotTreatCategoriesAsBooks() throws {
        let root = try fixture("root")
        #expect(root.entries.compactMap(GutenbergBook.init(entry:)).isEmpty)
        let feed = try fixture("chinese")
        let books = feed.entries.compactMap(GutenbergBook.init(entry:))
        #expect(books.count == 25)
        #expect(books[2].title.contains("紅樓夢"))
        #expect(books[2].author == "Xueqin Cao")
        #expect(books[2].feedURL?.absoluteString == "https://www.gutenberg.org/ebooks/24264.opds")
        #expect(books.first { $0.feedURL?.lastPathComponent == "52323.opds" }?.author == "")
    }

    @Test func carouselFreezesOrderAndRejectsMissingSelection() throws {
        var books = try fixture("chinese").entries.compactMap(GutenbergBook.init(entry:)).map(PublicLibraryBook.gutenberg)
        let selected = books[2].id
        let selection = try #require(PublicLibraryBookSelection(books: books, selectedID: selected))
        books.removeAll()
        #expect(selection.books.count == 25)
        #expect(selection.selectedID == selected)
        #expect(PublicLibraryBookSelection(books: selection.books, selectedID: "missing") == nil)
        #expect(PublicLibraryBookSelection(books: [], selectedID: selected) == nil)
    }

    @Test func detailLoadsOnlyWhenExplicitlySelectedAndOncePerPresentation() async throws {
        let entry = try #require(fixture("chinese").entries.first)
        let book = try #require(GutenbergBook(entry: entry))
        let feed = try fixture("1342")
        var requests: [URL] = []
        let page = GutenbergBookPageModel(book: book) { url in requests.append(url); return feed }
        #expect(requests.isEmpty)
        await page.load()
        await page.load()
        #expect(requests == [book.feedURL!])
        #expect(page.detail?.item.title == "Pride and Prejudice")
    }

    @Test func failedDetailKeepsErrorAndDoesNotRetryOnBodyUpdates() async throws {
        let book = try #require(GutenbergBook(entry: fixture("chinese").entries[0]))
        var count = 0
        let page = GutenbergBookPageModel(book: book) { _ in count += 1; throw URLError(.notConnectedToInternet) }
        await page.load()
        await page.load()
        #expect(count == 1)
        #expect(page.errorMessage != nil)
        #expect(page.detail == nil)
        await page.load(force: true)
        #expect(count == 2)
    }

    @Test func sharedBrowseModelLoadsOnePagePerActionAndDeduplicatesNextPage() async throws {
        let initial = try fixture("chinese")
        let nextURL = URL(string: "https://www.gutenberg.org/ebooks/search.opds/?start_index=26")!
        let route = OPDSFeedRoute(catalogID: PublicLibraryID.gutenberg.rawValue,
            url: PublicLibrary.gutenbergSearchURL(query: "l.zh").absoluteString, title: "Chinese")
        var requests: [URL] = []
        let model = OPDSBrowseModel(route: route) { url in
            requests.append(url)
            var feed = initial
            feed.nextPageURL = url == nextURL ? nil : nextURL
            return feed
        }
        #expect(requests.isEmpty)
        await model.load()
        #expect(requests.count == 1)
        #expect(model.entries.count == 25)
        await model.loadMore()
        #expect(requests.count == 2)
        #expect(requests.last == nextURL)
        #expect(model.entries.count == 25)
        #expect(model.nextPageURL == nil)
    }

    @Test func bundledCollectionsContainRealStableBookLinksAndNoRemoteArtwork() {
        #expect(PublicLibraryCollection.all.count == 4)
        for collection in PublicLibraryCollection.all {
            #expect(!collection.books.isEmpty)
            #expect(Set(collection.books.map(\.id)).count == collection.books.count)
            for book in collection.books {
                #expect(book.feedURL?.host == "www.gutenberg.org")
                #expect(book.feedURL?.pathExtension == "opds")
                #expect(book.entry == nil)
                #expect(!book.title.isEmpty)
            }
        }
    }
}
