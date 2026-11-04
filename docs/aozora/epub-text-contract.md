# The text both engines read from a converted Aozora chapter

A reading position is `(spineIndex, charOffset)`, and `charOffset` indexes the text of whichever engine lays the chapter out: `BrowserChapterLayout.sourceText` under BrowserAuto, or the legacy builder's attributed string after a fallback. A converted Aozora book stores positions against its chapters, so both engines must read the same text from them. `AozoraEngineParityTests` pins this; anyone changing `AozoraXHTMLWriter`'s markup or its stylesheet keeps it green.

## What each engine reads

A temporary probe on 2026-10-06 gave both engines the same chapters, horizontal and vertical, paged and scroll, on the iOS 27 simulator:

| XHTML | BrowserAuto | Legacy |
|---|---|---|
| `<p>A</p><p>B</p>` | `AB`: blocks get no separator | `A\nB\n` |
| `<p>A<br class="eol"/></p>`, with `br.eol { display: block }` | `A\n` | `A\n` |
| `<p>A<br/></p>` | `A\n` | `A`, U+2028, `\n` |
| `<br/>` inside a block | `\n` | U+2028 (same length) |
| `<h1>` | like `<h2>` | adds a leading `\n` |
| `<img>`, inline or alone in a block | U+FFFC since YueduCoreText 0.11 (`SourceTextBuilder.appendPicture`); nothing before | U+FFFC |
| ASCII space at a block's edge or next to `<br/>` | kept | dropped |
| two ASCII spaces, or a tab | one space | one space |
| `white-space: pre-wrap` | honoured | ignored |
| `"q"`, `'r'` | unchanged | curled (same length) |
| `page-break-before` | ignored | adds U+200B |
| U+3000, also at edges and alone in a block | kept | kept |
| ruby, `<span>`, `<sub>`, `<sup>`, `<em>`, nested `<div>` blocks | identical | identical |

BrowserAuto's paged and scroll texts were identical. It fell back to legacy for a non-default `ruby-position` (until YueduCoreText 0.15), and, in vertical writing, for any chapter holding an `<img>` (`VerticalTextSupport.accepts`, until 0.16).

## The rules the writer follows

- **End of block.** Every block ends with `<br class="eol"/>`, and the stylesheet sets `br.eol { display: block }`. A blank line is `<p><br class="eol"/></p>`. A chapter's text is each block's displayed text followed by `"\n"`.
- **Line break inside a block.** `<br/>`. Legacy reads U+2028, one unit like BrowserAuto's `"\n"`.
- **Headings.** `<h3>`, `<h4>`, `<h5>`, as aozora2html writes them; never `<h1>`.
- **Page breaks.** They end the chapter; the stylesheet has no page-break property.
- **Stylesheet limits.** No `writing-mode`, `@media`, `calc()`, tables, floats or positioning. `ruby-position` only sets a ruby's side: `ruby.left` for 左ルビ, and `ruby.over` for a right ruby inside one (converter version 4).
- **The stylesheet** (converter version 2) is written per book: the base rules, then a rule for each class the book's chapters use, in a fixed order (`AozoraXHTMLWriter.stylesheet(forChapters:)`). Its values follow 青空文庫's aozora.css and the inline styles aozora2html writes, in logical properties so one stylesheet serves both writing modes; font-size keywords are written in `rem`. A run of 罫囲み blocks is wrapped in one `<div class="keigakomi">`, which adds no text in either engine.
- **Raised and lowered runs** (converter version 5). 返り点 are `.kaeriten { font-size: 0.5em; vertical-align: sub }` and 訓点送り仮名 `.okurigana { font-size: 0.5em; vertical-align: super }`; 割り注 is `.warichu { font-size: 0.5em }` inside the （） the parser adds, and ゴシック体 is `.gothic { font-family: sans-serif }`. Both engines move a `super` or `sub` run by its parent's size, as WebKit does (YueduCoreText's `VerticalAlignShift`; legacy since this version): in vertical writing, up is right of the column. None of it changes the text.
- **U+3000.** Written as `&#12288;`. Legacy's cleanup of spaces between Han characters never ran (its pattern failed to compile) and was deleted in 55711b23; `HTMLCJKSeparatorPreservationTests` now pins U+3000 between Han verbatim, and the character reference stays, harmless.
- **ASCII whitespace.** Collapsed in the displayed text itself, as HTML collapses it (`AozoraDocumentParser`, Phase 1b Task 12): the engines disagree only about spaces at a block's edge, and there are none left.
- **Quotes.** Legacy curls straight quotes into characters of the same length; the parity test reads them back as straight.

## The ruby exception

BrowserAuto lays out a ruby over a base of inline text that shows something (`HorizontalRubySupport`), on either side of it; since YueduCoreText 0.15, a ruby whose base is one ruby; and since 0.17, a ruby whose base holds rubies beside its text, each inner ruby of one base and one `rt`. It lays out no `<rtc>`, no `<img>` in a base, and no ruby nested two deep. A chapter holding such a ruby goes to legacy in both writing modes. Both engines read the same text from it, so positions hold; only the engine changes. `AozoraEngineParityTests` pins both cases.

- **A word with readings on both sides**, a ruby and a 左に…のルビ on the same text, is written as a ruby inside a ruby, and BrowserAuto lays it out (converter version 4). So does **a ruby over part of another ruby's base**: a note on one character of a word with ruby, 「（ママ）」 most often (`<ruby><ruby>制<rt>（ママ）</rt></ruby>肘<rt>ちゅう</rt></ruby>`), an inner ruby inside an `em`, and one ruby over a whole kanbun sentence (59114, and 58400 spine 75). A ruby inside a ruby is in 82 chapters in 31 works of the corpus; `AozoraCorpusTests` scans every one in both writing modes and finds none left to legacy (YueduCoreText 0.17.0).
- **A ruby over a figure** stays the exception. 黒死館殺人事件 sets Hebrew letters this way (a figure, with the letter's name as its reading), and the ruby keeps the figure as its base: 19 rubies, all in that one work. When the figure's file is missing, as for a `.txt` imported without its zip, the ruby would annotate nothing, and the writer leaves it out.

## Figures

Both engines read one U+FFFC per figure: legacy always has, and BrowserAuto since YueduCoreText 0.11 (2026-11-01), whose migration moved positions saved before it. The engines agree, so a chapter with figures keeps its positions whichever lays it out.

- The planned chapter text, and the manifest's lengths and source maps, leave figures out: a figure contributes only its caption. An offset after a figure is one unit later in either engine for each figure before it. `AozoraEngineParityTests` removes the U+FFFC before comparing and counts them.
- Works with figures are 2.8% of the corpus.
- BrowserAuto lays figures out in vertical writing too, since YueduCoreText 0.16: upright at their size, an inline one centred on its column, a block one at the column's start. A chapter with figures goes to legacy only for another reason; in the corpus, that is the ruby over a figure.
