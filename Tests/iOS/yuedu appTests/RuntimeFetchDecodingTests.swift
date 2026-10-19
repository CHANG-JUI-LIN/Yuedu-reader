import Foundation
import Testing
@testable import yuedu_app

/// The Legado runtime fetch (`ModernParserBridge.fetch`) decodes with the same decoder as the
/// native path. It used to assume UTF-8 whenever the source's URL options named no charset,
/// which turned every GBK page into "".
@Suite("Runtime fetch decoding", .serialized)
struct RuntimeFetchDecodingTests {
    private static let gbk = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    @Test("a GBK page that declares its charset only in <meta> decodes")
    func gbkPageWithMetaCharset() async throws {
        let host = "gbk-\(UUID().uuidString.prefix(8).lowercased()).example"
        let html = #"<html><head><meta charset="gbk"></head><body><p>第一章 風起</p></body></html>"#
        GBKFixtureProtocol.serve(host: host, body: try #require(html.data(using: Self.gbk)))

        let scriptHost = SourceScriptHost(
            bridgeFor: BookSource(bookSourceUrl: "https://\(host)", bookSourceName: "gbk fixture"),
            requestSession: GBKFixtureProtocol.session()
        )
        let (body, _) = try await scriptHost.fetch(ruleUrl: "https://\(host)/chapter")

        #expect(body.contains("第一章 風起"))
    }

    @Test("the charset URL option decides, as in Legado")
    func charsetOptionDecides() async throws {
        let host = "gbk-\(UUID().uuidString.prefix(8).lowercased()).example"
        let html = "<p>第二章 雲湧</p>"
        GBKFixtureProtocol.serve(host: host, body: try #require(html.data(using: Self.gbk)))

        let scriptHost = SourceScriptHost(
            bridgeFor: BookSource(bookSourceUrl: "https://\(host)", bookSourceName: "gbk fixture"),
            requestSession: GBKFixtureProtocol.session()
        )
        let (body, _) = try await scriptHost.fetch(ruleUrl: #"https://\#(host)/chapter, {"charset":"gbk"}"#)

        #expect(body.contains("第二章 雲湧"))
    }
}

/// Answers one fixture host with a fixed body and a Content-Type that names no charset.
private final class GBKFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var host = ""
    nonisolated(unsafe) private static var body = Data()

    static func serve(host: String, body: Data) {
        lock.lock()
        self.host = host
        self.body = body
        lock.unlock()
    }

    /// The fetch goes through the bridge's request session, which `URLProtocol.registerClass`
    /// does not reach: the protocol has to be in the session's configuration.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GBKFixtureProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return request.url?.host == host
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let body = Self.body
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
