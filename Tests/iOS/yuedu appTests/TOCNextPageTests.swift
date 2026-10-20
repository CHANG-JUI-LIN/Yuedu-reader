import Foundation
import Testing
@testable import yuedu_app

/// `ruleToc.nextTocUrl` read the way Legado's `BookChapterList` reads it (legado-E, MD3 and
/// Sigma agree): a list of URLs, the page's own URL dropped. One URL is followed page by page
/// until a page comes round again; several are fetched together and merged in their order,
/// and those pages are not asked for a next page.
///
/// It used to be read as one string. A page-select TOC (`<select><option value>`) joined
/// every option with "\n" into a single URL that matched no page, and a rule result tens of
/// MB long was handed to `URL(string:relativeTo:)` whole — Crashlytics 4eaef04b, an OOM
/// inside its percent-encoding.
@Suite("TOC next pages", .serialized)
struct TOCNextPageTests {

    @Test("a page-select TOC fetches every other option once, in option order")
    func pageSelectFansOut() async throws {
        let host = Self.host()
        defer { TOCPageStubURLProtocol.remove(host) }
        let options = (1...3).map { "<option value=\"/toc?p=\($0)\">\($0)</option>" }.joined()
        for page in 1...3 {
            TOCPageStubURLProtocol.set(
                Self.page(chapters: ["p\(page)a", "p\(page)b"], extra: "<select>\(options)</select>"),
                for: "https://\(host)/toc?p=\(page)"
            )
        }
        var source = Self.source(host: host)
        source.ruleToc.nextTocUrl = "tag.option@value"

        let chapters = try await Self.fetch("https://\(host)/toc?p=1", source: source)

        #expect(chapters.map(\.title) == ["p1a", "p1b", "p2a", "p2b", "p3a", "p3b"])
        #expect(chapters.map(\.index) == Array(0..<6))
        for page in 1...3 {
            #expect(TOCPageStubURLProtocol.requestCount(for: "https://\(host)/toc?p=\(page)") == 1)
        }
    }

    /// Legado parses a following page's error response like any page (`newCallStrResponse`
    /// does not throw on a status): a dead page adds no chapters and the rest stand. Thrown,
    /// one dead option lost the whole table of contents, its first page included.
    @Test("a page that answers 404 adds nothing and the other pages stand")
    func deadPageKeepsTheRest() async throws {
        let host = Self.host()
        defer { TOCPageStubURLProtocol.remove(host) }
        let options = (1...3).map { "<option value=\"/toc?p=\($0)\">\($0)</option>" }.joined()
        for page in [1, 3] {
            TOCPageStubURLProtocol.set(
                Self.page(chapters: ["p\(page)"], extra: "<select>\(options)</select>"),
                for: "https://\(host)/toc?p=\(page)"
            )
        }
        var source = Self.source(host: host)
        source.ruleToc.nextTocUrl = "tag.option@value"

        let chapters = try await Self.fetch("https://\(host)/toc?p=1", source: source)

        #expect(chapters.map(\.title) == ["p1", "p3"])
        #expect(TOCPageStubURLProtocol.requestCount(for: "https://\(host)/toc?p=2") == 1)
    }

    /// Legado's `getStringList` reads the last `@` step as the value — any attribute name.
    /// Ours only read a few names (`href`, `src`, `text`…) and took `value` for a tag to select.
    @Test("a string list reads any attribute named by its last step")
    func stringListReadsAnyAttribute() {
        let options = (1...3).map { "<option value=\"/toc?p=\($0)\">\($0)</option>" }.joined()
        let engine = ModernRuleEngine()
        engine.setContent("<html><body><select>\(options)</select></body></html>", baseUrl: "https://h.yuedu.test/toc")

        #expect(engine.getStringList(ruleStr: "tag.option@value") == ["/toc?p=1", "/toc?p=2", "/toc?p=3"])
        #expect(engine.getStringList(ruleStr: "tag.option@value", isUrl: true) == [
            "https://h.yuedu.test/toc?p=1", "https://h.yuedu.test/toc?p=2", "https://h.yuedu.test/toc?p=3",
        ])
        #expect(engine.getStringList(ruleStr: "tag.option.0@value||tag.option@href") == ["/toc?p=1"])
    }

    @Test("a single next link is followed until it leads back to a page already read")
    func singleNextStopsOnRevisit() async throws {
        let host = Self.host()
        defer { TOCPageStubURLProtocol.remove(host) }
        TOCPageStubURLProtocol.set(
            Self.page(chapters: ["one"], extra: "<a class=\"next\" href=\"/toc/2\">下一頁</a>"),
            for: "https://\(host)/toc/1"
        )
        TOCPageStubURLProtocol.set(
            Self.page(chapters: ["two"], extra: "<a class=\"next\" href=\"/toc/1\">首頁</a>"),
            for: "https://\(host)/toc/2"
        )
        var source = Self.source(host: host)
        source.ruleToc.nextTocUrl = "class.next@href"

        let chapters = try await Self.fetch("https://\(host)/toc/1", source: source)

        #expect(chapters.map(\.title) == ["one", "two"])
        #expect(TOCPageStubURLProtocol.requestCount(for: "https://\(host)/toc/1") == 1)
        #expect(TOCPageStubURLProtocol.requestCount(for: "https://\(host)/toc/2") == 1)
    }

    @Test("a next link to the page itself is dropped")
    func selfLinkIsDropped() async throws {
        let host = Self.host()
        defer { TOCPageStubURLProtocol.remove(host) }
        TOCPageStubURLProtocol.set(
            Self.page(chapters: ["only"], extra: "<a class=\"next\" href=\"/toc\">本頁</a>"),
            for: "https://\(host)/toc"
        )
        var source = Self.source(host: host)
        source.ruleToc.nextTocUrl = "class.next@href"

        let chapters = try await Self.fetch("https://\(host)/toc", source: source)

        #expect(chapters.map(\.title) == ["only"])
        #expect(TOCPageStubURLProtocol.requestCount(for: "https://\(host)/toc") == 1)
    }

    /// Legado has no page limit; the pages read are what stop it. A 20-page cap here cut a
    /// 2,000-chapter book at 50 chapters a page down to its first 1,000.
    @Test("a TOC longer than twenty pages is read to its last page")
    func noPageCap() async throws {
        let host = Self.host()
        defer { TOCPageStubURLProtocol.remove(host) }
        let pageCount = 25
        for page in 1...pageCount {
            let next = page < pageCount ? "<a class=\"next\" href=\"/toc/\(page + 1)\">下一頁</a>" : ""
            TOCPageStubURLProtocol.set(
                Self.page(chapters: ["c\(page)"], extra: next),
                for: "https://\(host)/toc/\(page)"
            )
        }
        var source = Self.source(host: host)
        source.ruleToc.nextTocUrl = "class.next@href"

        let chapters = try await Self.fetch("https://\(host)/toc/1", source: source)

        #expect(chapters.map(\.title) == (1...pageCount).map { "c\($0)" })
    }

    /// A TOC URL with options or JS goes through the Legado runtime fetch, which used to
    /// parse the first page and stop. `data:` URLs take that branch without the network.
    @Test("the runtime TOC route follows next pages too")
    func runtimeRouteFollowsNextPages() async throws {
        let page2 = Self.dataURL(Self.page(chapters: ["two"], extra: ""))
        let page1 = Self.dataURL(Self.page(chapters: ["one"], extra: "<a class=\"next\" href=\"\(page2)\">下一頁</a>"))
        var source = Self.source(host: Self.host())
        source.ruleToc.nextTocUrl = "class.next@href"
        #expect(source.shouldUseLegadoRuntimeFetch(for: page1))

        let chapters = try await Self.fetch(page1, source: source)

        #expect(chapters.map(\.title) == ["one", "two"])
    }

    // MARK: - Fixtures

    private static func host() -> String {
        "toc-next-\(UUID().uuidString.lowercased()).yuedu.test"
    }

    private static func source(host: String) -> BookSource {
        var source = BookSource(bookSourceUrl: "https://\(host)", bookSourceName: "目錄翻頁測試")
        source.ruleToc.chapterList = "#list dd"
        source.ruleToc.chapterName = "a@text"
        source.ruleToc.chapterUrl = "a@href"
        return source
    }

    private static func page(chapters: [String], extra: String) -> String {
        let items = chapters.map { "<dd><a href=\"/c/\($0)\">\($0)</a></dd>" }.joined()
        return "<html><body><dl id=\"list\">\(items)</dl>\(extra)</body></html>"
    }

    private static func dataURL(_ html: String) -> String {
        "data:text/html;base64," + Data(html.utf8).base64EncodedString()
    }

    private static func fetch(_ tocURL: String, source: BookSource) async throws -> [OnlineChapterRef] {
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: TOCPageStubURLProtocol.session()))
        let package = try await fetcher.fetchTOCPackage(
            tocUrl: tocURL,
            source: source,
            forceRefresh: true,
            runPreUpdateJs: false,
            writesCache: false
        )
        return package.chapters
    }
}

/// Replies by full URL, so each page of one host is its own fixture; an unknown URL is a 404.
private final class TOCPageStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [String: String] = [:]
    nonisolated(unsafe) private static var requests: [String: Int] = [:]

    static func set(_ html: String, for url: String) {
        lock.withLock { pages[url] = html }
    }

    static func remove(_ host: String) {
        lock.withLock {
            pages = pages.filter { URL(string: $0.key)?.host != host }
            requests = requests.filter { URL(string: $0.key)?.host != host }
        }
    }

    static func requestCount(for url: String) -> Int {
        lock.withLock { requests[url] ?? 0 }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TOCPageStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".yuedu.test") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let key = url.absoluteString
        let html = Self.lock.withLock { () -> String? in
            Self.requests[key, default: 0] += 1
            return Self.pages[key]
        }
        let response = HTTPURLResponse(
            url: url, statusCode: html == nil ? 404 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((html ?? "not found").utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
