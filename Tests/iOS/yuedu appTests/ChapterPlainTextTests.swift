import Foundation
import Testing

@testable import yuedu_app

/// The text whole-book features read.
///
/// These exist because the AI features were reading `engine.chapterText(forSpine:)`, which
/// answers only for chapters `LayoutCache` is holding — five of them. A reader 94% through a
/// novel got a cast list of two entries with one line each. The fix reads chapter text from
/// the source instead, and that text has to survive the trip with its paragraphs intact.
@Suite("Chapter plain text")
struct ChapterPlainTextTests {

    /// The load-bearing property. `TTSSpeakerAnnotator` walks paragraphs and reads the
    /// speaker off the narration around each quote; collapse the paragraphs into one line and
    /// every line in the chapter belongs to whoever spoke first.
    @Test("paragraph breaks survive, because speaker attribution is per paragraph")
    func keepsParagraphBoundaries() {
        let html = """
        <p>張若塵皺眉道：「你來做什麼？」</p>
        <p>黑袍人冷笑道：「自然是取你性命。」</p>
        """
        let text = ChapterPlainText.fromHTML(html)
        let paragraphs = text.split(separator: "\n").map(String.init)
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].contains("張若塵"))
        #expect(paragraphs[1].contains("黑袍人"))
    }

    @Test("<br> is a paragraph break too")
    func breakTagsSplitParagraphs() {
        let text = ChapterPlainText.fromHTML("甲道：「一。」<br/>乙道：「二。」")
        #expect(text.split(separator: "\n").count == 2)
    }

    /// EPUB chapters routinely carry an inline stylesheet, and stripping tags alone leaves
    /// its rules behind as prose — which would then be indexed and searched as book text.
    @Test("style and script contents do not become book text")
    func dropsStyleAndScriptBodies() {
        let html = """
        <style>.p1 { font-size: 1em; color: #333; }</style>
        <p>正文開始。</p>
        <script>var spoiler = "結局";</script>
        """
        let text = ChapterPlainText.fromHTML(html)
        #expect(text.contains("正文開始。"))
        #expect(!text.contains("font-size"))
        #expect(!text.contains("spoiler"))
    }

    /// Note the deliberate asymmetry: `displayText` unescapes first and strips tags second,
    /// so `&lt;完&gt;` is removed along with real markup. That is the shared helper's existing
    /// contract — book-source rules escape real tags — and prose using angle brackets as
    /// punctuation is not something Chinese novels do.
    @Test("entities are decoded rather than indexed as their escapes")
    func decodesEntities() {
        let text = ChapterPlainText.fromHTML("<p>「他說&amp;我說」&nbsp;結束。</p>")
        #expect(text.contains("他說&我說"))
        #expect(text.contains("結束。"))
        #expect(!text.contains("&amp;"))
        #expect(!text.contains("&nbsp;"))
    }

    /// The whole point: a chapter that is not laid out still yields its text.
    @Test("an adapter reads chapters the layout engine has never seen")
    func adapterUsesGatheredTextForUnrenderedChapters() {
        let bookID = UUID()
        // Every reader path builds its chapter list with `content: ""` — the text lives in
        // the epub, the mapped txt file, or the online cache, never here.
        let chapters = (0..<4).map { BookChapter(index: $0, title: "第\($0)章", content: "") }
        let gathered = ["第零章正文", "第一章正文", "第二章正文", "第三章正文"]
        let adapter = AIBookContentAdapter(bookID: bookID, chapters: chapters) { gathered[$0] }

        #expect(adapter.chunkSections.count == 4)
        #expect(adapter.chunkSections.allSatisfy { !$0.text.isEmpty })
        // Progress spreads across the whole book, not across the one chapter that happened
        // to be rendered.
        let firstChapterEnd = adapter.progress(forSpine: 0, charOffset: gathered[0].count)
        #expect(firstChapterEnd > 0 && firstChapterEnd < 0.5)
    }

    /// What the old code did, kept as the contrast: with only the laid-out chapter readable,
    /// three quarters of the book is missing and the reader's position reads as the end of it.
    @Test("without gathered text only the rendered chapter is indexable")
    func adapterWithoutGatheredTextSeesAlmostNothing() {
        let bookID = UUID()
        let chapters = (0..<4).map { BookChapter(index: $0, title: "第\($0)章", content: "") }
        let adapter = AIBookContentAdapter(bookID: bookID, chapters: chapters) { index in
            index == 3 ? "只有這一章排好了" : nil
        }
        #expect(adapter.chunkSections.filter { !$0.text.isEmpty }.count == 1)
        #expect(adapter.progress(forSpine: 3, charOffset: 0) == 0)
    }
}
