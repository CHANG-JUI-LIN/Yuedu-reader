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

    /// A page that declares nothing: Legado leaves it to ICU's detector, and the option stands in
    /// for that detector here (`HTMLResponseDecoder.decode(data:response:declaredCharset:)`).
    @Test("the charset URL option decides a page that declares no charset")
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

    private static let big5 = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
    )

    /// `java.ajax(url,{"charset":…})` goes through AnalyzeUrl and the bridge's own transport,
    /// which decoded with charset detection alone and never saw the option. Legado reads this
    /// undeclared page with ICU's detector, which tells Big5 from GBK; the option stands in for
    /// it. Big5, not GBK: detection already reads this GBK text correctly, while these Big5
    /// bytes are also valid GBK and came back as "材彻 冻撮癬".
    @Test("java.ajax and java.ajaxAll honour the charset URL option")
    func javaAjaxHonoursCharsetOption() throws {
        let charset = "big5"
        let host = "ajax-\(charset)-\(UUID().uuidString.prefix(8).lowercased()).example"
        let text = "第三章 雲湧風起"
        let bytes = try #require(text.data(using: Self.big5))
        GBKFixtureProtocol.serve(host: host, body: bytes)

        // Only a page that detection reads wrongly can show whether the option is used.
        let response = HTTPURLResponse(
            url: URL(string: "https://\(host)/chapter")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]
        )
        #expect(HTMLResponseDecoder.decode(data: bytes, response: response) != text)

        let bridge = ModernParserBridge(
            source: BookSource(bookSourceUrl: "https://\(host)", bookSourceName: "charset fixture"),
            requestSession: GBKFixtureProtocol.session()
        )
        // `,{` with no space: that is what sends `java.ajax` to the AnalyzeUrl handler.
        let url = Self.jsString(#"https://\#(host)/chapter,{"charset":"\#(charset)"}"#)
        #expect(bridge.evaluateSourceScript("java.ajax(\(url))") == text)
        #expect(bridge.evaluateSourceScript("java.ajaxAll([\(url)])[0].body()") == text)
    }

    /// The native stage fetch (`BookSourceFetcher.fetchStageHTML`) decoded with detection alone
    /// and used the charset option only to encode the request body. An undeclared page is ICU's
    /// to detect in Legado, and the option stands in for it here. Both routes: without
    /// `loginCheckJs` (`fetchHTML`) and with it (`fetchPage` + `LegadoHTTPResult`).
    @Test("the native stage fetch honours the charset URL option", arguments: ["", "result"])
    func stageFetchHonoursCharsetOption(loginCheckJs: String) async throws {
        let host = "stage-big5-\(UUID().uuidString.prefix(8).lowercased()).example"
        let text = "第三章 雲湧風起"
        let bytes = try #require(text.data(using: Self.big5))
        GBKFixtureProtocol.serve(host: host, body: bytes)
        let url = try #require(URL(string: "https://\(host)/chapter"))

        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]
        )
        #expect(HTMLResponseDecoder.decode(data: bytes, response: response) != text)

        var source = BookSource(bookSourceUrl: "https://\(host)", bookSourceName: "charset fixture")
        source.loginCheckJs = loginCheckJs
        let fetcher = BookSourceFetcher(webFetcher: WebFetcher(session: GBKFixtureProtocol.session()))
        let html = try await fetcher.fetchStageHTML(
            url: url, method: "GET", body: nil, headers: [:],
            baseURL: source.bookSourceUrl, charset: "big5", source: source)

        #expect(html == text)
    }

    /// Legado decodes a response by its Content-Type, then its `<meta>` (`body.text()` never
    /// sees the option). 福书网吧 (YCK1331) posts its search as `gbk` and the page it gets back
    /// declares UTF-8: the option had made its title "淇℃伅鎻愮ず" instead of 信息提示.
    @Test("a page that declares its charset decodes by it, whatever the charset option says")
    func pageDeclarationBeatsCharsetOption() throws {
        let url = try #require(URL(string: "https://declared.example/search"))
        let plain = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]
        )
        let utf8Page = #"<html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"><title>信息提示</title></head></html>"#
        #expect(HTMLResponseDecoder.decode(data: Data(utf8Page.utf8), response: plain, declaredCharset: "gbk")?
            .contains("<title>信息提示</title>") == true)

        let gbkPage = #"<html><head><meta charset="gbk"><title>第三章 雲湧風起</title></head></html>"#
        let gbkBytes = try #require(gbkPage.data(using: Self.gbk))
        #expect(HTMLResponseDecoder.decode(data: gbkBytes, response: plain, declaredCharset: "big5")?
            .contains("第三章 雲湧風起") == true)

        let headerDeclared = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html; charset=gbk"]
        )
        let bare = try #require("<p>第三章 雲湧風起</p>".data(using: Self.gbk))
        #expect(HTMLResponseDecoder.decode(data: bare, response: headerDeclared, declaredCharset: "big5")
            == "<p>第三章 雲湧風起</p>")
    }

    private static func jsString(_ value: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [value])
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
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
