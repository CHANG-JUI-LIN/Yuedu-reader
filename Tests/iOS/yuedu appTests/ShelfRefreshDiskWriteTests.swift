import Foundation
import os
import Testing
@testable import yuedu_app

/// Bytes each writer puts on disk when the shelf's "check for new chapters" runs, through the
/// real `BookSourceFetcher` (TOC cache) and the real `BookStore` (chapter lists, shelf file).
///
/// 3.0.1 (146) field reports: 1 074 MB of writes in a day on a 248-online-book shelf, sampled
/// in `saveTOCPackage` under `refreshOnlineBookMetadata`. Each round below prints one
/// `DISKWRITE …` line per scenario; the assertions pin the rounds that must write nothing.
@MainActor
@Suite(.serialized)
struct ShelfRefreshDiskWriteTests {
    private static let books = 5
    private static let chapters = 2_000

    @Test("refreshing the shelf writes nothing for an unchanged list, one book's worth for a new chapter")
    func refreshWritesPerScenario() async throws {
        let host = "shelf-\(UUID().uuidString.lowercased()).yuedu.test"
        ShelfRefreshStubURLProtocol.set(TOCFixture(host: host, count: Self.chapters, token: nil), for: host)
        defer { ShelfRefreshStubURLProtocol.remove(host) }

        let source = Self.source(url: "https://\(host)")
        let previousSources = BookSourceStore.shared.sources
        BookSourceStore.shared.replaceSources([source])
        defer { BookSourceStore.shared.replaceSources(previousSources) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfRefreshDiskWrite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BookStore(metadataFileURL: directory.appendingPathComponent("books_meta.json"))
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: ShelfRefreshStubURLProtocol.session()))
        let live = LiveBookSourceFetcher(bookSourceFetcher: fetcher)

        let initial = TOCFixture(host: host, count: Self.chapters, token: nil).refs
        let bookIDs = (0..<Self.books).map { index in
            store.addOnlineBook(
                name: "書 \(index)", author: "作者", sourceId: source.id,
                bookInfoURL: "https://\(host)/book/\(index)", tocURL: "https://\(host)/toc/\(index)",
                chapters: initial
            ).id
        }
        defer {
            for index in 0..<Self.books {
                fetcher.clearTOCAndBookInfoCache(tocUrl: "https://\(host)/toc/\(index)", bookURL: nil, source: source)
            }
        }
        store.flushPendingMetadataSave()
        store.waitForQueuedWrites()

        func round(_ name: String, _ fixture: TOCFixture) async throws -> [String: DiskWriteTally.Total] {
            ShelfRefreshStubURLProtocol.set(fixture, for: host)
            let writers = [BookSourceFetcher.tocDiskWriteTallyName, BookChapterStore.diskWriteTallyName, "shelf"]
            let before = Dictionary(uniqueKeysWithValues: writers.map { ($0, DiskWriteTally.total($0)) })
            for id in bookIDs {
                _ = try await store.refreshOnlineBookMetadata(bookId: id, bookSourceFetcher: live)
            }
            store.flushPendingMetadataSave()
            store.waitForQueuedWrites()
            var delta: [String: DiskWriteTally.Total] = [:]
            for writer in writers {
                let after = DiskWriteTally.total(writer)
                delta[writer] = DiskWriteTally.Total(
                    count: after.count - before[writer]!.count, bytes: after.bytes - before[writer]!.bytes
                )
            }
            let line = writers.map { "\($0)=\(delta[$0]!.count)×/\(delta[$0]!.bytes)B" }.joined(separator: " ")
            print("DISKWRITE \(name) books=\(Self.books) chapters=\(fixture.count) \(line)")
            return delta
        }

        // First pass: the TOC cache is empty, the shelf already holds the list.
        _ = try await round("first", TOCFixture(host: host, count: Self.chapters, token: nil))
        // The same list again: nothing to write anywhere.
        let unchanged = try await round("unchanged", TOCFixture(host: host, count: Self.chapters, token: nil))
        #expect(unchanged[BookSourceFetcher.tocDiskWriteTallyName]?.bytes == 0)
        #expect(unchanged[BookChapterStore.diskWriteTallyName]?.bytes == 0)
        // One new chapter per book.
        _ = try await round("grew+1", TOCFixture(host: host, count: Self.chapters + 1, token: nil))
        // Same length, every URL carrying a new per-request token.
        _ = try await round("tokenURLs", TOCFixture(host: host, count: Self.chapters + 1, token: "a"))
        _ = try await round("tokenURLs2", TOCFixture(host: host, count: Self.chapters + 1, token: "b"))
    }

    @Test("a rewrite names what changed")
    func changeReason() throws {
        let a = TOCFixture(host: "x.test", count: 3, token: nil).refs
        let grown = TOCFixture(host: "x.test", count: 4, token: nil).refs
        let tokened = TOCFixture(host: "x.test", count: 3, token: "t").refs
        let base = TOCFieldDigests(chapters: a, runtimeVariables: nil)
        let stored = try #require(TOCFieldDigests(serialized: base.serialized))
        #expect(stored == base)
        #expect(TOCFieldDigests(chapters: grown, runtimeVariables: nil).changeReason(from: base, hadPackage: true) == "grew+1 n=4")
        #expect(TOCFieldDigests(chapters: tokened, runtimeVariables: nil).changeReason(from: base, hadPackage: true)
            == "sameCount n=3 fields=urls")
        var timed = a
        timed[1].updateTime = "3小時前"
        #expect(TOCFieldDigests(chapters: timed, runtimeVariables: nil).changeReason(from: base, hadPackage: true)
            == "sameCount n=3 fields=updateTimes")
        #expect(base.changeReason(from: nil, hadPackage: true) == "changed n=3 fields=unknown")
        #expect(base.changeReason(from: nil, hadPackage: false) == "new n=3")
    }

    private static func source(url: String) -> BookSource {
        var source = BookSource(bookSourceUrl: url, bookSourceName: "書架刷新寫入測試")
        source.searchUrl = url + "/search?q={{key}}"
        source.ruleToc.chapterList = "#list dd"
        source.ruleToc.chapterName = "a@text"
        source.ruleToc.chapterUrl = "a@href"
        return source
    }
}

/// A table of contents `count` chapters long; `token` stands for a per-request query
/// parameter some sites put on every chapter URL.
struct TOCFixture: Sendable {
    var host: String
    var count: Int
    var token: String?

    func url(_ index: Int) -> String {
        "https://\(host)/c/\(index)" + (token.map { "?t=\($0)" } ?? "")
    }

    func title(_ index: Int) -> String { "第\(index + 1)章 風起雲湧 之 \(index % 17)" }

    var html: String {
        let rows = (0..<count).map { "<dd><a href=\"\(url($0))\">\(title($0))</a></dd>" }.joined()
        return "<html><body><dl id=\"list\">\(rows)</dl></body></html>"
    }

    var refs: [OnlineChapterRef] {
        (0..<count).map { OnlineChapterRef(index: $0, title: title($0), url: url($0)) }
    }
}

private final class ShelfRefreshStubURLProtocol: URLProtocol {
    private static let fixtures = OSAllocatedUnfairLock(initialState: [String: TOCFixture]())

    static func set(_ fixture: TOCFixture, for host: String) {
        fixtures.withLock { $0[host] = fixture }
    }

    static func remove(_ host: String) {
        fixtures.withLock { $0[host] = nil }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ShelfRefreshStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return fixtures.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let fixture = Self.fixtures.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
