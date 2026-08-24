import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// In-chapter illustrations of an ONLINE book must be downloaded with the book source's own
/// headers, exactly like its cover and its comic pages already are.
///
/// Real case (2026-08-24): 🍇幻梦轻小说9.0 API版 (yckceo 7280) serves 插图 chapters as
/// `<img src="https://picture.302258.xyz/…jpg">`, and that CDN sits behind Cloudflare with the
/// source's declared User-Agent as the pass token — the UA ends in a bogus `Safari/537.36.3022`
/// and ONLY that exact string gets a 200. Any other UA, ours included, gets 403 "Just a moment".
/// The cover of the same book rendered fine (BookCoverLoader sends the source header map) while
/// every illustration came up blank, because `OnlineImageLoader` hardcoded a Safari UA instead.
/// Upstream legado downloads chapter images through `AnalyzeUrl(src, source = bookSource)`
/// (`BookHelp.saveImage`), which applies `source.getHeaderMap()`.
@Suite("Online chapter image source headers", .serialized)
@MainActor
struct OnlineChapterImageHeaderTests {

    /// The exact UA 幻梦轻小说 declares in `header`; the CDN treats it as a shared secret.
    private static let sourceUserAgent =
        "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) "
        + "Chrome/124.0.0.0 Mobile Safari/537.36.3022"

    private static func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6)).pngData { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
    }

    private static func renderSettings() -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "test",
            textColor: .label,
            backgroundColor: .systemBackground,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: 16,
            marginV: 16,
            footerHeight: 0,
            contentInsets: .zero,
            writingMode: .horizontal
        )
    }

    @Test("remote chapter image is fetched with the book source's header map")
    func remoteChapterImageUsesSourceHeaders() async throws {
        GatedImageCDNURLProtocol.reset(requiredUserAgent: Self.sourceUserAgent, body: Self.pngData())
        URLProtocol.registerClass(GatedImageCDNURLProtocol.self)
        defer { URLProtocol.unregisterClass(GatedImageCDNURLProtocol.self) }

        let url = "https://\(UUID().uuidString).picture-cdn.invalid/1/1614/54785/67547.jpg"
        let image = await OnlineImageLoader.load(
            src: url,
            renderWidth: 320,
            headers: ["User-Agent": Self.sourceUserAgent]
        )

        #expect(image != nil)
        #expect(GatedImageCDNURLProtocol.lastUserAgent == Self.sourceUserAgent)
        #expect(GatedImageCDNURLProtocol.lastStatusCode == 200)
    }

    @Test("no source headers keeps the built-in User-Agent (EPUB / headerless sources)")
    func headerlessLoadKeepsDefaultUserAgent() async throws {
        GatedImageCDNURLProtocol.reset(requiredUserAgent: nil, body: Self.pngData())
        URLProtocol.registerClass(GatedImageCDNURLProtocol.self)
        defer { URLProtocol.unregisterClass(GatedImageCDNURLProtocol.self) }

        let url = "https://\(UUID().uuidString).picture-cdn.invalid/plain.png"
        let image = await OnlineImageLoader.load(src: url, renderWidth: 320)

        #expect(image != nil)
        let ua = try #require(GatedImageCDNURLProtocol.lastUserAgent)
        #expect(ua.contains("iPhone"))
    }

    @Test("source headers reach the CDN through the online chapter builder")
    func builderCarriesSourceHeadersToImageDownload() async throws {
        GatedImageCDNURLProtocol.reset(requiredUserAgent: Self.sourceUserAgent, body: Self.pngData())
        URLProtocol.registerClass(GatedImageCDNURLProtocol.self)
        defer { URLProtocol.unregisterClass(GatedImageCDNURLProtocol.self) }

        // Shape of a 幻梦轻小说 插图 chapter: illustrations wrapped one per <p>.
        let host = "\(UUID().uuidString).picture-cdn.invalid"
        let html = """
        <p>————————</p>\
        <p><img src="https://\(host)/1/1614/54785/67547.jpg"></p>\
        <p><img src="https://\(host)/1/1614/54785/67548.jpg"></p>
        """
        let provider = FixedImageChapterProvider(html: html)
        let builder = OnlineProviderAttributedStringBuilder(
            provider: provider,
            renderSize: CGSize(width: 320, height: 480),
            imageHeaders: ["User-Agent": Self.sourceUserAgent]
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.renderSettings(),
            themeTextColor: .label,
            themeBackgroundColor: .systemBackground
        )

        #expect(GatedImageCDNURLProtocol.lastUserAgent == Self.sourceUserAgent)
        #expect(GatedImageCDNURLProtocol.requestCount >= 1)
        #expect(GatedImageCDNURLProtocol.rejectedCount == 0)
        // U+FFFC = the object-replacement char CoreText attachments occupy.
        #expect(result.attributedString.string.contains("\u{FFFC}"))
    }

    @Test("source header JSON parses into the request header map")
    func sourceHeaderJSONParses() throws {
        var source = BookSource()
        source.bookSourceUrl = "https://www.huanmengacg.com"
        source.header = #"{"User-Agent": "\#(Self.sourceUserAgent)"}"#

        let headers = BookCoverLoader.headers(
            sourceBaseURL: source.bookSourceUrl,
            sourceHeaders: source.parsedHeaders
        )
        #expect(headers["User-Agent"] == Self.sourceUserAgent)
        #expect(headers["Referer"] == "https://www.huanmengacg.com")
    }
}

// MARK: - Fixtures

private final class FixedImageChapterProvider: BookContentProvider {
    private let html: String

    init(html: String) {
        self.html = html
    }

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String { "第一卷 插图" }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        ChapterContentPayload(
            index: 0,
            title: "第一卷 插图",
            plainText: "",
            body: .html(html),
            sourceHref: "https://example.invalid/chapter/4251"
        )
    }
}

/// Models a Cloudflare-gated image CDN: 403 unless the request carries `requiredUserAgent`.
private final class GatedImageCDNURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var required: String?
    nonisolated(unsafe) private static var payload = Data()
    nonisolated(unsafe) private static var storedUA: String?
    nonisolated(unsafe) private static var storedStatus = 0
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var rejected = 0

    static func reset(requiredUserAgent: String?, body: Data) {
        lock.lock()
        required = requiredUserAgent
        payload = body
        storedUA = nil
        storedStatus = 0
        requests = 0
        rejected = 0
        lock.unlock()
    }

    static var lastUserAgent: String? { lock.withLock { storedUA } }
    static var lastStatusCode: Int { lock.withLock { storedStatus } }
    static var requestCount: Int { lock.withLock { requests } }
    static var rejectedCount: Int { lock.withLock { rejected } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("picture-cdn.invalid") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let ua = request.value(forHTTPHeaderField: "User-Agent")
        let (status, body): (Int, Data) = Self.lock.withLock {
            Self.storedUA = ua
            Self.requests += 1
            if let required = Self.required, ua != required {
                Self.rejected += 1
                Self.storedStatus = 403
                return (403, Data("<title>Just a moment...</title>".utf8))
            }
            Self.storedStatus = 200
            return (200, Self.payload)
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": status == 200 ? "image/png" : "text/html"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
