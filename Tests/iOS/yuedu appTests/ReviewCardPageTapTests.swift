@testable import YueduCoreText
import CoreText
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

    /// Scroll mode hit-tests through `CoreTextChunk` and snapped the same way. Its content is
    /// continuous: at the app's default spacing (line height 1.65, paragraphs 0.8em apart, with
    /// line spacing derived as `GlobalSettings` does) no gap is wider than two tap tolerances,
    /// so nothing there is out of reach. Opened up — the sliders go to 2.4 and 1.2em — a tap on
    /// the blank under a 段評 bubble or beside a card opened the review instead of the menu.
    @Test("in scroll mode, blank space between lines is not the review beside it")
    func scrollBlankSpaceIsNotTheReview() async throws {
        let spacings: [(lineHeight: CGFloat, paragraphEm: CGFloat)] = [(1.65, 0.8), (2.0, 1.0), (2.4, 1.2)]
        var reachable: [String] = []
        for spacing in spacings {
            let taps = try await scrollTaps(lineHeight: spacing.lineHeight, paragraphEm: spacing.paragraphEm)
            if !taps.snapped.isEmpty { reachable.append("\(spacing)") }
            #expect(taps.claimed.isEmpty, """
                \(spacing): \(taps.claimed.count) of \(taps.snapped.count) taps on blank space hit a line: \
                \(taps.claimed.prefix(6))
                """)
            #expect(taps.reviewsMissed.isEmpty, "\(spacing): a tap on the review no longer finds it: \(taps.reviewsMissed)")
        }
        try #require(!reachable.isEmpty, "no spacing leaves blank space next to a review: the test reaches nothing")
    }

    /// Taps in one scroll chunk holding prose with 段評 bubbles and a 本章说 card, at the
    /// given spacing: `snapped` are points clear of every line by more than the tap tolerance
    /// that the snapping lookup resolved to a review; `claimed` those a tap still resolves;
    /// `reviewsMissed` bubbles a tap on their middle no longer finds.
    private func scrollTaps(
        lineHeight: CGFloat,
        paragraphEm: CGFloat
    ) async throws -> (snapped: [CGPoint], claimed: [CGPoint], reviewsMissed: [CGRect]) {
        let fontSize: CGFloat = 20
        let bubble = ReaderHTMLUtilities.rewriteReviewComments(
            #"<comment count="2" onClick="java.startBrowser('https://example.com/r?p=1','段评')"/>"#
        )
        let prose = (0..<4).map { "<p>\(String(repeating: "字", count: 40))\($0)。\(bubble)</p>" }.joined()
        let cleaned = ReaderHTMLUtilities.sanitizeOnlineChapterMarkup(prose + chapterSayCard + prose)
        let attributed = try await build(
            html: cleaned,
            lineHeightMultiple: lineHeight,
            lineSpacing: (lineHeight - 1) * fontSize,
            paragraphSpacing: paragraphEm * fontSize
        )
        let chunks = CoreTextChunkSlicer.slice(
            attributedString: LayoutShared(attributed).wrappedValue,
            chapterIndex: 0,
            contentWidth: page.width - insets.left - insets.right
        ).chunks
        var found: (chunk: CoreTextChunk, reviews: [CoreTextPaginator.RenderedAttachment])?
        for chunk in chunks where found == nil {
            chunk.materializeFrameIfNeeded()
            let reviews = chunk.attachments.filter { $0.linkHref?.hasPrefix("ydreview://") == true }
            if reviews.contains(where: { $0.rect.width > page.width / 2 }) {
                found = (chunk, reviews)
            }
        }
        let (chunk, reviews) = try #require(found, "no chunk holds the card")
        let frame = try #require(chunk.frame)

        // Each line's vertical band, top-down in the chunk, as `stringIndex` measures it.
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        let bands = lines.indices.map { index -> ClosedRange<CGFloat> in
            var ascent: CGFloat = 0, descent: CGFloat = 0
            _ = CTLineGetTypographicBounds(lines[index], &ascent, &descent, nil)
            return (chunk.height - origins[index].y - ascent)...(chunk.height - origins[index].y + descent)
        }
        func isReview(_ index: Int?) -> Bool {
            index.flatMap { HTMLAttributedStringBuilder.linkHref(at: $0, in: chunk.attributedString) }?
                .hasPrefix("ydreview://") == true
        }

        // Under each bubble and across the card, the points clear of every line.
        let xs = reviews.map { $0.rect.width > page.width / 2 ? $0.rect.minX + $0.rect.width * 0.15 : $0.rect.midX }
        let blank = stride(from: CGFloat(0), through: chunk.height, by: 1).filter { y in
            bands.allSatisfy { y < $0.lowerBound - 10 || y > $0.upperBound + 10 }
        }
        let snapped = xs.flatMap { x in
            blank.map { CGPoint(x: x, y: $0) }.filter { isReview(chunk.stringIndex(atLocalPoint: $0)) }
        }
        let claimed = snapped.filter { chunk.stringIndex(atLocalPoint: $0, snapsToNearestLine: false) != nil }
        // Bubbles only: a tap on the card meets its rect first (`attachmentLinkTarget`).
        let missed = reviews.filter { $0.rect.width <= page.width / 2 }.filter {
            !isReview(chunk.stringIndex(atLocalPoint: CGPoint(x: $0.rect.midX, y: $0.rect.midY), snapsToNearestLine: false))
        }
        return (snapped, claimed, missed.map(\.rect))
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
        let attributed = try await build(html: html)
        return await CoreTextPaginator().paginate(
            spineIndex: 0,
            attrStr: LayoutShared(attributed).wrappedValue,
            renderSize: page,
            fontSize: 20,
            contentInsets: insets
        )
    }

    private func build(
        html: String,
        lineHeightMultiple: CGFloat = 1.6,
        lineSpacing: CGFloat = 0,
        paragraphSpacing: CGFloat = 10
    ) async throws -> NSAttributedString {
        // The page, as the reader passes its viewport: the builder takes the insets off itself.
        let builder = OnlineProviderAttributedStringBuilder(
            provider: ReviewCardChapterProvider(html: html),
            renderSize: page
        )
        return try await builder.buildChapter(
            at: 0,
            settings: ReaderRenderSettings(
                theme: "test", textColor: .black, backgroundColor: .white,
                fontSize: 20, lineHeightMultiple: lineHeightMultiple, lineSpacing: lineSpacing,
                paragraphSpacing: paragraphSpacing,
                letterSpacing: 0, marginH: insets.left, marginV: insets.bottom, footerHeight: 0,
                contentInsets: insets, writingMode: .horizontal
            ),
            themeTextColor: .black,
            themeBackgroundColor: .white
        ).attributedString
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
