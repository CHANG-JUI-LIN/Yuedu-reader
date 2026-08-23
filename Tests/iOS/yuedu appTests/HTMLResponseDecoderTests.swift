import Foundation
import Testing

@testable import yuedu_app

/// Charset decoding for source responses.
///
/// The failure these cover, reported 2026-08-23 with a screenshot: the chapter title rendered as
/// proper Chinese while the body was `è ± å° å®¶ææ¯æ¥` — UTF-8 bytes shown one-per-character,
/// i.e. decoded as ISO-8859-1. A single-byte Latin encoding decodes *any* byte sequence without
/// producing U+FFFD, so "it decoded without replacement characters" says nothing about whether it
/// was the right encoding, and must never be treated as high confidence.
@Suite("HTML response decoding")
struct HTMLResponseDecoderTests {

    private func response(contentType: String?, url: String = "https://example.com/1.html") -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: contentType.map { ["Content-Type": $0] } ?? [:]
        )!
    }

    private static let chineseBody = """
    <html><head><meta charset="utf-8"><title>克莱尔</title></head>
    <body><div id="content">她推开家门，屋子里没有开灯，只有窗外的路灯照进来一点光。<br>
    他坐在沙发上，手里握着一杯早就凉透的茶。</div></body></html>
    """

    @Test("a server that mislabels UTF-8 as ISO-8859-1 still decodes as UTF-8")
    func mislabeledLatin1ServerStillDecodesUTF8() throws {
        let data = Data(Self.chineseBody.utf8)
        let decoded = try #require(
            HTMLResponseDecoder.decode(
                data: data,
                response: response(contentType: "text/html; charset=ISO-8859-1")
            )
        )
        #expect(decoded.contains("她推开家门"), "decoded=>>>\(decoded.prefix(120))<<<")
        #expect(!decoded.contains("å"), "mojibake leaked: \(decoded.prefix(120))")
    }

    @Test("a server with no charset falls back to the document's own meta charset")
    func noCharsetHeaderUsesMetaCharset() throws {
        let data = Data(Self.chineseBody.utf8)
        let decoded = try #require(
            HTMLResponseDecoder.decode(data: data, response: response(contentType: "text/html"))
        )
        #expect(decoded.contains("她推开家门"), "decoded=>>>\(decoded.prefix(120))<<<")
    }

    @Test("a correctly declared GBK response still decodes as GBK")
    func declaredGBKDecodesAsGBK() throws {
        let gbkHTML = "<html><head><meta charset=\"gbk\"></head><body><div id=\"content\">她推开家门，屋子里没有开灯。</div></body></html>"
        let encoding = HTMLResponseDecoder.gbkEncoding
        let data = try #require((gbkHTML as NSString).data(using: encoding.rawValue))
        let decoded = try #require(
            HTMLResponseDecoder.decode(
                data: data,
                response: response(contentType: "text/html; charset=gbk")
            )
        )
        #expect(decoded.contains("她推开家门"), "decoded=>>>\(decoded.prefix(120))<<<")
    }

    @Test("a genuinely Latin-1 page still decodes as Latin-1")
    func genuineLatin1StillDecodes() throws {
        let latinHTML = "<html><body><p>Voilà, une café très chère, naïve résumé.</p></body></html>"
        let data = try #require(latinHTML.data(using: .isoLatin1))
        let decoded = try #require(
            HTMLResponseDecoder.decode(
                data: data,
                response: response(contentType: "text/html; charset=ISO-8859-1")
            )
        )
        #expect(decoded.contains("Voilà"), "decoded=>>>\(decoded.prefix(120))<<<")
        #expect(decoded.contains("très chère"), "decoded=>>>\(decoded.prefix(120))<<<")
    }

    @Test("the JS bridge decodes a mislabeled response the same way")
    func jsBridgeMatchesDecoder() throws {
        let data = Data(Self.chineseBody.utf8)
        let decoded = LegadoJSBridge.decodeData(
            data,
            response: response(contentType: "text/html; charset=ISO-8859-1")
        )
        #expect(decoded.contains("她推开家门"), "decoded=>>>\(decoded.prefix(120))<<<")
    }
}
