import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

// MARK: - Test Fixtures

private final class FixedChapterContentProvider: BookContentProvider {
    let payloads: [ChapterContentPayload]

    init(_ payloads: [ChapterContentPayload]) {
        self.payloads = payloads
    }

    var totalChapters: Int { payloads.count }

    func chapterTitle(at index: Int) -> String {
        payloads[index].title
    }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard payloads.indices.contains(index) else {
            throw BookContentProviderError.chapterIndexOutOfRange(index)
        }
        return payloads[index]
    }
}

private final class ThrowingChapterContentProvider: BookContentProvider {
    let error: Error
    let chapterCount: Int

    init(error: Error, chapterCount: Int) {
        self.error = error
        self.chapterCount = chapterCount
    }

    var totalChapters: Int { chapterCount }

    func chapterTitle(at index: Int) -> String { "第\(index + 1)章" }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        throw error
    }
}

// MARK: - Online reader pipeline unification

@Suite("Online reader pipeline unification", .serialized)
@MainActor
struct OnlineReaderPipelineUnificationTests {

    // MARK: - Render body explicit typing

    @Test("render body makes HTML versus text explicit")
    func renderBodyIsExplicit() {
        let html = ChapterRenderBody.html("<p>正文</p>")
        let text = ChapterRenderBody.plainText("正文")

        #expect(html != text)
        #expect(text.byteCount == "正文".lengthOfBytes(using: .utf8))
    }

    // MARK: - Provider HTML paragraph boundaries

    @Test("provider HTML keeps paragraph boundaries")
    func providerHTMLKeepsParagraphs() async throws {
        let provider = FixedChapterContentProvider([
            ChapterContentPayload(
                index: 0,
                title: "第一章",
                plainText: "第一段。\n第二段。",
                body: .html("<p>第一段。</p><p>第二段。</p>"),
                sourceHref: "https://example.com/1"
            )
        ])
        let builder = OnlineProviderAttributedStringBuilder(
            provider: provider,
            renderSize: CGSize(width: 320, height: 480)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.settings,
            themeTextColor: UIColor.label,
            themeBackgroundColor: UIColor.systemBackground
        )

        #expect(result.attributedString.string.contains("第一段。"))
        #expect(result.attributedString.string.contains("第二段。"))
        let firstRange = try #require(result.attributedString.string.range(of: "第一段。"))
        let secondRange = try #require(result.attributedString.string.range(of: "第二段。"))
        #expect(firstRange.upperBound < secondRange.lowerBound)
    }

    @Test("single HTML paragraph wrapping source newlines renders as distinct paragraphs")
    func singleHTMLParagraphWithInteriorNewlinesRendersDistinctParagraphs() async throws {
        let normalizedHTML = await ChapterFetcher.shared.buildRenderableNormalizedHTML(
            title: "第一章",
            plainTextContent: "第一段。\n第二段。\n第三段。\n第四段。",
            rawHTMLContent: "<p>第一段。\r\n　　第二段。\r\n　　第三段。\r\n　　第四段。</p>"
        )
        #expect(
            normalizedHTML.components(separatedBy: "<p>").count - 1 == 4,
            "normalizedHTML=>>>\(normalizedHTML)<<<"
        )
        let provider = FixedChapterContentProvider([
            ChapterContentPayload(
                index: 0,
                title: "第一章",
                plainText: "第一段。\n第二段。\n第三段。\n第四段。",
                body: .html(normalizedHTML),
                sourceHref: "https://example.com/1"
            )
        ])
        let builder = OnlineProviderAttributedStringBuilder(
            provider: provider,
            renderSize: CGSize(width: 320, height: 480)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.settings,
            themeTextColor: UIColor.label,
            themeBackgroundColor: UIColor.systemBackground
        )
        let lines = result.attributedString.string
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "第一章" }

        #expect(lines == ["第一段。", "第二段。", "第三段。", "第四段。"], "actual=>>>\(result.attributedString.string)<<<")
    }

    @Test("leading title review image joins the chapter heading")
    func leadingTitleReviewImageJoinsChapterHeading() async throws {
        let svg = ##"<svg width="850" height="850" xmlns="http://www.w3.org/2000/svg"><rect width="850" height="850" rx="180" fill="#A9A9A9"/><text x="425" y="425">2</text></svg>"##
        let base64 = Data(svg.utf8).base64EncodedString()
        let clickConfig = #"{"style":"text","type":"qd","click":"showCmt(123, 456, -1, 999, 'ios', '改版')"}"#
        let titleBubble = "<img src=\"data:image/svg+xml;base64,\(base64),\(clickConfig)\">"
        let normalizedHTML = await ChapterFetcher.shared.buildRenderableNormalizedHTML(
            title: "第251章 找到剑虎兰龙雀的巫师剑买家！",
            plainTextContent: "莫泊桑家族的小公主看着洛克从外面走廊走来。",
            rawHTMLContent: "\(titleBubble)\n莫泊桑家族的小公主看着洛克从外面走廊走来。",
            reviewContext: ReaderHTMLUtilities.LegadoReviewContext(
                sourceName: "神魔小说",
                sourceURL: "https://shenmoxs.top"
            )
        )

        let h1Start = try #require(normalizedHTML.range(of: "<h1>"))
        let h1End = try #require(normalizedHTML.range(of: "</h1>", range: h1Start.upperBound..<normalizedHTML.endIndex))
        let headingHTML = String(normalizedHTML[h1Start.lowerBound..<h1End.upperBound])
        let bodyHTML = String(normalizedHTML[h1End.upperBound...])

        #expect(headingHTML.contains("第251章 找到剑虎兰龙雀的巫师剑买家！"))
        #expect(headingHTML.contains(#"class="yd-review-image""#))
        #expect(headingHTML.contains(#"data-yd-imgstyle="text""#))
        #expect(!bodyHTML.contains(#"class="yd-review-image""#))
        #expect(bodyHTML.contains("莫泊桑家族的小公主看着洛克从外面走廊走来。"))

        let provider = FixedChapterContentProvider([
            ChapterContentPayload(
                index: 0,
                title: "第251章 找到剑虎兰龙雀的巫师剑买家！",
                plainText: "莫泊桑家族的小公主看着洛克从外面走廊走来。",
                body: .html(normalizedHTML),
                sourceHref: "https://shenmoxs.top/chapter?bookId=123&chapterId=456"
            )
        ])
        let rendered = try await OnlineProviderAttributedStringBuilder(
            provider: provider,
            renderSize: CGSize(width: 640, height: 480)
        ).buildChapter(
            at: 0,
            settings: Self.settings,
            themeTextColor: .label,
            themeBackgroundColor: .systemBackground
        ).attributedString
        let renderedNSString = rendered.string as NSString
        let titleRange = renderedNSString.range(of: "第251章 找到剑虎兰龙雀的巫师剑买家！")
        let attachmentRange = renderedNSString.range(of: "\u{FFFC}")
        try #require(titleRange.location != NSNotFound)
        try #require(attachmentRange.location != NSNotFound)
        let titleParagraphRange = renderedNSString.paragraphRange(for: titleRange)

        #expect(NSLocationInRange(attachmentRange.location, titleParagraphRange))
        let attachmentFont = try #require(
            rendered.attribute(.font, at: attachmentRange.location, effectiveRange: nil) as? UIFont
        )
        #expect(abs(attachmentFont.pointSize - Self.settings.titleSize) < 0.5)
        let reviewHref = try #require(
            rendered.attribute(
                HTMLAttributedStringBuilder.internalLinkAttribute,
                at: attachmentRange.location,
                effectiveRange: nil
            ) as? String
        )
        #expect(ReaderHTMLUtilities.isTitleReviewHref(reviewHref))
    }

    // MARK: - Provider cache miss becomes engine signal

    @Test("provider cache miss becomes engine contentNotCached")
    func providerCacheMissBecomesEngineSignal() async {
        let provider = ThrowingChapterContentProvider(
            error: BookContentProviderError.contentNotCached(0),
            chapterCount: 1
        )
        let builder = OnlineProviderAttributedStringBuilder(
            provider: provider,
            renderSize: CGSize(width: 320, height: 480)
        )

        await #expect(throws: AttributedStringBuildingError.contentNotCached(0)) {
            try await builder.buildChapter(
                at: 0,
                settings: Self.settings,
                themeTextColor: UIColor.label,
                themeBackgroundColor: UIColor.systemBackground
            )
        }
    }

    // MARK: - Legacy parity: provider builder renders paragraph review badges from cached normalized HTML

    @Test("provider builder renders paragraph review badges from cached normalized HTML")
    func providerBuilderRendersReviewBadgesFromCachedHTML() async throws {
        let reviewHTML = #"""
        <html><body>
        <div rs-native>一个老旧的钨丝灯被黑色的电线悬在屋子中央，闪烁着昏暗的光芒。
        <comment count="99" onPress="java.showReadingBrowser('https://v6.gyks.cf/get_para_review?book_id=1&amp;ssionid=abc')">
        </div>
        </body></html>
        """#
        let provider = FixedChapterContentProvider([
            ChapterContentPayload(
                index: 0,
                title: "第一章",
                plainText: "一个老旧的钨丝灯被黑色的电线悬在屋子中央，闪烁着昏暗的光芒。",
                body: .html(reviewHTML),
                sourceHref: "https://example.com/books/1/chapter.html"
            )
        ])
        let builder = OnlineProviderAttributedStringBuilder(
            provider: provider,
            renderSize: CGSize(width: 320, height: 480)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.renderSettings(),
            themeTextColor: UIColor.label,
            themeBackgroundColor: UIColor.systemBackground
        )

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
        #expect(attr.string.contains("一个老旧的钨丝灯"))
    }

    @Test("rs-native review blocks keep online paragraph geometry")
    func nativeReviewBlocksKeepOnlineParagraphGeometry() async throws {
        // Exact structure emitted by 大灰狼起点.getCommentsios when 段評 is enabled.
        let reviewHTML = #"""
        <html><body><article id="reader-content">
        <h1>第177章 让我也成为你们的主人吧</h1>
        <div rs-native>白豆蔻农场之中的第一段正文。<comment count="4" onPress="java.showReadingBrowser('https://qd.doubi.tk/comments?bookId=1&amp;chapterId=2&amp;paragraphId=1','起点段评')"></comment></div>
        <div rs-native>这是构筑师的第二段正文。</div>
        <div rs-native>洛克知道眼前还有第三段正文。</div>
        </article></body></html>
        """#
        let provider = FixedChapterContentProvider([
            ChapterContentPayload(
                index: 0,
                title: "第177章 让我也成为你们的主人吧",
                plainText: "白豆蔻农场之中的第一段正文。\n这是构筑师的第二段正文。\n洛克知道眼前还有第三段正文。",
                body: .html(reviewHTML),
                sourceHref: "https://m.qidian.com/chapter/1/2/"
            )
        ])
        let builder = OnlineProviderAttributedStringBuilder(
            provider: provider,
            renderSize: CGSize(width: 320, height: 640)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.settings,
            themeTextColor: UIColor.label,
            themeBackgroundColor: UIColor.systemBackground
        )
        let attributed = result.attributedString
        let ns = attributed.string as NSString
        let bodyTexts = [
            "白豆蔻农场之中的第一段正文。",
            "这是构筑师的第二段正文。",
            "洛克知道眼前还有第三段正文。",
        ]
        let bodyStarts = try bodyTexts.map { text -> Int in
            let range = ns.range(of: text)
            return try #require(range.location == NSNotFound ? nil : range.location)
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: attributed.length),
            CGPath(rect: CGRect(x: 0, y: 0, width: 320, height: 640), transform: nil),
            nil
        )
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: lines.count), &origins)

        let bodyOrigins = try bodyStarts.map { start -> CGPoint in
            let lineIndex = try #require(
                lines.firstIndex { CTLineGetStringRange($0).location == start }
            )
            return origins[lineIndex]
        }
        for (start, origin) in zip(bodyStarts, bodyOrigins) {
            let paragraph = try #require(
                attributed.attribute(.paragraphStyle, at: start, effectiveRange: nil)
                    as? NSParagraphStyle
            )
            #expect(abs(paragraph.firstLineHeadIndent - Self.settings.fontSize * 2) < 0.5)
            #expect(abs(paragraph.paragraphSpacing - Self.settings.paragraphSpacing) < 0.5)
            #expect(abs(origin.x - Self.settings.fontSize * 2) < 0.5)
        }
        for index in 1..<bodyOrigins.count {
            let baselineGap = bodyOrigins[index - 1].y - bodyOrigins[index].y
            #expect(baselineGap > Self.settings.fontSize * Self.settings.lineHeightMultiple)
        }
    }

    // MARK: - Legacy parity: provider builder renders cached HTML images

    @Test("provider builder renders cached HTML images")
    func providerBuilderRendersCachedHTMLImages() async throws {
        let imageData = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 6)).pngData { ctx in
            UIColor.systemRed.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        }
        let html = #"""
        <html><body>
        <p>图前<img src="data:image/png;base64,\#(imageData.base64EncodedString())" alt="inline">图后</p>
        </body></html>
        """#
        let provider = FixedChapterContentProvider([
            ChapterContentPayload(
                index: 0,
                title: "第一章",
                plainText: "图前图后",
                body: .html(html),
                sourceHref: "https://example.com/books/1/chapter.html"
            )
        ])
        let builder = OnlineProviderAttributedStringBuilder(
            provider: provider,
            renderSize: CGSize(width: 320, height: 480)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.renderSettings(),
            themeTextColor: UIColor.label,
            themeBackgroundColor: UIColor.systemBackground
        )

        #expect(result.attributedString.string.contains("\u{FFFC}"))
        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var foundImageAttachment = false
        result.attributedString.enumerateAttribute(
            delegateKey,
            in: NSRange(location: 0, length: result.attributedString.length)
        ) { value, _, _ in
            if value != nil {
                foundImageAttachment = true
            }
        }
        #expect(foundImageAttachment)
    }

    @Test("本章说 card img survives the provider HTML pipeline and renders an attachment")
    func chapterCommentCardSurvivesProviderPipeline() async throws {
        // The 起点 本章说 card is emitted by getComments() as an <img> whose data-URI src carries a
        // trailing Legado click-config: data:image/svg+xml;base64,<B64>,{"style":"FULL",...}. The
        // inner double-quotes of that suffix sit INSIDE the src="" attribute, so an HTML parser
        // terminates the attribute early unless the suffix is stripped first. ChapterFetcher
        // sanitizes it, but the provider path (OnlineProviderAttributedStringBuilder) does not —
        // this test reproduces the user's "本章说 doesn't show" through that exact path.
        let cardSVG = ##"<svg width="1080" height="700" xmlns="http://www.w3.org/2000/svg"><rect width="1080" height="700" fill="rgba(255,255,255,0.25)" rx="35"/><text x="80" y="75" font-size="44" fill="#000">本章说</text><text x="80" y="280" font-size="42" fill="#000">绝傲蜀风</text></svg>"##
        let b64 = Data(cardSVG.utf8).base64EncodedString()
        let clickConfig = #"{"style":"FULL","type":"qd","click":"androidshowChapterComments(1,2,3)"}"#
        let cardImg = "<img src=\"data:image/svg+xml;base64,\(b64),\(clickConfig)\">"
        let html = "<p>正文段落。</p>\n\(cardImg)"

        let provider = FixedChapterContentProvider([
            ChapterContentPayload(
                index: 0,
                title: "第一章",
                plainText: "正文段落。",
                body: .html(html),
                sourceHref: "https://example.com/books/1/chapter.html"
            )
        ])
        let builder = OnlineProviderAttributedStringBuilder(
            provider: provider,
            renderSize: CGSize(width: 320, height: 480)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: Self.renderSettings(),
            themeTextColor: UIColor.label,
            themeBackgroundColor: UIColor.systemBackground
        )

        let delegateKey = NSAttributedString.Key(kCTRunDelegateAttributeName as String)
        var foundImageAttachment = false
        result.attributedString.enumerateAttribute(
            delegateKey,
            in: NSRange(location: 0, length: result.attributedString.length)
        ) { value, _, _ in
            if value != nil { foundImageAttachment = true }
        }
        #expect(foundImageAttachment, "本章说 card produced no image attachment — it was dropped in the provider HTML pipeline. string=>>>\(result.attributedString.string)<<<")
    }

    @Test("provider images stay inside the reader content column")
    func providerImagesStayInsideContentColumn() async throws {
        let imageData = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 458)).pngData { context in
            UIColor.systemGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 458))
        }
        let provider = FixedChapterContentProvider([
            ChapterContentPayload(
                index: 0,
                title: "第一章",
                plainText: "本章說",
                body: .html("<p>正文</p><img src=\"data:image/png;base64,\(imageData.base64EncodedString())\" alt=\"本章說\">"),
                sourceHref: "https://example.com/books/1/chapter.html"
            )
        ])
        let pageWidth: CGFloat = 430
        let horizontalInset: CGFloat = 32
        let contentWidth = pageWidth - horizontalInset * 2
        let settings = ReaderRenderSettings(
            theme: "test",
            textColor: .label,
            backgroundColor: .systemBackground,
            fontSize: 18,
            lineHeightMultiple: 1.4,
            lineSpacing: 0,
            paragraphSpacing: 8,
            letterSpacing: 0,
            marginH: horizontalInset,
            marginV: 16,
            footerHeight: 0,
            contentInsets: UIEdgeInsets(top: 16, left: horizontalInset, bottom: 16, right: horizontalInset),
            writingMode: .horizontal
        )
        let builder = OnlineProviderAttributedStringBuilder(
            provider: provider,
            renderSize: CGSize(width: pageWidth, height: 800)
        )

        let result = try await builder.buildChapter(
            at: 0,
            settings: settings,
            themeTextColor: UIColor.label,
            themeBackgroundColor: UIColor.systemBackground
        )
        let imageRun = try #require(EPUBTestFixtures.imageRunInfos(in: result.attributedString).first)

        #expect(
            imageRun.info.drawWidth <= contentWidth + 0.5,
            "image width \(imageRun.info.drawWidth) must fit content column \(contentWidth)"
        )
    }

    // MARK: - OnlineChapterContentService cache-only test

    @Test("cache-only service reports missing content")
    func cacheOnlyReportsMissingContent() async throws {
        var book = ReadingBook(
            title: "線上書",
            source: "https://example.com/book",
            contentFilename: ""
        )
        book.isOnline = true
        book.bookSourceId = UUID()
        book.onlineChapters = [
            OnlineChapterRef(index: 0, title: "第一章", url: "https://example.com/1")
        ]

        let service = OnlineChapterContentService(book: book, store: nil)

        await #expect(throws: BookContentProviderError.contentNotCached(0)) {
            try await service.payload(at: 0, policy: .cacheOnly)
        }
    }

    // MARK: - Shared settings

    private static let settings = ReaderRenderSettings(
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
