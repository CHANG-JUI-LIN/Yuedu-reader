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
