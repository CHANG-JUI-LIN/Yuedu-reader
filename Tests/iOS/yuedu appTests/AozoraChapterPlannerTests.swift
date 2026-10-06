import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora chapter planner")
struct AozoraChapterPlannerTests {
    private func plan(_ text: String, limit: Int = AozoraChapterPlanner.limit) -> [AozoraChapter] {
        AozoraChapterPlanner.plan(AozoraDocumentParser.parse(text), source: text, limit: limit)
    }

    // MARK: Chapters

    @Test("the header is the title page, and the colophon is the last chapter")
    func titlePageAndColophon() {
        let chapters = plan("題\n著者\n\n本文\n\n底本：「題」架空書房\n入力：誰か\n")
        #expect(chapters.map(\.role) == [.titlePage, .body, .colophon])
        #expect(chapters.map(\.text) == ["題\n著者\n", "本文\n", "底本：「題」架空書房\n入力：誰か\n"])
        #expect(chapters[0].navigation == [AozoraNavigationEntry(title: "題", level: 1, anchor: nil)])
        #expect(chapters[2].navigation == [AozoraNavigationEntry(title: "底本", level: 1, anchor: nil)])
    }

    @Test("a 大見出し or 中見出し block starts a chapter; a 小見出し does not")
    func headingsStartChapters() {
        let text = """
            題

            前書き
            第一章［＃「第一章」は大見出し］
            本文一
            小節［＃「小節」は小見出し］
            本文二
            第二章［＃「第二章」は中見出し］
            本文三

            """
        let chapters = plan(text)
        #expect(chapters.map(\.text) == ["題\n", "前書き\n", "第一章\n本文一\n小節\n本文二\n", "第二章\n本文三\n"])
        // Text before the first heading has no entry of its own.
        #expect(chapters[1].navigation.isEmpty)
        let small = blockIndex(of: chapters[2].spans[2], in: text)
        #expect(chapters[2].navigation == [
            AozoraNavigationEntry(title: "第一章", level: 1, anchor: nil),
            AozoraNavigationEntry(title: "小節", level: 3, anchor: AozoraChapterPlanner.anchor(blockIndex: small)),
        ])
        #expect(chapters[3].navigation == [AozoraNavigationEntry(title: "第二章", level: 2, anchor: nil)])
    }

    @Test("every page break ends a chapter and adds nothing to its text", arguments: ["改ページ", "改丁", "改段", "改見開き"])
    func pageBreaks(command: String) {
        let chapters = plan("題\n\n本文一\n［＃\(command)］\n本文二\n")
        #expect(chapters.map(\.text) == ["題\n", "本文一\n", "本文二\n"])
    }

    @Test("blank blocks at a chapter's edges go, and an empty chapter goes")
    func blankEdges() {
        let chapters = plan("題\n\n\n本文一\n\n［＃改ページ］\n\n\n［＃改ページ］\n\n本文二\n\n\n")
        #expect(chapters.map(\.text) == ["題\n", "本文一\n", "本文二\n"])
    }

    @Test("blank blocks inside a chapter stay")
    func blankInside() {
        #expect(plan("題\n\n上\n\n下\n").map(\.text) == ["題\n", "上\n\n下\n"])
    }

    @Test("a chapter over the limit splits before the block that would cross it; parts are listed as 題(1), 題(2)")
    func splitting() {
        // 章 and its line break are 2 units, each line after it 6: the third line would make 14.
        let chapters = plan("題\n\n章［＃「章」は中見出し］\nあいうえお\nかきくけこ\nさしすせそ\n", limit: 13)
        #expect(chapters.map(\.text) == ["題\n", "章\nあいうえお\n", "かきくけこ\nさしすせそ\n"])
        #expect(chapters[1].navigation == [AozoraNavigationEntry(title: "章(1)", level: 1, anchor: nil)])
        #expect(chapters[2].navigation == [AozoraNavigationEntry(title: "章(2)", level: 1, anchor: nil)])
    }

    @Test("a single block longer than the limit stays whole")
    func longBlock() {
        let chapters = plan("題\n\nあいうえおかきくけこ\n短い\n", limit: 5)
        #expect(chapters.map(\.text) == ["題\n", "あいうえおかきくけこ\n", "短い\n"])
    }

    @Test("text before the first heading, split into parts, is listed under the work's title")
    func untitledParts() {
        let chapters = plan("題\n\nあいうえお\nかきくけこ\n", limit: 6)
        #expect(chapters.dropFirst().map(\.navigation) == [
            [AozoraNavigationEntry(title: "題(1)", level: 1, anchor: nil)],
            [AozoraNavigationEntry(title: "題(2)", level: 1, anchor: nil)],
        ])
    }

    // MARK: Navigation

    @Test("an inline heading is listed at its level, pointing at its anchor")
    func inlineHeading() throws {
        let text = "題\n\n前\n一［＃「一」は同行中見出し］　本文\n"
        let chapters = plan(text)
        let body = try #require(chapters.last)
        let paragraph = body.spans[1]
        #expect(body.navigation == [
            AozoraNavigationEntry(title: "一", level: 2,
                                  anchor: AozoraChapterPlanner.anchor(blockIndex: blockIndex(of: paragraph, in: text))),
        ])
    }

    @Test("a multi-line heading's title joins its lines with a space")
    func multiLineHeading() {
        let chapters = plan("題\n\n［＃ここから中見出し］\n二\n\n副題\n［＃ここで中見出し終わり］\n本文\n")
        #expect(chapters.last?.navigation == [AozoraNavigationEntry(title: "二 副題", level: 2, anchor: nil)])
    }

    @Test("a heading that shows only white space has no entry, and the headings after it keep theirs")
    func blankHeading() {
        // As a few works set U+3000 alone as a 大見出し. Readium, as EPUB 3 asks, ignores
        // an entry with a blank label together with every entry nested under it.
        let chapters = plan("題\n\n［＃大見出し］　［＃大見出し終わり］\n献呈［＃「献呈」は中見出し］\n本文\n")
        #expect(chapters.map(\.text) == ["題\n", "　\n", "献呈\n本文\n"])
        #expect(chapters.map(\.navigation) == [
            [AozoraNavigationEntry(title: "題", level: 1, anchor: nil)],
            [],
            [AozoraNavigationEntry(title: "献呈", level: 2, anchor: nil)],
        ])
    }

    // MARK: Source map

    @Test("a chapter's map agrees with the document's inside blocks, and its line breaks map to the source's")
    func chapterSourceMap() throws {
        let text = "題\n\n本文［＃「本文」に傍点］です\n次の行\n"
        let document = AozoraDocumentParser.parse(text)
        let chapters = AozoraChapterPlanner.plan(document, source: text)
        let body = try #require(chapters.last)
        #expect(body.text == "本文です\n次の行\n")
        let units = text as NSString
        let map = body.sourceMap
        #expect(map.sourceOffset(forDisplayed: 0) == units.range(of: "本文").location)
        #expect(map.sourceOffset(forDisplayed: 2) == units.range(of: "です").location)
        // The "\n" after 本文です is the line break that followed it.
        #expect(map.sourceOffset(forDisplayed: 4) == units.range(of: "です\n").location + 2)
        #expect(map.sourceOffset(forDisplayed: 5) == units.range(of: "次の行").location)
        // After the document's last block it stands for nothing, at the end of the source.
        #expect(map.sourceOffset(forDisplayed: 8) == units.length)
        // Inside a block, offsets map as the document's map maps them.
        let documentStart = document.sourceMap.displayedOffset(forSource: units.range(of: "本文").location)
        for offset in 0..<4 {
            #expect(map.sourceOffset(forDisplayed: offset)
                == document.sourceMap.sourceOffset(forDisplayed: documentStart + offset))
        }
    }

    // MARK: Helpers

    private func blockIndex(of span: AozoraBlockSpan, in text: String) -> Int {
        AozoraDocumentParser.parse(text).blockSpans.firstIndex(of: span) ?? -1
    }
}
