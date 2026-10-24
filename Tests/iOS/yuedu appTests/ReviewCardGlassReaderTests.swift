@testable import YueduCoreText
import CoreText
import Foundation
import Testing
import UIKit
@testable import yuedu_app

private final class GlassCardChapterProvider: BookContentProvider {
    let payload: ChapterContentPayload

    init(_ payload: ChapterContentPayload) {
        self.payload = payload
    }

    var totalChapters: Int { 1 }

    func chapterTitle(at index: Int) -> String { payload.title }

    func contentForChapter(index: Int) async throws -> ChapterContentPayload {
        guard index == 0 else { throw BookContentProviderError.chapterIndexOutOfRange(index) }
        return payload
    }
}

/// A worn glass template has to reach the screen as the system's glass: the card's
/// `ReviewCardImage` must survive the online chapter build and pagination, and the page and
/// the scroll chunk must each put a `ReviewCardGlassView` where the card is.
@MainActor
@Suite("Review card glass in the reader", .serialized)
struct ReviewCardGlassReaderTests {
    private static let size = CGSize(width: 360, height: 640)
    private static let insets = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

    /// 起点's 本章说 card, trimmed to one comment (as in `ReviewCardTemplateTests`).
    private static let sourceChapterCard = """
    <svg xmlns="http://www.w3.org/2000/svg" width="1000" height="322" viewBox="0 0 1000 322">
        <rect x="0" y="30" width="1000" height="262" rx="30" fill="rgba(244,249,245,0.55)"/>
        <rect x="44" y="62" width="164" height="56" rx="28" fill="#5E8A6A"/>
        <text x="126" y="101" font-size="34" fill="#FFFFFF" text-anchor="middle" font-weight="bold">本章说</text>
        <text x="956" y="102" font-size="34" fill="#5E8A6A" text-anchor="end" font-weight="bold">12条评论 〉</text>
        <rect x="44" y="130" width="912" height="2" fill="#e8e8e851"/>
        <text x="44" y="182" font-size="36" fill="#5E8A6A" font-weight="bold">书友20250107212008897</text>
        <text x="956" y="186" font-size="32" fill="#F06260" text-anchor="end" font-weight="bold">57</text>
        <text x="44" y="236" font-size="38" fill="#333333">怎么主角栏里没有主角</text>
    </svg>
    """

    private static let settings = ReaderRenderSettings(
        theme: "test",
        textColor: .black,
        backgroundColor: .white,
        fontSize: 18,
        lineHeightMultiple: 1.4,
        lineSpacing: 0,
        paragraphSpacing: 8,
        letterSpacing: 0,
        marginH: 16,
        marginV: 16,
        footerHeight: 0,
        contentInsets: insets,
        writingMode: .horizontal
    )

    /// The chapter as the online reader builds it: the card arrives as a source `<img>` data URI.
    private func buildChapter() async throws -> NSAttributedString {
        let base64 = Data(Self.sourceChapterCard.utf8).base64EncodedString()
        let clickConfig = #"{"style":"FULL","type":"qd","click":"showChapterComments(1,2)"}"#
        let prose = String(repeating: "山風吹過竹林，葉聲沙沙作響。", count: 12)
        let html = await ChapterFetcher.shared.buildRenderableNormalizedHTML(
            title: "第一章",
            plainTextContent: prose,
            rawHTMLContent: "<div rs-native>\(prose)<img src=\"data:image/svg+xml;base64,\(base64),\(clickConfig)\">\(prose)</div>",
            reviewContext: ReaderHTMLUtilities.LegadoReviewContext(
                sourceName: "起点中文",
                sourceURL: "https://m.qidian.com/chapter/1/2"
            )
        )
        let provider = GlassCardChapterProvider(ChapterContentPayload(
            index: 0,
            title: "第一章",
            plainText: prose,
            body: .html(html),
            sourceHref: "https://m.qidian.com/chapter/1/2"
        ))
        return try await OnlineProviderAttributedStringBuilder(provider: provider, renderSize: Self.size)
            .buildChapter(at: 0, settings: Self.settings, themeTextColor: .black, themeBackgroundColor: .white)
            .attributedString
    }

    private func glassViews(in view: UIView) -> [ReviewCardGlassView] {
        view.subviews.flatMap { subview -> [ReviewCardGlassView] in
            if let glass = subview as? ReviewCardGlassView { return [glass] }
            return glassViews(in: subview)
        }
    }

    /// Curl back pages, cover-transition and auto-read snapshots draw the card's glass as a
    /// still stand-in. Like the live glass it must let the page show through: on 起点's beige
    /// paper it was a white slab (#69).
    @Test("a baked glass card keeps the page's colour")
    func bakedGlassKeepsPageColour() throws {
        let paper = UIColor(red: 216 / 255, green: 196 / 255, blue: 158 / 255, alpha: 1)
        let cardSize = CGSize(width: 200, height: 100)
        let clear = UIGraphicsImageRenderer(size: cardSize).image { _ in }
        let card = try #require(ReviewCardImage(
            image: clear,
            glassPanels: [ReviewCardGlassPanel(rect: CGRect(origin: .zero, size: cardSize), cornerRadius: 12)],
            isNight: false
        ))
        let attachment = CoreTextPaginator.RenderedAttachment(
            rect: CGRect(origin: .zero, size: cardSize),
            image: card,
            opacity: 1
        )
        // A context of known RGBA layout, set up as UIKit draws (origin top-left).
        let width = Int(cardSize.width), height = Int(cardSize.height)
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.translateBy(x: 0, y: cardSize.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        paper.setFill()
        UIRectFill(CGRect(origin: .zero, size: cardSize))
        attachment.draw(glassCards: .baked)
        UIGraphicsPopContext()
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        let centre = ((height / 2) * width + width / 2) * 4
        let red = CGFloat(bytes[centre]) / 255
        let green = CGFloat(bytes[centre + 1]) / 255
        let blue = CGFloat(bytes[centre + 2]) / 255
        let alpha = CGFloat(bytes[centre + 3]) / 255
        var paperRed: CGFloat = 0, paperGreen: CGFloat = 0, paperBlue: CGFloat = 0
        paper.getRed(&paperRed, green: &paperGreen, blue: &paperBlue, alpha: nil)
        #expect(alpha == 1)
        // Lifted a little, never washed out: the blue channel is where white shows first.
        #expect(blue - paperBlue < 0.06, "panel \(red) \(green) \(blue) over paper \(paperRed) \(paperGreen) \(paperBlue)")
        // Lifted, not darkened (a colour-space round trip may cost a step).
        #expect(red > paperRed - 0.01 && green > paperGreen - 0.01 && blue > paperBlue - 0.01)
    }

    @Test("a worn glass template is live glass on the page and in the scroll chunk")
    func glassCardReachesPageAndChunk() async throws {
        let settings = GlobalSettings.shared
        let stores = ReadingSettingsStoresSnapshot()
        let oldChoices = settings.commentCardChoices
        defer {
            settings.commentCardChoices = oldChoices
            stores.restore()
        }
        settings.selectCommentCardStyle(id: nil, for: .chapterSay)
        settings.setCommentCardPrefersSelectedStyle(true, for: .chapterSay)

        // The second build is served from the rasterizer's cache, which must keep the subclass.
        for pass in 1...2 {
            let chapter = try await buildChapter()

            let layout = await CoreTextPaginator().paginate(
                spineIndex: 0,
                attrStr: LayoutShared(chapter).wrappedValue,
                renderSize: Self.size,
                fontSize: Self.settings.fontSize,
                contentInsets: Self.insets
            )
            let page = try #require(
                layout.pageRanges.indices.first { !layout.reviewCardGlassAttachments(onPage: $0).isEmpty },
                "pass \(pass): no page holds a glass card"
            )
            let cards = layout.reviewCardGlassAttachments(onPage: page)
            #expect(cards.count == 1)
            let card = try #require(cards.first)
            #expect(card.reviewCardGlassImage?.isNight == false)

            let pageView = CoreTextPageView(frame: CGRect(origin: .zero, size: Self.size))
            pageView.configure(layout: layout, pageIndex: page)
            let pageGlass = glassViews(in: pageView)
            #expect(pageGlass.count == 1)
            #expect(pageGlass.first?.frame == pageView.viewRect(forRenderRect: card.rect))

            let chunks = CoreTextChunkSlicer.slice(
                attributedString: chapter,
                chapterIndex: 0,
                contentWidth: Self.size.width - Self.insets.left - Self.insets.right
            ).chunks
            let chunk = try #require(chunks.first { chunk in
                chunk.materializeFrameIfNeeded()
                return !ReviewCardGlassView.uniqueGlassCards(
                    chunk.attachments + chunk.blockRenderables.compactMap(\.imageAttachment)
                ).isEmpty
            }, "pass \(pass): no chunk holds a glass card")
            let chunkCard = try #require(ReviewCardGlassView.uniqueGlassCards(
                chunk.attachments + chunk.blockRenderables.compactMap(\.imageAttachment)
            ).first)
            for axis in [CoreTextScrollAxis.vertical, .horizontalRTL] {
                let cell = CoreTextChunkCollectionCell(frame: CGRect(x: 0, y: 0, width: Self.size.width, height: chunk.height + 40))
                cell.bind(
                    chunk: chunk,
                    axis: axis,
                    horizontalInset: Self.insets.left,
                    verticalInset: 20,
                    leadingSpacing: 0,
                    viewportSize: Self.size
                )
                cell.syncReviewCardGlass()
                let chunkGlass = glassViews(in: cell.contentView)
                #expect(chunkGlass.count == 1, "\(axis)")
                #expect(chunkGlass.first?.frame == chunkCard.rect, "\(axis)")
                cell.prepareForReuse()
                #expect(glassViews(in: cell.contentView).isEmpty, "\(axis)")
            }
        }
    }
}
