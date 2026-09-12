@testable import YueduCoreText
import Foundation
import ReadiumShared
import Testing
import UIKit
@testable import yuedu_app

@Suite("Calibre DOM CFI precision", .serialized)
struct CalibreCFIMapperTests {
    @Test("Calibre spine prefix and UTF-16 DOM offsets survive CJK, emoji and collapsed whitespace")
    func textOffsetUsesServerDOM() throws {
        let source = "第一段😀中文  與繁體字元精確位置測試，接著繼續閱讀正文。"
        let rendered = source.replacingOccurrences(of: "  ", with: " ")
        let position = (rendered as NSString).range(of: "與").location
        let match = try CalibreCFIMapper.match(document: calibreDOM(source), spineIndex: 1,
                                              renderedText: rendered, charOffset: position)
        let expected = (source as NSString).range(of: "與").location
        #expect(match.cfi == "epubcfi(/4/2/4/2/1:\(expected))")
        #expect((match.text as NSString).substring(from: match.textOffset).hasPrefix("與繁體"))
    }

    @Test("comment tails merge into the same odd CFI step after an inline element")
    func inlineAndCommentTail() throws {
        let paragraph: [String: Any] = ["n": "p", "x": "起始文字與內嵌",
            "c": [["n": "em", "x": "強調", "l": " 丙"],
                  ["s": "c", "x": "ignored comment", "l": "丁尾端正文是目前閱讀位置。"]]]
        let text = "起始文字與內嵌強調 丙丁尾端正文是目前閱讀位置。"
        let result = try CalibreCFIMapper.match(document: calibreDOM(paragraph: paragraph), spineIndex: 0,
            renderedText: text, charOffset: (text as NSString).range(of: "丁").location)
        #expect(result.cfi == "epubcfi(/2/2/4/2/3:2)")
        #expect((result.text as NSString).substring(from: result.textOffset) == "丁尾端正文是目前閱讀位置。")
    }

    @Test("actual CoreText vertical preparation maps back to original DOM punctuation offsets")
    @MainActor
    func preparedVerticalTextKeepsDOMPrecision() throws {
        let source = "　　(甲)[乙]{丙}<丁>《戊》「己」，目前位置(庚)；繼續正文！"
        let raw = NSAttributedString(string: source, attributes: [.font: UIFont.systemFont(ofSize: 17)])
        let prepared = CoreTextPaginator.preparedAttributedString(raw, writingMode: .verticalRTL,
            fontSize: 17, maxInlineAnnotationAdvance: nil)
        #expect(prepared.string != source)
        let position = (prepared.string as NSString).range(of: "庚").location
        let result = try CalibreCFIMapper.match(document: calibreDOM(source), spineIndex: 2,
            renderedText: prepared.string, charOffset: position, isVertical: true)
        let expected = (source as NSString).range(of: "庚").location
        #expect(result.cfi == "epubcfi(/6/2/4/2/1:\(expected))")
        #expect((result.text as NSString).substring(from: result.textOffset).hasPrefix("庚)"))
    }

    @Test("a text position after a rasterized table uses its actual DOM node, not the renderer offset")
    func attachmentDoesNotShiftDOMOffset() throws {
        let before = "表格之前的說明文字。"
        let after = "表格之後的正文從這個字元開始，繼續閱讀精確定位測試。"
        let document = try JSONSerialization.data(withJSONObject: ["version": 1, "tree": ["n": "html",
            "c": [["n": "head"], ["n": "body", "c": [["n": "p", "x": before],
                ["n": "table", "c": [["n": "tr", "c": [["n": "td", "x": "這裡是表格內文，閱讀器將整個表格呈現為圖片。"]]]]],
                ["n": "p", "x": after]]]]]])
        let rendered = before + "\n\u{FFFC}\n" + after
        let offset = (rendered as NSString).range(of: after).location
        let result = try CalibreCFIMapper.match(document: document, spineIndex: 0,
                                               renderedText: rendered, charOffset: offset)
        #expect(result.cfi == "epubcfi(/2/2/4/6/1:0)")
        #expect(result.text == after)
    }

    @Test("ambiguous, absent, image-only and malformed positions never produce a guessed CFI")
    func rejectUnverifiedLocations() throws {
        let phrase = "相同句子重複出現不能猜測現在位於哪一段。"
        #expect(throws: CalibreProgressError.self) {
            try CalibreCFIMapper.match(document: calibreDOM(phrase + phrase), spineIndex: 0,
                                      renderedText: phrase, charOffset: 2)
        }
        #expect(throws: CalibreProgressError.self) {
            try CalibreCFIMapper.match(document: calibreDOM(phrase), spineIndex: 0,
                                      renderedText: "完全不同的內容，禁止捏造遠端閱讀位置。", charOffset: 2)
        }
        #expect(throws: CalibreProgressError.self) {
            try CalibreCFIMapper.match(document: calibreDOM(phrase), spineIndex: 0,
                                      renderedText: "\u{FFFC}", charOffset: 0)
        }
        #expect(throws: CalibreProgressError.self) {
            try CalibreCFIMapper.match(document: Data("{}".utf8), spineIndex: 0,
                                      renderedText: phrase, charOffset: 2)
        }
    }
}

@Suite("Calibre progress use cases", .serialized)
@MainActor
struct CalibreProgressServiceTests {
    @Test("legacy connections remain opted out and saving sends no request")
    func optInIsRequired() async throws {
        let connection = try JSONDecoder().decode(OPDSCatalog.self,
            from: Data(#"{"id":"old","name":"Old","url":"https://example.org/opds","kind":"calibre"}"#.utf8))
        #expect(!connection.syncProgress)
        let context = try Context(enabled: false)
        defer { context.cleanup() }
        await context.save(offset: 3)
        #expect(context.transport.requests.isEmpty)
        #expect(context.service.state(for: context.book.id) == .idle)
    }

    @Test("image-only cover creates no failed pending upload and the next text page synchronizes")
    func coverDoesNotBlockLaterText() async throws {
        let context = try Context()
        defer { context.cleanup() }
        await context.service.save(book: context.book, chapterHref: "cover.xhtml",
            position: CoreTextReadingPosition(spineIndex: 0, charOffset: 0), renderedText: "\u{FFFC}\n")
        await context.service.save(book: context.book, chapterHref: "cover.xhtml",
            position: CoreTextReadingPosition(spineIndex: 0, charOffset: 0), renderedText: "  \n")
        #expect(context.service.state(for: context.book.id) == .idle)
        #expect(context.transport.requests.isEmpty)
        await context.save(offset: 3)
        #expect(context.service.state(for: context.book.id) == .synced)
        #expect(context.transport.webPosts.count == 1)
        #expect(context.transport.annotationPosts.isEmpty)
    }

    @Test("vertical context and source offsets survive a persisted manual retry")
    func verticalSnapshotRetry() async throws {
        let context = try Context()
        defer { context.cleanup() }
        let source = "　　(甲)[乙]{丙}<丁>《戊》「己」，目前位置(庚)；繼續正文！"
        context.transport.document = try calibreDOM(source)
        let prepared = CoreTextPaginator.preparedAttributedString(
            NSAttributedString(string: source, attributes: [.font: UIFont.systemFont(ofSize: 17)]),
            writingMode: .verticalRTL, fontSize: 17, maxInlineAnnotationAdvance: nil)
        let offset = (prepared.string as NSString).range(of: "庚").location
        context.transport.postError = URLError(.notConnectedToInternet)
        await context.service.save(book: context.book, chapterHref: "OPS/ch1.xhtml",
            position: CoreTextReadingPosition(spineIndex: 0, charOffset: offset),
            renderedText: prepared.string, isVertical: true)
        let restarted = CalibreProgressService(connections: context.connections,
            storageDirectory: context.root.appendingPathComponent("progress"), defaults: context.defaults,
            transportFactory: { _ in context.transport })
        context.transport.postError = nil
        await restarted.retry(bookID: context.book.id)
        #expect(restarted.state(for: context.book.id) == .synced)
        let data = try #require(context.transport.webPosts.last?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["cfi"] as? String == "epubcfi(/4/2/4/2/1:\((source as NSString).range(of: "庚").location))")
    }

    @Test("a newer local snapshot arriving during a read prevents posting the obsolete location")
    func coalescesBeforeExternalWrite() async throws {
        let context = try Context()
        defer { context.cleanup() }
        context.transport.onManifest = { await context.save(offset: 11) }
        await context.save(offset: 3)
        #expect(context.service.state(for: context.book.id) == .synced)
        #expect(context.transport.webPosts.count == 1)
        let data = try #require(context.transport.webPosts.first?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["cfi"] as? String == "epubcfi(/4/2/4/2/1:11)")
    }

    @Test("server prepared spine and real DOM determine the uploaded CFI; repeated save is deduplicated")
    func uploadsVerifiedCFI() async throws {
        let context = try Context()
        defer { context.cleanup() }
        await context.save(offset: 5)
        #expect(context.service.state(for: context.book.id) == .synced)
        let post = try #require(context.transport.webPosts.first)
        let postData = try #require(post.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: postData) as? [String: Any])
        #expect(post.url?.path == "/proxy/book-set-last-read-position/Library/7/EPUB")
        #expect(body["cfi"] as? String == "epubcfi(/4/2/4/2/1:5)")
        #expect(body["pos_frac"] as? Double == 0.42)
        #expect((body["device"] as? String)?.hasPrefix("Yuedu-") == true)
        #expect(context.transport.annotationPosts.isEmpty)
        #expect(context.transport.requests.contains {
            $0.url?.path == "/proxy/book-file/7/EPUB/999/123/OPS/ch1.xhtml"
                && URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "Library"
        })
        let count = context.transport.requests.count
        await context.save(offset: 5)
        #expect(context.transport.requests.count == count)
    }

    @Test("failure retains latest position across restart and requires explicit retry")
    func durableRetryDoesNotRunAutomatically() async throws {
        let context = try Context()
        defer { context.cleanup() }
        context.transport.postError = URLError(.notConnectedToInternet)
        await context.save(offset: 3)
        let count = context.transport.requests.count
        await context.save(offset: 9)
        #expect(context.transport.requests.count == count)
        let restarted = CalibreProgressService(connections: context.connections,
            storageDirectory: context.root.appendingPathComponent("progress"), defaults: context.defaults,
            transportFactory: { _ in context.transport })
        if case .failed = restarted.state(for: context.book.id) {} else { Issue.record("Pending upload was lost") }
        #expect(context.transport.requests.count == count)
        context.transport.postError = nil
        await restarted.retry(bookID: context.book.id)
        #expect(restarted.state(for: context.book.id) == .synced)
        let postedData = try #require(context.transport.webPosts.last?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: postedData) as? [String: Any])
        #expect(body["cfi"] as? String == "epubcfi(/4/2/4/2/1:9)")
        let restoredAgain = CalibreProgressService(connections: context.connections,
            storageDirectory: context.root.appendingPathComponent("progress"), defaults: context.defaults,
            transportFactory: { _ in context.transport })
        #expect(restoredAgain.state(for: context.book.id) == .idle)
    }

    @Test("server conversion in progress reports retryable state without polling or uploading")
    func preparationNeedsManualRetry() async throws {
        let context = try Context()
        defer { context.cleanup() }
        context.transport.preparing = true
        await context.save(offset: 3)
        #expect(context.service.state(for: context.book.id) == .failed(CalibreProgressError.preparing.localizedDescription))
        #expect(context.transport.posts.isEmpty)
        let count = context.transport.requests.count
        context.transport.preparing = false
        await context.save(offset: 8)
        #expect(context.transport.requests.count == count)
        await context.service.retry(bookID: context.book.id)
        #expect(context.service.state(for: context.book.id) == .synced)
        #expect(context.transport.webPosts.count == 1)
        #expect(context.transport.annotationPosts.isEmpty)
    }

    @Test("missing login, non-native server, and unverified DOM never upload")
    func refusesUnsafeProgress() async throws {
        let context = try Context()
        defer { context.cleanup() }
        var changed = context.connection
        changed.username = nil
        context.connections.update(changed, password: nil)
        await context.save(offset: 3)
        #expect(context.transport.requests.isEmpty)
        changed.username = "reader"
        context.connections.update(changed, password: nil)
        context.transport.nativeServer = false
        await context.service.retry(bookID: context.book.id)
        #expect(context.transport.posts.isEmpty)
        context.transport.nativeServer = true
        context.transport.document = try calibreDOM("完全不同的書籍版本與正文，不能寫入錯誤的閱讀位置。")
        await context.service.retry(bookID: context.book.id)
        #expect(context.transport.posts.isEmpty)
        #expect(context.service.state(for: context.book.id) == .failed(CalibreProgressError.unmappedPosition.localizedDescription))
    }

    @Test("disabling synchronization prevents retry of a durable failed upload")
    func disablingPreventsRetry() async throws {
        let context = try Context()
        defer { context.cleanup() }
        context.transport.postError = URLError(.timedOut)
        await context.save(offset: 3)
        var connection = context.connection
        connection.syncProgress = false
        context.connections.update(connection, password: nil)
        let count = context.transport.requests.count
        await context.service.retry(bookID: context.book.id)
        #expect(context.transport.requests.count == count)
    }

    @MainActor
    private final class Context {
        let root: URL
        let defaults: UserDefaults
        let connections: OPDSCatalogStore
        let connection: OPDSCatalog
        let transport: CalibreProgressFixtureTransport
        let service: CalibreProgressService
        let book: ReadingBook
        let text = "閱讀正文用來驗證精確的跨裝置字元位置，同步後仍然繼續在這裡閱讀。"

        init(enabled: Bool = true) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defaults = UserDefaults(suiteName: "CalibreProgressTests-" + root.lastPathComponent)!
            connections = OPDSCatalogStore(storageDirectory: root, importLegacyWebDAV: false)
            var saved = connections.add(name: "Calibre", url: "https://example.org/proxy/opds",
                username: "reader", password: nil, kind: .calibre)
            saved.syncProgress = enabled
            connections.update(saved, password: nil)
            connection = saved
            transport = CalibreProgressFixtureTransport(document: try calibreDOM(text))
            let transport = transport
            service = CalibreProgressService(connections: connections,
                storageDirectory: root.appendingPathComponent("progress"), defaults: defaults,
                transportFactory: { _ in transport })
            var book = ReadingBook(title: "Test", author: "Author", source: "local_epub", contentFilename: "test.epub")
            book.remoteSource = RemoteBookReference(connectionID: saved.id, entryID: "book-7",
                format: RemoteLibraryFormat(url: URL(string: "https://example.org/proxy/get/EPUB/7/Library")!,
                                            fileExtension: "epub", mimeType: "application/epub+zip"))
            book.currentPosition = 0.42
            self.book = book
        }
        func save(offset: Int) async {
            await service.save(book: book, chapterHref: "/OPS/ch1.xhtml",
                position: CoreTextReadingPosition(spineIndex: 0, charOffset: offset), renderedText: text)
        }
        func cleanup() {
            connections.remove(connection)
            defaults.removePersistentDomain(forName: "CalibreProgressTests-" + root.lastPathComponent)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private func calibreDOM(_ text: String) throws -> Data { try calibreDOM(paragraph: ["n": "p", "x": text]) }
private func calibreDOM(paragraph: [String: Any]) throws -> Data {
    try JSONSerialization.data(withJSONObject: ["version": 1, "ns_map": ["http://www.w3.org/1999/xhtml"],
        "tree": ["n": "html", "c": [["n": "head"], ["n": "body", "c": [paragraph]]]]])
}

private final class CalibreProgressFixtureTransport: RemoteLibraryTransport {
    var document: Data
    var postError: Error?
    var preparing = false
    var nativeServer = true
    var onManifest: (() async -> Void)?
    var requests: [URLRequest] = []
    var posts: [URLRequest] { requests.filter { $0.httpMethod == "POST" } }
    var webPosts: [URLRequest] { posts.filter { $0.url!.path.contains("book-set-last-read-position") } }
    var annotationPosts: [URLRequest] { posts.filter { $0.url!.path.contains("book-update-annotations") } }
    init(document: Data) { self.document = document }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = request.url!.path
        let data: Data
        if request.httpMethod == "POST" {
            guard path.contains("book-set-last-read-position") else { throw URLError(.unsupportedURL) }
            if let postError { throw postError }
            data = Data()
        } else if path.contains("library-info") {
            let object: [String: Any] = nativeServer
                ? ["library_map": ["Library": "Test"], "default_library": "Library"] : [:]
            data = try JSONSerialization.data(withJSONObject: object)
        } else if path.contains("book-manifest") {
            if let onManifest {
                self.onManifest = nil
                await onManifest()
            }
            let object: [String: Any] = preparing ? ["job_status": "running"] :
                ["spine": ["cover.xhtml", "OPS/ch1.xhtml"], "book_hash": ["size": 999, "mtime": 123]]
            data = try JSONSerialization.data(withJSONObject: object)
        } else { data = document }
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
    func download(for request: URLRequest) async throws -> (URL, HTTPURLResponse) { throw URLError(.unsupportedURL) }
    func stream(request: any HTTPRequestConvertible, consume: @escaping (Data, Double?) -> HTTPResult<Void>) async -> HTTPResult<HTTPResponse> {
        .failure(.rangeNotSupported)
    }
}
