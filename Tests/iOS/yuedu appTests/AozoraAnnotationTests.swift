import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora annotations")
struct AozoraAnnotationTests {
    // MARK: Forward references and ranges

    @Test("a forward reference wraps the text right before it")
    func forwardEmphasis() {
        #expect(inlines("書きたいことは多いが［＃「書きたいことは多いが」に傍点］、苦しい") == [
            .emphasis(.sesameDot, side: .right, [.text("書きたいことは多いが")]), .text("、苦しい"),
        ])
    }

    @Test("every 傍点 shape, and 左に for the other side", arguments: AozoraEmphasisStyle.allCases)
    func emphasisShapes(shape: AozoraEmphasisStyle) {
        #expect(inlines("点［＃「点」に\(shape.rawValue)］") == [.emphasis(shape, side: .right, [.text("点")])])
        #expect(inlines("点［＃「点」の左に\(shape.rawValue)］") == [.emphasis(shape, side: .left, [.text("点")])])
    }

    @Test("every 傍線 shape, and 左に for the other side", arguments: AozoraSidelineStyle.allCases)
    func sidelineShapes(shape: AozoraSidelineStyle) {
        #expect(inlines("線［＃「線」に\(shape.rawValue)］") == [.sideline(shape, side: .right, [.text("線")])])
        #expect(inlines("線［＃「線」の左に\(shape.rawValue)］") == [.sideline(shape, side: .left, [.text("線")])])
    }

    @Test("×傍点 is ばつ傍点")
    func saltireAlias() {
        #expect(inlines("点［＃「点」に×傍点］") == [.emphasis(.saltire, side: .right, [.text("点")])])
    }

    @Test("a range wraps the text between its start and its end")
    func ranges() {
        #expect(inlines("前［＃傍点］強調［＃傍点終わり］後") == [
            .text("前"), .emphasis(.sesameDot, side: .right, [.text("強調")]), .text("後"),
        ])
        #expect(inlines("［＃斜体］Italic［＃斜体終わり］") == [.italic([.text("Italic")])])
        #expect(inlines("［＃太字］太［＃太字終わり］と細") == [.bold([.text("太")]), .text("と細")])
        #expect(inlines("［＃２段階小さな文字］小［＃小さな文字終わり］") == [.size(steps: -2, [.text("小")])])
        #expect(inlines("［＃縦中横］12［＃縦中横終わり］月") == [.tateChuYoko([.text("12")]), .text("月")])
        #expect(inlines("［＃行右小書き］ッ［＃行右小書き終わり］") == [.script(.lineRight, [.text("ッ")])])
    }

    @Test("forward references for size, 縦中横, scripts, 罫囲み, 横組み and キャプション")
    func forwardStyles() {
        #expect(inlines("大［＃「大」は１段階大きな文字］") == [.size(steps: 1, [.text("大")])])
        #expect(inlines("太［＃「太」は太字］") == [.bold([.text("太")])])
        #expect(inlines("斜［＃「斜」は斜体］") == [.italic([.text("斜")])])
        #expect(inlines("12［＃「12」は縦中横］月") == [.tateChuYoko([.text("12")]), .text("月")])
        #expect(inlines("m2［＃「2」は上付き小文字］") == [.text("m"), .script(.upper, [.text("2")])])
        #expect(inlines("H2O［＃「2」は下付き小文字］") == [.text("H"), .script(.lower, [.text("2")]), .text("O")])
        #expect(inlines("箱［＃「箱」は罫囲み］") == [.boxed([.text("箱")])])
        #expect(inlines("ABC［＃「ABC」は横組み］") == [.horizontal([.text("ABC")])])
        #expect(inlines("図１［＃「図１」はキャプション］") == [.caption([.text("図１")])])
        #expect(inlines("12［＃「12」は縦中横、行右小書き］") == [.script(.lineRight, [.tateChuYoko([.text("12")])])])
    }

    @Test("a 割り注 is set in parentheses unless the text has them")
    func warichu() {
        #expect(inlines("本文［＃割り注］注釈［＃割り注終わり］続き") == [
            .text("本文"), .warichu([.text("（注釈）")]), .text("続き"),
        ])
        #expect(inlines("具（［＃割り注］そな［＃割り注終わり］）えた") == [
            .text("具（"), .warichu([.text("そな")]), .text("）えた"),
        ])
        #expect(inlines("再板［＃ここから割り注］三板［＃改行］1908［＃ここで割り注終わり］") == [
            .text("再板"), .warichu([.text("（三板"), .lineBreak, .text("1908）")]),
        ])
    }

    @Test("ruby-like notes: 注記, 左のルビ, 傍記, and a 注記付き range")
    func rubyNotes() {
        #expect(inlines("頒［＃「頒」に「ママ」の注記］") == [.ruby(base: [.text("頒")], reading: "ママ", side: .right)])
        #expect(inlines("刺［＃「刺」の左に「テフダ」の注記］") == [.ruby(base: [.text("刺")], reading: "テフダ", side: .left)])
        #expect(inlines("あいう［＃「あいう」に「・」の傍記］") == [
            .ruby(base: [.text("あいう")], reading: "・\u{00A0}・\u{00A0}・", side: .right),
        ])
        #expect(inlines("［＃注記付き］勝安房守［＃「本ト麟太郎」の注記付き終わり］") == [
            .ruby(base: [.text("勝安房守")], reading: "本ト麟太郎", side: .right),
        ])
    }

    @Test("返り点 and 訓点送り仮名 are shown small, beside the text")
    func kunten() {
        #expect(inlines("学［＃（ビテ）］而時習［＃レ］之") == [
            .text("学"), .kuntenOkurigana("ビテ"), .text("而時習"), .kaeriten("レ"), .text("之"),
        ])
        #expect(inlines("一レ点").displayedText == "一レ点")
    }

    @Test("a code in a forward reference replaces the text with that character")
    func forwardGaiji() {
        let result = inlines("酒？！［＃「？！」は一文字、第3水準1-8-77、210-11］")
        #expect(result == [
            .text("酒"),
            .gaiji(AozoraGaiji(resolved: "\u{2048}", description: "一文字",
                               code: .jis(plane: 1, row: 8, cell: 77))),
        ])
        #expect(result.displayedText == "酒\u{2048}")
    }

    @Test("styles nest: 傍点 inside 太字 inside a heading")
    func nesting() {
        #expect(body("強調［＃「強調」に傍点］［＃「強調」は太字］［＃「強調」は中見出し］").last == .heading(
            .medium, .normal, [.bold([.emphasis(.sesameDot, side: .right, [.text("強調")])])], .plain))
    }

    @Test("a forward reference matches the base text of ruby")
    func forwardReferenceOverRuby() {
        #expect(body("｜第一《だいいち》章［＃「第一章」は大見出し］").last == .heading(
            .large, .normal, [.ruby(base: [.text("第一")], reading: "だいいち", side: .right), .text("章")], .plain))
        #expect(inlines("｜大臣《だいじん》［＃「臣」に傍点］") == [
            .ruby(base: [.text("大"), .emphasis(.sesameDot, side: .right, [.text("臣")])],
                  reading: "だいじん", side: .right),
        ])
    }

    @Test("an annotation between a base and its reading keeps the ruby")
    func annotationBeforeReading() {
        #expect(inlines("｜瀕［＃「瀕」は太字］《ひん》せり") == [
            .ruby(base: [.bold([.text("瀕")])], reading: "ひん", side: .right), .text("せり"),
        ])
    }

    @Test("a missing target and an unknown annotation never reach the text")
    func missingAndUnknown() {
        let missing = AozoraDocumentParser.parse("題\n\n本文［＃「存在しない」に傍点］\n")
        #expect(lastInlines(missing) == [.text("本文")])
        #expect(missing.diagnostics[.missingForwardReference] == 1)

        let unknown = AozoraDocumentParser.parse("題\n\n本文［＃「x」は分数］続き\n")
        #expect(lastInlines(unknown) == [.text("本文"), .unknownAnnotation("「x」は分数"), .text("続き")])
        #expect(unknown.body.last?.displayedText == "本文続き")
        #expect(unknown.diagnostics[.unknownAnnotation("「…」は分数")] == 1)
    }

    @Test("an unclosed range closes at its line end; an unopened end is diagnosed")
    func unclosedRange() {
        let unclosed = AozoraDocumentParser.parse("題\n\n［＃傍点］強調だけ\n次の行\n")
        #expect(unclosed.body.suffix(2) == [
            .paragraph([.emphasis(.sesameDot, side: .right, [.text("強調だけ")])], .plain),
            .paragraph([.text("次の行")], .plain),
        ])
        #expect(unclosed.diagnostics[.unclosedRange] == 1)
        #expect(AozoraDocumentParser.parse("題\n\n本文［＃傍点終わり］\n").diagnostics[.unopenedRangeEnd] == 1)
    }

    @Test("editorial notes are kept in the tree but never shown")
    func editorialNotes() {
        let result = inlines("鋭［＃「鋭」は底本では「鈍」］い［＃ママ］")
        #expect(result == [
            .text("鋭"), .editorialNote("「鋭」は底本では「鈍」"), .text("い"), .editorialNote("ママ"),
        ])
        #expect(result.displayedText == "鋭い")
    }

    // MARK: Blocks

    @Test("headings: whole lines become heading blocks, 同行 headings run into the paragraph")
    func headings() {
        #expect(body("［＃５字下げ］一［＃「一」は中見出し］").last == .heading(
            .medium, .normal, [.text("一")], AozoraParagraphStyle(firstLineIndent: 5, indent: 5)))
        #expect(body("［＃大見出し］第一章［＃大見出し終わり］").last == .heading(
            .large, .normal, [.text("第一章")], .plain))
        #expect(inlines("一月十日［＃「一月十日」は同行中見出し］　午前") == [
            .heading(.medium, .sameLine, [.text("一月十日")]), .text("　午前"),
        ])
        #expect(inlines("［＃窓小見出し］要旨［＃窓小見出し終わり］　本文") == [
            .heading(.small, .window, [.text("要旨")]), .text("　本文"),
        ])
    }

    @Test("the lines of ［＃ここから…見出し］ make one heading")
    func multilineHeading() {
        let blocks = body("［＃ここから中見出し］\n含羞《はぢらひ》\n\n　　――在りし日の歌――\n［＃ここで中見出し終わり］\n本文")
        #expect(blocks.suffix(2) == [
            .heading(.medium, .normal, [
                .ruby(base: [.text("含羞")], reading: "はぢらひ", side: .right),
                .lineBreak, .lineBreak, .text("　　――在りし日の歌――"),
            ], .plain),
            .paragraph([.text("本文")], .plain),
        ])
    }

    @Test("page breaks", arguments: [
        ("改ページ", AozoraPageBreakKind.page), ("改頁", .page), ("改丁", .leaf),
        ("改段", .column), ("改見開き", .spread),
    ])
    func pageBreaks(command: String, kind: AozoraPageBreakKind) {
        #expect(body("前\n［＃\(command)］\n後").suffix(3) == [
            .paragraph([.text("前")], .plain), .pageBreak(kind), .paragraph([.text("後")], .plain),
        ])
    }

    @Test("字下げ: one line, a block, hanging indents, and a block replacing an open one")
    func indents() {
        #expect(style(body("［＃３字下げ］本文").last) == AozoraParagraphStyle(firstLineIndent: 3, indent: 3))
        #expect(style(body("［＃天から２字下げ］本文").last) == AozoraParagraphStyle(firstLineIndent: 2, indent: 2))
        let block = body("［＃ここから２字下げ］\n一\n二\n［＃ここで字下げ終わり］\n三")
        #expect(block.suffix(3).map(style) == [
            AozoraParagraphStyle(firstLineIndent: 2, indent: 2), AozoraParagraphStyle(firstLineIndent: 2, indent: 2),
            .plain,
        ])
        #expect(style(body("［＃ここから改行天付き、折り返して３字下げ］\n長い行").last)
                == AozoraParagraphStyle(firstLineIndent: 0, indent: 3))
        #expect(style(body("［＃ここから２字下げ、折り返して３字下げ］\n長い行").last)
                == AozoraParagraphStyle(firstLineIndent: 2, indent: 3))
        let replaced = AozoraDocumentParser.parse("題\n\n［＃ここから２字下げ］\n一\n［＃ここから４字下げ］\n二\n［＃ここで字下げ終わり］\n三\n")
        #expect(replaced.body.suffix(3).map(style) == [
            AozoraParagraphStyle(firstLineIndent: 2, indent: 2), AozoraParagraphStyle(firstLineIndent: 4, indent: 4),
            .plain,
        ])
        #expect(replaced.diagnostics[.unclosedRange] == 0)
    }

    @Test("地付き and 字上げ: at the line start, after the text, and splitting a line")
    func endAlignment() {
        #expect(style(body("［＃地付き］（了）").last) == AozoraParagraphStyle(endAlignment: 0))
        #expect(style(body("［＃地から２字上げ］東京　子規　拝").last) == AozoraParagraphStyle(endAlignment: 2))
        #expect(style(body("（明治四十四年一月）［＃地付き］").last) == AozoraParagraphStyle(endAlignment: 0))
        #expect(body("　青年は詰問する間もなかった。［＃地付き］（未完）").suffix(2) == [
            .paragraph([.text("　青年は詰問する間もなかった。")], .plain),
            .paragraph([.text("（未完）")], AozoraParagraphStyle(endAlignment: 0)),
        ])
        #expect(style(body("［＃ここから地から１字上げ］\n署名").last) == AozoraParagraphStyle(endAlignment: 1))
    }

    @Test("block styles: size, 字詰め, 罫囲み, 横組み, キャプション, 太字")
    func blockStyles() {
        #expect(style(body("［＃ここから１段階小さな文字］\n小").last) == AozoraParagraphStyle(sizeSteps: -1))
        #expect(style(body("［＃ここから１６字詰め］\n詰").last) == AozoraParagraphStyle(characterLimit: 16))
        #expect(style(body("［＃ここから罫囲み］\n囲").last) == AozoraParagraphStyle(isBoxed: true))
        #expect(style(body("［＃ここから横組み］\n横").last) == AozoraParagraphStyle(isHorizontal: true))
        #expect(style(body("［＃ここからキャプション］\n説明").last) == AozoraParagraphStyle(isCaption: true))
        #expect(body("［＃ここから太字］\n太").last == .paragraph([.bold([.text("太")])], .plain))
    }

    @Test("figures: alone on a line, with a caption, and set into text")
    func images() {
        #expect(body("［＃挿絵１（fig226_01.png、横570×縦829）入る］").last == .image(
            source: "fig226_01.png", width: 570, height: 829, caption: []))
        #expect(body("［＃「村の博突打　1914年」のキャプション付きの図（fig728_01.png、横650×縦698）入る］").last == .image(
            source: "fig728_01.png", width: 650, height: 698, caption: [.text("村の博突打　1914年")]))
        #expect(inlines("人形［＃図６（fig50713_06.png、横36×縦56）入る］は") == [
            .text("人形"), .image(source: "fig50713_06.png", width: 36, height: 56, caption: []), .text("は"),
        ])
    }

    @Test("［＃改行］ breaks the line")
    func lineBreak() {
        #expect(inlines("上［＃改行］下") == [.text("上"), .lineBreak, .text("下")])
    }

    @Test("a block left open at the end of the body is diagnosed")
    func unclosedBlock() {
        #expect(AozoraDocumentParser.parse("題\n\n［＃ここから２字下げ］\n本文\n").diagnostics[.unclosedRange] == 1)
    }

    @Test("the public-domain download: notes resolve and the signature is end-aligned")
    func publicDomainFixture() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/TXTEncodings/aozora-neko-jijo.txt")
        let document = AozoraDocumentParser.parse(try TXTFileReader.readTextFile(url: fixture))
        let text = document.body.map(\.displayedText).joined(separator: "\n")
        #expect(!text.contains("［＃"))
        #expect(document.body.contains(.paragraph([.text("東京　子規　拝")], AozoraParagraphStyle(endAlignment: 2))))
        let emphasised = document.body.flatMap(inlines(of:)).flatMap(\.styleNames)
        #expect(emphasised.filter { $0 == "傍点" }.count == 3)
        #expect(emphasised.filter { $0 == "傍線" }.count == 2)
        #expect(document.diagnostics.isEmpty)
    }

    // MARK: Helpers

    private func body(_ text: String) -> [AozoraBlock] {
        AozoraDocumentParser.parse("題\n\n" + text + "\n").body
    }

    private func inlines(_ line: String) -> [AozoraInline] {
        lastInlines(AozoraDocumentParser.parse("題\n\n" + line + "\n"))
    }

    private func lastInlines(_ document: AozoraDocument) -> [AozoraInline] {
        document.body.last.map(inlines(of:)) ?? []
    }

    private func inlines(of block: AozoraBlock) -> [AozoraInline] {
        switch block {
        case .paragraph(let inlines, _), .heading(_, _, let inlines, _): return inlines
        case .pageBreak, .image: return []
        }
    }

    private func style(_ block: AozoraBlock?) -> AozoraParagraphStyle? {
        switch block {
        case .paragraph(_, let style)?, .heading(_, _, _, let style)?: return style
        default: return nil
        }
    }
}

private extension AozoraInline {
    /// The 傍点 and 傍線 shapes in this node and below it.
    var styleNames: [String] {
        switch self {
        case .emphasis(let shape, _, let children): return [shape.rawValue] + children.flatMap(\.styleNames)
        case .sideline(let shape, _, let children): return [shape.rawValue] + children.flatMap(\.styleNames)
        case .ruby(let children, _, _), .bold(let children), .italic(let children), .size(_, let children),
             .tateChuYoko(let children), .script(_, let children), .warichu(let children),
             .heading(_, _, let children), .boxed(let children), .horizontal(let children),
             .caption(let children), .image(_, _, _, let children):
            return children.flatMap(\.styleNames)
        case .text, .gaiji, .kaeriten, .kuntenOkurigana, .lineBreak, .editorialNote, .unknownAnnotation:
            return []
        }
    }
}
