import Foundation
import Testing
@testable import yuedu_app

/// The OPDS, Calibre and Gutenberg rows the Explore home saves for its next launch
/// (`HomeFeedPageStore`; maintainer, 2026-11-07: 先顯示舊的、背景更新). Every test saves into a
/// folder of its own; OPDS requests are answered by `HomeFeedStub`, nothing reaches the network.
@MainActor
@Suite("Home feed saved pages", .serialized)
struct HomeFeedPageStoreTests {
    /// Two books and a navigation entry, as an OPDS root that lists its books.
    private static let rootFeed = """
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/"><id>root</id><title>Root</title>
      <entry>
        <id>urn:uuid:5f1c0d2e-0000-4000-8000-000000000001</id><title>三體</title><author><name>劉慈欣</name></author>
        <dc:language>zh-Hant</dc:language>
        <link rel="http://opds-spec.org/acquisition" href="/book/1.epub" type="application/epub+zip"/>
        <link rel="http://opds-spec.org/image" href="/cover/1.jpg" type="image/jpeg"/>
      </entry>
      <entry>
        <id>urn:uuid:5f1c0d2e-0000-4000-8000-000000000002</id><title>球狀閃電</title><author><name>劉慈欣</name></author>
        <link rel="http://opds-spec.org/acquisition" href="/book/2.epub" type="application/epub+zip"/>
      </entry>
      <entry>
        <id>urn:uuid:5f1c0d2e-0000-4000-8000-000000000003</id><title>分類</title>
        <link rel="subsection" href="/categories" type="application/atom+xml;profile=opds-catalog;kind=navigation"/>
      </entry>
    </feed>
    """

    /// Gutenberg's navigation-feed books: a link to the book's own feed, the creator as content.
    private static let gutenbergBooks = [
        OPDSEntry(id: "https://www.gutenberg.org/ebooks/84.opds", title: "Frankenstein", summary: "Mary Wollstonecraft Shelley",
                  navigationURL: URL(string: "https://www.gutenberg.org/ebooks/84.opds")),
        OPDSEntry(id: "https://www.gutenberg.org/ebooks/1342.opds", title: "Pride and Prejudice", summary: "Jane Austen",
                  navigationURL: URL(string: "https://www.gutenberg.org/ebooks/1342.opds")),
    ]

    @Test("an entry reads back from disk exactly as it was saved")
    func entryRoundTrip() async throws {
        let entry = OPDSEntry(
            id: "urn:uuid:round-trip", title: "三體", author: "劉慈欣", summary: "<p>地球往事<b>三部曲</b></p>",
            navigationURL: URL(string: "https://library.test/entry/1"),
            acquisitions: [OPDSAcquisition(url: URL(string: "https://library.test/book/1.epub")!, type: "application/epub+zip",
                                           rel: "http://opds-spec.org/acquisition", size: 1_234_567)],
            thumbnailURL: URL(string: "https://library.test/thumb/1.jpg"), coverURL: URL(string: "https://library.test/cover/1.jpg"),
            alternateURL: URL(string: "https://library.test/book/1"), authorNames: ["劉慈欣"],
            relatedLinks: [OPDSRelatedLink(title: "同作者", url: URL(string: "https://library.test/author/1")!)],
            language: "zh-Hant", identifiers: ["urn:isbn:9787536692930"], category: "科幻")
        #expect(try JSONDecoder().decode(OPDSEntry.self, from: JSONEncoder().encode(entry)) == entry)

        let (pages, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = SourceInstanceKey(type: .opds, id: "round-trip")
        let section = HomeSection(layout: .row, binding: .latest)
        #expect(await pages.read(source: source, section: section) == nil, "nothing saved yet")
        await pages.write([entry], source: source, section: section)
        #expect(await pages.read(source: source, section: section) == [entry])
        #expect(await pages.read(source: SourceInstanceKey(type: .opds, id: "another"), section: section) == nil,
                "another source's 「最新」 is another row")
    }

    @Test("an OPDS 「最新」 row is saved, and the next launch draws it without a request")
    func opdsLatestRow() async throws {
        let (pages, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let root = URL(string: "https://latest.home-feed.test/opds")!
        HomeFeedStub.setFeed(Self.rootFeed, for: root)
        let connection = OPDSCatalog(name: "書房", url: root.absoluteString, kind: .opds)
        let section = HomeSection(layout: .row, binding: .latest)

        let provider = OPDSProvider(connection: connection, homeFeedPages: pages) {
            OPDSClient(kind: .opds, httpClient: HomeFeedStub.client(base: root))
        }
        #expect(await provider.savedPage(section) == nil, "nothing saved yet")
        let loaded = try await provider.load(section)
        #expect(loaded.count == 2, "the books, not the navigation entry")

        let relaunched = OPDSProvider(connection: connection, homeFeedPages: pages) {
            Issue.record("the saved row made a request")
            return OPDSClient(kind: .opds)
        }
        #expect(try #require(await relaunched.savedPage(section)) == loaded, "the same cards the load drew")
        let other = OPDSCatalog(name: "另一個書房", url: root.absoluteString, kind: .opds)
        #expect(await OPDSProvider(connection: other, homeFeedPages: pages) { OPDSClient(kind: .opds) }.savedPage(section) == nil,
                "another connection's row, though at the same address")
    }

    @Test("a Gutenberg feed row is saved; a bundled list needs none; a feed that emptied is not drawn from before")
    func gutenbergRows() async throws {
        let (pages, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let availability = PublicLibraryAvailability(defaults: UserDefaults(suiteName: "HomeFeedPageStoreTests-\(UUID().uuidString)")!)
        let section = HomeSection(layout: .row, binding: .gutenbergFeed(url: "https://www.gutenberg.org/ebooks/search.opds/?sort_order=downloads"))

        let gutenberg = GutenbergProvider(availability: availability, homeFeedPages: pages) { _ in OPDSFeed(entries: Self.gutenbergBooks) }
        let loaded = try await gutenberg.load(section)
        #expect(loaded.count == 2)

        var requests = 0
        let relaunched = GutenbergProvider(availability: availability, homeFeedPages: pages) { _ in
            requests += 1
            return OPDSFeed()
        }
        #expect(try #require(await relaunched.savedPage(section)) == loaded, "the same cards the load drew")
        #expect(requests == 0, "read with no request")

        let collection = try #require(PublicLibraryCollection.all.first)
        #expect(await relaunched.savedPage(HomeSection(layout: .row, binding: .gutenbergCollection(id: collection.id))) == nil,
                "a bundled list sends no request, so it has nothing to wait for")

        #expect(try await relaunched.load(section).isEmpty)
        #expect(await relaunched.savedPage(section) == nil, "an empty page is none, and it replaced the older one")
    }

    @Test("past its capacity the store drops the rows saved longest ago")
    func trimsOldestRows() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HomeFeedPageStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pages = HomeFeedPageStore(directory: folder, capacity: 5)
        let source = SourceInstanceKey(type: .opds, id: "capacity")
        let sections = (0..<6).map { HomeSection(layout: .row, binding: .opdsFeed(connectionID: "capacity", url: "https://capacity.test/\($0)")) }
        for (index, section) in sections.prefix(5).enumerated() {
            await pages.write(Self.gutenbergBooks, source: source, section: section)
            let file = try #require(pages.fileURL(source: source, section: section))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000 + Double(index))], ofItemAtPath: file.path)
        }
        await pages.write(Self.gutenbergBooks, source: source, section: sections[5])

        var kept: [Int] = []
        for (index, section) in sections.enumerated() {
            if await pages.read(source: source, section: section) != nil { kept.append(index) }
        }
        #expect(kept == [2, 3, 4, 5], "down to four fifths, the oldest first")
    }

    private func makeStore() throws -> (HomeFeedPageStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HomeFeedPageStore-\(UUID().uuidString)", isDirectory: true)
        return (HomeFeedPageStore(directory: folder), folder)
    }
}

// MARK: - Transport stub

/// Answers each host with its one feed.
private final class HomeFeedStub: Foundation.URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byHost: [String: String] = [:]

    static func setFeed(_ xml: String, for base: URL) {
        lock.withLock { byHost[base.host ?? ""] = xml }
    }

    static func client(base: URL) -> RemoteLibraryHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HomeFeedStub.self]
        return RemoteLibraryHTTPClient(baseURL: base, configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let xml = Self.lock.withLock({ Self.byHost[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/atom+xml"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(xml.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
