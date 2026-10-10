import Foundation
import Testing
@testable import yuedu_app

// Unified library 2a: providers and the registry. Each provider is tested against the same
// client calls the browse models make, through a stubbed transport.

// MARK: - Failures

@Suite("Source failure")
struct SourceFailureTests {
    @Test("every classified failure keeps the original text", arguments: [
        OPDSError.authenticationFailed as Error, OPDSError.loginPage, OPDSError.http(503), OPDSError.invalidFeed, OPDSError.noData,
        OPDSError.unsupportedScheme, URLError(.timedOut), URLError(.notConnectedToInternet), URLError(.badURL),
    ])
    func keepsText(_ error: Error) throws {
        #expect(try SourceFailure.classify(error).localizedDescription == error.localizedDescription)
    }

    @Test("failures are typed")
    func kinds() throws {
        #expect(try SourceFailure.classify(OPDSError.authenticationFailed).kind == .authentication)
        #expect(try SourceFailure.classify(OPDSError.loginPage).kind == .authentication)
        let rejected = try SourceFailure.classify(OPDSError.http(404))
        #expect(rejected.kind == .rejected && rejected.status == 404)
        #expect(try SourceFailure.classify(OPDSError.invalidFeed).kind == .parse)
        #expect(try SourceFailure.classify(URLError(.timedOut)).kind == .timeout)
        #expect(try SourceFailure.classify(URLError(.networkConnectionLost)).kind == .network)
        #expect(SourceFailure.connectionRemoved.localizedDescription == localized("書庫連線已移除，請重新加入伺服器。"))
    }

    @Test("cancellation passes through unclassified")
    func cancellation() {
        #expect(throws: CancellationError.self) { try SourceFailure.classify(CancellationError()) }
        #expect(throws: URLError.self) { try SourceFailure.classify(URLError(.cancelled)) }
    }

    @Test("the underlying error is what gets logged")
    func loggable() throws {
        let failure = try SourceFailure.classify(URLError(.timedOut))
        #expect((SourceFailure.loggable(failure) as? URLError)?.code == .timedOut)
    }
}

// MARK: - OPDS and Gutenberg

@MainActor
@Suite("OPDS provider", .serialized)
struct OPDSProviderTests {
    private let root = URL(string: "https://opds.example/root")!

    @Test("navigation entries are locations, books are items, and the next link is the cursor")
    func browse() async throws {
        let provider = makeProvider(kind: .opds) { request in
            #expect(request.url == URL(string: "https://opds.example/root"))
            return (200, Self.atom, "application/atom+xml")
        }
        let page = try await provider.browse(nil, after: nil)

        #expect(page.entries.count == 2, "an entry with neither a link nor an acquisition is left out")
        guard case .location(let location) = page.entries[0], case .item(let record, let summary, _) = page.entries[1] else {
            Issue.record("unexpected entries: \(page.entries)")
            return
        }
        #expect(location == CollectionLocation(id: "https://opds.example/new", title: "新書"))
        #expect(record.key == SourceItemKey(instance: SourceInstanceKey(type: .opds, id: provider.connection.id), item: "urn:isbn:9787536692930"))
        #expect(record.identifiers.contains(.normalized(.isbn13, "9787536692930")!))
        #expect(summary.title == "三體")
        #expect(summary.blurb == "地球往事")
        #expect(summary.cover == .remote(URL(string: "https://opds.example/cover.jpg")!, headers: [:]))
        #expect(page.next == CollectionCursor(value: "https://opds.example/root?page=2"))
    }

    @Test("a cursor is fetched as given, and an empty feed is an empty page")
    func cursorAndEmpty() async throws {
        var requested: [URL] = []
        let provider = makeProvider(kind: .opds) { request in
            requested.append(request.url!)
            return (200, #"<feed xmlns="http://www.w3.org/2005/Atom"><id>x</id><title>Empty</title></feed>"#, "application/atom+xml")
        }
        let page = try await provider.browse(nil, after: CollectionCursor(value: "https://opds.example/root?page=2"))
        #expect(requested == [URL(string: "https://opds.example/root?page=2")!])
        #expect(page.entries.isEmpty && page.next == nil)
    }

    @Test("server answers become typed failures with their old text")
    func failures() async throws {
        for (status, body, kind) in [(401, "", SourceFailure.Kind.authentication), (500, "", .rejected), (200, "<not-a-feed/>", .parse)] {
            let provider = makeProvider(kind: .opds) { _ in (status, body, "application/xml") }
            do {
                _ = try await provider.feed(root, isSearch: false)
                Issue.record("status \(status) should fail")
            } catch let failure as SourceFailure {
                #expect(failure.kind == kind)
            }
        }
    }

    @Test("Calibre's 404 'No books found' is an empty search, and only a search")
    func calibreEmptySearch() async throws {
        let provider = makeProvider(kind: .calibre) { _ in (404, "No books found", "text/plain") }
        #expect(try await provider.feed(root, isSearch: true).entries.isEmpty)
        await #expect(throws: SourceFailure.self) { _ = try await provider.feed(root, isSearch: false) }
    }

    @Test("a catalog with no advertised search has none")
    func noSearch() async throws {
        let provider = makeProvider(kind: .opds) { _ in (500, "", "text/plain") }
        #expect(try await provider.searchURL(query: "三體", search: nil) == nil)
        let template = OPDSSearch.template("https://opds.example/search?q={searchTerms}", baseURL: root)
        #expect(try await provider.searchURL(query: "abc", search: template) == URL(string: "https://opds.example/search?q=abc"))
    }

    @Test("Gutenberg goes through its transport and its own search URL, and is hidden in the China region")
    func gutenberg() async throws {
        var requested: [URL] = []
        let availability = PublicLibraryAvailability(defaults: UserDefaults(suiteName: "gutenberg-provider-\(UUID().uuidString)")!)
        let provider = GutenbergProvider(availability: availability) { url in
            requested.append(url)
            var entry = OPDSEntry(id: "https://www.gutenberg.org/ebooks/1342.opds", title: "Pride and Prejudice")
            entry.navigationURL = URL(string: "https://www.gutenberg.org/ebooks/1342.opds")
            var feed = OPDSFeed()
            feed.entries = [entry]
            return feed
        }
        #expect(try await provider.searchURL(query: "austen", search: nil) == PublicLibrary.gutenbergSearchURL(query: "austen"))
        let page = try await provider.browse(nil, after: nil)
        #expect(requested == [URL(string: PublicLibrary.gutenberg.url)!])
        guard case .item(let record, _, _) = page.entries.first else { Issue.record("expected a book"); return }
        #expect(record.key.item == "1342")
        #expect(provider.availability == .available)
        availability.receive(countryCode: "CHN")
        #expect(provider.availability == .hiddenInRegion)
    }

    // MARK: Helpers

    private func makeProvider(kind: RemoteLibraryKind, handler: @escaping (URLRequest) -> (Int, String, String)) -> OPDSProvider {
        ProviderHTTPStub.setHandler(for: root) { request in
            let (status, body, type) = handler(request)
            return (status, ["Content-Type": type], Data(body.utf8))
        }
        let connection = OPDSCatalog(name: "Fixture", url: root.absoluteString, kind: kind)
        let root = root
        return OPDSProvider(connection: connection) { OPDSClient(kind: kind, httpClient: ProviderHTTPStub.client(base: root)) }
    }

    static let atom = """
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/terms/">
      <id>root</id><title>Root</title>
      <link rel="next" href="/root?page=2" type="application/atom+xml"/>
      <entry><id>nav</id><title>新書</title><link rel="subsection" href="/new" type="application/atom+xml;profile=opds-catalog"/></entry>
      <entry>
        <id>urn:isbn:9787536692930</id><title>三體</title><author><name>劉慈欣</name></author>
        <summary type="html">&lt;p&gt;地球往事&lt;/p&gt;</summary>
        <link rel="http://opds-spec.org/image/thumbnail" href="/cover.jpg" type="image/jpeg"/>
        <link rel="http://opds-spec.org/acquisition" href="/book.epub" type="application/epub+zip"/>
      </entry>
      <entry><id>orphan</id><title>Nowhere</title></entry>
    </feed>
    """
}

// MARK: - WebDAV

@MainActor
@Suite("WebDAV provider", .serialized)
struct WebDAVProviderTests {
    private let root = URL(string: "https://dav.example/books/")!

    @Test("folders are locations; book files are items with acquisitions; other files have none")
    func browse() async throws {
        let provider = makeProvider { request in
            #expect(request.httpMethod == "PROPFIND")
            return (207, Self.listing)
        }
        let page = try await provider.browse(nil, after: nil)
        #expect(page.entries.count == 3)
        #expect(page.entries.contains(.location(CollectionLocation(id: "https://dav.example/books/Fiction/", title: "Fiction"))))
        let items = page.entries.compactMap { entry -> SourceRecord? in
            if case .item(let record, _, _) = entry { return record }
            return nil
        }
        let epub = try #require(items.first { $0.key.item == "三體.epub" })
        #expect(!epub.acquisitions.isEmpty)
        let image = try #require(items.first { $0.key.item == "cover.jpg" })
        #expect(image.acquisitions.isEmpty)
        #expect(page.next == nil)
    }

    @Test("an authentication failure is typed, with the old text")
    func failure() async throws {
        let provider = makeProvider { _ in (401, "") }
        do {
            _ = try await provider.list(root)
            Issue.record("should fail")
        } catch let failure as SourceFailure {
            #expect(failure.kind == .authentication)
            #expect(failure.localizedDescription == OPDSError.authenticationFailed.localizedDescription)
        }
    }

    private func makeProvider(handler: @escaping (URLRequest) -> (Int, String)) -> WebDAVProvider {
        ProviderHTTPStub.setHandler(for: root) { request in
            let (status, body) = handler(request)
            return (status, ["Content-Type": "application/xml"], Data(body.utf8))
        }
        let connection = OPDSCatalog(name: "Fixture", url: root.absoluteString, kind: .webDAV)
        let root = root
        return WebDAVProvider(connection: connection) {
            WebDAVBrowseClient(serverUrl: root.absoluteString, username: "", password: "", httpClient: ProviderHTTPStub.client(base: root))
        }
    }

    static let listing = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:">
      <d:response><d:href>/books/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      <d:response><d:href>/books/Fiction/</d:href><d:propstat><d:prop><d:displayname>Fiction</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      <d:response><d:href>/books/%E4%B8%89%E9%AB%94.epub</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>1024</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      <d:response><d:href>/books/cover.jpg</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>10</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
    </d:multistatus>
    """
}

// MARK: - Aozora and the shelf

@MainActor
@Suite("Aozora provider")
struct AozoraProviderTests {
    @Test("the root lists four ways in; works page by offset; not ready and region are reported")
    func browse() async throws {
        let index = AozoraCatalogIndex(catalog: try AozoraCatalog.decode(AozoraCatalogTests.fixture))
        var ready = true
        let availability = PublicLibraryAvailability(defaults: UserDefaults(suiteName: "aozora-provider-\(UUID().uuidString)")!)
        let provider = AozoraProvider(catalog: { ready ? index : nil }, availability: availability)

        let root = try await provider.browse(nil, after: nil)
        #expect(root.entries.map { entry -> String in
            if case .location(let location) = entry { return location.id }
            return ""
        } == ["new", "authors", "titles", "categories"])

        let newest = try await provider.browse(CollectionLocation(id: "new", title: ""), after: nil)
        #expect(newest.entries.count == min(index.newWorks.count, AozoraProvider.pageSize))
        if case .item(let record, let summary, _) = newest.entries.first {
            #expect(record.identifiers.contains { $0.scheme == .aozoraWork })
            #expect(summary.language == "ja")
        } else {
            Issue.record("expected a work")
        }

        let authors = try await provider.browse(CollectionLocation(id: "authors", title: ""), after: nil)
        #expect(authors.entries.count == index.authorGroups.count)

        #expect(provider.availability == .available)
        ready = false
        #expect(provider.availability == .catalogNotReady)
        await #expect(throws: SourceFailure.self) { _ = try await provider.browse(nil, after: nil) }
        availability.receive(countryCode: "CHN")
        #expect(provider.availability == .hiddenInRegion)
    }
}

@MainActor
@Suite("Shelf provider", .serialized)
struct ShelfProviderTests {
    @Test("groups are locations, books are items carrying their copy")
    func browse() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShelfProvider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json"))
        var grouped = ReadingBook(title: "三體", author: "劉慈欣", source: "local_epub", contentFilename: "a.epub")
        grouped.group = "科幻"
        let loose = ReadingBook(title: "紅樓夢", author: "曹雪芹", source: "local_epub", contentFilename: "b.epub")
        store.saveReadingBook(grouped)
        store.saveReadingBook(loose)
        defer { store.waitForQueuedWrites() }
        let provider = ShelfProvider(store: store)

        let root = try await provider.browse(nil, after: nil)
        #expect(root.entries.first == .location(CollectionLocation(id: "group/科幻", title: "科幻")))
        let rootCopies = root.entries.compactMap { entry -> UUID? in
            if case .item(let record, _, _) = entry { return record.copyID }
            return nil
        }
        #expect(Set(rootCopies) == [grouped.id, loose.id])

        let group = try await provider.browse(CollectionLocation(id: "group/科幻", title: "科幻"), after: nil)
        #expect(group.entries.count == 1)
    }
}

// MARK: - The registry

@MainActor
@Suite("Source provider registry", .serialized)
struct SourceProviderRegistryTests {
    @Test("connections become providers, resolved at each lookup; the region hides only the list")
    func registry() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ProviderRegistry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let connections = OPDSCatalogStore(storageDirectory: folder, importLegacyWebDAV: false)
        let opds = connections.add(name: "OPDS", url: "https://opds.example/", username: nil, password: nil, kind: .opds)
        let calibre = connections.add(name: "Calibre", url: "https://calibre.example/opds", username: nil, password: nil, kind: .calibre)
        let dav = connections.add(name: "DAV", url: "https://dav.example/", username: nil, password: nil, kind: .webDAV)
        let availability = PublicLibraryAvailability(defaults: UserDefaults(suiteName: "registry-\(UUID().uuidString)")!)
        let registry = SourceProviderRegistry(connections: connections, availability: availability)

        #expect(registry.opdsProvider(catalogID: opds.id)?.instance == SourceInstanceKey(type: .opds, id: opds.id))
        #expect(registry.opdsProvider(catalogID: calibre.id)?.instance == SourceInstanceKey(type: .calibre, id: calibre.id))
        #expect(registry.opdsProvider(catalogID: dav.id) == nil)
        #expect(registry.webDAVProvider(connectionID: dav.id)?.instance == SourceInstanceKey(type: .webDAV, id: dav.id))
        #expect(registry.webDAVProvider(connectionID: opds.id) == nil)

        connections.remove(opds)
        #expect(registry.opdsProvider(catalogID: opds.id) == nil, "a removed connection is gone at once")

        #expect(registry.browsableProviders().map(\.instance.type) == [.calibre, .webDAV, .gutenberg, .aozora])
        availability.receive(countryCode: "CHN")
        #expect(registry.browsableProviders().map(\.instance.type) == [.calibre, .webDAV])
        #expect(registry.opdsProvider(catalogID: PublicLibraryID.gutenberg.rawValue) != nil, "an open storefront keeps its source")
    }
}

// MARK: - Transport stub

/// Answers by host, so the OPDS and WebDAV suites never answer each other's requests if
/// they run at the same time.
private final class ProviderHTTPStub: Foundation.URLProtocol {
    typealias Handler = (URLRequest) -> (Int, [String: String], Data)
    private static let handlers = NSLock()
    nonisolated(unsafe) private static var byHost: [String: Handler] = [:]

    static func setHandler(for base: URL, _ handler: @escaping Handler) {
        handlers.withLock { byHost[base.host ?? ""] = handler }
    }

    static func client(base: URL) -> RemoteLibraryHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProviderHTTPStub.self]
        return RemoteLibraryHTTPClient(baseURL: base, configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handlers.withLock({ Self.byHost[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
