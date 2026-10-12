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

    /// 2026-10-12: the illustrated Sense and Sensibility drew three author lines in 作品詳情's
    /// hero, its commentator and illustrator among them, as 「Austen, Jane」. The record says
    /// who did what; the hero names the author, as Apple Books does.
    @Test func recordRolesTellTheAuthorFromTheOtherContributors() throws {
        let detail = try GutenbergBookDetail(feed: fixture("21839"))
        #expect(detail.authors.map(\.name) == ["Austen, Jane", "Dobson, Austin", "Thomson, Hugh"])
        #expect(detail.authors.map(\.role) == ["Author", "Commentator", "Illustrator"])
        #expect(detail.mainAuthors.map(\.displayName) == ["Jane Austen"])
        #expect(detail.contributors.map(\.displayName) == ["Austin Dobson", "Hugh Thomson"])
        #expect(detail.contributors.map(\.roleKey) == ["評註", "插畫"])
    }

    @Test func catalogNamesReadInNaturalOrder() {
        #expect(GutenbergAuthor.displayName("Austen, Jane") == "Jane Austen")
        #expect(GutenbergAuthor.displayName("Wells, H. G. (Herbert George)") == "H. G. Wells")
        #expect(GutenbergAuthor.displayName("King, Martin Luther, Jr.") == "King, Martin Luther, Jr.")
        #expect(GutenbergAuthor.displayName("Lu Xun") == "Lu Xun")
        #expect(GutenbergAuthor.displayName("Homer") == "Homer")
    }

    @Test func aozoraHeroNamesTheAuthorAndListsTheTranslator() {
        var work = AozoraWork(id: "000001", title: "作品", yomi: "", sortYomi: "", subtitle: "",
                              kanaStyle: "", ndc: "", published: "", updated: "", card: "", text: "",
                              textUpdated: "", credits: [.init(person: "001", role: "著者"), .init(person: "002", role: "翻訳者")],
                              source: "", sourcePublisher: "")
        #expect(work.authorCredits.map(\.person) == ["001"])
        #expect(work.otherCredits.map(\.person) == ["002"])
        work.credits = [.init(person: "003", role: "編者"), .init(person: "004", role: "校訂者")]
        #expect(work.authorCredits.map(\.person) == ["003"], "no 著者: the first credit")
        #expect(work.otherCredits.map(\.person) == ["004"])
    }

    /// Without roles (a record that lists none, or OPDS 2), every person is an author.
    @Test func withoutRolesEveryoneIsAnAuthor() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry><id>one</id><title>Book</title>
        <author><name>Last, First</name></author><author><name>Other, Person</name></author>
        <link rel="http://opds-spec.org/acquisition" href="https://www.gutenberg.org/book.epub" type="application/epub+zip"/>
        <link rel="related" type="application/atom+xml" title="By Last, First…" href="https://www.gutenberg.org/ebooks/author/1.opds"/>
        <link rel="related" type="application/atom+xml" title="By Other, Person…" href="https://www.gutenberg.org/ebooks/author/2.opds"/>
        </entry></feed>
        """
        let detail = try GutenbergBookDetail(feed: OPDSClient.parseFeed(data: Data(xml.utf8),
                                                                        feedURL: URL(string: PublicLibrary.gutenberg.url)!))
        #expect(detail.mainAuthors.count == 2)
        #expect(detail.contributors.isEmpty)
    }

    /// Gutenberg's Atom content is its bibliographic record, one `<p>` per field (Title,
    /// Credits, Summary, EBook No., Downloads, Subject, Rights…). 簡介 is its Summary field
    /// alone, and nothing when the book has none: the record is never the description.
    @Test func descriptionIsTheRecordsSummaryAlone() throws {
        let detail = try GutenbergBookDetail(feed: fixture("1342"))
        let summary = try #require(detail.item.summary)
        #expect(summary.hasPrefix("\"Pride and Prejudice\" by Jane Austen is a novel published in 1813."))
        #expect(!summary.hasPrefix("Summary"))
        for field in ["EBook No.", "Downloads:", "Credits:", "Rights:", "LoCC:", "Reading Level:"] {
            #expect(!summary.contains(field), "\(field) is not the description")
        }
    }

    @Test func aRecordWithoutASummaryHasNoDescription() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><entry>
        <id>https://www.gutenberg.org/ebooks/79765.images</id><title>Hero stories of France</title>
        <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml">
        <p>This edition has images.</p>
        <p>LoC No.: 20007446</p>
        <p>
        Contents:
        Vercingetorix, the Hero Patriot -- Saint Denis, the Missionary
        </p>
        <p>Author: Tappan, Eva March, 1854-1930</p>
        <p>EBook No.: 79765</p>
        <p>Downloads: 0</p>
        <p>Rights: Public domain in the USA.</p>
        </div></content>
        <author><name>Tappan, Eva March</name></author>
        <link rel="http://opds-spec.org/acquisition" href="https://www.gutenberg.org/ebooks/79765.epub3.images" type="application/epub+zip"/>
        </entry></feed>
        """
        let feed = try OPDSClient.parseFeed(data: Data(xml.utf8), feedURL: URL(string: "https://www.gutenberg.org/ebooks/79765.opds")!)
        #expect(try GutenbergBookDetail(feed: feed).item.summary == nil)
    }

    /// A Gutenberg list's Atom content is the creator or a download count, never a description,
    /// so its cards carry none for 作品詳情 to fall back on.
    @Test func listEntriesCarryNoBlurb() async throws {
        var entry = OPDSEntry(id: "https://www.gutenberg.org/ebooks/1342", title: "Pride and Prejudice")
        entry.summary = "Austen, Jane"
        entry.navigationURL = URL(string: "https://www.gutenberg.org/ebooks/1342.opds")
        let page = await GutenbergProvider.page(
            from: OPDSFeed(entries: [entry]), connectionID: PublicLibraryID.gutenberg.rawValue,
            record: { GutenbergBook(entry: $0).map(SourceRecord.derived(from:)) },
            opening: { .opdsEntry($0, connectionID: PublicLibraryID.gutenberg.rawValue) })
        guard case .item(let record, let summary, _) = try #require(page.entries.first) else {
            Issue.record("The entry is a book"); return
        }
        #expect(record.authors == ["Austen, Jane"], "The creator is the author")
        #expect(summary.blurb == nil)
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
