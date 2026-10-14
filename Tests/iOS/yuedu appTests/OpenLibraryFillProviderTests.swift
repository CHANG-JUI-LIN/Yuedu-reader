import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Unified library Phase 3c: Open Library by ISBN (level A). Requests are answered by a
/// `URLProtocol` on the provider's own session; nothing reaches the network.
@MainActor
@Suite("Open Library fill provider", .serialized)
struct OpenLibraryFillProviderTests {
    private let isbn = ExternalIdentifier.normalized(.isbn13, "9787536692930")!

    @Test("only a copy with an ISBN is looked up")
    func needsISBN() throws {
        let (provider, _) = try makeProvider()
        #expect(provider.canLookUp(query(identifiers: [isbn])))
        #expect(!provider.canLookUp(query(identifiers: [])))
        #expect(!provider.canLookUp(query(identifiers: [isbn], missing: [.language])))
    }

    @Test("the edition the ISBN names gives its own cover; an English description is not given to a Chinese book")
    func chineseEdition() async throws {
        let (provider, directory) = try makeProvider()
        defer { try? FileManager.default.removeItem(at: directory) }
        OpenLibraryStub.install([
            "/search.json": .json(search(isbns: ["9787536692930", "7536692935"], cover: 10246665,
                                         subjects: ["Science fiction", "china", "Fiction, science fiction, general"])),
            "/works/OL17267881W.json": .json(#"{"description": {"type": "/type/text", "value": "The Three-Body Problem is…"}}"#),
            "/b/id/10246665-L.jpg": .image,
        ])

        let result = try await provider.lookUp(query(title: "三體", identifiers: [isbn]))

        #expect(result.values[.intro] == nil)
        #expect(result.values[.tags] == nil)
        #expect(result.values[.cover] == .text("ol-10246665.jpg"))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ol-10246665.jpg").path))
        #expect(Set(result.identifiers.map(\.scheme)) == [.openLibraryWork, .openLibraryEdition])
        #expect(result.identifiers.contains { $0.value == "OL17267881W" })
        #expect(result.sourceItem?.item == "/works/OL17267881W")
    }

    @Test("a description and subjects in the copy's own script are given")
    func sameScript() async throws {
        let (provider, directory) = try makeProvider()
        defer { try? FileManager.default.removeItem(at: directory) }
        OpenLibraryStub.install([
            "/search.json": .json(search(isbns: ["9787536692930"], cover: nil, subjects: ["Fiction", "Foxes", "subject:x"])),
            "/works/OL17267881W.json": .json(#"{"description": "A fox outwits three farmers."}"#),
        ])

        let result = try await provider.lookUp(query(title: "Fantastic Mr Fox", identifiers: [isbn]))

        #expect(result.values[.intro] == .text("A fox outwits three farmers."))
        #expect(result.values[.tags] == .texts(["Fiction", "Foxes"]))
        #expect(result.values[.cover] == nil, "the edition has no cover")
    }

    @Test("a record whose edition does not carry the copy's ISBN is not the copy's")
    func isbnMismatch() async throws {
        let (provider, directory) = try makeProvider()
        defer { try? FileManager.default.removeItem(at: directory) }
        OpenLibraryStub.install(["/search.json": .json(search(isbns: ["9780140328721"], cover: 1, subjects: []))])

        let result = try await provider.lookUp(query(title: "三體", identifiers: [isbn]))

        #expect(result.values.isEmpty && result.identifiers.isEmpty)
        #expect(OpenLibraryStub.paths == ["/search.json"])
    }

    @Test("no record is an empty answer")
    func notFound() async throws {
        let (provider, directory) = try makeProvider()
        defer { try? FileManager.default.removeItem(at: directory) }
        OpenLibraryStub.install(["/search.json": .json(#"{"numFound": 0, "docs": []}"#)])

        #expect(try await provider.lookUp(query(identifiers: [isbn])).values.isEmpty)
    }

    @Test("a rate-limited or failing server is a failure; a missing cover is not")
    func failures() async throws {
        let (provider, directory) = try makeProvider()
        defer { try? FileManager.default.removeItem(at: directory) }
        OpenLibraryStub.install(["/search.json": .status(429)])
        await #expect(throws: OpenLibraryFillProvider.LookupError.self) { try await provider.lookUp(query(identifiers: [isbn])) }

        OpenLibraryStub.install([
            "/search.json": .json(search(isbns: ["9787536692930"], cover: 5, subjects: [])),
            "/b/id/5-L.jpg": .status(404),
        ])
        let result = try await provider.lookUp(query(identifiers: [isbn], missing: [.cover]))
        #expect(result.values.isEmpty)
        #expect(!result.identifiers.isEmpty, "still the copy's record")
    }

    @Test("requests name the app, never a person, and ask for every ISBN at once")
    func requestShape() async throws {
        let (provider, directory) = try makeProvider()
        defer { try? FileManager.default.removeItem(at: directory) }
        OpenLibraryStub.install(["/search.json": .json(#"{"docs": []}"#)])
        let second = ExternalIdentifier.normalized(.isbn13, "9780140328721")!

        _ = try await provider.lookUp(query(identifiers: [isbn, second]))

        let request = try #require(OpenLibraryStub.requests.first)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Yuedu/") == true)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("@") == false)
        let q = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
        #expect(q == "isbn:(9780140328721 OR 9787536692930)")
    }

    @Test("requests to one host are spaced by the pacer's interval")
    func pacing() async {
        let pacer = RequestPacer(interval: 0.3)
        let start = Date()
        await pacer.wait(for: "openlibrary.org")
        await pacer.wait(for: "covers.openlibrary.org")
        #expect(Date().timeIntervalSince(start) < 0.25, "another host is not held back")
        await pacer.wait(for: "openlibrary.org")
        #expect(Date().timeIntervalSince(start) >= 0.29)
    }

    @Test("a script is told apart")
    func scripts() {
        #expect(WritingScript(of: "三體") == .cjk)
        #expect(WritingScript(of: "ノルウェイの森") == .cjk)
        #expect(WritingScript(of: "Fantastic Mr Fox") == .latin)
        #expect(WritingScript(of: "1984") == .other)
    }

    // MARK: - Helpers

    private func makeProvider() throws -> (OpenLibraryFillProvider, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenLibraryStub.self]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OpenLibrary-\(UUID().uuidString)", isDirectory: true)
        let provider = OpenLibraryFillProvider(fetcher: WebFetcher(session: URLSession(configuration: configuration)),
                                               pacer: RequestPacer(interval: 0), coverDirectory: directory)
        return (provider, directory)
    }

    private func query(title: String = "三體", identifiers: [ExternalIdentifier],
                       missing: Set<MetadataField> = [.cover, .intro, .tags]) -> MetadataFillQuery {
        MetadataFillQuery(copyID: UUID(), title: title, authors: ["劉慈欣"], identifiers: identifiers,
                          copySource: .localLibrary, missing: missing)
    }

    private func search(isbns: [String], cover: Int?, subjects: [String]) -> String {
        let coverField = cover.map { #", "cover_i": \#($0)"# } ?? ""
        let isbnList = isbns.map { "\"\($0)\"" }.joined(separator: ", ")
        let subjectList = subjects.map { "\"\($0)\"" }.joined(separator: ", ")
        return #"{"numFound": 1, "docs": [{"key": "/works/OL17267881W", "subject": [\#(subjectList)], "editions": {"docs": [{"key": "/books/OL25840916M"\#(coverField), "isbn": [\#(isbnList)]}]}}]}"#
    }
}

/// Answers by URL path from a table; records every request.
private final class OpenLibraryStub: URLProtocol, @unchecked Sendable {
    enum Reply {
        case json(String)
        case image
        case status(Int)
    }

    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static var paths: [String] { lock.withLock { requests.compactMap { $0.url?.path } } }

    static func install(_ table: [String: Reply]) {
        lock.withLock {
            replies = table
            requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply: Reply? = Self.lock.withLock {
            Self.requests.append(request)
            return Self.replies[request.url?.path ?? ""]
        }
        let status: Int
        let body: Data
        switch reply {
        case .json(let text): (status, body) = (200, Data(text.utf8))
        case .image:
            let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 6)).image { context in
                UIColor.red.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 6))
            }
            (status, body) = (200, image.pngData() ?? Data())
        case .status(let code): (status, body) = (code, Data())
        case nil: (status, body) = (404, Data())
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
