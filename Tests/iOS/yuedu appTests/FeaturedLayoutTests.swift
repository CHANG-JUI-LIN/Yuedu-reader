import Foundation
import Testing
@testable import yuedu_app

/// Decisions 30 and 37: the 精選 layout, and the category its card shows, carried from where a
/// source has one and never made up.
@Suite("精選 layout and categories")
@MainActor
struct FeaturedLayoutTests {
    private let feedURL = URL(string: "https://example.com/opds")!

    private func atom(_ categories: String) -> String {
        """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Feed</title>
        <entry><id>urn:1</id><title>Book</title>\(categories)
        <link rel="http://opds-spec.org/acquisition" href="/1.epub" type="application/epub+zip"/></entry>
        </feed>
        """
    }

    @Test("OPDS 1: the first category with a name, past classification codes and the DCMI type")
    func atomCategory() throws {
        // Gutenberg's book feed, as recorded: the LCC code and the DCMI type come first.
        let gutenberg = atom("""
        <category scheme="http://purl.org/dc/terms/DCMIType" term="Text"/>
        <category scheme="http://purl.org/dc/terms/LCC" term="PL" label="Language and Literatures: Languages and literatures of Eastern Asia, Africa, Oceania"/>
        <category scheme="http://purl.org/dc/terms/LCSH" term="Upper class -- China -- Fiction"/>
        """)
        let entry = try #require(OPDSClient.parseFeed(data: Data(gutenberg.utf8), feedURL: feedURL).entries.first)
        #expect(entry.category == "Upper class -- China -- Fiction")

        // A label is the category's name; the term is its key.
        let labelled = atom(#"<category term="fantasy" label="奇幻"/>"#)
        #expect(try OPDSClient.parseFeed(data: Data(labelled.utf8), feedURL: feedURL).entries.first?.category == "奇幻")

        let codesOnly = atom(#"<category scheme="http://purl.org/dc/terms/LCC" term="PL" label="Languages"/>"#)
        #expect(try OPDSClient.parseFeed(data: Data(codesOnly.utf8), feedURL: feedURL).entries.first?.category == nil)
        #expect(try OPDSClient.parseFeed(data: Data(atom("").utf8), feedURL: feedURL).entries.first?.category == nil)
    }

    @Test("OPDS 2: the first subject, a name or an object's name")
    func jsonSubject() throws {
        func subject(_ json: String) throws -> String? {
            let document = """
            {"metadata": {"title": "Feed"}, "publications": [
              {"metadata": {"title": "Book", "identifier": "urn:1", "subject": \(json)},
               "links": [{"rel": "http://opds-spec.org/acquisition/open-access", "href": "/1.epub", "type": "application/epub+zip"}]}
            ]}
            """
            return try OPDS2FeedParser.parse(data: Data(document.utf8), feedURL: feedURL).entries.first?.category
        }
        #expect(try subject(#""Science Fiction""#) == "Science Fiction")
        #expect(try subject(#"[{"name": "推理", "code": "x"}, "Other"]"#) == "推理")
        #expect(try subject(#"[{"name": "PL", "scheme": "http://purl.org/dc/terms/LCC"}, {"name": {"en": "History"}}]"#) == "History")
        #expect(try subject("[]") == nil)
    }

    @Test("a book source's kind: its first tag that is not a number, a date or a count")
    func sourceKind() {
        #expect(WorkSummary.category(fromSourceKind: "玄幻,連載,2023-01-01") == "玄幻")
        #expect(WorkSummary.category(fromSourceKind: "2023-01-01 120萬字 都市") == "都市")
        #expect(WorkSummary.category(fromSourceKind: "  ") == nil)
        #expect(WorkSummary.category(fromSourceKind: "123,4.5") == nil)
        #expect(WorkSummary.category(fromSourceKind: String(repeating: "長", count: 100))?.count == WorkSummary.categoryLimit)

        var source = BookSource()
        source.bookSourceUrl = "https://source.example"
        let book = OnlineBook(name: "斗罗大陆", author: "唐家三少", intro: "", coverUrl: "",
                              bookUrl: "https://site.example/book/9", tocUrl: "", wordCount: "",
                              lastChapter: "", kind: "玄幻、完結", sourceId: source.id, sourceName: "S")
        guard case .item(_, let summary, _) = CollectionEntry.onlineBook(book, source: source) else {
            Issue.record("a book-source book is an item")
            return
        }
        #expect(summary.category == "玄幻")
    }

    @Test("精選 is written as its own value, so a build before it keeps it and draws a row")
    func storedValue() throws {
        let layout = HomeSectionLayout(style: .featured)
        #expect(layout.rawValue == "featured")
        #expect(layout.isKnown)
        let section = HomeSection(layout: layout, binding: .gutenbergCollection(id: "chinese"))
        let decoded = try JSONDecoder().decode(HomeSection.self, from: JSONEncoder().encode(section))
        #expect(decoded.layout.style == .featured)
    }
}
