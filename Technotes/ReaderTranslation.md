# 整章翻譯 in the Reader

Translations are laid out inside the reader itself (the user chose this over a separate
translation page on 2026-09-25): side by side under each paragraph (雙語對照) or in its place
(只看譯文). This note is the contract for keeping that from moving anything else.

## Two offset spaces

A translated chapter has two texts:

- **Source text** — the chapter as the builder made it. Every stored or exchanged position
  is here: reading progress, bookmarks, highlights and notes, TTS, AI selections and
  citations, TOC anchors (`anchorOffsets`), `chapterText(forSpine:)`.
- **Display text** — the source with translations spliced in. Only the layout engines see it:
  `ChapterLayout.attributedString`, `pageRanges`, chunk `charRange`s, drawing, hit-testing.

`ReaderTranslationLayout` is the map between them. With translation off, or for a chapter
that has no translations yet, there is no map and every conversion is the identity — the
untranslated reader runs exactly the code it always did.

## Positions inside a translation

Translated text has no source character of its own. A position there is
`CoreTextReadingPosition(charOffset: anchor, translationOffset: k)`:

- 雙語對照: `anchor` is the paragraph's line break (or last character for the chapter's last
  paragraph); the translation follows it in display order, so `(anchor, nil) < (anchor, k)`.
- 只看譯文: `charOffset` is the proportional source character, so turning translation off
  resumes at about the same place in the same paragraph.

`translationOffset` makes positions **round-trip exactly**: `readingPosition(atDisplay: d)`
mapped back gives `d`. Page turning depends on it — `positionAfter` must never return the
page it was given. A position whose translation is gone (translation off, translations
cleared) reads as its source character. `ReaderLocation` and the position store carry the
field; it is optional, so old saved positions decode unchanged.

## Where the conversion happens

- **Splice**: `ChapterDocumentStore` right after `buildChapter`, when
  `ReaderRenderSettings.translation.isActive`. Both engines share the store, so paged and
  scroll lay out the same document. Image-only chapters are never spliced.
- **Paged**: `ChapterLayout+Translation.swift` helpers, used by `CoreTextPageEngine`'s position
  API, `CoreTextReadingPositionMapper` and the `StablePositionResolving` defaults.
- **Page view**: annotations are converted on the way in (`setTextAnnotations`, and again
  in `configure` for a new layout); every request that leaves the view (highlight, note,
  delete, AI) names the stored range via `bookRange`. The TTS highlight hint is converted.
- **Scroll**: `CoreTextScrollEngine` keeps a map per loaded chapter; the VC converts the
  visible position, the restore target, annotations (`displayedTextAnnotations`), requests
  and the TTS hint through it.
- **Browser engine**: translated chapters always take the CoreText path
  (`BrowserChapterFailureReason.readerTranslation`), so the browser engine never sees a map.

## Deliberate limits

- Selecting translated text offers only 複製 and AI 查詞: a highlight, note or replace rule
  needs the book's own characters, and the assistant can only cite the book.
- TTS reads the source text in both modes.
- In 只看譯文 the source paragraphs are not on screen, so highlights inside them are not drawn.
- Paragraphs are cut at `\n`, U+2028 and U+2029 (`ReaderTranslationText`); a translation is
  stored under a digest of its paragraph's trimmed text, so it survives anything that moves
  offsets (font, margins, replace rules elsewhere) and is lost only when that paragraph's
  text changes (繁簡轉換, a replace rule that touches it).
- A translation looks like its paragraph's main text — the style covering most of its
  visible characters, as the book set it (a regex highlight is re-applied by the engines) —
  and takes every box that text's colour was chosen against: an inline box, the paragraph's
  block and container boxes (same ids, so they are drawn around the translation too), and a
  對話氣泡 of its own fitted to its width. A colour without its box was invisible: 诡秘之主's
  `span.look` headings are white on orange. Never kern, the language attribute, links or
  attachments.
- A paragraph with no visible text of its own — a designed chapter title, drawn from its
  render plan over clear placeholders — is left as drawn, untranslated on screen.

## Requests

A batch is at most 2,000 source characters or 40 paragraphs (`AIChapterTranslation`) and goes
out with `LLMGenerationRequest.defaultMaxTokens`. The translation and a thinking model's
reasoning both count against that budget. Under the transport's old 1024-token default every
batch came back `length` — 「AI 回覆被截斷」 in both modes — so a smaller budget needs a
measured batch to justify it.

## Tests

`ReaderTranslationLayoutTests` (splice, round trip, annotations, selections, page turning
through a real paginated chapter), `AIChapterTranslationTests` (order, batches, strict parse,
run and storage), plus the existing `ReaderPositionWalkTests`.
