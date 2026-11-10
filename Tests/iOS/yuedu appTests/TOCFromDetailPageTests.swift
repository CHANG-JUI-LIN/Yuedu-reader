import Foundation
import Testing
@testable import yuedu_app

/// Legado `WebBook.getChapterListAwait`: a TOC at the book's own URL is read from the detail
/// page the detail stage just read (`tocHtml`), not requested again. Over half the sources of
/// the YCK packs have no tocUrl rule, and on a slow site the second fetch of the same page was
/// the one that timed out (轻之文库, YCK1331).
@Suite("TOC from the detail page", .serialized)
struct TOCFromDetailPageTests {
    private static let page = """
        <html><body><h1>書名</h1>
        <ul><li><a class='x' href='/c/1'>第一章</a></li><li><a class='x' href='/c/2'>第二章</a></li></ul>
        </body></html>
        """

    private func setUp(_ name: String, tocRule: String = "") -> (BookSourceFetcher, BookSource, String) {
        let host = "\(name).toc-from-detail.test"
        DetailPageStubURLProtocol.serve(Self.page, at: host)
        var source = BookSource()
        source.bookSourceName = "TOC from detail \(name)"
        source.bookSourceUrl = "https://\(host)"
        source.ruleBookInfo.name = "h1@text"
        source.ruleBookInfo.tocUrl = tocRule
        source.ruleToc.chapterList = ".x"
        source.ruleToc.chapterName = "text"
        source.ruleToc.chapterUrl = "href"
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: DetailPageStubURLProtocol.session()))
        return (fetcher, source, "https://\(host)/book/\(UUID().uuidString.prefix(8))")
    }

    private func readBook(
        _ fetcher: BookSourceFetcher, _ source: BookSource, _ bookURL: String, handsOverPage: Bool
    ) async throws -> (info: BookInfoPackage, toc: TOCPackage) {
        let info = try await fetcher.fetchBookInfoPackage(url: bookURL, source: source, usesCache: false)
        let toc = try await fetcher.fetchTOCPackage(
            tocUrl: info.tocUrl, source: source, forceRefresh: true, writesCache: false,
            detailPage: handsOverPage ? info.onlineBook.detailPage : nil
        )
        return (info, toc)
    }

    @Test("a TOC at the book's own URL is read from its detail page, in one request")
    func readsTheDetailPage() async throws {
        let (fetcher, source, bookURL) = setUp("own-url")
        let (info, toc) = try await readBook(fetcher, source, bookURL, handsOverPage: true)
        #expect(info.tocUrl == bookURL)
        #expect(info.onlineBook.detailPage?.url == bookURL)
        #expect(toc.chapters.map(\.title) == ["第一章", "第二章"])
        #expect(DetailPageStubURLProtocol.requests(to: bookURL) == 1)
    }

    @Test("without the page handed over, the same TOC is fetched again")
    func fetchesWithoutThePage() async throws {
        let (fetcher, source, bookURL) = setUp("no-page")
        let (_, toc) = try await readBook(fetcher, source, bookURL, handsOverPage: false)
        #expect(toc.chapters.map(\.title) == ["第一章", "第二章"])
        #expect(DetailPageStubURLProtocol.requests(to: bookURL) == 2)
    }

    @Test("a TOC elsewhere keeps no detail page and is fetched from its own URL")
    func tocElsewhereIsFetched() async throws {
        let (fetcher, source, bookURL) = setUp("elsewhere", tocRule: "a.x@href")
        let (info, toc) = try await readBook(fetcher, source, bookURL, handsOverPage: true)
        #expect(info.tocUrl != bookURL)
        #expect(info.onlineBook.detailPage == nil)
        #expect(toc.chapters.map(\.title) == ["第一章", "第二章"])
        #expect(DetailPageStubURLProtocol.requests(to: bookURL) == 1)
        #expect(DetailPageStubURLProtocol.requests(to: info.tocUrl) == 1)
    }

    @Test("a stored detail package carries no page")
    func storedPackageCarriesNoPage() throws {
        var package = BookInfoPackage(
            sourceId: UUID(), sourceName: "s", bookURL: "https://a.test/b", name: "n", author: "",
            intro: "", coverUrl: "", tocUrl: "https://a.test/b", wordCount: "", lastChapter: "",
            kind: "", runtimeVariables: nil, rawHTMLFilename: nil, savedAt: Date()
        )
        package.tocHtml = "<html></html>"
        #expect(package.onlineBook.detailPage != nil)
        let decoded = try JSONDecoder().decode(BookInfoPackage.self, from: JSONEncoder().encode(package))
        #expect(decoded.onlineBook.detailPage == nil)
    }
}

/// Serves one page at each test host and counts the requests per URL. It lives in the
/// session's configuration: `URLProtocol.registerClass` does not reach a custom session.
private final class DetailPageStubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [String: String] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]

    static func serve(_ html: String, at host: String) {
        lock.withLock { pages[host] = html }
    }

    static func requests(to url: String) -> Int {
        lock.withLock { counts[url] ?? 0 }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DetailPageStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { pages[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let html = Self.lock.withLock({ () -> String? in
                  Self.counts[url.absoluteString, default: 0] += 1
                  return Self.pages[host]
              }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(html.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
