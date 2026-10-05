import Foundation
import Testing
@testable import yuedu_app

/// 閱讀設定 › 段評氣泡 appears for a book that shows bubbles. It used to be gated on review
/// *links* only, while the renderer draws — and those settings restyle — any SVG the
/// recognizer takes for a bubble: a source whose bubbles carry no tap handler this app
/// can run, or none at all, showed bubbles on every page and no way to restyle them.
@Suite("Paragraph-review bubbles are found where the renderer finds them")
struct CommentBubblePresenceTests {
    private static let bubbleSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">\
    <path d="M2 2 H30 V24 H12 L6 30 V24 H2 Z" fill="#FFFFFF" stroke="#999999"/>\
    <text x="16" y="17" font-size="10" text-anchor="middle">12</text></svg>
    """

    private static let illustrationSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="200" height="120" viewBox="0 0 200 120">\
    <rect width="200" height="120" fill="#EEEEEE"/><circle cx="60" cy="60" r="30" fill="#88AA88"/></svg>
    """

    private static func dataURI(_ svg: String) -> String {
        "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString()
    }

    @Test func aBubbleWithoutAReviewLinkStillCounts() {
        let bubble = Self.dataURI(Self.bubbleSVG)
        let chapter = #"<p>段落<img data-yd-imgstyle="text" src="\#(bubble)"></p>"#
        // What the renderer draws as a bubble…
        #expect(CommentBubbleSVGRecognizer.recognize(src: bubble, svgContent: nil) != nil)
        // …carries none of what the entry used to look for,
        #expect(!ReaderHTMLUtilities.containsParagraphReviewLinks(in: chapter))
        // and is found now.
        #expect(CommentBubbleSVGRecognizer.containsRecognizedBubble(inChapterHTML: chapter))
    }

    @Test func anIllustrationIsNotABubble() {
        let chapter = #"<p><img src="\#(Self.dataURI(Self.illustrationSVG))"></p>"#
        #expect(!CommentBubbleSVGRecognizer.containsRecognizedBubble(inChapterHTML: chapter))
    }

    @Test func aBubbleAfterAnIllustrationIsStillFound() {
        let chapter = """
        <p><img src="\(Self.dataURI(Self.illustrationSVG))"></p>\
        <p>段落<img src="\(Self.dataURI(Self.bubbleSVG))"></p>
        """
        #expect(CommentBubbleSVGRecognizer.containsRecognizedBubble(inChapterHTML: chapter))
    }

    /// The reader asks this of the chapter package's content — the source's own output, in
    /// which a `<comment>` marker is not yet a review link. 起点 qimo's iOS branch emits only
    /// these, so its chapters drew bubbles while the entry stayed hidden.
    @Test func aRawCommentMarkerCounts() {
        let chapter = #"<div rs-native>正文<comment count="1" onClick="java.startBrowser('https://qdgo.qimo.host/reviews?bookId=1&chapterId=2&paragraphId=2','起点段评')"/></div>"#
        #expect(ReaderHTMLUtilities.containsParagraphReviewLinks(in: chapter))
        #expect(!ReaderHTMLUtilities.containsParagraphReviewLinks(
            in: #"<div rs-native>正文<comment count="1"/></div>"#
        ))
    }

    @Test func reviewLinksStillCount() {
        #expect(ReaderHTMLUtilities.containsParagraphReviewLinks(
            in: #"<a href="ydreview://r?d=abc" class="yd-review">3</a>"#
        ))
        #expect(ReaderHTMLUtilities.containsParagraphReviewLinks(
            in: #"<img src="x.svg" onclick="showCmt('1','2')">"#
        ))
        #expect(!ReaderHTMLUtilities.containsParagraphReviewLinks(in: "<p>正文</p>"))
    }
}
