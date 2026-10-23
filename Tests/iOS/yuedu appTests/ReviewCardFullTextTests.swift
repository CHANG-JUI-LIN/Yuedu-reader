import Foundation
import Testing
@testable import yuedu_app

/// 起点读书qm's 热评 card cuts a comment to 18 characters plus `...` before drawing it. The
/// chapter must still reach a reader's template with the whole comment — taken from the
/// `/api/godcomments` response the content rule fetched, through the source's own `[fn=N]`
/// replacer — while the source's own drawing of the card stays as the source drew it.
@Suite("Review card full text", .serialized)
struct ReviewCardFullTextTests {
    /// 起点读书qm's own card code, verbatim but for a shorter face map.
    private static let jsLib = #"""
    function escapeXml(s) {
    return String(s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&apos;");
    }
    function replaceEmoji(str) {
    if (!str) return "";
    const MAP = { 11:"🙄", 19:"😂" };
    return str.replace(/\[fn=(\d+)\]/g, (m, id) => MAP[id] || m);
    }
    function createGodCommentSvg(godItem) {
    const w = 1000, h = 140, pad = 32, tw = 140, th = 56, cy = h / 2 + 14;
    const txt = escapeXml.call(this, replaceEmoji(godItem.text || godItem.Content || ""));
    const dtxt = txt.length > 18 ? txt.slice(0, 18) + "..." : txt;
    return `<svg width="${w}" height="${h}" xmlns="http://www.w3.org/2000/svg">
    <rect width="100%" height="100%" fill="rgba(255,255,255,0.5)" rx="70"/>
    <rect x="${pad}" y="${(h-th)/2}" width="${tw}" height="${th}" rx="30" fill="#FF4444"/>
    <text x="${pad+tw/2}" y="${cy}" font-size="32" fill="#FFF" text-anchor="middle" font-weight="bold">热评</text>
    <text x="${pad+tw+24}" y="${cy}" font-size="40" fill="#000" font-weight="bold">${dtxt}</text>
    </svg>`;
    }
    """#

    /// The content rule's shape: fetch the chapter's god comments, hang each card under its
    /// paragraph.
    private static let contentRule = """
    <js>
    var god = JSON.parse(java.ajax('https://\(GodCommentsURLProtocol.host)/api/godcomments?bookId=1&chapterId=2')).Data.Reviews;
    var paras = ['', '第一段。', '第二段。', '第三段。'];
    god.forEach(function (item) {
        var b64 = java.base64Encode(createGodCommentSvg.call(this, item));
        paras[item.ParagraphId] += '<img src="data:image/svg+xml;base64,' + b64 + ',{"style":"FULL","type":"god","click":"showQdCmt(1,2,' + item.ParagraphId + ')"}">';
    });
    paras.slice(1).join('<br>');
    </js>
    """

    private func cards(in html: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"data:image/svg\+xml;base64,([A-Za-z0-9+/=]+)"#)
        let ns = html as NSString
        return regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            Data(base64Encoded: ns.substring(with: match.range(at: 1))).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    @Test("a 热评 the source cut reads whole after the chapter build")
    func cutHotCommentReadsWhole() async throws {
        var source = BookSource(
            bookSourceUrl: "https://\(GodCommentsURLProtocol.host)",
            bookSourceName: "起点读书qm fixture"
        )
        source.lastUpdateTime = Int64.random(in: 1...Int64.max)
        source.jsLib = Self.jsLib
        source.ruleContent.content = Self.contentRule
        let bridge = ModernParserBridge(source: source, requestSession: GodCommentsURLProtocol.session())
        let chapter = OnlineChapterRef(index: 0, title: "第一章", url: "https://\(GodCommentsURLProtocol.host)/chapter/2")

        let parsed = try bridge.parseChapterResult(
            html: "fixture",
            baseURL: chapter.url,
            source: source,
            chapterRef: chapter
        )
        let html = await ChapterFetcher.shared.buildRenderableNormalizedHTML(
            title: "第一章",
            plainTextContent: "第一段。\n第二段。\n第三段。",
            rawHTMLContent: parsed.content,
            reviewContext: ReaderHTMLUtilities.LegadoReviewContext(
                sourceName: source.bookSourceName,
                sourceURL: chapter.url
            )
        )

        let svgs = try cards(in: html)
        #expect(svgs.count == 3)
        let comments = svgs.compactMap { ReviewCardContent.extract(from: $0)?.comments.first?.content }
        #expect(comments == [
            "很有道理……无法反驳。",
            "第一次看到把煤气欠费写得那么惊心动魄的小说🙄",
            "😂本文为了提升更文效率，防止作者拖更，每章都在凌晨三点发出来，我已经习惯了",
        ])
        // The source's own drawing is untouched: still its 18 characters and `...`.
        #expect(svgs[2].contains(">😂本文为了提升更文效率，防止作者拖...</text>"))
    }

    @Test("a cut comment's beginning, without the mark or a half character")
    func cutPrefix() {
        #expect(ReviewCardFullText.cutPrefix(of: "本文为了提升更文效率，防止作者拖更，...") == "本文为了提升更文效率，防止作者拖更，")
        #expect(ReviewCardFullText.cutPrefix(of: "好好看⋯") == "好好看")
        #expect(ReviewCardFullText.cutPrefix(of: "好好看……") == "好好看")
        #expect(ReviewCardFullText.cutPrefix(of: "好好看…") == "好好看")
        #expect(ReviewCardFullText.cutPrefix(of: "好好看\u{FFFD}...") == "好好看")
        #expect(ReviewCardFullText.cutPrefix(of: "研发部门R&am...") == "研发部门R")
        #expect(ReviewCardFullText.cutPrefix(of: "好好看") == nil)
    }

    @Test("a cut comment takes the one text it begins, and only that one")
    func fullTextMatching() {
        let full = "本文为了提升更文效率，防止作者拖更，每章都在凌晨三点发出来"
        #expect(ReviewCardFullText.fullText(of: "本文为了提升更文效率，防止作者拖更，...", among: ["无关", full]) == full)
        // Wrapped and collapsed by the source as it drew the card.
        #expect(ReviewCardFullText.fullText(of: "本文为了 提升更文效率...", among: [full]) == full)
        #expect(ReviewCardFullText.fullText(of: "本文为了提升更文效率，防止作者拖更，...", among: [full + "\n"]) == full)
        // Two different comments begin this way: neither is known to be it.
        #expect(ReviewCardFullText.fullText(of: "本文为了提升...", among: [full, "本文为了提升作者的收入"]) == nil)
        // Too little left to tell comments apart.
        #expect(ReviewCardFullText.fullText(of: "本文...", among: [full]) == nil)
        #expect(ReviewCardFullText.fullText(of: "本文为了提升更文效率", among: [full]) == nil)
    }
}

/// `/api/godcomments` as 起点 answers it: the comments under `Data.Reviews`, one of them with a
/// face code inside the part the card keeps, one with a face code after it.
private final class GodCommentsURLProtocol: URLProtocol {
    static let host = "godcomments.test"

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GodCommentsURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let body: [String: Any] = [
            "Data": [
                "Reviews": [
                    ["Content": "很有道理……无法反驳。", "ParagraphId": 1, "ReviewId": 11],
                    ["Content": "第一次看到把煤气欠费写得那么惊心动魄的小说[fn=11]", "ParagraphId": 2, "ReviewId": 12],
                    ["Content": "[fn=19]本文为了提升更文效率，防止作者拖更，每章都在凌晨三点发出来，我已经习惯了", "ParagraphId": 3, "ReviewId": 13],
                ],
            ],
            "Message": "",
            "Result": 0,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json; charset=utf-8"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
