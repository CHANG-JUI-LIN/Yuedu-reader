import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

@Suite("Paragraph review (段評) markers")
struct ParagraphReviewMarkerTests {

    /// Extracts the first href value from an `<a href="…">` in a string.
    private func firstHref(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"href=\"([^\"]*)\""#) else { return nil }
        let ns = html as NSString
        guard let m = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private func firstReviewHref(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"href=\"(ydreview://[^\"]*)\""#) else { return nil }
        let ns = html as NSString
        guard let m = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    @Test("rewrites the iOS paraForiOS comment marker into a ydreview anchor")
    func rewritesMarkerIntoAnchor() throws {
        let raw = #"<div rs-native>第一段文字<comment count="12" onPress="java.showReadingBrowser('https://api.example.com/cmt?book_id=1&amp;ssionid=abc','番茄段评')"></div>"#
        let rewritten = ReaderHTMLUtilities.rewriteReviewComments(raw)

        #expect(!rewritten.contains("<comment"))
        #expect(rewritten.contains("第一段文字"))

        let href = try #require(firstHref(in: rewritten))
        #expect(href.hasPrefix("ydreview://"))

        let marker = try #require(ReaderHTMLUtilities.decodeReviewHref(href))
        #expect(marker.count == "12")
        #expect(marker.title == "番茄段评")
        // &amp; in the HTML attribute must be unescaped back to a real ampersand.
        #expect(marker.url == "https://api.example.com/cmt?book_id=1&ssionid=abc")
    }

    @Test("handles lowercased onpress and an explicit closing tag")
    func handlesLowercasedAndClosedTag() throws {
        let raw = #"<div>章節<comment count="3" onpress="java.showReadingBrowser('https://x.test/y','七猫段评')"></comment></div>"#
        let rewritten = ReaderHTMLUtilities.rewriteReviewComments(raw)

        let href = try #require(firstHref(in: rewritten))
        let marker = try #require(ReaderHTMLUtilities.decodeReviewHref(href))
        #expect(marker.count == "3")
        #expect(marker.url == "https://x.test/y")
        #expect(marker.title == "七猫段评")
    }

    @Test("handles showReadingBrowser markers without an explicit title")
    func handlesSingleArgumentShowReadingBrowser() throws {
        let raw = #"<div>章節<comment count="8" onPress="java.showReadingBrowser('https://x.test/review?book_id=1&amp;ssionid=abc')"></div>"#
        let rewritten = ReaderHTMLUtilities.rewriteReviewComments(raw)

        let href = try #require(firstHref(in: rewritten))
        let marker = try #require(ReaderHTMLUtilities.decodeReviewHref(href))
        #expect(marker.count == "8")
        #expect(marker.url == "https://x.test/review?book_id=1&ssionid=abc")
        #expect(marker.title == "")
    }

    @Test("leaves HTML without comment markers unchanged and is idempotent")
    func leavesPlainHTMLUnchangedAndIdempotent() {
        let plain = "<p>沒有段評的普通段落</p>"
        #expect(ReaderHTMLUtilities.rewriteReviewComments(plain) == plain)

        let raw = #"<div>文字<comment count="5" onPress="java.showReadingBrowser('https://a.test/b','塔读段评')"></div>"#
        let once = ReaderHTMLUtilities.rewriteReviewComments(raw)
        let twice = ReaderHTMLUtilities.rewriteReviewComments(once)
        #expect(once == twice)
    }

    @Test("decodeReviewHref rejects non-review hrefs")
    func rejectsNonReviewHrefs() {
        #expect(ReaderHTMLUtilities.decodeReviewHref("https://example.com/page") == nil)
        #expect(ReaderHTMLUtilities.decodeReviewHref("#chapter-2") == nil)
        #expect(ReaderHTMLUtilities.reviewTarget(fromHref: "https://example.com") == nil)
    }

    @Test("reviewTarget surfaces url and title for sheet presentation")
    func reviewTargetSurfacesURLAndTitle() throws {
        let raw = #"<div>x<comment count="99+" onPress="java.showReadingBrowser('https://r.test/p?a=1&amp;b=2','QQ阅读段评')"></div>"#
        let href = try #require(firstHref(in: ReaderHTMLUtilities.rewriteReviewComments(raw)))
        let target = try #require(ReaderHTMLUtilities.reviewTarget(fromHref: href))
        #expect(target.url == "https://r.test/p?a=1&b=2")
        #expect(target.title == "QQ阅读段评")
    }

    @Test("rewrites qidian image click config into source-image review link")
    func rewritesQidianImageClickConfig() throws {
        let raw = #"<p>段落<img src="data:image/svg+xml;base64,PHN2Zy8+,{"style":"text","type":"qd","click":"showCmt(123, 456, 7, 999,'ios','改版')"}"></p>"#
        let cleaned = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(
            raw,
            reviewContext: ReaderHTMLUtilities.LegadoReviewContext(
                sourceName: "🔅企点小说(禁止🚫分享)",
                sourceURL: "https://m.qidian.com#禁止外传"
            )
        )

        #expect(cleaned.contains(#"class="yd-review-image""#))
        #expect(cleaned.contains(#"src="data:image/svg+xml;base64,PHN2Zy8+""#))
        #expect(!cleaned.contains(#""click":"#))

        let href = try #require(firstHref(in: cleaned))
        let marker = try #require(ReaderHTMLUtilities.decodeReviewHref(href))
        #expect(marker.url == "https://sb.shazi.tk/comments?bookId=123&chapterId=456&paragraphId=7")
        #expect(marker.title == "起點段評")
    }

    @Test("rewrites api qidian image click config with source token")
    func rewritesAPIQidianImageClickConfigWithToken() throws {
        let raw = #"<p>段落<img src="data:image/svg+xml;base64,PHN2Zy8+,{"style":"text","type":"qd","click":"showCmt(123,456,7,999)"}"></p>"#
        let cleaned = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(
            raw,
            reviewContext: ReaderHTMLUtilities.LegadoReviewContext(
                sourceName: "📖起点中文",
                sourceURL: "https://api-x.shrtxs.cn/qd/",
                sourceVariableJSON: #"{"token":"tok-1"}"#
            )
        )

        let href = try #require(firstHref(in: cleaned))
        let marker = try #require(ReaderHTMLUtilities.decodeReviewHref(href))
        #expect(marker.url == "https://api-x.shrtxs.cn/qidth/?bookId=123&chapterId=456&paragraphId=7&token=tok-1")
        #expect(marker.title == "起點段評")
    }

    @Test("paged adapter rewrites raw cached review markers before rendering")
    func pagedAdapterRewritesRawCachedReviewMarkers() async throws {
        let raw = #"""
        <html>
        <body>
        <div rs-native>房间陷入了短暂安静。<comment count="99" onPress="java.showReadingBrowser('https://v6.gyks.cf/get_para_review?book_id=1&amp;ssionid=abc','番茄段评')"></div>
        <a href="/next">下一章</a>
        </body>
        </html>
        """#
        let provider = SingleChapterReviewProvider(html: raw)
        let adapter = UniversalBookResourceAdapter(
            contentProvider: provider,
            chapterSourceHrefs: ["https://example.com/books/1/chapter.html"],
            customScheme: "reader-test"
        )

        let html = try await adapter.chapterHTML(at: 0)

        #expect(!html.localizedCaseInsensitiveContains("<comment"))
        let href = try #require(firstReviewHref(in: html))
        let marker = try #require(ReaderHTMLUtilities.decodeReviewHref(href))
        #expect(marker.count == "99")
        #expect(marker.url == "https://v6.gyks.cf/get_para_review?book_id=1&ssionid=abc")
        #expect(marker.title == "番茄段评")
    }

    @Test("source fetch success reuses persisted render artifacts instead of rewriting from plain text")
    func sourceFetchSuccessReusesPersistedRenderArtifacts() {
        let packageWithReviewHTML = ChapterPackage(
            bookId: UUID(),
            chapterIndex: 4,
            sourceURL: "https://example.com/chapter",
            tocTitle: "Chapter",
            canonicalTitle: "Chapter",
            content: "房间陷入了短暂安静。",
            contentChecksum: "checksum",
            rawHTMLFilename: "4.raw.html",
            normalizedHTMLFilename: "4.normalized.xhtml",
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )

        #expect(OnlineChapterCacheWritePolicy.shouldReusePersistedRenderArtifacts(
            package: packageWithReviewHTML,
            hasBookSource: true
        ))
        #expect(OnlineChapterCacheWritePolicy.contentFilename(chapterIndex: 4) == "4.txt")
        #expect(!OnlineChapterCacheWritePolicy.shouldReusePersistedRenderArtifacts(
            package: packageWithReviewHTML,
            hasBookSource: false
        ))

        let plainPackage = ChapterPackage(
            bookId: UUID(),
            chapterIndex: 5,
            sourceURL: "https://example.com/plain",
            tocTitle: "Plain",
            canonicalTitle: "Plain",
            content: "普通章節",
            contentChecksum: "checksum",
            rawHTMLFilename: nil,
            normalizedHTMLFilename: nil,
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
        #expect(!OnlineChapterCacheWritePolicy.shouldReusePersistedRenderArtifacts(
            package: plainPackage,
            hasBookSource: true
        ))

        let strippedPackage = ChapterPackage(
            bookId: UUID(),
            chapterIndex: 6,
            sourceURL: "https://example.com/stripped",
            tocTitle: "Stripped",
            canonicalTitle: "Stripped",
            content: "只剩純文字的舊快取",
            contentChecksum: "checksum",
            rawHTMLFilename: nil,
            normalizedHTMLFilename: "6.normalized.xhtml",
            savedAt: Date(),
            state: .cached,
            failureReason: nil
        )
        #expect(OnlineChapterCacheWritePolicy.shouldRefetchStrippedRenderArtifacts(
            package: strippedPackage,
            hasBookSource: true
        ))
        #expect(!OnlineChapterCacheWritePolicy.shouldRefetchStrippedRenderArtifacts(
            package: strippedPackage,
            hasBookSource: false
        ))
    }
}

private struct SingleChapterReviewProvider: BookContentProvider {
    let html: String
    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String {
        index == 0 ? "Chapter" : ""
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard index == 0 else { throw BookContentProviderError.chapterIndexOutOfRange(index) }
        return ChapterContentPayload(
            index: index,
            title: "Chapter",
            plainText: "房间陷入了短暂安静。",
            body: .html(html),
            sourceHref: "https://example.com/books/1/chapter.html"
        )
    }
}

@Suite("Online volume separators")
struct OnlineVolumeSeparatorTests {
    @Test("volume ref with empty url renders separator payload")
    func volumeRefWithEmptyURLRendersSeparatorPayload() async throws {
        var book = ReadingBook(
            title: "起点测试书",
            author: "Author",
            source: "https://api-x.shrtxs.cn/qd/",
            contentFilename: ""
        )
        book.isOnline = true
        book.bookSourceId = UUID()
        book.onlineChapters = [
            OnlineChapterRef(index: 0, title: "作品相关", url: "", isVolume: true)
        ]

        let service = OnlineChapterContentService(book: book, store: nil)
        let payload = try await service.payload(at: 0, policy: .cacheOnly)

        #expect(payload.title == "作品相关")
        #expect(payload.plainText == "作品相关")
        #expect(payload.sourceHref == "volume/0")
        if case .html(let html) = payload.body {
            #expect(html.contains("yd-volume-separator"))
        } else {
            Issue.record("Expected .html body for volume separator")
        }
    }
}

@Suite("Paragraph review rendering pipeline")
@MainActor
struct ParagraphReviewRenderingTests {

    /// Drives the real HTML → CoreText pipeline and verifies the marker becomes a tappable
    /// badge: an inline attachment (CTRunDelegate) carrying a `ydreview://` internal link.
    @Test("renders a tappable badge attachment carrying the ydreview link")
    func rendersBadgeAttachment() async throws {
        let raw = #"<body><p>段落文字<comment count="7" onPress="java.showReadingBrowser('https://r.test/p?x=1&amp;y=2','番茄段评')"></p></body>"#
        let html = ReaderHTMLUtilities.rewriteReviewComments(raw)

        let cfg = HTMLAttributedStringBuilder.Config(
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 8,
            firstLineIndent: 0,
            textColor: .label,
            backgroundColor: .systemBackground,
            fontFamilyName: nil,
            renderWidth: 360
        )
        let result = await HTMLAttributedStringBuilder().build(html: html, config: cfg)
        let attr = result.attributedString

        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var foundReviewLink = false
        var linkHasAttachment = false
        attr.enumerateAttribute(
            HTMLAttributedStringBuilder.internalLinkAttribute,
            in: NSRange(location: 0, length: attr.length)
        ) { value, range, _ in
            guard let href = value as? String, href.hasPrefix("ydreview://") else { return }
            foundReviewLink = true
            if attr.attribute(delegateKey, at: range.location, effectiveRange: nil) != nil {
                linkHasAttachment = true
            }
        }

        #expect(foundReviewLink)
        #expect(linkHasAttachment)
        // The body paragraph text must still be present.
        #expect(attr.string.contains("段落文字"))
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
}
