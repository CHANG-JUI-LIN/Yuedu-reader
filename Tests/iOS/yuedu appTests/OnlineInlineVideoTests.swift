@testable import YueduCoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// 起点's 彩蛋 videos play inline in the page (user's request, 2026-10-10). The source writes a
/// `<video>` whose `src`/`poster` carry a Legado `,{headers}` option; the video CDN answers 403
/// without that `Referer` (measured with curl the same day). Three transforms sit between the
/// source HTML and the player — the fetcher's sanitizer, SwiftSoup, the IR converter — and any
/// of them can drop the option, so this runs the chapter through all of them.
@Suite("Online inline video", .serialized)
@MainActor
struct OnlineInlineVideoTests {

    /// Exactly what the modified 起点读书qm emits for a video 彩蛋 (`qtMidpageContent`).
    private static let videoURL = "https://v.tingbook.com/v.f30.mp4?t=6acb5641&us=1&sign=abc"
    private static let posterURL = "https://127.0.0.1:9/cover.jpg"
    private static let eggHTML = """
        <p>视频:鄙视链顶端的白真真，点击播放键播放</p>
        <video controls src="\(videoURL),{"headers":{"Referer":"https://m.qidian.com/"}}" \
        poster="\(posterURL),{"headers":{"Referer":"https://m.qidian.com/"}}"></video>
        """

    private static func settings() -> ReaderRenderSettings {
        ReaderRenderSettings(
            theme: "sepia", textColor: .black, backgroundColor: .white,
            fontSize: 18, lineHeightMultiple: 1.6, lineSpacing: 10, paragraphSpacing: 8,
            letterSpacing: 0, marginH: 20, marginV: 16, footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20)
        )
    }

    private static func videoAttachment(in attributed: NSAttributedString) -> EPUBMediaAttachment? {
        var found: EPUBMediaAttachment?
        attributed.enumerateAttribute(
            HTMLAttributedStringBuilder.mediaAttachmentAttribute,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            if let media = value as? EPUBMediaAttachment, media.kind == .video {
                found = media
                stop.pointee = true
            }
        }
        return found
    }

    @Test("the egg video reaches the reader with its URL, its Referer and the source's headers")
    func eggVideoEndToEnd() async throws {
        let title = "彩蛋：视频：鄙视链顶端的白真真"
        let normalized = await ChapterFetcher.shared.buildRenderableNormalizedHTML(
            title: title, plainTextContent: "", rawHTMLContent: Self.eggHTML
        )
        #expect(normalized.contains("<video"))

        let payload = ChapterContentPayload(
            index: 0, title: title, plainText: "", body: .html(normalized),
            sourceHref: "https://qdgo.qimo.host/content"
        )
        let built = try await OnlineProviderAttributedStringBuilder(
            provider: InlineVideoStubProvider(payload: payload),
            renderSize: CGSize(width: 400, height: 800),
            imageHeaders: ["User-Agent": "SourceUA/1.0", "Referer": "https://source.example/"]
        ).buildChapter(at: 0, settings: Self.settings(), themeTextColor: .black, themeBackgroundColor: .white)

        let media = try #require(Self.videoAttachment(in: built.attributedString))
        let request = try await EPUBMediaURLResolver.playableRequest(for: media)
        #expect(request.url.absoluteString == Self.videoURL)
        // The video's own option beats the source-wide Referer; the source's UA still rides along.
        #expect(request.headers["Referer"] == "https://m.qidian.com/")
        #expect(request.headers["User-Agent"] == "SourceUA/1.0")
        // The poster keeps its own option for the image loader.
        let poster = OnlineImageRequestOptions.decode(try #require(media.posterHref))
        #expect(poster.src == Self.posterURL)
        #expect(poster.headers["Referer"] == "https://m.qidian.com/")
    }

    private static func build(_ html: String) async throws -> NSAttributedString {
        let normalized = await ChapterFetcher.shared.buildRenderableNormalizedHTML(
            title: "第1章", plainTextContent: "", rawHTMLContent: html
        )
        let payload = ChapterContentPayload(
            index: 0, title: "第1章", plainText: "", body: .html(normalized),
            sourceHref: "https://book.example/chapter/1"
        )
        return try await OnlineProviderAttributedStringBuilder(
            provider: InlineVideoStubProvider(payload: payload),
            renderSize: CGSize(width: 400, height: 800)
        ).buildChapter(at: 0, settings: Self.settings(), themeTextColor: .black, themeBackgroundColor: .white)
            .attributedString
    }

    private static func webEmbed(in attributed: NSAttributedString) -> ReaderWebEmbed? {
        var found: ReaderWebEmbed?
        attributed.enumerateAttribute(
            HTMLAttributedStringBuilder.webEmbedAttribute,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, stop in
            if let embed = value as? ReaderWebEmbed { found = embed; stop.pointee = true }
        }
        return found
    }

    @Test("an iframe pointing at a video file is a video and plays inline")
    func iframeVideoFileIsVideo() async throws {
        let built = try await Self.build(
            #"<p>前文</p><iframe src="https://cdn.example/clip.mp4" title="片段"></iframe><p>後文</p>"#
        )
        let media = try #require(Self.videoAttachment(in: built))
        #expect(media.sourceHref == "https://cdn.example/clip.mp4")
        #expect(Self.webEmbed(in: built) == nil)
    }

    @Test("an iframe page becomes a tap-to-load embed carrying the chapter as Referer")
    func iframePageIsWebEmbed() async throws {
        let built = try await Self.build(
            #"<p>前文</p><iframe src="https://player.example/embed/42" width="640" height="360" title="預告片"></iframe><p>後文</p>"#
        )
        let embed = try #require(Self.webEmbed(in: built))
        #expect(embed.src == "https://player.example/embed/42")
        #expect(embed.title == "預告片")
        #expect(embed.referer == "https://book.example/chapter/1")
        #expect(abs((embed.aspectRatio ?? 0) - 360.0 / 640.0) < 0.001)
        #expect(Self.videoAttachment(in: built) == nil)

        // The paginator hands the embed to the page as part of the drawn card's attachment.
        let layout = await CoreTextPaginator().paginate(
            spineIndex: 0, attrStr: LayoutShared(built).wrappedValue, renderSize: CGSize(width: 400, height: 800),
            fontSize: 18, contentInsets: UIEdgeInsets(top: 40, left: 20, bottom: 40, right: 20)
        )
        let attachments = layout.inlineAttachments.values.flatMap { $0 } + layout.blockAttachments.values.flatMap { $0 }
        let card = try #require(attachments.first { $0.webEmbed != nil })
        guard case .web(let live)? = InlineLiveContent(card) else {
            Issue.record("card is not live web content")
            return
        }
        #expect(live.src == embed.src)
    }

    @Test("a page the source built loads in place, as the address its Referer option names")
    func sourceBuiltPageIsWebEmbed() async throws {
        // What the 彩蛋 player in 起点读书qm（行內影片）writes: the player page with its 弹幕,
        // base64 in the src, and the Referer the page's video request needs.
        let page = #"<!DOCTYPE html><html><body><video src="https://v.tingbook.com/v.mp4?a=1&amp;b=2"></video><script>var D=[{"t":"怎么没人","c":""}];</script></body></html>"#
        let base64 = Data(page.utf8).base64EncodedString()
        let built = try await Self.build(
            #"<p>前文</p><iframe title="彩蛋视频" width="720" height="1280" src="data:text/html;base64,"#
                + base64 + #",{"headers":{"Referer":"https://m.qidian.com/"}}"></iframe><p>後文</p>"#
        )
        let embed = try #require(Self.webEmbed(in: built))
        #expect(embed.title == "彩蛋视频")
        #expect(abs((embed.aspectRatio ?? 0) - 1280.0 / 720.0) < 0.001)
        let inline = try #require(embed.inlinePage)
        #expect(inline.html == page)
        #expect(inline.baseURL?.absoluteString == "https://m.qidian.com/")
        #expect(embed.host == "m.qidian.com")
    }

    @Test("a source-built page without a Referer option loads as the chapter's address")
    func sourceBuiltPageFallsBackToChapter() {
        let html = "<p>hi</p>"
        let embed = ReaderWebEmbed(
            src: "data:text/html;charset=utf-8," + (html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""),
            title: nil, referer: "https://book.example/chapter/1"
        )
        #expect(embed.inlinePage?.html == html)
        #expect(embed.inlinePage?.baseURL?.absoluteString == "https://book.example/chapter/1")
        // A web address is loaded by URL, never as an inline page.
        let address = ReaderWebEmbed(src: "https://player.example/embed/42", title: nil, referer: nil)
        #expect(address.inlinePage == nil)

        // The source's own page shows without a tap; a web address waits for one.
        #expect(InlineLiveContent.web(embed).showsWithoutTap)
        #expect(!InlineLiveContent.web(address).showsWithoutTap)
    }

    @Test("a chapter that is only a video, an audio or an iframe page is content, not an empty chapter")
    func mediaOnlyChapterIsNotEmpty() async {
        // 起点读书qm（行內影片）'s 彩蛋 is its player page alone once the caption moved into it;
        // only images used to count, so it failed as `.emptyContent`.
        for body in [
            #"<iframe title="彩蛋视频" width="720" height="405" src="data:text/html;base64,PHA+aGk8L3A+"></iframe>"#,
            #"<video controls src="https://cdn.example/clip.mp4"></video>"#,
            #"<audio controls src="https://cdn.example/clip.mp3"></audio>"#,
        ] {
            let content = await ChapterFetcher.shared.resolveContent(
                parsed: ChapterParsePayload(content: body, title: "彩蛋章", sourceMatched: true, isPay: false)
            )
            #expect(content.contains(body.prefix(7)), "\(body.prefix(7)) chapter resolved to \(content.debugDescription)")
        }
    }

    @Test("a 1×1 tracking iframe does not become a card")
    func trackingIframeIsNotACard() async throws {
        let built = try await Self.build(
            #"<p>前文</p><iframe src="https://track.example/pixel" width="1" height="1"></iframe><p>後文</p>"#
        )
        #expect(Self.webEmbed(in: built) == nil)
    }

    @Test("a relative iframe is not loaded into a web view")
    func relativeIframeStaysAsItWas() async throws {
        let built = try await Self.build(#"<p>前文</p><iframe src="../inner.html">替代文字</iframe>"#)
        #expect(Self.webEmbed(in: built) == nil)
        #expect(Self.videoAttachment(in: built) == nil)
    }

    @Test("a cover whose js opens a browser page is a tap, not an image to preview")
    func browserOpeningCoverIsATap() throws {
        // Exactly what the original 起点读书qm writes for a video 彩蛋.
        let html = #"<img src="https://v.tingbook.com/cover.jpg,{'type':'qd',"js":"java.startBrowser('https://h5.if.qidian.com/h5/share/middle?bookId=1&chapterId=2&pageId=3','彩蛋视频')",'style':'FULL'}">"#
        let context = ReaderHTMLUtilities.LegadoReviewContext(sourceName: "起点读书qm", sourceURL: "https://qdgo.qimo.host")
        let sanitized = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(html, reviewContext: context)
        let href = try #require(sanitized.range(of: "ydreview://").map { String(sanitized[$0.lowerBound...].prefix { $0 != "\"" }) })
        let target = try #require(ReaderHTMLUtilities.reviewTarget(fromHref: href))
        #expect(target.requiresSourceJS)
        #expect(target.sourceJS.contains("java.startBrowser("))
    }

    @Test("a single-quoted option block carries its headers too, as legado reads it")
    func singleQuotedOptionHeaders() {
        let suffix = ",{'headers':{'Referer':'https://m.qidian.com/'}}"
        #expect(OnlineImageRequestOptions.headers(fromOptionSuffix: suffix)["Referer"] == "https://m.qidian.com/")
    }

    @Test("a media tag without headers loses only its option block")
    func optionWithoutHeadersIsDropped() {
        let html = #"<video src="https://a.example/v.mp4,{'type':'qd'}"></video>"#
        #expect(ReaderHTMLUtilities.carryingMediaRequestHeaders(html) == #"<video src="https://a.example/v.mp4"></video>"#)
    }
}

private struct InlineVideoStubProvider: BookContentProvider {
    let payload: ChapterContentPayload

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String {
        index == payload.index ? payload.title : ""
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard index == payload.index else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }
        return payload
    }
}
