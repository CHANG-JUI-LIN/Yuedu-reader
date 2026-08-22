import CoreGraphics
import Foundation
import Testing
@testable import yuedu_app

/// A source review card is prose drawn in viewBox units, so the width we rasterize it at is its
/// text size. Sizing it off the reading column made the same card read at ~13pt in an iPhone
/// column and ~38pt in an iPad landscape column, and made rotating an iPad change the card's text
/// size while the prose around it stayed put. These tests pin the card to the reader's own body
/// text instead.
@Suite("Review card SVG sizing")
struct ReviewCardSVGMetricsTests {

    /// Verbatim 企点小说 本章说 card (sb.shazi.tk/chapter/chapterEndComments?…&svg=1), trimmed to
    /// one comment. Authored 1000 units wide with a 38-unit comment line — calibrated for a phone.
    private let chapterCommentCard = """
    <?xml version="1.0" encoding="UTF-8"?>
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

    /// A 段評 count bubble — one digit in a small coordinate system. Must keep its own sizing;
    /// it is scaled to the line height further down the pipeline.
    private let countBubble = """
    <svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 216 200'>
      <path fill='#802622' d='M20 20 H196 V150 H20 Z'/>
      <text x='108' y='110' font-size='96' fill='#FFFFFF' text-anchor='middle'>7</text>
    </svg>
    """

    @Test("the 本章说 card is recognized, with its comment line as the body text")
    func recognizesChapterCommentCard() {
        let card = ReviewCardSVGMetrics.textCard(in: chapterCommentCard)
        #expect(card?.coordinateWidth == 1000)
        // Longest run is the 21-character 书友… line at font-size 36.
        #expect(card?.dominantFontSize == 36)
        #expect(abs((card?.textFraction ?? 0) - 0.036) < 0.0001)
    }

    @Test("the card reads at the reader's body size, not the column's")
    func cardWidthTracksBodyPointSize() throws {
        let card = try #require(ReviewCardSVGMetrics.textCard(in: chapterCommentCard))

        // iPad mini, 21pt reader text: portrait and landscape must agree.
        let portrait = ReviewCardSVGMetrics.preferredWidth(
            for: card, bodyPointSize: 21, columnWidth: 700
        )
        let landscape = ReviewCardSVGMetrics.preferredWidth(
            for: card, bodyPointSize: 21, columnWidth: 1050
        )
        #expect(abs(portrait - landscape) < 0.5)
        // 21pt / 0.036 ≈ 583pt — the width at which the card's own text is 21pt.
        #expect(abs(portrait - 21 / card.textFraction) < 0.5)
        // Which is exactly the point: the card no longer blows up with the column.
        #expect(landscape < 1050)
    }

    @Test("a bigger 字級 setting makes the card bigger")
    func cardFollowsFontSizeSetting() throws {
        let card = try #require(ReviewCardSVGMetrics.textCard(in: chapterCommentCard))
        let small = ReviewCardSVGMetrics.preferredWidth(
            for: card, bodyPointSize: 16, columnWidth: 1050
        )
        let large = ReviewCardSVGMetrics.preferredWidth(
            for: card, bodyPointSize: 26, columnWidth: 1050
        )
        #expect(large > small)
    }

    @Test("a narrow column still wins — the card never overflows it")
    func cardNeverExceedsTheColumn() throws {
        let card = try #require(ReviewCardSVGMetrics.textCard(in: chapterCommentCard))
        let width = ReviewCardSVGMetrics.preferredWidth(
            for: card, bodyPointSize: 21, columnWidth: 350
        )
        #expect(width == 350)
    }

    @Test("no reader font to match keeps the old column-width sizing")
    func withoutBodyPointSizeNothingChanges() throws {
        let card = try #require(ReviewCardSVGMetrics.textCard(in: chapterCommentCard))
        #expect(
            ReviewCardSVGMetrics.preferredWidth(for: card, bodyPointSize: 0, columnWidth: 900)
                == 900
        )
    }

    @Test("a 段評 count bubble is not a card")
    func countBubbleIsNotACard() {
        #expect(ReviewCardSVGMetrics.textCard(in: countBubble) == nil)
    }

    @Test("a card carrying a bitmap keeps its authored size")
    func photoCardIsNotResized() {
        let withPhoto = chapterCommentCard.replacingOccurrences(
            of: "<rect x=\"44\" y=\"130\"",
            with: "<image x=\"44\" y=\"130\" width=\"64\" height=\"64\" href=\"data:image/png;base64,AA\"/><rect x=\"44\" y=\"131\""
        )
        #expect(ReviewCardSVGMetrics.textCard(in: withPhoto) == nil)
    }

    @Test("a single-run label is not a card")
    func singleTextRunIsNotACard() {
        let banner = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 120">
            <rect width="1000" height="120" fill="#eee"/>
            <text x="20" y="80" font-size="40">版权所有</text>
        </svg>
        """
        #expect(ReviewCardSVGMetrics.textCard(in: banner) == nil)
    }

    @Test("font-size written in a style declaration is read too")
    func fontSizeFromStyleAttribute() {
        let styled = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1000 200">
            <text x="20" y="60" style="fill:#333; font-size:20px">本章说</text>
            <text x="20" y="140" style="font-size: 40px ; fill:#333">这是一条比较长的评论内容</text>
        </svg>
        """
        let card = ReviewCardSVGMetrics.textCard(in: styled)
        #expect(card?.dominantFontSize == 40)
    }
}
