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

    /// Live proof against the real CDN, off by default (needs network + the site up).
    /// `RUN_HUANMENG_IMAGE_LIVE_TESTS=1` to run it.
    @Test(
        "LIVE: 幻梦轻小说 illustration loads only with the source's header map",
        .enabled(if: ProcessInfo.processInfo.environment["RUN_HUANMENG_IMAGE_LIVE_TESTS"] == "1"
                 || ProcessInfo.processInfo.environment["TEST_RUNNER_RUN_HUANMENG_IMAGE_LIVE_TESTS"] == "1")
    )
    func liveIllustrationNeedsSourceHeaders() async throws {
        // 青春猪头少年不会梦到兔女郎学姊 · 第一卷 插图, first plate.
        let src = "https://picture.302258.xyz/1/1614/54785/67547.jpg"
        let headers = BookCoverLoader.headers(
            sourceBaseURL: "https://www.huanmengacg.com",
            sourceHeaders: ["User-Agent": Self.sourceUserAgent]
        )

        let withoutHeaders = await OnlineImageLoader.load(src: src, renderWidth: 360, timeout: 20)
        let withHeaders = await OnlineImageLoader.load(
            src: src, renderWidth: 360, timeout: 20, headers: headers
        )

        #expect(withoutHeaders == nil, "the built-in UA is 403'd by the CDN's Cloudflare rule")
        #expect(withHeaders != nil)
        if let withHeaders {
            print("⟐TEST live illustration = \(Int(withHeaders.size.width))x\(Int(withHeaders.size.height))")
        }
    }

    /// A PNG of exactly `size` in PIXELS — the renderer's default scale would silently make the
    /// bitmap 2–3x the requested size, which is the number these tests assert on.
    private static func pngData(pixels size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("an oversized print scan is downsampled to the reader's ceiling")
    func oversizedIllustrationIsDownsampled() async throws {
        // Same shape as the 第一卷 插图 spread: far wider than any column or preview.
        let big = Self.pngData(pixels: CGSize(width: 3000, height: 1971))
        GatedImageCDNURLProtocol.reset(requiredUserAgent: nil, body: big)
        URLProtocol.registerClass(GatedImageCDNURLProtocol.self)
        defer { URLProtocol.unregisterClass(GatedImageCDNURLProtocol.self) }

        let url = "https://\(UUID().uuidString).picture-cdn.invalid/spread.png"
        let image = try #require(await OnlineImageLoader.load(src: url, renderWidth: 360))

        #expect(max(image.size.width, image.size.height) == 2048)
        // Aspect ratio survives: 3000:1971 → 2048:1345.
        #expect(abs(image.size.height - 2048.0 * 1971.0 / 3000.0) < 2.0)
    }

    @Test("a plate already under the ceiling is never upscaled")
    func smallIllustrationIsUntouched() async throws {
        // 716x1023 — the size most plates in that chapter actually are.
        let plate = Self.pngData(pixels: CGSize(width: 716, height: 1023))
        GatedImageCDNURLProtocol.reset(requiredUserAgent: nil, body: plate)
        URLProtocol.registerClass(GatedImageCDNURLProtocol.self)
        defer { URLProtocol.unregisterClass(GatedImageCDNURLProtocol.self) }

        let url = "https://\(UUID().uuidString).picture-cdn.invalid/plate.png"
        let image = try #require(await OnlineImageLoader.load(src: url, renderWidth: 360))

        #expect(image.size == CGSize(width: 716, height: 1023))
    }

    @Test("bytes ImageIO cannot open still degrade through UIImage(data:)")
    func undecodableBytesFallBackToUIImage() {
        #expect(OnlineImageLoader.decodedImage(from: Data("not an image".utf8)) == nil)
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

    // MARK: - Legado per-image `headers` option

    @Test("a per-image header option survives the chapter sanitizer")
    func perImageHeadersSurviveSanitizing() throws {
        let raw = #"<p><img src="https://cdn.example/1.jpg,{"headers":{"Referer":"https://plates.example/"}}"></p>"#
        let sanitized = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(raw)

        // The suffix itself must be gone — its inner quotes break SwiftSoup's attribute parsing.
        #expect(!sanitized.contains(",{"))
        let range = try #require(sanitized.range(of: #"(?<=src=")[^"]+"#, options: .regularExpression))
        let decoded = OnlineImageRequestOptions.decode(String(sanitized[range]))
        #expect(decoded.src == "https://cdn.example/1.jpg")
        #expect(decoded.headers["Referer"] == "https://plates.example/")
    }

    @Test("an image's own headers win over the source's")
    func perImageHeadersOverrideSourceHeaders() async throws {
        GatedImageCDNURLProtocol.reset(requiredUserAgent: "per-image-ua", body: Self.pngData())
        URLProtocol.registerClass(GatedImageCDNURLProtocol.self)
        defer { URLProtocol.unregisterClass(GatedImageCDNURLProtocol.self) }

        let src = OnlineImageRequestOptions.encoding(
            src: "https://\(UUID().uuidString).picture-cdn.invalid/1.jpg",
            headers: ["User-Agent": "per-image-ua"]
        )
        let image = await OnlineImageLoader.load(
            src: src,
            renderWidth: 320,
            headers: ["User-Agent": "source-wide-ua", "Referer": "https://source.example/"]
        )

        #expect(image != nil)
        #expect(GatedImageCDNURLProtocol.lastUserAgent == "per-image-ua")
        // Source headers it does not override are still sent.
        #expect(GatedImageCDNURLProtocol.lastReferer == "https://source.example/")
        // The fragment must never reach the wire.
        #expect(GatedImageCDNURLProtocol.lastPath?.contains("yd-imgh") == false)
    }

    @Test("an ordinary src is returned untouched by the option codec")
    func plainSourcesAreUntouched() {
        let plain = "https://cdn.example/a.jpg"
        #expect(OnlineImageRequestOptions.encoding(src: plain, headers: [:]) == plain)
        #expect(OnlineImageRequestOptions.decode(plain).src == plain)
        #expect(OnlineImageRequestOptions.decode(plain).headers.isEmpty)
        // A data: URI carries its bytes — there is no request to add headers to.
        let dataURI = "data:image/png;base64,AAAA"
        #expect(
            OnlineImageRequestOptions.encoding(src: dataURI, headers: ["A": "b"]) == dataURI
        )
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
    nonisolated(unsafe) private static var storedReferer: String?
    nonisolated(unsafe) private static var storedPath: String?
    nonisolated(unsafe) private static var storedStatus = 0
    nonisolated(unsafe) private static var requests = 0
    nonisolated(unsafe) private static var rejected = 0

    static func reset(requiredUserAgent: String?, body: Data) {
        lock.lock()
        required = requiredUserAgent
        payload = body
        storedUA = nil
        storedReferer = nil
        storedPath = nil
        storedStatus = 0
        requests = 0
        rejected = 0
        lock.unlock()
    }

    static var lastUserAgent: String? { lock.withLock { storedUA } }
    static var lastReferer: String? { lock.withLock { storedReferer } }
    static var lastPath: String? { lock.withLock { storedPath } }
    static var lastStatusCode: Int { lock.withLock { storedStatus } }
    static var requestCount: Int { lock.withLock { requests } }
    static var rejectedCount: Int { lock.withLock { rejected } }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix("picture-cdn.invalid") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let ua = request.value(forHTTPHeaderField: "User-Agent")
        let referer = request.value(forHTTPHeaderField: "Referer")
        let path = request.url?.absoluteString
        let (status, body): (Int, Data) = Self.lock.withLock {
            Self.storedUA = ua
            Self.storedReferer = referer
            Self.storedPath = path
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
