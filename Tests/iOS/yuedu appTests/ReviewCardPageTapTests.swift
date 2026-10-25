@testable import YueduCoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

/// Feedback #86 (TestFlight 3.0.0 (140), iOS 26.3, 起点 qimo): on a page holding nothing but a
/// 本章说 card, tapping the previous-page zone did nothing, and the log repeated
/// `⟐ link.tap unresolved … href=ydreview://…`. The blank page snapped to the card's line, so
/// the page claimed the tap as a link and handed the review href to page navigation.
@Suite("A review card alone on its page", .serialized)
@MainActor
struct ReviewCardPageTapTests {
    private let page = CGSize(width: 393, height: 852)
    private let insets = UIEdgeInsets(top: 70, left: 22, bottom: 50, right: 22)
    private let chapterSayURL = "https://example.com/chapter-say"

    /// 起点 qimo's iOS-runtime card: the handler sits on the image itself (`rewriteImageHandlerTag`).
    /// A PNG instead of the source's SVG keeps WebKit out of the test; it is not a bubble either,
    /// so it still becomes a block card.
    private var chapterSayCard: String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: CGSize(width: 1080, height: 600), format: format).pngData { context in
            UIColor.systemGray5.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1080, height: 600))
        }
        return #"<img src="data:image/png;base64,\#(png.base64EncodedString())" onClick="java.startBrowser('\#(chapterSayURL)','本章说')"/>"#
    }

    @Test("a tap on the blank part of the card's page turns the page")
    func blankTapFallsThroughToPageTurn() async throws {
        let (view, card) = try await cardAlonePage()
        // Inside the card's horizontal span, so the line's x tolerance alone cannot reject it:
        // only the distance from the card's line can.
        let x = card.rect.minX + card.rect.width * 0.15
        let y = card.rect.maxY + 80 < page.height - insets.bottom
            ? card.rect.maxY + 80
            : card.rect.minY - 80
        let point = CGPoint(x: x, y: y)
        try #require(point.x < page.width / 3, "not in the previous-page zone")
        try #require(y > insets.top && y < page.height - insets.bottom, "no blank part on the page")

        #expect(view.debugShouldHandleTap(at: point) == false, "the page claimed a tap on blank space")

        var reached: [String] = []
        view.onInternalLinkTap = { reached.append("link \($0.prefix(24))") }
        view.onImageAttachmentTap = { _ in reached.append("attachment") }
        view.onReviewTap = { _ in reached.append("review") }
        view.debugHandleTap(at: point)
        #expect(reached.isEmpty, "blank space acted on: \(reached)")
    }

    @Test("a tap on the card opens its review")
    func cardTapOpensReview() async throws {
        let (view, card) = try await cardAlonePage()
        let point = CGPoint(x: card.rect.midX, y: card.rect.midY)
        #expect(view.debugShouldHandleTap(at: point))

        var opened: CoreTextPaginator.RenderedAttachment?
        var navigated: String?
        view.onImageAttachmentTap = { opened = $0 }
        view.onInternalLinkTap = { navigated = $0 }
        view.debugHandleTap(at: point)
        let href = try #require(opened?.linkHref, "the card's tap did not reach the review sheet's handler")
        #expect(ReaderHTMLUtilities.reviewTarget(fromHref: href)?.url == chapterSayURL)
        #expect(navigated == nil, "the review href went to page navigation")
    }

    /// A tap can land on a review link's character without landing on its badge image: inside
    /// the line, just outside the badge's hit slop. That reaches the text-link branch, which
    /// used to hand the href to page navigation and log `link.tap unresolved`.
    @Test("a review link reached through its text opens the review, not navigation")
    func reviewLinkThroughTextOpensReview() async throws {
        let marker = ReaderHTMLUtilities.rewriteReviewComments(
            #"<comment count="2" onClick="java.startBrowser('https://example.com/r?p=1','段评')"/>"#
        )
        let layout = try await layout(html: "<p>短句。\(marker)</p>")
        let bubble = try #require(reviewAttachments(on: layout, page: 0).first)
        let view = pageView(layout, page: 0)
        // The page's first line: nothing above it to be nearer. 9pt clears the badge's 8pt slop.
        let point = CGPoint(x: bubble.rect.midX, y: bubble.rect.minY - 9)

        var opened: ReaderHTMLUtilities.ReviewTarget?
        var reached: [String] = []
        view.onReviewTap = { opened = $0 }
        view.onInternalLinkTap = { reached.append("link \($0.prefix(24))") }
        view.onImageAttachmentTap = { _ in reached.append("attachment") }
        #expect(view.debugShouldHandleTap(at: point))
        view.debugHandleTap(at: point)
        #expect(opened?.url == "https://example.com/r?p=1")
        #expect(reached.isEmpty, "the review link went elsewhere: \(reached)")
    }

    // MARK: - Fixture

    /// The chapter's prose, then its 本章说 card, with just enough prose that the card no longer
    /// fits under it and opens the last page alone. (A chapter of nothing but the card is a
    /// different page altogether: `imagePage`, no text layout at all.)
    private func cardAlonePage() async throws -> (CoreTextPageView, CoreTextPaginator.RenderedAttachment) {
        let card = chapterSayCard
        var found: (CoreTextPageView, CoreTextPaginator.RenderedAttachment)?
        for paragraphs in 1...40 where found == nil {
            let prose = (0..<paragraphs).map { "<p>\(String(repeating: "字", count: 30))\($0)</p>" }.joined()
            let cleaned = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(prose + card)
            try #require(cleaned.contains("yd-review-image"), "the card lost its review anchor")
            let layout = try await layout(html: cleaned)
            guard let pageIndex = layout.pageRanges.indices.last,
                  let attachment = reviewAttachments(on: layout, page: pageIndex).first
            else { continue }
            let range = layout.pageRanges[pageIndex]
            let text = (layout.attributedString.string as NSString)
                .substring(with: NSRange(location: range.location, length: range.length))
            guard text.unicodeScalars.allSatisfy({
                $0 == "\u{FFFC}" || CharacterSet.whitespacesAndNewlines.contains($0)
            }) else { continue }
            try #require(attachment.rect.width > page.width / 2, "the card is not full-width")
            found = (pageView(layout, page: pageIndex), attachment)
        }
        return try #require(found, "no amount of prose left the card alone on its page")
    }

    private func reviewAttachments(
        on layout: CoreTextPaginator.ChapterLayout,
        page: Int
    ) -> [CoreTextPaginator.RenderedAttachment] {
        ((layout.inlineAttachments[page] ?? []) + (layout.blockAttachments[page] ?? [])
            + (layout.blockRenderables[page] ?? []).compactMap(\.imageAttachment))
            .filter { $0.linkHref?.hasPrefix("ydreview://") == true }
    }

    private func pageView(_ layout: CoreTextPaginator.ChapterLayout, page: Int) -> CoreTextPageView {
        let view = CoreTextPageView(frame: CGRect(origin: .zero, size: layout.renderSize))
        view.configure(layout: layout, pageIndex: page)
        return view
    }

    private func layout(html: String) async throws -> CoreTextPaginator.ChapterLayout {
        // The page, as the reader passes its viewport: the builder takes the insets off itself.
        let builder = OnlineProviderAttributedStringBuilder(
            provider: ReviewCardChapterProvider(html: html),
            renderSize: page
        )
        let built = try await builder.buildChapter(
            at: 0,
            settings: ReaderRenderSettings(
                theme: "test", textColor: .black, backgroundColor: .white,
                fontSize: 20, lineHeightMultiple: 1.6, lineSpacing: 0, paragraphSpacing: 10,
                letterSpacing: 0, marginH: insets.left, marginV: insets.bottom, footerHeight: 0,
                contentInsets: insets, writingMode: .horizontal
            ),
            themeTextColor: .black,
            themeBackgroundColor: .white
        )
        return await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: LayoutShared(built.attributedString).wrappedValue,
            renderSize: page,
            fontSize: 20,
            contentInsets: insets
        )
    }
}

/// An untitled chapter: what is on its pages is exactly what the test put there.
private final class ReviewCardChapterProvider: BookContentProvider {
    private let html: String

    init(html: String) {
        self.html = html
    }

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String { "" }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        ChapterContentPayload(
            index: 0,
            title: "",
            plainText: "",
            body: .html(html),
            sourceHref: "https://example.com/1"
        )
    }
}
