import Foundation
import Testing
@testable import yuedu_app

/// RSS pages decode with the book sources' `HTMLResponseDecoder`, as Legado reads RSS through
/// the same `getStrResponse`. The scraper's own decoder tried the header charset, then UTF-8,
/// then GB18030: a Big5 page came out as GB18030 mojibake, and a UTF-8 page served as
/// ISO-8859-1 as Latin-1 mojibake. Feed and icon discovery read homepages as UTF-8 only, so a
/// GBK homepage yielded nothing.
@Suite("RSS page decoding", .serialized)
struct RSSPageDecodingTests {
    private static let big5 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)
        )
    )
    private static let gbk = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    @Test("a Big5 article that names its charset only in <meta> decodes")
    func big5ArticleWithMetaCharset() async throws {
        let html = #"<html><head><meta charset="big5"></head><body><p>臺灣繁體內文</p></body></html>"#
        let content = try await Self.articleContent(
            body: try #require(html.data(using: Self.big5)),
            contentType: "text/html"
        )
        #expect(content == "臺灣繁體內文")
    }

    @Test("a UTF-8 article served as ISO-8859-1 decodes as UTF-8")
    func utf8ArticleLabelledLatin1() async throws {
        let html = "<html><body><p>第一章 風起</p></body></html>"
        let content = try await Self.articleContent(
            body: Data(html.utf8),
            contentType: "text/html; charset=iso-8859-1"
        )
        #expect(content == "第一章 風起")
    }

    @Test("feed discovery reads a GBK homepage")
    func feedDiscoveryReadsGBKHomepage() throws {
        let html = #"<html><head><meta charset="gbk"><title>中文新聞站</title><link rel="alternate" type="application/rss+xml" href="/news.rss"></head><body>內容</body></html>"#
        let urls = RSSFeedDiscovery.feedURLs(
            inHTML: try #require(html.data(using: Self.gbk)),
            baseURL: try #require(URL(string: "https://gbk-news.example/"))
        )
        #expect(urls.map(\.absoluteString) == ["https://gbk-news.example/news.rss"])
    }

    private static func articleContent(body: Data, contentType: String) async throws -> String? {
        let host = "rss-page-\(UUID().uuidString.prefix(8).lowercased()).example"
        RSSPageFixtureProtocol.serve(host: host, contentType: contentType, body: body)

        var source = RSSSource(name: "rss page fixture", url: "https://\(host)/")
        source.ruleContent = "@css:p@text"
        return try await LegadoRSSScraper.fetchArticleContent(
            source: source, articleLink: "https://\(host)/article",
            session: RSSPageFixtureProtocol.session
        )
    }
}

/// Answers one fixture host with a fixed body and Content-Type.
private final class RSSPageFixtureProtocol: URLProtocol {
    /// A session that answers through this protocol. `URLProtocol.registerClass` reaches only
    /// `URLSession.shared`, which the app no longer uses (`ServerTrustPolicy`).
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RSSPageFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }()

    private static let lock = NSLock()
    nonisolated(unsafe) private static var host = ""
    nonisolated(unsafe) private static var contentType = ""
    nonisolated(unsafe) private static var body = Data()

    static func serve(host: String, contentType: String, body: Data) {
        lock.lock()
        self.host = host
        self.contentType = contentType
        self.body = body
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let contentType = Self.contentType
        let body = Self.body
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
