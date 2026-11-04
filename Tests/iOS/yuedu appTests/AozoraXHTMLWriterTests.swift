import Foundation
import Testing
@testable import yuedu_app

@Suite("Aozora XHTML writer")
struct AozoraXHTMLWriterTests {
    // MARK: Blocks

    @Test("a paragraph ends with the end-of-block break")
    func paragraph() {
        #expect(body("本文") == #"<p>本文<br class="eol"/></p>"#)
    }

    @Test("an empty paragraph is only the break")
    func emptyParagraph() {
        #expect(body("上\n\n下") == #"<p>上<br class="eol"/></p><p><br class="eol"/></p><p>下<br class="eol"/></p>"#)
    }

    @Test("paragraph styles become aozora2html classes", arguments: [
        ("［＃ここから２字下げ］\n本文\n［＃ここで字下げ終わり］", "jisage_2"),
        ("［＃ここから２字下げ、折り返して３字下げ］\n本文\n［＃ここで字下げ終わり］", "jisage_3 first_2"),
        ("本文［＃地付き］", "chitsuki_0"),
        ("［＃ここから地から１字上げ］\n本文\n［＃ここで字上げ終わり］", "chitsuki_1"),
        ("［＃ここから１６字詰め］\n本文\n［＃ここで字詰め終わり］", "jizume_16"),
        ("［＃ここから１段階小さな文字］\n本文\n［＃ここで小さな文字終わり］", "sho1"),
    ])
    func paragraphClasses(text: String, classes: String) {
        #expect(body(text) == #"<p class="\#(classes)">本文<br class="eol"/></p>"#)
    }

    @Test("a run of 罫囲み blocks is one box around them")
    func boxedBlocks() {
        #expect(body("前\n［＃ここから罫囲み］\n上\n下\n［＃ここで罫囲み終わり］\n後")
            == #"<p>前<br class="eol"/></p><div class="keigakomi"><p class="keigakomi">上<br class="eol"/></p>"#
            + #"<p class="keigakomi">下<br class="eol"/></p></div><p>後<br class="eol"/></p>"#)
        #expect(body("［＃ここから罫囲み］\n本文\n［＃ここで罫囲み終わり］")
            == #"<div class="keigakomi"><p class="keigakomi">本文<br class="eol"/></p></div>"#)
    }

    @Test("heading blocks are h3, h4 and h5 with an id", arguments: [
        ("大見出し", "h3", "o-midashi"),
        ("中見出し", "h4", "naka-midashi"),
        ("小見出し", "h5", "ko-midashi"),
    ])
    func headingBlocks(command: String, tag: String, name: String) throws {
        let text = "題\n\n前\n章［＃「章」は\(command)］\n"
        let (xhtml, document) = try written(text)
        let index = try #require(document.blockSpans.firstIndex { span in
            if case .heading = AozoraXHTMLWriter.block(span, in: document) { return true }
            return false
        })
        #expect(xhtml.contains(#"<\#(tag) class="\#(name)" id="h\#(index)">章<br class="eol"/></\#(tag)>"#))
    }

    @Test("a 同行見出し is a span with its class and an id")
    func sameLineHeading() throws {
        let text = "題\n\n一［＃「一」は同行中見出し］　本文\n"
        let (xhtml, document) = try written(text)
        let index = document.blockSpans.count - 1
        #expect(xhtml.contains(
            #"<p><span class="dogyo-naka-midashi" id="h\#(index)">一</span>&#12288;本文<br class="eol"/></p>"#))
    }

    // MARK: Inlines

    @Test("inline constructs map to aozora2html markup", arguments: [
        ("上［＃改行］下", #"上<br/>下"#),
        ("｜漢字《かんじ》", #"<ruby>漢字<rt>かんじ</rt></ruby>"#),
        ("刺［＃「刺」の左に「テフダ」の注記］", #"<ruby class="left">刺<rt>テフダ</rt></ruby>"#),
        // Readings on both sides: inside a left ruby a right one names its side.
        ("室適《しつてき》［＃「室適」の左に「オクサマ」のルビ］",
         #"<ruby class="left"><ruby class="over">室適<rt>しつてき</rt></ruby><rt>オクサマ</rt></ruby>"#),
        ("｜真似《まね》［＃「真似」に「ママ」の注記］", #"<ruby><ruby>真似<rt>まね</rt></ruby><rt>ママ</rt></ruby>"#),
        ("強調［＃「強調」に傍点］", #"<em class="sesame_dot">強調</em>"#),
        ("点［＃「点」の左に傍点］", #"<em class="sesame_dot_after">点</em>"#),
        ("線［＃「線」に傍線］", #"<em class="underline_solid">線</em>"#),
        ("線［＃「線」の左に傍線］", #"<em class="overline_solid">線</em>"#),
        ("太［＃「太」は太字］", #"<span class="futoji">太</span>"#),
        ("斜［＃「斜」は斜体］", #"<span class="shatai">斜</span>"#),
        ("大［＃「大」は１段階大きな文字］", #"<span class="dai1">大</span>"#),
        ("12［＃「12」は縦中横］", #"<span class="tcy">12</span>"#),
        ("x2［＃「2」は上付き小文字］", #"x<sup class="superscript">2</sup>"#),
        ("x2［＃「2」は下付き小文字］", #"x<sub class="subscript">2</sub>"#),
        ("学［＃（ビテ）］而時習［＃レ］之", #"学<sup class="okurigana">ビテ</sup>而時習<sub class="kaeriten">レ</sub>之"#),
        ("本［＃割り注］注［＃割り注終わり］", #"本<span class="warichu">（注）</span>"#),
        ("箱［＃「箱」は罫囲み］", #"<span class="keigakomi">箱</span>"#),
        ("ABC［＃「ABC」は横組み］", #"<span class="yokogumi">ABC</span>"#),
        ("図１［＃「図１」はキャプション］", #"<span class="caption">図１</span>"#),
        ("※［＃「口＋世」、ページ数-行数］", #"※<span class="notes">（口＋世）</span>"#),
        ("本文［＃「本文」はママ］", "本文"),
        ("本文［＃何かの未知の注記］", "本文"),
        ("A&B<C>", "A&amp;B&lt;C&gt;"),
        ("　本文", "&#12288;本文"),
    ])
    func inlines(text: String, markup: String) {
        #expect(body(text) == "<p>\(markup)<br class=\"eol\"/></p>")
    }

    // MARK: Figures

    @Test("a figure in a line keeps its size, and its caption in alt and after it")
    func inlineFigure() {
        let images = ["fig1.png": "../images/fig1.png"]
        #expect(body("前［＃挿絵１（fig1.png、横100×縦50）入る］後", images: images)
            == #"<p>前<img class="illustration" src="../images/fig1.png" alt="" width="100" height="50"/>後<br class="eol"/></p>"#)
        #expect(body("前［＃「猫の図」のキャプション付きの図（fig1.png、横100×縦50）入る］後", images: images)
            == #"<p>前<img class="illustration" src="../images/fig1.png" alt="猫の図" width="100" height="50"/><span class="caption">猫の図</span>後<br class="eol"/></p>"#)
    }

    @Test("a figure alone on its line is a figure paragraph")
    func figureBlock() {
        #expect(body("［＃挿絵１（fig1.png、横100×縦50）入る］", images: ["fig1.png": "../images/fig1.png"])
            == #"<p class="figure"><img class="illustration" src="../images/fig1.png" alt="" width="100" height="50"/><br class="eol"/></p>"#)
    }

    @Test("a figure whose file is missing leaves its caption only")
    func missingFigure() {
        #expect(body("前［＃「猫の図」のキャプション付きの図（fig1.png、横100×縦50）入る］後")
            == #"<p>前<span class="caption">猫の図</span>後<br class="eol"/></p>"#)
    }

    @Test("a ruby over a figure keeps the figure as its base, and goes when the file is missing")
    func rubyOverFigure() {
        // As 黒死館殺人事件 sets Hebrew letters: ［＃ヘブライ文字「YOD」（fig1317_24.png…）入る］《ヨッド》.
        let line = "文字［＃ヘブライ文字「YOD」（fig1.png、横15×縦23）入る］《ヨッド》まで"
        #expect(body(line, images: ["fig1.png": "../images/fig1.png"])
            == #"<p>文字<ruby><img class="illustration" src="../images/fig1.png" alt="" width="15" height="23"/><rt>ヨッド</rt></ruby>まで<br class="eol"/></p>"#)
        #expect(body(line) == #"<p>文字まで<br class="eol"/></p>"#)
    }

    // MARK: Document

    @Test("the document is XHTML in Japanese with its title and stylesheet, and no whitespace between blocks")
    func wholeDocument() throws {
        let (xhtml, _) = try written("題\n\n第一章［＃「第一章」は中見出し］\n上\n下\n")
        #expect(xhtml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"))
        #expect(xhtml.contains(#"<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="ja" lang="ja">"#))
        #expect(xhtml.contains("<title>第一章</title>"))
        #expect(xhtml.contains(#"<link rel="stylesheet" type="text/css" href="../style/aozora.css"/>"#))
        let inner = try #require(xhtml.range(of: "<body>").flatMap { start in
            xhtml.range(of: "</body>").map { String(xhtml[start.upperBound..<$0.lowerBound]) }
        })
        #expect(!inner.contains("\n"))
        #expect(inner.contains(#"</h4><p>上<br class="eol"/></p><p>下"#))
    }

    @Test("a book with no classes gets the base rules only")
    func baseStylesheet() {
        let css = AozoraXHTMLWriter.stylesheet(forChapters: [body("本文")])
        #expect(css == AozoraXHTMLWriter.baseStylesheet)
        #expect(css.contains("br.eol { display: block; }"))
        #expect(css.contains("p { margin: 0; }"))
        #expect(css.contains("h3, h4, h5 { margin: 0; }"))
        #expect(css.contains(".notes { font-size: smaller; }"))
    }

    @Test("the stylesheet has a rule for each class the book uses, and no others")
    func rulesForUsedClasses() {
        let chapters = [
            body("［＃ここから２字下げ］\n本文\n［＃ここで字下げ終わり］"),
            body("［＃ここから１０字下げ］\n本文\n［＃ここで字下げ終わり］\n［＃ここから２字下げ］\n本文\n［＃ここで字下げ終わり］"),
        ]
        let css = AozoraXHTMLWriter.stylesheet(forChapters: chapters)
        #expect(css == AozoraXHTMLWriter.baseStylesheet
            + ".jisage_2 { margin-inline-start: 2em; }\n.jisage_10 { margin-inline-start: 10em; }\n")
        #expect(AozoraXHTMLWriter.stylesheet(forChapters: chapters.reversed()) == css, "the same bytes whatever the order")
    }

    @Test("each class maps to its rule", arguments: [
        ("［＃ここから２字下げ、折り返して３字下げ］\n本文\n［＃ここで字下げ終わり］",
         [".jisage_3 { margin-inline-start: 3em; }", ".jisage_3.first_2 { text-indent: -1em; }"]),
        ("［＃ここから改行天付き、折り返して３字下げ］\n本文\n［＃ここで字下げ終わり］",
         [".jisage_3.first_0 { text-indent: -3em; }"]),
        ("本文［＃地付き］", [".chitsuki_0 { text-align: end; margin-inline-end: 0em; }"]),
        ("［＃ここから地から１字上げ］\n本文\n［＃ここで字上げ終わり］", [".chitsuki_1 { text-align: end; margin-inline-end: 1em; }"]),
        ("［＃ここから１６字詰め］\n本文\n［＃ここで字詰め終わり］", [".jizume_16 { max-inline-size: 16em; }"]),
        ("［＃ここから１段階小さな文字］\n本文\n［＃ここで小さな文字終わり］", [".sho1 { font-size: 0.8125rem; }"]),
        ("大［＃「大」は２段階大きな文字］", [".dai2 { font-size: 1.5rem; }"]),
        ("大［＃「大」は４段階大きな文字］", [".dai4 { font-size: 2rem; }"]),
        ("小［＃「小」は３段階小さな文字］", [".sho3 { font-size: 0.5625rem; }"]),
        ("第一章［＃「第一章」は大見出し］", [".o-midashi { font-size: 1.25em; font-weight: bold; }"]),
        ("一［＃「一」は同行中見出し］　本文", [".dogyo-naka-midashi { font-size: 1.125rem; font-weight: bold; }"]),
        ("節［＃「節」は小見出し］", [".ko-midashi { font-size: 1rem; font-weight: bold; }"]),
        ("［＃ここから罫囲み］\n本文\n［＃ここで罫囲み終わり］",
         ["div.keigakomi { border: 1px solid; padding-block-start: 0.5em; padding-block-end: 0.5em; padding-inline-start: 1em; padding-inline-end: 0.5em; }", "span.keigakomi { border: 1px solid; }"]),
        ("太［＃「太」は太字］と斜［＃「斜」は斜体］", [".futoji { font-weight: bold; }", ".shatai { font-style: italic; }"]),
        ("図［＃「図」はキャプション］", [".caption { font-size: 0.8125rem; font-weight: bold; }"]),
        ("x2［＃「2」は上付き小文字］", [".superscript { font-size: 0.8125rem; }"]),
        ("学［＃（ビテ）］而時習［＃レ］之", [".okurigana { font-size: 0.8125rem; }", ".kaeriten { font-size: 0.8125rem; }"]),
        ("12［＃「12」は縦中横］", [".tcy { text-combine-upright: all; }"]),
        ("室適《しつてき》［＃「室適」の左に「オクサマ」のルビ］",
         ["ruby.left { -webkit-ruby-position: after; ruby-position: under; }",
          "ruby.over { -webkit-ruby-position: before; ruby-position: over; }"]),
        ("強調［＃「強調」に傍点］と点［＃「点」の左に傍点］",
         [".sesame_dot { font-style: normal; -webkit-text-emphasis-style: filled sesame; text-emphasis-style: filled sesame; -webkit-text-emphasis-position: over right; text-emphasis-position: over right; }",
          ".sesame_dot_after { font-style: normal; -webkit-text-emphasis-style: filled sesame; text-emphasis-style: filled sesame; -webkit-text-emphasis-position: under left; text-emphasis-position: under left; }"]),
        ("×［＃「×」にばつ傍点］と蛇［＃「蛇」に蛇の目傍点］",
         [#".saltire { font-style: normal; -webkit-text-emphasis-style: "×"; text-emphasis-style: "×"; -webkit-text-emphasis-position: over right; text-emphasis-position: over right; }"#,
          ".fisheye { font-style: normal; -webkit-text-emphasis-style: open double-circle; text-emphasis-style: open double-circle; -webkit-text-emphasis-position: over right; text-emphasis-position: over right; }"]),
        ("線［＃「線」に傍線］と線［＃「線」の左に波線］",
         [".underline_solid { font-style: normal; text-decoration-line: underline; text-decoration-style: solid; text-underline-position: right; }",
          ".overline_wave { font-style: normal; text-decoration-line: underline; text-decoration-style: wavy; text-underline-position: left; }"]),
        ("線［＃「線」に鎖線］", [".underline_dotted { font-style: normal; text-decoration-line: underline; text-decoration-style: dotted; text-underline-position: right; }"]),
    ] as [(String, [String])])
    func classRule(text: String, rules: [String]) {
        let css = AozoraXHTMLWriter.stylesheet(forChapters: [body(text)])
        for rule in rules {
            #expect(css.contains(rule + "\n"), "\(rule) in \(css)")
        }
    }

    @Test("the stylesheet sets no colour, writing mode or the other properties the contract rules out")
    func stylesheetLimits() {
        let css = AozoraXHTMLWriter.stylesheet(forChapters: [body(
            "［＃ここから罫囲み］\n本文\n［＃ここで罫囲み終わり］\n強調［＃「強調」に傍点］、12［＃「12」は縦中横］、図［＃「図」はキャプション］、"
                + "室適《しつてき》［＃「室適」の左に「オクサマ」のルビ］")])
        #expect(!css.contains("color"))
        for forbidden in ["writing-mode", "@media", "calc(", "float"] {
            #expect(!css.contains(forbidden), "\(forbidden)")
        }
        // `ruby-position` only sets a ruby's side: 左ルビ, and a right ruby inside one.
        for line in css.split(separator: "\n") where line.contains("ruby-position") {
            #expect(line.hasPrefix("ruby.left ") || line.hasPrefix("ruby.over "), "\(line)")
        }
        // The `position` property: `text-emphasis-position` and `text-underline-position` place marks.
        #expect(css.range(of: #"(?<![-\w])position\s*:"#, options: .regularExpression) == nil, "\(css)")
    }

    // MARK: Helpers

    /// The last chapter of a one-line document, written; with its document.
    private func written(_ text: String, images: [String: String] = [:]) throws -> (String, AozoraDocument) {
        let document = AozoraDocumentParser.parse(text)
        let chapter = try #require(AozoraChapterPlanner.plan(document, source: text).last)
        return (AozoraXHTMLWriter.document(for: chapter, in: document, images: images), document)
    }

    /// The `<body>` content of the chapter holding `line`; empty when there is none,
    /// which fails the comparison that asked for it.
    private func body(_ line: String, images: [String: String] = [:]) -> String {
        let text = "題\n\n" + line + "\n"
        let document = AozoraDocumentParser.parse(text)
        guard let chapter = AozoraChapterPlanner.plan(document, source: text).last else { return "" }
        let xhtml = AozoraXHTMLWriter.document(for: chapter, in: document, images: images)
        guard let start = xhtml.range(of: "<body>"), let end = xhtml.range(of: "</body>") else { return "" }
        return String(xhtml[start.upperBound..<end.lowerBound])
    }
}
