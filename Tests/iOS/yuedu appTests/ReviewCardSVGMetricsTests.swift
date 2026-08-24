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

    /// The other shape the same family of cards ships in: authored `width`/`height` with **no**
    /// viewBox (起点 jsLib `ChapterCmtSvg`). Its coordinate system is the declared width, and it
    /// reaches the reader as an inline `<svg>` element rather than an `<img src="data:…">`.
    private let noViewBoxCard = """
    <svg width="1080" height="700" xmlns="http://www.w3.org/2000/svg">
        <rect width="1080" height="700" fill="rgba(255,255,255,0.25)" rx="35"/>
        <text x="80" y="75" font-size="44" font-family="Arial" fill="#000">本章说</text>
        <text x="1000" y="75" font-size="36" text-anchor="end" fill="#000">525条评论 ❯</text>
        <text x="80" y="190" font-weight="bold" font-size="42" fill="#000">绝傲蜀风</text>
        <text x="80" y="280" font-size="42" fill="#000">近现代背景、古董加点、漂亮妹妹</text>
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

    @Test("a card authored without a viewBox is measured off its declared width")
    func noViewBoxCardIsRecognized() throws {
        let card = try #require(ReviewCardSVGMetrics.textCard(in: noViewBoxCard))
        #expect(card.coordinateWidth == 1080)
        // Longest run is the 15-character 近现代… line at font-size 42.
        #expect(card.dominantFontSize == 42)
    }

    /// The iPad report: the card's text read visibly larger than the prose beside it, and
    /// shrinking the card to fix that left a pill floating mid-column. The card stays full
    /// width; its canvas is widened until its own text is body-sized.
    @Test("a wide column widens the card's canvas instead of shrinking the card")
    func wideColumnWidensTheCanvas() throws {
        let reshaped = try #require(
            ReviewCardSVGMetrics.reshapedForColumn(
                svg: chapterCommentCard, bodyPointSize: 18, columnWidth: 900, path: "test"
            )
        )
        // 36 units of text at 18pt across a 900pt column ⇒ a 1800-unit canvas.
        #expect(reshaped.contains(#"viewBox="0 0 1800 322""#))
        #expect(reshaped.contains(#"width="1800""#))
        // Rasterized at the column, the comment line now measures the reader's body size.
        let card = try #require(ReviewCardSVGMetrics.textCard(in: reshaped))
        #expect(abs(900 * card.textFraction - 18) < 0.5)
    }

    @Test("the card's background and rules grow with the canvas")
    func fullBleedGeometryStretches() throws {
        let reshaped = try #require(
            ReviewCardSVGMetrics.reshapedForColumn(
                svg: chapterCommentCard, bodyPointSize: 18, columnWidth: 900, path: "test"
            )
        )
        // Background plate: x=0 width=1000 → spans the whole widened canvas.
        #expect(reshaped.contains(#"<rect x="0" y="30" width="1800""#))
        // Separator rule: x=44 width=912 (right edge 956, a 44-unit margin) → keeps that margin.
        #expect(reshaped.contains(#"<rect x="44" y="130" width="1756""#))
    }

    @Test("right-anchored text travels with the right edge")
    func rightAnchoredTextFollowsTheEdge() throws {
        let reshaped = try #require(
            ReviewCardSVGMetrics.reshapedForColumn(
                svg: chapterCommentCard, bodyPointSize: 18, columnWidth: 900, path: "test"
            )
        )
        // 12条评论 sat at x=956 (44 from the right edge) and must stay 44 from the new one.
        #expect(reshaped.contains(#"x="1756""#))
        // The badge and the comment line are anchored left and must not move.
        #expect(reshaped.contains(#"<text x="126" y="101""#))
        #expect(reshaped.contains(#"<text x="44" y="236""#))
    }

    @Test("a phone column leaves the card exactly as the source drew it")
    func narrowColumnIsUntouched() {
        // 36 units at 19pt would need a 664-unit canvas — narrower than the authored 1000, and
        // narrowing would crop the author's layout.
        #expect(
            ReviewCardSVGMetrics.reshapedForColumn(
                svg: chapterCommentCard, bodyPointSize: 19, columnWidth: 350, path: "test"
            ) == nil
        )
    }

    @Test("no reader font to match keeps the old column-width sizing")
    func withoutBodyPointSizeNothingChanges() {
        #expect(
            ReviewCardSVGMetrics.reshapedForColumn(
                svg: chapterCommentCard, bodyPointSize: 0, columnWidth: 900, path: "test"
            ) == nil
        )
    }

    @Test("an SVG that is not a card is never reshaped")
    func nonCardsAreNeverReshaped() {
        #expect(
            ReviewCardSVGMetrics.reshapedForColumn(
                svg: countBubble, bodyPointSize: 18, columnWidth: 900, path: "test"
            ) == nil
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
