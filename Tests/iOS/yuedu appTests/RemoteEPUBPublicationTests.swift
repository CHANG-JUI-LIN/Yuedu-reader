@testable import YueduCoreText
import CryptoKit
import Foundation
import Network
import ReadiumShared
import ReadiumZIPFoundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Remote EPUB publication", .serialized)
@MainActor
struct RemoteEPUBPublicationTests {
    @Test("real URLSession HTTP ranges render the first page before transferring the complete EPUB")
    func loopbackHTTPFirstPageUsesPartialTransfer() async throws {
        let fixture = try await makeFixture(paddingBytes: 24 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let bytes = try Data(contentsOf: fixture.url)
        let server = try EPUBLoopbackHTTPServer(data: bytes)
        let url = try await server.start()
        defer { server.stop() }
        let transport = RemoteLibraryHTTPClient(baseURL: url)
        let begin = SourcePerfTrace.now
        let probe = try await RemoteLibraryService.probe(url, epub: true, transport: transport)
        #expect(probe.supportsRanges)
        let length = try #require(probe.length)
        let version = try #require(probe.version)
        let bookID = UUID()
        let cache = RemoteLibraryCache(root: fixture.url.deletingLastPathComponent().appendingPathComponent("ranges"))
        let directory = try cache.directory(bookID: bookID, version: version)
        let client = RemoteLibraryResourceClient(transport: transport, url: HTTPURL(url: url)!,
            length: length, entityTag: probe.entityTag, lastModified: probe.lastModified, directory: directory)
        let session = try await PublicationSession.open(remoteURL: url, bookID: bookID,
            httpClient: client, version: version, cacheDirectory: directory)
        let builder = EPUBAttributedStringBuilder(session: session, renderSize: CGSize(width: 320, height: 480))
        let chapter = try await builder.buildChapter(at: 0, settings: EPUBTestFixtures.renderSettings(),
            themeTextColor: .black, themeBackgroundColor: .white)
        let layout = await CoreTextPaginator().paginate(spineIndex: 0, attrStr: chapter.attributedString,
            renderSize: CGSize(width: 320, height: 480), fontSize: 17, contentInsets: .zero, writingMode: .horizontal)
        #expect(!layout.pageRanges.isEmpty)
        #expect(chapter.attributedString.string.contains("遠端閱讀正文"))
        let snapshot = server.snapshot
        #expect(snapshot.getCount > 0)
        #expect(snapshot.getCount == snapshot.rangeCount)
        #expect(snapshot.bytesSent > 0 && snapshot.bytesSent < bytes.count)
        // Only small entries are needed by this fixture. Catch excessive ZIP
        // read-ahead even when dictionary entry order happens to hide it.
        #expect(snapshot.bytesSent < 1024 * 1024)
        let detail = "fileBytes=\(bytes.count) transferredBytes=\(snapshot.bytesSent) GET=\(snapshot.getCount) Range=\(snapshot.rangeCount)"
        SourcePerfTrace.record("remote.epub.httpFirstPage", detail, since: begin, thresholdMs: 0)
        print("[RemoteEPUBHTTPTest] \(detail) elapsedMs=\(Int((SourcePerfTrace.now - begin) * 1000))")
    }

    @Test("large remote EPUB renders its first page without receiving the entire ZIP")
    func rangeOpeningAndCoreTextRendering() async throws {
        let fixture = try await makeFixture(paddingBytes: 24 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        let client = EPUBRangeHTTPClient(data: try Data(contentsOf: fixture.url))
        let session = try await PublicationSession.open(
            remoteURL: URL(string: "https://library.example/books/中文.epub")!,
            bookID: UUID(), httpClient: client, version: "v1"
        )
        #expect(session.bookTitle == "Remote A")
        #expect(session.language == "zh-Hant")
        #expect(session.pageProgressionDirection == .rtl)
        #expect(session.tocEntries.first?.title == "第一章")
        let chapter = try await session.chapterHTML(at: 0)
        #expect(chapter.contains("遠端閱讀正文"))

        let builder = EPUBAttributedStringBuilder(session: session, renderSize: CGSize(width: 320, height: 480))
        let output = try await builder.buildChapter(
            at: 0, settings: EPUBTestFixtures.renderSettings(),
            themeTextColor: .black, themeBackgroundColor: .white
        )
        #expect(output.attributedString.string.contains("遠端閱讀正文"))
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: output.attributedString,
            renderSize: CGSize(width: 320, height: 480), fontSize: 17,
            contentInsets: .zero, writingMode: .horizontal
        )
        #expect(!layout.pageRanges.isEmpty)
        #expect(client.getRequests.allSatisfy { $0.hasHeader("Range") })
        #expect(client.uniqueBytesServed < client.data.count)
        #expect(client.bytesServed < 1024 * 1024)
        print("[RemoteEPUBTest] total=\(client.data.count) uniqueBytes=\(client.uniqueBytesServed) transferred=\(client.bytesServed) rangeRequests=\(client.getRequests.count)")
    }

    @Test("remote package reads percent-encoded chapters, images, CSS and obfuscated fonts")
    func remotePackageResources() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        #expect(try Data(contentsOf: fixture.url).count < 65_633)
        let session = try await PublicationSession.open(
            remoteURL: URL(string: "https://library.example/book.epub")!,
            bookID: UUID(), httpClient: EPUBRangeHTTPClient(data: try Data(contentsOf: fixture.url))
        )
        #expect(session.chapterIndex(for: "OPS/中文 章.xhtml") == 0)
        let chapter = try await session.chapterHTML(at: 0)
        #expect(chapter.contains("遠端閱讀正文"))
        let css = try await session.response(for: session.resourceURL(for: "OPS/style.css"))
        #expect(String(data: css.data, encoding: .utf8)?.contains("line-height") == true)
        let image = try await session.response(for: session.resourceURL(for: "OPS/封面.png"))
        #expect(image.data == fixture.image)
        let font = try await session.response(for: session.resourceURL(for: "OPS/fonts/test.otf"))
        #expect(font.data == fixture.font)
        #expect(session.pronunciationLexicons.first?.lexemes.first?.grapheme == "Readium")
        #expect(session.mediaOverlaysByChapter[0]?.fragments.first?.clipEnd == 2)
        #expect(session.opfManifestItemsByID["chapter"]?.href.contains("中文") == true
            || session.opfManifestItemsByID["chapter"]?.href.contains("%E4") == true)
    }

    @Test("stored and deflated entries larger than read-ahead preserve concurrent full and partial reads", arguments: [false, true])
    func largeEntryReads(compressed: Bool) async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        // Incompressible deterministic bytes ensure deflate needs multiple
        // remote chunks, rather than testing only a tiny compressed stream.
        var state: UInt64 = 17
        let payload = Data((0..<(256 * 1024)).map { _ -> UInt8 in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return UInt8(truncatingIfNeeded: state >> 32)
        })
        let archive = try await ReadiumZIPFoundation.Archive(url: fixture.url, accessMode: .update)
        try await archive.addEntry(with: "OPS/大型 資源.bin", type: .file, uncompressedSize: Int64(payload.count),
            compressionMethod: compressed ? .deflate : .none) { position, count in
                payload.subdata(in: Int(position)..<min(Int(position) + count, payload.count))
            }
        let client = EPUBRangeHTTPClient(data: try Data(contentsOf: fixture.url))
        let source = try await DefaultResourceFactory(httpClient: client)
            .make(url: HTTPURL(string: "https://library.example/book.epub")!).get()
        let asset = try await RemoteEPUBArchiveOpener().sniffOpen(resource: source).get()
        let resource = try #require(asset.container[RelativeURL(path: "OPS/大型 資源.bin")!])
        #expect(try await resource.properties().get().archive?.isEntryCompressed == compressed)
        async let complete = resource.read().get()
        async let partial = resource.read(range: 90_000..<180_000).get()
        let (whole, slice) = try await (complete, partial)
        #expect(whole == payload)
        #expect(slice == payload.subdata(in: 90_000..<180_000))
        #expect(client.getRequests.allSatisfy { $0.hasHeader("Range") })
    }

    @Test("a changed remote version cannot reuse old spine metadata")
    func remoteVersionInvalidatesSpineCache() async throws {
        let first = try await makeFixture(title: "Remote A")
        let second = try await makeFixture(title: "Remote B")
        defer {
            try? FileManager.default.removeItem(at: first.url.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.url.deletingLastPathComponent())
        }
        let bookID = UUID()
        let url = URL(string: "https://library.example/book.epub")!
        let a = try await PublicationSession.open(remoteURL: url, bookID: bookID,
            httpClient: EPUBRangeHTTPClient(data: try Data(contentsOf: first.url)), version: "etag-a")
        let b = try await PublicationSession.open(remoteURL: url, bookID: bookID,
            httpClient: EPUBRangeHTTPClient(data: try Data(contentsOf: second.url)), version: "etag-b")
        #expect(a.bookTitle == "Remote A")
        #expect(b.bookTitle == "Remote B")
    }

    @Test("authentication and range failures propagate without an unbounded GET")
    func openingFailureDoesNotDownloadWholeBook() async throws {
        for failure in [HTTPError.security(nil), .rangeNotSupported, .timeout(nil)] {
            let client = EPUBRangeHTTPClient(data: Data(), failure: failure)
            do {
                _ = try await PublicationSession.open(
                    remoteURL: URL(string: "https://library.example/book.epub")!,
                    bookID: UUID(), httpClient: client
                )
                Issue.record("Expected opening to fail")
            } catch {
                #expect(client.getRequests.allSatisfy { $0.hasHeader("Range") })
                #expect(client.bytesServed == 0)
            }
        }
    }

    @Test("the resource registry releases a closed publication and its HTTP client")
    func registryDoesNotRetainPublication() async throws {
        let fixture = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.url.deletingLastPathComponent()) }
        var session: PublicationSession? = try await PublicationSession.open(sourceURL: fixture.url)
        let id = try #require(session?.id)
        weak var weakSession = session
        #expect(PublicationSessionRegistry.shared.session(for: id) === session)
        session = nil
        #expect(weakSession == nil)
        #expect(PublicationSessionRegistry.shared.session(for: id) == nil)
    }

    private func makeFixture(title: String = "Remote A", paddingBytes: Int = 0) async throws -> (url: URL, image: Data, font: Data) {
        let identifier = "urn:uuid:remote-epub-test"
        let font = Data((0..<2048).map { UInt8($0 % 251) })
        let key = Array(Insecure.SHA1.hash(data: Data(identifier.utf8)))
        var obfuscatedFont = font
        for index in 0..<1040 { obfuscatedFont[index] ^= key[index % key.count] }
        let image = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aY4kAAAAASUVORK5CYII=")!
        var entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
            <?xml version="1.0"?>
            <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
            """.utf8),
            "OPS/package.opf": Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <package version="3.0" unique-identifier="bookid" xmlns="http://www.idpf.org/2007/opf">
              <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                <dc:identifier id="bookid">\(identifier)</dc:identifier><dc:title>\(title)</dc:title><dc:language>zh-Hant</dc:language><dc:creator>Remote Author</dc:creator>
              </metadata>
              <manifest>
                <item id="nav" href="nav.xhtml" properties="nav" media-type="application/xhtml+xml"/>
                <item id="chapter" href="%E4%B8%AD%E6%96%87%20%E7%AB%A0.xhtml" media-type="application/xhtml+xml" media-overlay="overlay"/>
                <item id="style" href="style.css" media-type="text/css"/>
                <item id="image" href="%E5%B0%81%E9%9D%A2.png" media-type="image/png"/>
                <item id="font" href="fonts/test.otf" media-type="application/vnd.ms-opentype"/>
                <item id="lexicon" href="lexicon.pls" media-type="application/pls+xml"/>
                <item id="overlay" href="chapter.smil" media-type="application/smil+xml"/>
              </manifest>
              <spine page-progression-direction="rtl"><itemref idref="chapter"/></spine>
            </package>
            """.utf8),
            "OPS/nav.xhtml": Data(EPUBTestFixtures.xhtml(title: "Contents", body: """
            <nav epub:type="toc"><ol><li><a href="%E4%B8%AD%E6%96%87%20%E7%AB%A0.xhtml">第一章</a></li></ol></nav>
            """).utf8),
            "OPS/中文 章.xhtml": Data(EPUBTestFixtures.xhtml(title: "第一章", body: "<p>遠端閱讀正文，可以立即閱讀。</p>", head: "<link rel=\"stylesheet\" href=\"style.css\"/>").utf8),
            "OPS/style.css": Data("p { line-height: 1.5; }".utf8),
            "OPS/封面.png": image,
            "OPS/fonts/test.otf": obfuscatedFont,
            "OPS/lexicon.pls": Data("""
            <?xml version="1.0"?><lexicon version="1.0" alphabet="ipa" xml:lang="en" xmlns="http://www.w3.org/2005/01/pronunciation-lexicon"><lexeme><grapheme>Readium</grapheme><phoneme>ˈriːdiəm</phoneme></lexeme></lexicon>
            """.utf8),
            "OPS/chapter.smil": Data("""
            <?xml version="1.0"?><smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body><seq><par id="p1"><text src="%E4%B8%AD%E6%96%87%20%E7%AB%A0.xhtml#p1"/><audio src="audio.mp3" clipBegin="0s" clipEnd="2s"/></par></seq></body></smil>
            """.utf8),
            "META-INF/encryption.xml": Data("""
            <?xml version="1.0"?>
            <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
              <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><enc:CipherData><enc:CipherReference URI="OPS/fonts/test.otf"/></enc:CipherData></enc:EncryptedData>
            </encryption>
            """.utf8)
        ]
        if paddingBytes > 0 { entries["padding.bin"] = Data(repeating: 0x6B, count: paddingBytes) }
        return (try await EPUBTestFixtures.makeArchive(entries: entries), image, font)
    }
}

@Suite("Remote EPUB range cache", .serialized)
struct RemoteLibraryResourceClientTests {
    @Test("a failed read reports its original HTTP error once and cancellation stays quiet")
    func failureCallbackPreservesError() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = HTTPURL(string: "https://library.example/book.epub")!
        let recorder = RemoteRangeFailureRecorder()
        let timedOut = RemoteLibraryResourceClient(
            transport: EPUBRangeHTTPClient(data: Data(), failure: .timeout(URLError(.timedOut))),
            url: url, length: 64, entityTag: nil, lastModified: nil, directory: directory,
            onFailure: { recorder.append($0) })
        let request = HTTPRequest(url: url, headers: ["Range": "bytes=0-15"])
        let result = await timedOut.fetch(request)
        if case .failure(.timeout(let error)) = result {
            #expect((error as? URLError)?.code == .timedOut)
        } else { Issue.record("The original timeout error must be returned") }
        #expect(recorder.errors.count == 1)
        if case .timeout(let error)? = recorder.errors.first {
            #expect((error as? URLError)?.code == .timedOut)
        } else { Issue.record("The original timeout error must be reported") }
        let cancelled = RemoteLibraryResourceClient(
            transport: EPUBRangeHTTPClient(data: Data(), failure: .cancelled),
            url: url, length: 64, entityTag: nil, lastModified: nil, directory: directory,
            onFailure: { recorder.append($0) })
        let cancelledResult = await cancelled.fetch(request)
        if case .failure(.cancelled) = cancelledResult {} else { Issue.record("Cancellation must propagate") }
        #expect(recorder.errors.count == 1)
    }

    @Test("cached range remains readable offline and preserves HTTP range metadata")
    func cachedRangeWorksOffline() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = HTTPURL(string: "https://library.example/book.epub")!
        let bytes = Data((0..<64).map(UInt8.init))
        let request = HTTPRequest(url: url, headers: ["Range": "bytes=16-31"])
        let online = RemoteLibraryResourceClient(transport: EPUBRangeHTTPClient(data: bytes),
            url: url, length: 64, entityTag: "\"fixture\"", lastModified: nil, directory: directory)
        let first = try await online.fetch(request).get()
        let offline = RemoteLibraryResourceClient(transport: EPUBRangeHTTPClient(data: bytes, failure: .offline(nil)),
            url: url, length: 64, entityTag: "\"fixture\"", lastModified: nil, directory: directory)
        let cached = try await offline.fetch(request).get()
        #expect(first.body == bytes.subdata(in: 16..<32))
        #expect(cached.body == first.body)
        #expect(cached.valueForHeader("Content-Range") == "bytes 16-31/64")
        #expect(cached.valueForHeader("ETag") == "\"fixture\"")
    }

    @Test("incorrect ranges, truncated bytes and changed versions never enter the cache")
    func invalidRangeResponsesAreRejected() async throws {
        let url = HTTPURL(string: "https://library.example/book.epub")!
        let base = ["Content-Length": "16", "Content-Range": "bytes 16-31/64", "ETag": "\"fixture\""]
        let responses: [([String: String], Data)] = [
            (base.merging(["Content-Range": "bytes 0-15/64"]) { _, new in new }, Data(repeating: 0, count: 16)),
            (base.merging(["Content-Range": "bytes 16-31/65"]) { _, new in new }, Data(repeating: 0, count: 16)),
            (base, Data(repeating: 0, count: 8)),
            (base.merging(["ETag": "\"changed\""]) { _, new in new }, Data(repeating: 0, count: 16))
        ]
        for (headers, body) in responses {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let client = RemoteLibraryResourceClient(transport: FixedRangeResponseClient(headers: headers, body: body),
                url: url, length: 64, entityTag: "\"fixture\"", lastModified: nil, directory: directory)
            let result = await client.fetch(HTTPRequest(url: url, headers: ["Range": "bytes=16-31"]))
            if case .success = result { Issue.record("Invalid bytes were exposed to the EPUB parser") }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @Test("weak ETags still verify Last-Modified before returning a range")
    func weakETagAlsoChecksLastModified() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = HTTPURL(string: "https://library.example/book.epub")!
        let transport = FixedRangeResponseClient(headers: ["Content-Length": "16", "Content-Range": "bytes 16-31/64",
            "ETag": "W/\"fixture\"", "Last-Modified": "Fri, 11 Sep 2026 00:00:00 GMT"], body: Data(repeating: 0, count: 16))
        let client = RemoteLibraryResourceClient(transport: transport, url: url, length: 64,
            entityTag: "W/\"fixture\"", lastModified: "Thu, 10 Sep 2026 00:00:00 GMT", directory: directory)
        let result = await client.fetch(HTTPRequest(url: url, headers: ["Range": "bytes=16-31"]))
        if case .success = result { Issue.record("Changed content must be rejected") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("clearing automatic cache leaves active books protected")
    func clearKeepsActiveBooks() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = RemoteLibraryCache(root: directory)
        let activeID = UUID()
        let active = try cache.directory(bookID: activeID, version: "v1")
        let inactive = try cache.directory(bookID: UUID(), version: "v1")
        cache.retain(activeID)
        try cache.clearInactive()
        #expect(FileManager.default.fileExists(atPath: active.path))
        #expect(!FileManager.default.fileExists(atPath: inactive.path))
        cache.release(activeID)
        try cache.clearInactive()
        #expect(!FileManager.default.fileExists(atPath: active.path))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RemoteRangeFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [HTTPError] = []
    var errors: [HTTPError] { lock.withLock { values } }
    func append(_ error: HTTPError) { lock.withLock { values.append(error) } }
}

private final class FixedRangeResponseClient: HTTPClient {
    let headers: [String: String]
    let body: Data
    init(headers: [String: String], body: Data) { self.headers = headers; self.body = body }

    func stream(request convertible: any HTTPRequestConvertible,
                consume: @escaping (Data, Double?) -> HTTPResult<Void>) async -> HTTPResult<HTTPResponse> {
        switch convertible.httpRequest() {
        case .failure(let error): return .failure(error)
        case .success(let request):
            if case .failure(let error) = consume(body, 1) { return .failure(error) }
            return .success(HTTPResponse(request: request, url: request.url, status: .partialContent,
                headers: headers, mediaType: .epub, body: nil))
        }
    }
}

private final class EPUBRangeHTTPClient: HTTPClient {
    let data: Data
    private let failure: HTTPError?
    private let lock = NSLock()
    private var requests: [HTTPRequest] = []
    private var ranges: [Range<Int>] = []

    init(data: Data, failure: HTTPError? = nil) {
        self.data = data
        self.failure = failure
    }

    var getRequests: [HTTPRequest] { lock.withLock { requests.filter { $0.method == .get } } }
    var bytesServed: Int { lock.withLock { ranges.reduce(0) { $0 + $1.count } } }
    var uniqueBytesServed: Int {
        lock.withLock {
            var upper = 0
            var count = 0
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                count += max(0, range.upperBound - max(upper, range.lowerBound))
                upper = max(upper, range.upperBound)
            }
            return count
        }
    }

    func stream(
        request convertible: any HTTPRequestConvertible,
        consume: @escaping (Data, Double?) -> HTTPResult<Void>
    ) async -> HTTPResult<HTTPResponse> {
        let request: HTTPRequest
        switch convertible.httpRequest() {
        case .success(let value): request = value
        case .failure(let error): return .failure(error)
        }
        lock.withLock { requests.append(request) }
        if let failure { return .failure(failure) }
        var headers = ["Content-Length": String(data.count), "Accept-Ranges": "bytes", "ETag": "\"fixture\""]
        var status = HTTPStatus.ok
        if request.method == .get {
            guard let header = request.headers.first(where: { $0.key.lowercased() == "range" })?.value,
                  header.hasPrefix("bytes=") else {
                return .failure(.rangeNotSupported)
            }
            let bounds = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 2, let lower = Int(bounds[0]), let requestedUpper = Int(bounds[1]),
                  lower >= 0, lower < data.count else { return .failure(.malformedRequest(url: request.url.string)) }
            let upper = min(data.count, requestedUpper + 1)
            let range = lower..<upper
            lock.withLock { ranges.append(range) }
            headers["Content-Length"] = String(range.count)
            headers["Content-Range"] = "bytes \(lower)-\(upper - 1)/\(data.count)"
            status = .partialContent
            if case .failure(let error) = consume(data.subdata(in: range), 1) { return .failure(error) }
        }
        return .success(HTTPResponse(request: request, url: request.url, status: status,
            headers: headers, mediaType: .epub, body: nil))
    }
}

/// A loopback-only HTTP fixture with a real URLSession transport. Readiness is
/// signalled by Network.framework, never by sleeping and hoping the port is open.
private final class EPUBLoopbackHTTPServer: @unchecked Sendable {
    struct Snapshot { let getCount: Int; let rangeCount: Int; let bytesSent: Int }
    private let data: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "RemoteEPUBTests.HTTPServer")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var connections: [NWConnection] = []
    private var getCount = 0
    private var rangeCount = 0
    private var bytesSent = 0

    init(data: Data) throws {
        self.data = data
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    var snapshot: Snapshot {
        lock.withLock { Snapshot(getCount: getCount, rangeCount: rangeCount, bytesSent: bytesSent) }
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    guard let port = self.listener.port,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/book.epub") else {
                        self.finishStart(.failure(URLError(.cannotConnectToHost)))
                        return
                    }
                    self.finishStart(.success(url))
                case .failed(let error): self.finishStart(.failure(error))
                case .cancelled: self.finishStart(.failure(CancellationError()))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.lock.withLock { self.connections.append(connection) }
                connection.start(queue: self.queue)
                self.receiveHeaders(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        let open = lock.withLock { let value = connections; connections.removeAll(); return value }
        open.forEach { $0.cancel() }
        finishStart(.failure(CancellationError()))
    }

    private func finishStart(_ result: Result<URL, Error>) {
        let callback = lock.withLock { let value = continuation; continuation = nil; return value }
        callback?.resume(with: result)
    }

    private func receiveHeaders(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let chunk { request.append(chunk) }
            guard error == nil, request.count < 64 * 1024 else { connection.cancel(); return }
            if let boundary = request.range(of: Data("\r\n\r\n".utf8)),
               let text = String(data: request[..<boundary.lowerBound], encoding: .utf8) {
                self.respond(connection, headers: text)
            } else if !complete {
                self.receiveHeaders(connection, accumulated: request)
            } else { connection.cancel() }
        }
    }

    private func respond(_ connection: NWConnection, headers rawHeaders: String) {
        let lines = rawHeaders.components(separatedBy: "\r\n")
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        var body = Data()
        var responseHeaders = ["Content-Type": "application/epub+zip", "Accept-Ranges": "bytes", "ETag": "\"loopback-fixture\"", "Connection": "close"]
        var status = "200 OK"
        if method == "GET" {
            var range = 0..<data.count
            if let value = headers["range"], value.hasPrefix("bytes=") {
                let bounds = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count == 2, let lower = Int(bounds[0]), let inclusiveUpper = Int(bounds[1]),
                      lower >= 0, lower < data.count, inclusiveUpper >= lower else { connection.cancel(); return }
                range = lower..<min(data.count, inclusiveUpper + 1)
                status = "206 Partial Content"
                responseHeaders["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(data.count)"
            }
            body = data.subdata(in: range)
            lock.withLock {
                getCount += 1
                if headers["range"] != nil { rangeCount += 1 }
                bytesSent += body.count
            }
        }
        responseHeaders["Content-Length"] = String(method == "HEAD" ? data.count : body.count)
        let head = "HTTP/1.1 \(status)\r\n" + responseHeaders.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") + "\r\n\r\n"
        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
