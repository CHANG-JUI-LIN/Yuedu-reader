@testable import YueduCoreText
import Testing
import UIKit
@testable import yuedu_app

/// A module's comments in a chapter the browser engine lays out: written into the chapter's
/// HTML, drawn, and no part of the chapter's text.
@MainActor
@Suite("Comments added to a browser chapter")
struct BrowserChapterAdditionsTests {
    /// A chapter as an EPUB writes one: an XML declaration, self-closing tags, entities, ruby,
    /// a line break, an `epub:type`, a picture, nested containers.
    private static let chapter = """
    <?xml version="1.0" encoding="utf-8"?>
    <!DOCTYPE html>
    <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
    <head><title>第三章 風起</title><meta charset="utf-8"/></head>
    <body>
      <div class="chapter">
        <h1>第三章&#160;風起</h1>
        <p>風，起了。<br/>他<ruby>推<rt>tuī</rt></ruby>開門 &amp; 走進長夜。</p>
        <p>「嗯。」<a epub:type="noteref" href="#n1">1</a></p>
        <p><img src="map.png" alt=""/>地圖之後還有一段。</p>
        <aside epub:type="footnote" id="n1"><p>註一。</p></aside>
      </div>
    </body>
    </html>
    """

    private func placements(for paragraphs: [String]) -> ReaderCommentPlacements {
        var placements = ReaderCommentPlacements()
        let quoted = paragraphs.firstIndex { $0.contains("他推開門") }!
        placements.bubbles[quoted] = .init(count: 230, href: "ydreview://r?d=abc", title: "段評")
        placements.cards[quoted] = [.init(content: ReviewCardContent.sample(for: .hotComment), href: "ydreview://r?d=hot")]
        placements.chapterEnd = [.init(content: ReviewCardContent.sample(for: .authorSay), href: "ydreview://r?d=say"),
                                 .init(content: ReviewCardContent.sample(for: .chapterSay), href: "ydreview://r?d=all")]
        return placements
    }

    @Test("a paragraph is asked about by its own text, without a ruby's reading")
    func paragraphTexts() throws {
        var asked: [String] = []
        let added = BrowserChapterAdditions.inject(into: Self.chapter, spine: 3) { paragraphs in
            asked = paragraphs
            return nil
        }
        #expect(added == nil, "nothing to add: the chapter is read as it is")
        #expect(asked.count == 5, "the title, three paragraphs and the note: \(asked)")
        #expect(asked.contains { $0.contains("他推開門") && !$0.contains("tuī") })
    }

    @Test("the comments are written in as added pictures, each naming what it draws and what it opens")
    func injects() throws {
        let added = try #require(BrowserChapterAdditions.inject(into: Self.chapter, spine: 3, placements: placements))
        #expect(added.html.components(separatedBy: BrowserAddedContent.attributeName).count - 1 == 4, "a bubble and three cards")
        #expect(added.pictures["yd-added:bubble/99"] == .bubble(count: 230), "one picture for every bubble of a count")
        #expect(added.pictures.count == 4)
        for href in ["ydreview://r?d=abc", "ydreview://r?d=hot", "ydreview://r?d=say", "ydreview://r?d=all"] {
            #expect(added.html.contains("href=\"\(href)\""), "\(href)")
        }
        let bubble = try #require(added.html.range(of: "yd-added:bubble/99")), paragraphEnd = try #require(added.html.range(of: "走進長夜。"))
        let hot = try #require(added.html.range(of: "yd-added:card/3/1")), next = try #require(added.html.range(of: "「嗯。」"))
        #expect(paragraphEnd.upperBound <= bubble.lowerBound && bubble.upperBound <= hot.lowerBound && hot.upperBound <= next.lowerBound,
                "the bubble ends its paragraph, the card is under it, before the next paragraph")
    }

    @Test("the chapter's text and every offset in it are what they are without the comments")
    func sourceTextIsUntouched() async throws {
        let picture = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 300, height: 90), color: .gray)
        let plain = try await BrowserLayoutTestSupport.layout(Self.chapter, width: 300, height: 400, imageLoader: { _ in picture })
        let added = try #require(BrowserChapterAdditions.inject(into: Self.chapter, spine: 3, placements: placements))
        let decorated = try await BrowserLayoutTestSupport.layout(added.html, width: 300, height: 400, imageLoader: { _ in picture })
        #expect(decorated.doc.lastSourceText == plain.doc.lastSourceText)
        #expect(!plain.doc.lastSourceText.isEmpty)
        let drawn = BrowserLayoutTestSupport.allImageFragments(decorated.pages).filter(\.isAddedContent)
        #expect(drawn.count == 4, "the bubble and the three cards are drawn: \(drawn.map(\.source))")
        #expect(Set(drawn.compactMap(\.linkTarget)) == ["ydreview://r?d=abc", "ydreview://r?d=hot", "ydreview://r?d=say", "ydreview://r?d=all"])
        #expect(BrowserLayoutTestSupport.allImageFragments(plain.pages).filter(\.isAddedContent).isEmpty)
        // Every page is still found by its position, a page of cards alone by the card it starts with.
        let ranges = BrowserPageGeometry.buildPageRanges(decorated.pages, sourceText: decorated.doc.lastSourceText)
        let starts = BrowserPageGeometry.buildPageAddedStarts(decorated.pages, sourceText: decorated.doc.lastSourceText)
        for page in ranges.indices {
            #expect(BrowserPageGeometry.pageIndex(forCharOffset: ranges[page].location, addedIndex: starts[page], ranges: ranges,
                                                  addedStarts: starts, sourceText: decorated.doc.lastSourceText) == page,
                    "page \(page) of \(ranges) \(starts)")
        }
    }

    /// The book's resource with every picture a chapter names answered by one picture.
    @MainActor
    private final class PictureResource: BrowserLayoutResourceProviding {
        let base: MockBrowserLayoutResource
        let picture: UIImage
        init(_ base: MockBrowserLayoutResource, picture: UIImage) {
            self.base = base
            self.picture = picture
        }
        var chapterCount: Int { base.chapterCount }
        func chapterTitle(at index: Int) -> String { base.chapterTitle(at: index) }
        func chapterSourceHref(at index: Int) -> String? { base.chapterSourceHref(at: index) }
        func chapterHTML(at index: Int) async throws -> String { try await base.chapterHTML(at: index) }
        func cssFrontendInput(forChapter index: Int, html: String) async -> CSSFrontendInput {
            await base.cssFrontendInput(forChapter: index, html: html)
        }
        func prepareFonts(requests: Set<BrowserFontRequest>) async {}
        func prefetchImages(forChapter index: Int, html: String, renderWidth: CGFloat) async -> [String: UIImage] {
            let sources = html.matches(of: /src="([^"]+)"/).map { String($0.1) }
            return Dictionary(sources.map { ($0, picture) }, uniquingKeysWith: { first, _ in first })
        }
        func loadImage(forChapter index: Int, source: String, renderWidth: CGFloat) async -> UIImage? { picture }
        func fontResolver() -> BrowserFontResolver? { nil }
    }

    /// The reader turns by position (`positionAfter` / `positionBefore`), saves the position of
    /// the page it settles on and comes back to it. A page of cards alone shares its offset with
    /// the chapter's end, so each of those has to carry which card the page starts with.
    @Test("a page of nothing but cards is turned to, turned back from and come back to, like any page")
    func cardsOnlyPageIsAPosition() async throws {
        let settings = ReaderRenderSettings(
            theme: "paper", textColor: .black, backgroundColor: .white, fontSize: 17, lineHeightMultiple: 1.4,
            lineSpacing: 0, paragraphSpacing: 6, letterSpacing: 0, marginH: 12, marginV: 12, footerHeight: 24,
            contentInsets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
        let added = try #require(BrowserChapterAdditions.inject(into: Self.chapter, spine: 0, placements: placements))
        let base = MockBrowserLayoutResource(chapters: [
            .init(title: "第三章 風起", href: "c0.xhtml", html: added.html, css: []),
            .init(title: "第四章", href: "c1.xhtml", html: "<html><body><p>下一章。</p></body></html>", css: []),
        ])
        // Tall enough that the chapter's last cards cannot share a page with its text.
        let picture = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 276, height: 260), color: .gray)
        let store = CharOffsetStore(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("bl-added-\(UUID().uuidString)"))
        let delegate = CoreTextPageEngine(attributedBuilder: MockAttributedStringBuilder(texts: ["第三章 風起", "下一章。"]),
                                          renderSettings: settings, offsetStore: store)
        let engine = BrowserLayoutPageEngine(resource: PictureResource(base, picture: picture), delegate: delegate,
                                             settings: settings, mode: .browserAuto)
        await engine.start(renderSize: CGSize(width: 300, height: 400), bookId: "test")
        _ = await engine.preloadChapter(at: 1)

        let firstOfNext = try #require(engine.pageIndex(for: CoreTextReadingPosition(spineIndex: 1, charOffset: 0)))
        #expect(firstOfNext >= 2)
        let positions = try (0..<firstOfNext).map { try #require(engine.readingPosition(forPage: $0)) }
        let cardPages = positions.indices.filter { positions[$0].translationOffset != nil }
        #expect(!cardPages.isEmpty, "the chapter ends in a page of cards alone: \(positions)")
        for (page, position) in positions.enumerated() {
            #expect(positions.firstIndex(of: position) == page, "every page has a position of its own: \(positions)")
        }

        for (page, position) in positions.enumerated() {
            #expect(engine.pageIndex(for: position) == page, "page \(page) is found by \(position)")
            // What the reader saves and restores is the page's own position.
            let shown = try #require(engine.pageViewController(at: page) as? BrowserLayoutPageViewController)
            #expect(shown.coreTextReadingPosition == position)
            let restored = try #require(engine.pageViewController(for: position) as? BrowserLayoutPageViewController)
            #expect(restored.globalPageIndex == page)
        }
        // A turn forward from each page is the next page; a turn back from that one is this page.
        for page in positions.indices.dropLast() {
            #expect(engine.positionAfter(positions[page]) == positions[page + 1])
            #expect(engine.positionBefore(positions[page + 1]) == positions[page])
        }
        // Across the chapter's edge both ways.
        let last = try #require(positions.last)
        let next = try #require(engine.positionAfter(last))
        #expect(next.spineIndex == 1)
        let back = try #require(engine.positionBefore(next))
        #expect(engine.pageIndex(for: back) == firstOfNext - 1, "back from the next chapter lands on the cards: \(back)")
        // The cards gone (the module removed, the comments turned off): the position is the
        // source character's own page.
        #expect(engine.pageIndex(for: CoreTextReadingPosition(spineIndex: 0, charOffset: last.charOffset, translationOffset: 99)) != nil)
    }

    /// 直排: a card is a picture read left to right among columns read top to bottom. It is
    /// whole, on the page, keeps its shape and opens its comments; so does a bubble.
    @Test("in a vertical chapter the cards and bubbles are whole, on their page and can be tapped")
    func verticalChapter() async throws {
        let page = CGSize(width: 300, height: 400)
        let picture = BrowserLayoutTestSupport.makeImage(size: CGSize(width: 276, height: 92), color: .gray)
        let added = try #require(BrowserChapterAdditions.inject(into: Self.chapter, spine: 3, placements: placements))
        let vertical = ["html { writing-mode: vertical-rl; }"]
        let plain = try await BrowserLayoutTestSupport.layout(Self.chapter, cssTexts: vertical, width: page.width,
                                                              height: page.height, imageLoader: { _ in picture })
        let decorated = try await BrowserLayoutTestSupport.layout(added.html, cssTexts: vertical, width: page.width,
                                                                  height: page.height, imageLoader: { _ in picture })
        #expect(decorated.doc.lastSourceText == plain.doc.lastSourceText)
        let drawn = BrowserLayoutTestSupport.allImageFragments(decorated.pages).filter(\.isAddedContent)
        #expect(drawn.count == 4, "\(drawn.map(\.source))")
        for image in drawn {
            let rect = image.rect.rawValue
            #expect(CGRect(origin: .zero, size: page).insetBy(dx: -0.5, dy: -0.5).contains(rect), "\(image.source) at \(rect)")
            #expect(image.linkTarget != nil)
            guard image.source.contains("card") else { continue }
            #expect(abs(rect.width / rect.height - 3) < 0.05, "\(image.source) keeps its shape: \(rect)")
            #expect(rect.width > 100, "\(image.source) is wide enough to read: \(rect)")
        }
    }

    @Test("a bubble's picture leaves room under the bubble, so it sits at the middle of its line")
    func bubblePicture() throws {
        let image = try #require(BrowserChapterAdditions.bubbleImage(count: 12, pointSize: 20, textColor: .black))
        let bare = try #require(CommentBubbleSVGRecognizer.commentBadgeImage(count: "12", pointSize: 20, themeTextColor: .black))
        #expect(image.size.width == bare.size.width && image.size.height >= bare.size.height)
    }
}
