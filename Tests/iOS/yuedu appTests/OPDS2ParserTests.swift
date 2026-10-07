import Foundation
import Testing
@testable import yuedu_app

/// Hand-written documents in the shape of Gutenberg's OPDS 2 development
/// endpoint (plan 2026-10-07-public-domain-libraries, decision 18). The
/// recorded responses are checked by `GutenbergOPDS2FixtureTests`.
@Suite("OPDS 2 JSON parser")
struct OPDS2ParserTests {

    private let base = URL(string: "https://opds-test.pglaf.org/opds/")!

    private let root = """
    {
      "@context": "https://readium.org/webpub-manifest/context.jsonld",
      "metadata": {"title": "Project Gutenberg", "numberOfItems": 78605, "x-unknown": {"nested": [1, 2]}},
      "links": [
        {"rel": "self", "href": "/opds/", "type": "application/opds+json"},
        {"rel": "start", "href": "/opds/", "type": "application/opds+json"},
        {"rel": "search", "href": "search{?query,title,author}", "type": "application/opds+json", "templated": true},
        {"rel": ["alternate"], "href": "https://www.gutenberg.org/", "type": "text/html"}
      ],
      "facets": [{"metadata": {"title": "Sort"}, "links": [{"href": "?sort=title", "title": "Title"}]}],
      "groups": [
        {
          "metadata": {"title": "Navigation"},
          "navigation": [
            {"href": "bookshelves", "title": "Bookshelves", "type": "application/opds+json", "rel": "subsection"},
            {"href": "subjects", "title": "Subjects", "type": "application/opds+json"}
          ]
        },
        {
          "metadata": {"title": "Recently Added", "numberOfItems": 78605},
          "links": [{"rel": "self", "href": "recent", "type": "application/opds+json", "title": "See all"}],
          "publications": [
            {"metadata": {"title": "Inline", "identifier": "urn:x"},
             "links": [{"rel": "http://opds-spec.org/acquisition/open-access", "href": "/ebooks/1.epub3.images", "type": "application/epub+zip"}]}
          ]
        }
      ]
    }
    """

    private let page = """
    {
      "metadata": {"title": "Recently Added", "itemsPerPage": 2, "currentPage": 1, "numberOfItems": 78605},
      "links": [
        {"rel": "self", "href": "/opds/recent", "type": "application/opds+json"},
        {"rel": "next", "href": "/opds/recent?page=2", "type": "application/opds+json"}
      ],
      "publications": [
        {
          "metadata": {
            "@type": "http://schema.org/Book",
            "identifier": "https://www.gutenberg.org/ebooks/1342",
            "title": "Pride and Prejudice",
            "language": "en",
            "author": {"name": "Austen, Jane", "sortAs": "Austen, Jane",
                       "links": [{"href": "/opds/authors/68", "type": "application/opds+json"}]},
            "description": "<p>A novel of <b>manners</b>.</p>",
            "subject": [{"name": "Courtship -- Fiction"}],
            "modified": "2026-10-01T00:00:00Z"
          },
          "links": [
            {"rel": "self", "href": "/opds/ebooks/1342", "type": "application/opds-publication+json"},
            {"rel": "alternate", "href": "https://www.gutenberg.org/ebooks/1342", "type": "text/html"},
            {"rel": "http://opds-spec.org/acquisition/open-access", "href": "https://www.gutenberg.org/ebooks/1342.epub.noimages", "type": "application/epub+zip"},
            {"rel": "http://opds-spec.org/acquisition/open-access", "href": "https://www.gutenberg.org/ebooks/1342.epub3.images", "type": "application/epub+zip", "properties": {"x": 1}},
            {"rel": "http://opds-spec.org/acquisition/open-access", "href": "https://www.gutenberg.org/ebooks/1342.kf8.images", "type": "application/x-mobipocket-ebook"}
          ],
          "images": [
            {"href": "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.small.jpg", "type": "image/jpeg", "width": 66, "height": 100},
            {"href": "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg", "type": "image/jpeg", "width": 345, "height": 500}
          ]
        },
        {
          "metadata": {
            "identifier": "https://www.gutenberg.org/ebooks/25328",
            "title": "老子",
            "language": ["zh", "en"],
            "author": ["Laozi", {"name": {"en": "Unknown", "zh": "佚名"}}]
          },
          "links": [{"rel": ["http://opds-spec.org/acquisition/open-access"], "href": "/ebooks/25328.epub.images", "type": "application/epub+zip"}]
        }
      ]
    }
    """

    private let publication = """
    {
      "metadata": {"identifier": "https://www.gutenberg.org/ebooks/1342", "title": "Pride and Prejudice",
                   "language": "en", "author": [{"name": "Austen, Jane", "sortAs": "Austen, Jane"}]},
      "links": [
        {"rel": "self", "href": "/opds/ebooks/1342", "type": "application/opds-publication+json"},
        {"rel": "http://opds-spec.org/acquisition/open-access", "href": "https://www.gutenberg.org/cache/epub/1342/pg1342-images-3.epub", "type": "application/epub+zip", "length": 24836548}
      ],
      "images": [
        {"href": "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.small.jpg", "type": "image/jpeg", "width": 66, "rel": "http://opds-spec.org/image/thumbnail"},
        {"href": "https://www.gutenberg.org/cache/epub/1342/pg1342.cover.medium.jpg", "type": "image/jpeg", "width": 200, "rel": "http://opds-spec.org/image"}
      ]
    }
    """

    private func parse(_ json: String, _ url: URL? = nil, type: String = "application/json") throws -> OPDSFeed {
        try OPDSClient.parseFeed(data: Data(json.utf8), feedURL: url ?? base, contentType: type)
    }

    @Test("both JSON media types select the OPDS 2 parser; Atom types do not")
    func contentTypeDispatch() throws {
        #expect(OPDS2FeedParser.handles(contentType: "application/json"))
        #expect(OPDS2FeedParser.handles(contentType: "application/json; charset=utf-8"))
        #expect(OPDS2FeedParser.handles(contentType: "Application/OPDS+JSON"))
        #expect(OPDS2FeedParser.handles(contentType: "application/opds-publication+json"))
        #expect(!OPDS2FeedParser.handles(contentType: "application/atom+xml;profile=opds-catalog"))
        #expect(!OPDS2FeedParser.handles(contentType: nil))
        #expect(try parse(root, type: "application/opds+json").title == "Project Gutenberg")
        // Without a JSON type the document goes to the Atom parser, which rejects it.
        #expect(throws: OPDSError.self) { try OPDSClient.parseFeed(data: Data(root.utf8), feedURL: base) }
    }

    @Test("root: groups flatten to navigation entries; unknown members are ignored")
    func rootGroups() throws {
        let feed = try parse(root)
        #expect(feed.title == "Project Gutenberg")
        let titles = feed.entries.map { $0.title }
        #expect(titles == ["Bookshelves", "Subjects", "Recently Added"])
        #expect(feed.entries.allSatisfy { $0.isNavigation })
        #expect(feed.entries.map { $0.navigationURL?.absoluteString } == [
            "https://opds-test.pglaf.org/opds/bookshelves",
            "https://opds-test.pglaf.org/opds/subjects",
            "https://opds-test.pglaf.org/opds/recent",
        ])
        #expect(feed.alternateURL?.absoluteString == "https://www.gutenberg.org/")
        #expect(feed.nextPageURL == nil)
    }

    @Test("a publications group without a self link keeps its publications inline")
    func groupWithoutSelfLink() throws {
        let json = """
        {"metadata": {"title": "T"}, "groups": [{"metadata": {"title": "Featured"}, "publications": [
          {"metadata": {"title": "Book"}, "links": [{"rel": "http://opds-spec.org/acquisition", "href": "b.epub", "type": "application/epub+zip"}]}
        ]}]}
        """
        let entries = try parse(json).entries
        #expect(entries.count == 1)
        #expect(entries.first?.isBook == true)
        #expect(entries.first?.id == "https://opds-test.pglaf.org/opds/b.epub")
    }

    @Test("templated search expands only the query, encoded, against the feed URL")
    func searchTemplate() async throws {
        let feed = try parse(root)
        let search = try #require(feed.search)
        let url = try #require(try await OPDSClient().searchFeedURL(search: search, query: "Jane Austen & co/+?"))
        #expect(url.absoluteString == "https://opds-test.pglaf.org/opds/search?query=Jane%20Austen%20%26%20co%2F%2B%3F")
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Jane Austen & co/+?")
    }

    @Test("URI template conversion covers the forms OPDS 2 search links use")
    func uriTemplates() throws {
        #expect(OPDS2FeedParser.openSearchTemplate(fromURITemplate: "search{?query,title,author}") == "search?query={searchTerms}")
        #expect(OPDS2FeedParser.openSearchTemplate(fromURITemplate: "/s?lang=en{&title,query}") == "/s?lang=en&query={searchTerms}")
        #expect(OPDS2FeedParser.openSearchTemplate(fromURITemplate: "/s/{query}{?page}") == "/s/{searchTerms}")
        #expect(OPDS2FeedParser.openSearchTemplate(fromURITemplate: "/s{?title,author}") == nil)
        let noQuery = """
        {"metadata": {"title": "T"}, "links": [{"rel": "search", "href": "s{?title}", "templated": true}], "navigation": []}
        """
        #expect(try parse(noQuery).search == nil)
    }

    @Test("publications: identifier, authors with sortAs, language, images, acquisitions, pagination")
    func publicationsPage() throws {
        let feed = try parse(page, URL(string: "https://opds-test.pglaf.org/opds/recent")!)
        #expect(feed.title == "Recently Added")
        #expect(feed.nextPageURL?.absoluteString == "https://opds-test.pglaf.org/opds/recent?page=2")
        #expect(feed.entries.count == 2)

        let book = try #require(feed.entries.first)
        #expect(book.id == "https://www.gutenberg.org/ebooks/1342")
        #expect(book.title == "Pride and Prejudice")
        #expect(book.isBook)
        #expect(book.author == "Austen, Jane")
        #expect(book.authorNames == ["Austen, Jane"])
        let related = book.relatedLinks.map { $0.url.absoluteString }
        #expect(related == ["https://opds-test.pglaf.org/opds/authors/68"])
        #expect(book.summary == "A novel of manners.")
        #expect(book.navigationURL?.absoluteString == "https://opds-test.pglaf.org/opds/ebooks/1342")
        #expect(book.alternateURL?.absoluteString == "https://www.gutenberg.org/ebooks/1342")
        #expect(book.coverURL?.lastPathComponent == "pg1342.cover.medium.jpg")
        #expect(book.thumbnailURL?.lastPathComponent == "pg1342.cover.small.jpg")
        #expect(book.acquisitions.count == 3)
        #expect(book.bestAcquisition?.url.lastPathComponent == "1342.epub3.images")
        #expect(book.bestAcquisition?.rel == "http://opds-spec.org/acquisition/open-access")

        let second = feed.entries[1]
        #expect(second.title == "老子")
        #expect(second.authorNames.count == 2)
        #expect(second.authorNames.first == "Laozi")
        #expect(second.bestAcquisition?.url.absoluteString == "https://opds-test.pglaf.org/ebooks/25328.epub.images")
        #expect(second.coverURL == nil)
    }

    @Test("a publication document becomes a one-entry feed")
    func publicationDocument() throws {
        let feed = try parse(publication, URL(string: "https://opds-test.pglaf.org/opds/ebooks/1342")!)
        #expect(feed.title == "Pride and Prejudice")
        let book = try #require(feed.entries.first)
        #expect(feed.entries.count == 1)
        #expect(book.isBook)
        #expect(book.author == "Austen, Jane")
        #expect(book.coverURL?.lastPathComponent == "pg1342.cover.medium.jpg")
        #expect(book.thumbnailURL?.lastPathComponent == "pg1342.cover.small.jpg")
        #expect(book.bestAcquisition?.size == 24836548)
        #expect(book.bestAcquisition?.importExtension == "epub")
    }

    @Test("language maps choose the preferred language, then English, then a stable key")
    func languageMaps() {
        let map = ["fr": "Orgueil", "en": "Pride", "zh-Hant": "傲慢"]
        #expect(OPDS2FeedParser.LocalizedString.pick(map, preferred: ["zh-Hant-TW", "zh-Hant"]) == "傲慢")
        #expect(OPDS2FeedParser.LocalizedString.pick(map, preferred: ["fr-CA"]) == "Orgueil")
        #expect(OPDS2FeedParser.LocalizedString.pick(map, preferred: ["ja"]) == "Pride")
        #expect(OPDS2FeedParser.LocalizedString.pick(["fr": "B", "de": "A"], preferred: ["ja"]) == "A")
    }

    @Test("empty collections are valid; malformed or mistyped documents are errors")
    func distinguishesEmptyAndInvalid() throws {
        #expect(try parse(#"{"metadata": {"title": "No results"}, "publications": []}"#).entries.isEmpty)
        func expectInvalid(_ json: String) {
            do {
                _ = try parse(json)
                Issue.record("Expected invalidFeed for \(json)")
            } catch OPDSError.invalidFeed {} catch {
                Issue.record("Unexpected error for \(json): \(error)")
            }
        }
        expectInvalid(#"{"metadata": {"title": "Cut off""#)
        expectInvalid("[]")
        expectInvalid("{}")
        expectInvalid(#"{"publications": 5}"#)
        expectInvalid(#"{"navigation": [{"title": "missing href"}]}"#)
        expectInvalid(#"{"publications": [{"links": []}]}"#)
        expectInvalid(#"{"metadata": {"title": 7}, "navigation": []}"#)
        do {
            _ = try parse("")
            Issue.record("Empty body must not become an empty catalog")
        } catch OPDSError.noData {} catch { Issue.record("Unexpected error: \(error)") }
    }
}
