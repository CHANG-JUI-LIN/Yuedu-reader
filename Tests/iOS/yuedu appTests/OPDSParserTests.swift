import Foundation
import Testing
@testable import yuedu_app

@Suite("OPDS Atom parser")
struct OPDSParserTests {

    private let feedURL = URL(string: "https://example.com/opds")!

    private let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:opds="http://opds-spec.org/2010/catalog">
      <title>Sample Catalog</title>
      <link rel="next" href="?page=2" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
      <link rel="search" href="/opds/search.xml" type="application/opensearchdescription+xml"/>
      <entry>
        <title>Fiction</title>
        <id>nav-fiction</id>
        <link rel="subsection" href="/opds/fiction" type="application/atom+xml;profile=opds-catalog;kind=acquisition"/>
      </entry>
      <entry>
        <title>The Great Book</title>
        <id>urn:book:1</id>
        <author><name>Jane Doe</name></author>
        <summary>A great book.</summary>
        <link rel="http://opds-spec.org/image/thumbnail" href="/covers/1-thumb.jpg" type="image/jpeg"/>
        <link rel="http://opds-spec.org/image" href="/covers/1.jpg" type="image/jpeg"/>
        <link rel="http://opds-spec.org/acquisition" href="/download/1.epub" type="application/epub+zip"/>
      </entry>
      <entry>
        <title>PDF Only</title>
        <id>urn:book:2</id>
        <link rel="http://opds-spec.org/acquisition/open-access" href="/download/2.pdf" type="application/pdf"/>
      </entry>
    </feed>
    """

    @Test func genericMediaTypeUsesAdvertisedFilename() {
        let file = OPDSAcquisition(url: URL(string: "https://example.com/book.EPUB")!,
            type: "application/octet-stream", rel: "http://opds-spec.org/acquisition")
        #expect(file.importExtension == "epub")
        #expect(file.isSupported)
        let unsupported = OPDSAcquisition(url: URL(string: "https://example.com/book.mobi")!,
            type: "application/octet-stream", rel: "http://opds-spec.org/acquisition")
        #expect(!unsupported.isSupported)
    }

    @Test("parses feed title, pagination and search links")
    func feedLevelLinks() throws {
        let feed = try OPDSClient.parseFeed(data: Data(sample.utf8), feedURL: feedURL)
        #expect(feed.title == "Sample Catalog")
        #expect(feed.nextPageURL?.absoluteString == "https://example.com/opds?page=2")
        #expect(feed.searchDescriptionURL?.absoluteString == "https://example.com/opds/search.xml")
        #expect(feed.entries.count == 3)
    }

    @Test("classifies a navigation entry and resolves relative href")
    func navigationEntry() throws {
        let feed = try OPDSClient.parseFeed(data: Data(sample.utf8), feedURL: feedURL)
        let nav = try #require(feed.entries.first { $0.title == "Fiction" })
        #expect(nav.isNavigation)
        #expect(!nav.isBook)
        #expect(nav.navigationURL?.absoluteString == "https://example.com/opds/fiction")
    }

    @Test("classifies a book entry with author, covers and EPUB acquisition")
    func bookEntry() throws {
        let feed = try OPDSClient.parseFeed(data: Data(sample.utf8), feedURL: feedURL)
        let book = try #require(feed.entries.first { $0.title == "The Great Book" })
        #expect(book.isBook)
        #expect(book.author == "Jane Doe")
        #expect(book.thumbnailURL?.absoluteString == "https://example.com/covers/1-thumb.jpg")
        #expect(book.coverURL?.absoluteString == "https://example.com/covers/1.jpg")
        #expect(book.displayCoverURL == book.thumbnailURL)
        #expect(book.bestAcquisition?.importExtension == "epub")
    }

    @Test("PDF acquisition is readable")
    func unsupportedAcquisition() throws {
        let feed = try OPDSClient.parseFeed(data: Data(sample.utf8), feedURL: feedURL)
        let pdf = try #require(feed.entries.first { $0.title == "PDF Only" })
        #expect(pdf.isBook)
        #expect(pdf.bestAcquisition?.importExtension == "pdf")
    }
    @Test("empty Atom feed is valid; broken XML and HTML login are errors")
    func distinguishesEmptyAndInvalid() throws {
        #expect(try OPDSClient.parseFeed(data: Data("<feed xmlns=\"http://www.w3.org/2005/Atom\"/>".utf8), feedURL: feedURL).entries.isEmpty)
        #expect(throws: OPDSError.self) { try OPDSClient.parseFeed(data: Data("<feed><entry>".utf8), feedURL: feedURL) }
        do {
            _ = try OPDSClient.parseFeed(data: Data("<html><body>Login</body></html>".utf8), feedURL: feedURL)
            Issue.record("HTML must not become an empty catalog")
        } catch OPDSError.loginPage {} catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test("XHTML descriptions preserve nested text, multiple authors and acquisition sizes")
    func nestedMetadata() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom" xml:base="https://example.com/proxy/opds/">
          <entry><id>b</id><title>A &amp; B</title><author><name>One</name></author><author><name>Two</name></author>
          <content type="xhtml"><div xmlns="http://www.w3.org/1999/xhtml"><p>First <b>bold</b>.</p><p>Second.</p></div></content>
          <link rel="http://opds-spec.org/acquisition" href="get/1.epub?library=main" type="application/epub+zip" length="2345"/></entry>
        </feed>
        """
        let entry = try #require(OPDSClient.parseFeed(data: Data(xml.utf8), feedURL: feedURL).entries.first)
        #expect(entry.author == "One, Two")
        #expect(entry.summary == "First bold. Second.")
        #expect(entry.title == "A & B")
        #expect(entry.bestAcquisition?.size == 2345)
        #expect(entry.bestAcquisition?.url.absoluteString == "https://example.com/proxy/opds/get/1.epub?library=main")
    }

    @Test("search templates retain braces and encode punctuation in path or query")
    func rawSearchTemplate() async throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><link rel="search" type="application/atom+xml" href="search/{searchTerms}?library=main&amp;count={count?}"/></feed>
        """
        let base = URL(string: "https://example.com/proxy/opds/")!
        let feed = try OPDSClient.parseFeed(data: Data(xml.utf8), feedURL: base)
        let search = try #require(feed.search)
        let url = try #require(try await OPDSClient().searchFeedURL(search: search, query: "中文 &/+?#"))
        #expect(url.absoluteString == "https://example.com/proxy/opds/search/%E4%B8%AD%E6%96%87%20%26%2F%2B%3F%23?library=main&count=50")
        let queryURL = try #require(OPDSClient.resolveSearchTemplate("?q={searchTerms}&library=x", baseURL: base, query: "a&b=c+d"))
        #expect(URLComponents(url: queryURL, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "a&b=c+d")
    }

    @Test("Calibre no-books compatibility only applies to explicit search 404")
    func calibreNoResults() {
        let data = Data("No books found".utf8)
        #expect(OPDSClient.isCalibreEmptySearch(data: data, status: 404, kind: .calibre, isSearch: true))
        #expect(!OPDSClient.isCalibreEmptySearch(data: data, status: 404, kind: .calibre, isSearch: false))
        #expect(!OPDSClient.isCalibreEmptySearch(data: data, status: 404, kind: .opds, isSearch: true))
        #expect(!OPDSClient.isCalibreEmptySearch(data: Data("Not found".utf8), status: 404, kind: .calibre, isSearch: true))
        #expect(!OPDSClient.isCalibreEmptySearch(data: data, status: 401, kind: .calibre, isSearch: true))
    }

}
