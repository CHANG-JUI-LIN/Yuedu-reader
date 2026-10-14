import Foundation
import SwiftUI
import Testing
@testable import yuedu_app

/// Unified search 4b-2: 搜索 asks every saved OPDS and Calibre library on submit, each on its
/// own, and one library failing marks only its own answer.
@MainActor
@Suite("Library search", .serialized)
struct LibrarySearchTests {
    @Test("each library answers on its own: results, empty, Calibre's 404, offline, no search")
    func eachLibraryAnswers() async throws {
        let found = library("found", kind: .opds) { request in
            request.url?.path == "/search" ? .feed(Self.bookFeed) : .feed(Self.rootWithSearch)
        }
        let empty = library("empty", kind: .opds) { request in
            request.url?.path == "/search" ? .feed(Self.emptyFeed) : .feed(Self.rootWithSearch)
        }
        let calibre = library("calibre", kind: .calibre) { request in
            request.url?.path == "/search" ? .status(404, "No books found") : .feed(Self.rootWithSearch)
        }
        let offline = library("offline", kind: .opds) { _ in .fail(URLError(.notConnectedToInternet)) }
        let noSearch = library("nosearch", kind: .opds) { _ in .feed(Self.emptyFeed) }
        let search = LibrarySearch(providers: { [found, empty, calibre, offline, noSearch] })

        var answers: [String: LibrarySearchAnswer] = [:]
        await search.search("三體") { answers[$0.connectionID] = $0 }

        #expect(answers[found.instance.id]?.outcome == .results)
        #expect(answers[found.instance.id]?.entries.count == 1)
        #expect(answers[empty.instance.id]?.outcome == .empty)
        #expect(answers[calibre.instance.id]?.outcome == .empty, "Calibre answers an empty search with 404")
        guard case .failed(let reason) = answers[offline.instance.id]?.outcome else {
            Issue.record("offline should fail, got \(String(describing: answers[offline.instance.id]))")
            return
        }
        #expect(!reason.isEmpty)
        #expect(answers[noSearch.instance.id]?.outcome == .noSearch, "no search link is not a failure")
    }

    @Test("the model shows the books it found and the libraries that failed, with their names")
    func modelSections() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = library("found", name: "家裡的 Calibre", kind: .opds) { request in
            request.url?.path == "/search" ? .feed(Self.bookFeed) : .feed(Self.rootWithSearch)
        }
        let offline = library("offline", name: "公司書庫", kind: .opds) { _ in .fail(URLError(.notConnectedToInternet)) }
        let model = LibrarySearchModel(search: LibrarySearch(providers: { [found, offline] }))

        model.start("三體", store: store)
        #expect(model.isSearching)
        await model.waitForTesting()

        #expect(!model.isSearching)
        let match = try #require(model.matches.first)
        #expect(model.matches.count == 1)
        #expect(match.rowContent.title == "三體")
        #expect(match.rowContent.author == "劉慈欣")
        #expect(match.rowContent.detail == "家裡的 Calibre")
        if case .opdsEntry = match.route.opening {} else {
            Issue.record("a library book opens its OPDS entry, got \(match.route.opening)")
        }
        #expect(model.failures.map(\.name) == ["公司書庫"])

        model.clear()
        #expect(model.matches.isEmpty && model.failures.isEmpty && !model.isSearching)
    }

    @Test("a library that takes too long fails on its own; the others still answer")
    func timeout() async throws {
        let found = library("quick", kind: .opds) { request in
            request.url?.path == "/search" ? .feed(Self.bookFeed) : .feed(Self.rootWithSearch)
        }
        let slow = library("slow", kind: .opds) { _ in .never }
        let search = LibrarySearch(providers: { [found, slow] }, timeout: .milliseconds(300))

        var answers: [String: LibrarySearchAnswer] = [:]
        await search.search("三體") { answers[$0.connectionID] = $0 }

        #expect(answers[found.instance.id]?.outcome == .results)
        guard case .failed = answers[slow.instance.id]?.outcome else {
            Issue.record("the slow library should time out, got \(String(describing: answers[slow.instance.id]))")
            return
        }
    }

    @Test("the root is read once: a second search sends only the search")
    func rootOnce() async throws {
        var paths: [String] = []
        let found = library("once", kind: .opds) { request in
            paths.append(request.url?.path ?? "")
            return request.url?.path == "/search" ? .feed(Self.bookFeed) : .feed(Self.rootWithSearch)
        }
        let search = LibrarySearch(providers: { [found] })
        await search.search("三體") { _ in }
        await search.search("球狀閃電") { _ in }
        #expect(paths == ["/root", "/search", "/search"])
    }

    @Test("the iOS 17 row asks for the cover with its library's headers, and the table reloads for it")
    func iOS17Row() async throws {
        let (store, folder) = try makeStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let found = library("row", kind: .opds) { request in
            request.url?.path == "/search" ? .feed(Self.bookFeed) : .feed(Self.rootWithSearch)
        }
        let model = LibrarySearchModel(search: LibrarySearch(providers: { [found] }))
        model.start("三體", store: store)
        await model.waitForTesting()
        let match = try #require(model.matches.first)

        let row = IOS17SearchResultTableRow(libraryMatch: match)
        #expect(row.id == match.id)
        #expect(row.content == match.rowContent)
        #expect(row.coverURL == "https://row.library.test/cover.jpg")
        #expect(row.remoteCover != nil)

        // In the tab root's one list (4c-3) the library's book leads its work and keeps this
        // cover request.
        let works = UnifiedSearchModel(sourceURL: { _ in nil })
        await works.update(UnifiedSearchParts(libraries: model.matches), query: "三體")
        let work = try #require(works.rows.first)
        let workRow = IOS17SearchResultTableRow(unified: work, colorScheme: .light, filledCover: { _ in nil })
        #expect(workRow.coverURL == row.coverURL)
        #expect(workRow.remoteCover == row.remoteCover)
    }

    // MARK: - Fixtures

    static let rootWithSearch = """
    <feed xmlns="http://www.w3.org/2005/Atom"><id>root</id><title>Root</title>
      <link rel="search" type="application/atom+xml" href="/search?q={searchTerms}"/>
    </feed>
    """

    static let bookFeed = """
    <feed xmlns="http://www.w3.org/2005/Atom"><id>search</id><title>Search</title>
      <entry>
        <id>urn:isbn:9787536692930</id><title>三體</title><author><name>劉慈欣</name></author>
        <link rel="http://opds-spec.org/image/thumbnail" href="/cover.jpg" type="image/jpeg"/>
        <link rel="http://opds-spec.org/acquisition" href="/book.epub" type="application/epub+zip"/>
      </entry>
    </feed>
    """

    static let emptyFeed = #"<feed xmlns="http://www.w3.org/2005/Atom"><id>x</id><title>Empty</title></feed>"#

    private func library(_ host: String, name: String? = nil, kind: RemoteLibraryKind,
                         handler: @escaping (URLRequest) -> LibraryStub.Answer) -> OPDSProvider {
        let root = URL(string: "https://\(host).library.test/root")!
        LibraryStub.setHandler(for: root, handler)
        let connection = OPDSCatalog(name: name ?? host, url: root.absoluteString, kind: kind)
        return OPDSProvider(connection: connection) { OPDSClient(kind: kind, httpClient: LibraryStub.client(base: root)) }
    }

    private func makeStore() throws -> (BookStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LibrarySearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return (BookStore(metadataFileURL: folder.appendingPathComponent("books_meta.json")), folder)
    }
}

// MARK: - Transport stub

/// Answers by host, so each library in a test answers on its own.
private final class LibraryStub: Foundation.URLProtocol {
    enum Answer {
        case feed(String)
        case status(Int, String)
        case fail(URLError)
        /// Never answers, as a server that hangs.
        case never
    }

    typealias Handler = (URLRequest) -> Answer
    private static let lock = NSLock()
    nonisolated(unsafe) private static var byHost: [String: Handler] = [:]

    static func setHandler(for base: URL, _ handler: @escaping Handler) {
        lock.withLock { byHost[base.host ?? ""] = handler }
    }

    static func client(base: URL) -> RemoteLibraryHTTPClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibraryStub.self]
        return RemoteLibraryHTTPClient(baseURL: base, configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.byHost[request.url?.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, body, type): (Int, String, String)
        switch handler(request) {
        case .feed(let xml): (status, body, type) = (200, xml, "application/atom+xml")
        case .status(let code, let text): (status, body, type) = (code, text, "text/plain")
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
            return
        case .never:
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
