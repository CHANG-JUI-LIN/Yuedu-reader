# Vertical Writing

Vertical EPUB/TXT pages use `ReaderWritingMode.verticalRTL`,
`kCTFrameProgressionAttributeName = rightToLeft`, and
`kCTVerticalFormsAttributeName = true`.

Both engines set CJK text through the same pass in YueduCoreText's
`YueduCoreTextTypography` module, in both writing modes. The rules and the
decisions behind them are in
`docs/superpowers/plans/2026-10-06-vertical-typography.md` ("What landed").

## The shared pass

| Step | Function | What it does |
| --- | --- | --- |
| Style | `CJKTypographyStyleResolver` (app) | One `CJKTypographyStyle` per book and 繁簡轉換: Traditional, Simplified, Japanese or Korean, decided by the first text the reader shows that tells its script (converters label Traditional text `zh-cn`). Only text that shows no script falls back to the declared language, then the interface language. |
| Fonts | `CJKTypography.applyFonts` | Han and CJK punctuation in the style's font (PingFang TC/SC, Hiragino Sans, Apple SD Gothic Neo), kana in Hiragino Sans, Hangul in Apple SD Gothic Neo. Dashes, ellipses, quotation marks and middle dots next to CJK text go with it. A font that has the character keeps it. `replacedFontAttribute` keeps line heights on the original font. |
| Positions | `CJKTypography.applyPositions` | 、。，．：；？！ where the style puts them: centred for Taiwan and Hong Kong, after the text for the Mainland (CLREQ), JLREQ's places for Japanese. Only fonts that set them elsewhere move: baseline offset across the line, a pair of opposite kerns along it, so advances stay. System fonts need no move. |
| Spacing | `CJKTypography.applySpacing` | CLREQ: a pair of adjacent marks involving a bracket takes 1.5 em instead of 2, the space taken so the bracket stays against its text. ：；？！ in vertical text, and ？！ in Taiwan and Hong Kong horizontal text, never shrink. Japanese (JLREQ §3.1.4) squeezes only between the marks, so ？」 stays 2 em. Amounts come from each mark's measured ink. |
| Orientation | `CJKTypography.applyOrientation` | CSS Writing Modes 3 `text-orientation: mixed` by UAX #50 (`VerticalOrientation`): `U` upright, `Tu` upright with the font's vertical alternate, `Tr` the vertical alternate or sideways, `R` (ASCII letters and digits) sideways and centred on the column (`centreSideways`, added to any existing baseline offset). |

`CJKTypography.apply` runs fonts, positions and spacing. Callers:

- Legacy: `NodeAttributedStringRenderer` runs it over the whole chapter (and the
  TXT path's inline content) after 繁簡轉換 and after `CJKTypographyProcessor`
  has curled quotes. `CoreTextPaginator.preparedAttributedString` then sets the
  vertical-forms attribute and runs `applyOrientation`.
- BrowserAuto: `InlineLayout` runs it per inline formatting context when the
  configuration carries a `cjkTypographyStyle`
  (`BrowserLayoutPageEngine.makeBrowserConfig`), then orientation in vertical
  writing.

No character is ever replaced: there are no presentation forms (︒︐﹁…) and
no Latin-run regex any more. Reading positions, search, copy and TTS see the
book's own characters.

The pass is timed as `cjk.typography.prepare`: a `⏱` line per legacy chapter,
and a Points of Interest interval per paragraph in YueduCoreText.

## Coordinate Rules

CoreText reuses horizontal API names, but vertical mode changes their axis
meaning:

| API value | Horizontal meaning | Vertical-rl meaning |
| --- | --- | --- |
| `CTLineGetOffsetForStringIndex` | x advance | inline advance from column top downward |
| `CTLineGetTypographicBounds width` | x extent | inline column length |
| `ascent` | above baseline | block-start/right extent |
| `descent` | below baseline | block-end/left extent |
| `lineOrigin.x` | line start x | column baseline x |
| `lineOrigin.y` | baseline y | column top y in CoreText coordinates |

When converting to UIKit coordinates:

- column top y = `layoutHeight - (contentPathRect.minY + lineOrigin.y)`
- column x extents come from `baselineX - descent` and `baselineX + ascent`

Two traps:

- **Character boundaries after a squeeze.** `CTLineGetOffsetForStringIndex`
  splits the kern on the character before a boundary, so after a negative kern
  the boundary lands half the kern inside the next glyph. Selection, highlight,
  narration and hit testing go through `GlyphBoundary.offset(_:at:)` and
  `index(_:at:)` in both engines.
- **Glyph positions in vertical runs** are in rotated space. Measure advances
  with `CTRunGetAdvances`, not positions.

## 縦中横 (text-combine-upright)

Only authored: `text-combine-upright: all | digits n` and the prefixed
`-webkit-text-combine`, `-epub-text-combine(-horizontal)` and
`-ms-text-combine-horizontal`. Digits and Latin are never combined
automatically. `TextCombineUpright` parses the value and segments digit runs;
`CombinedUpright.line` composes the cell (letter-spacing ignored, scaled
horizontally into one em when wider).

- BrowserAuto: each text node or digit run is an atomic inline box one em
  long; the walker emits a horizontal text fragment centred in it.
- Legacy: the characters stay in the string. A run delegate gives the first
  character an em of advance and the rest none
  (`CoreTextPaginator.markCombinedUprightCells`); their glyphs take the
  context's fill colour, which `drawVerticalFrame` makes clear, and the page
  view and scroll chunks draw the cell's text horizontally afterwards.

## Inline Images

For vertical run delegates:

- `getWidth` is the inline advance downward.
- `getAscent` / `getDescent` are block-direction x extents.
- inline image rect y is computed from the column top plus text advance.
- padding-left/right from CSS must not move the image away from the column
  center in x.

BrowserAuto still sends a vertical chapter holding an `<img>` to legacy
(`VerticalTextSupport.accepts`).

## Inline Annotation Spans

Vertical `.small*` spans are represented as custom annotation delegate runs. The
main CoreText frame reserves one column-width placeholder; `CoreTextPageView`
draws the annotation content manually after the frame is drawn.

Important details:

- Strip `.baselineOffset` and `.paragraphStyle` from annotation content before
  manual drawing.
- Use font `lineHeight` as the per-character advance, not raw `pointSize`, to
  avoid clipping small red note glyphs.
- Split oversized annotation delegate runs in `CoreTextPaginator` so a long note
  can paginate instead of becoming an impossible single run.

## Tests

- App: `VerticalTypographyAcceptanceTests` (both engines, drawn and measured
  from coloured ink), `LegacyTateChuYokoTests`, `LegacySelectionGeometryTests`,
  `CoreTextWritingModeTests`, `CoreTextPipelineTests`.
- YueduCoreText: `VerticalOrientationTests`, `CJKTypographyStyleTests`,
  `CJKPunctuationTests`, `CJKSpacingTests`, `GlyphBoundaryTests`,
  `TextCombineUprightTests`.
- The Red Chamber line-break baseline
  (`docs/browser-layout/line-break-baseline/redchamber.tsv`) moves when spacing
  or fonts change; re-record it by the rule in
  `docs/browser-layout/fidelity-loop/README.md`.
