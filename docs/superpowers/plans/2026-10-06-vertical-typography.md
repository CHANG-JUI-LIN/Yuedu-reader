# Vertical Typography Implementation Plan

> Reported 2026-10-06 by the maintainer, with three screenshots:
> - 紅樓夢 in vertical writing: punctuation pairs overlap, and 。，are not centred;
> - a copyright page: Latin letters and digits stand upright, one per cell.
>
> Standards: [CSS Writing Modes Level 3](https://www.w3.org/TR/css-writing-modes-3/) (`text-orientation`, `text-combine-upright`), [UAX #50](https://www.unicode.org/reports/tr50/), [CLREQ](https://www.w3.org/TR/clreq/), [JLREQ](https://www.w3.org/TR/jlreq/). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In vertical writing, both engines set text the way W3C specifies:
- Latin letters and digits sideways; kana and Han upright;
- punctuation where CLREQ or JLREQ places it for the text's script, and as wide as they allow;
- CJK fonts chosen by the text's language.

Readers can switch 橫排／直排 for TXT and online books, and for Aozora books once [Aozora Phase 1d](2026-10-05-aozora-bunko-support.md) lands. Horizontal writing gets the same fonts, punctuation positions and punctuation spacing, because each fix sits in the code both orientations share.

**Decisions (maintainer, 2026-10-06):**
1. **This plan comes first.** Aozora books get vertical writing only after it lands.
2. **Punctuation follows the text's script, not its declared language.**
   - Traditional text: centred (Taiwan and Hong Kong, CLREQ).
   - Simplified text: top right in vertical, bottom left in horizontal (Mainland, CLREQ).
   - Text with kana: JLREQ.
   - Declared languages are unreliable. The reported 紅樓夢 declares `dc:language` `zh` and `xml:lang` `zh-cn`, and its text is Traditional.
   - The reader's 繁簡轉換 output counts, not the source.
3. **Digits and Latin letters follow the W3C default, `text-orientation: mixed`: sideways.** Only authored `text-combine-upright` (縦中横) sets them upright in one cell. No automatic 縦中横.
4. **Fonts whose punctuation does not match the style are corrected to the standard position by measurement.** The system fonts already match and are left alone.
5. **The 排版方向 control returns.** Of the Aozora Bunko readers on the App Store, 5 of 8 are confirmed to switch 縦書き／横書き; the other 3 mention only 縦書き. It is shown for books that may be vertical (TXT, online; Aozora in Phase 1d). Other EPUBs keep following their own declaration.

**Architecture:** One shared pass in `YueduCoreTextTypography` (the package both engines already import) does the orientation, the punctuation placement and the punctuation spacing:
- `VerticalOrientation`: the UAX #50 table, generated.
- `CJKTypographyStyle`: `.traditional`, `.simplified` or `.japanese`; its detection; its language tag and system font cascade.
- `CJKPunctuation`: classes, positions and squeezable sides per style and orientation, from CLREQ and JLREQ.
- `CJKTypography.apply(to:style:writingMode:)`: the pass. BrowserAuto calls it where it builds a line's attributed string; legacy calls it where `CJKTypographyProcessor.apply` runs today. Neither engine keeps rules of its own.

The app resolves the style once per book and passes it in `ReaderRenderSettings` (legacy, TXT, online) and `BrowserLayoutConfig` (BrowserAuto).

**Tech Stack:** Swift 6, Swift Testing, CoreText, Python 3 for the table generator.

---

## What is wrong today

A temporary probe on 2026-10-06 (iOS 27 simulator, 17 pt) dumped every character's font, kerning and vertical-forms flag from both engines:

| Symptom | Engine | Cause |
|---|---|---|
| ：「 overlap; ？」 and 。」 too | legacy | See the compression bullets below. |
| 。，、 not centred in Traditional text | legacy | Every mark is replaced by a vertical presentation form (︒︐︑︓﹁…), which sits in the Mainland/Japanese corner. The substitution map is built from the primary font `.SFUI-Regular`, which has no CJK glyphs, so every mark "lacks" an alternate (`CoreTextPaginator.swift:1684-1693`, `VerticalLayoutConfig.swift`). The legacy text carries no language at all. |
| kana sideways | legacy | `CoreTextPaginator.swift:1776-1786` removes vertical forms from every run outside Han and a few CJK blocks; kana are outside them. |
| Latin and digits upright, one per cell | BrowserAuto | `InlineLayout.swift:171-174` sets vertical forms on the whole line. |
| Han drawn with PingFang SC in Traditional and Japanese text | BrowserAuto | The default family is `PingFangSC-Regular` (`InlineLayout.swift:781`), and the fallbacks are fixed: Georgia, PingFang SC, STHeiti SC (`ReaderFontCascade.swift:7-12`). `lang` is read (`ComputedStyleTreeBuilder.swift:425`) but only becomes `kCTLanguageAttributeName`. |
| authored 縦中横 | both | BrowserAuto sends the chapter to legacy (`BrowserLayoutCapabilityScanner.swift:144`); legacy ignores `text-combine-upright`. |
| no way to choose 直排 | app | The 排版方向 picker lived in `FontSettingsView`, which nothing presented; it was deleted as dead code in 4f41e195. `GlobalSettings.readerWritingMode` is only read. |

The legacy compression is `CJKTypographyProcessor.apply`, called at `NodeAttributedStringRenderer.swift:205`. It kerns ：「 by −17.00 pt (a whole em), ？」 by −4.61 pt and 。」 by −6.26 pt, in vertical and horizontal text alike:
- it counts ？！：； as closing marks with a squeezable half em;
- it squeezes a closing mark followed by an opening one by a whole em;
- it measures the squeezable gap on a horizontal line (`CJKTypographyProcessor.swift:359-388`) and applies that gap to vertical text;
- it ignores the script.

The reported book is `redchamber-vertical` in the fidelity corpus. Its chapters run in legacy because they hold one-character marker images, and BrowserAuto rejects images in vertical writing (fidelity loop item S005). Its 版權頁 (`text/part0001.html`) has no images and runs in BrowserAuto.

## What the standards say

- **Orientation** (CSS Writing Modes 3, `text-orientation: mixed`). Characters with UAX #50 `Vertical_Orientation` `U` are upright. `Tu` are upright, using the font's vertical alternate when it has one. `Tr` use the vertical alternate, and are rotated when the font has none. `R` are rotated 90° clockwise. ASCII letters and digits are `R`; kana, Han, and full-width letters and digits are `U`; full-width commas and stops are `Tu`, brackets `Tr`.
- **Position** (CLREQ). Taiwan and Hong Kong centre punctuation in both orientations. The Mainland puts it at the end of the text it follows: bottom left in horizontal, top right in vertical. JLREQ puts 、。 top right in vertical, and centres ：；？！.
- **Width** (CLREQ, Punctuation Width Adjustment). Many Taiwan publications do not adjust punctuation width; most Mainland and Hong Kong ones do. Regardless of the overall style:
  - when a bracket meets another punctuation mark, the pair's 2 em shrink to 1.5 em;
  - the squeeze keeps brackets against the text they enclose;
  - fixed marks never shrink: interpuncts; ？！ in Taiwan and Hong Kong horizontal text; ：；？！ in vertical text everywhere.

  JLREQ §3.1.4 gives the Japanese pairs (for example 」「 keeps half an em between the brackets, 。」 none).
- **Line start and end**: CLREQ allows trimming an opening bracket at line start; GB/T 15834 trims full-width marks at line end in Mainland text. Not in this plan.

## Guardrails

- **Text never changes.** No character substitution: positions, search, copy and TTS all see the source characters. The legacy presentation-form substitution goes.
- **One implementation.** Both engines call the shared pass in `YueduCoreTextTypography`.
- **Cite the standard.** Every rule cites its standard and section in a code comment.
- **Measure.** Report layout time before and after, with `browser.viewport.layout`, the legacy pagination timing and a new `cjk.typography.prepare` span.
- **The fidelity tools are locked.** Do not edit `scripts/fidelity/` or `RenderFidelityOracleTests.swift`; their hashes are locked. Score `redchamber-vertical` and `kusamakura` before and after with `fidelity.py compare`.
- **The fidelity loop's line-break baseline.** `BrowserLayoutLineBreakBaselineTests` changes where spacing changes. Re-record it in the same commit, listing every changed spine and three sample chapters, as the loop's rule requires (`docs/browser-layout/line-break-baseline/rerecord-2026-10-01.md`).
- **YueduCoreText is the local package `../YueduCoreText`.** It was at 0.6.1 with a clean tree on 2026-10-06. Changes there bump its version, and its own test targets run.
- **Running tests.** Use `bash scripts/xctest.sh`, with the toolchain from `scripts/sim.sh`.

## File map

- Create `scripts/vertical_orientation.py`: UCD `VerticalOrientation.txt` at a pinned version → `../YueduCoreText/Sources/YueduCoreTextTypography/VerticalOrientationTable.swift`, plus a manifest with the version and SHA-256s.
- Create in `../YueduCoreText/Sources/YueduCoreTextTypography/`: `VerticalOrientation.swift`, `CJKTypographyStyle.swift`, `CJKPunctuation.swift`, `CJKTypography.swift`.
- Modify:
  - `CJKTypographyProcessor.swift`: its classes and compression move into `CJKPunctuation`;
  - `VerticalLayoutConfig.swift` and `String+VerticalNormalization.swift`: the substitution goes;
  - `../YueduCoreText/Sources/YueduCoreText/Engine/InlineLayout.swift`;
  - `../YueduCoreText/Sources/YueduCoreText/Layout/ReaderFontCascade.swift`;
  - `../YueduCoreText/Sources/YueduCoreText/Engine/ComputedStyleTreeBuilder.swift` (`BrowserLayoutConfig`);
  - `../YueduCoreText/Sources/YueduCoreText/Engine/BrowserLayoutCapabilityScanner.swift`.
- Modify in the app:
  - `Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift` and `NodeAttributedStringRenderer.swift`;
  - `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutPageEngine.swift` (`makeBrowserConfig`);
  - `Modules/Services/LibraryStore/Models.swift` (`ReaderRenderSettings`);
  - `Modules/Core/AI/AIAnswerLanguage.swift`: its script rule becomes the shared `ChineseScript`;
  - `Modules/Features/Reader/ReaderSettingsView.swift`: the 排版方向 row.
- Create `Modules/Features/Reader/ReaderTypographyStyleResolver.swift`.
- Tests:
  - create `VerticalTypographyAcceptanceTests`, `VerticalOrientationTests`, `CJKTypographyStyleTests`, `CJKPunctuationTests`;
  - update `CJKTypographyProcessorTests` (in `CoreTextPipelineTests.swift`), which pins today's compression.
- Docs: rewrite `docs/coretext/vertical-writing.md`. It describes the Latin-run regex and the presentation forms that this plan removes.
- `NOTICE`: credit the Unicode data.

---

## Task 1: Acceptance tests

**Files:**
- Create: `Tests/iOS/yuedu appTests/VerticalTypographyAcceptanceTests.swift`

- [ ] **Step 1: Write the tests**

Write three self-written chapters: Traditional text declared `xml:lang="zh-cn"` (as the reported book is), Simplified text, and Japanese text. Each holds:
- the pairs ：「, ？」, 。」, 」「, 、「, （「;
- a Latin word, a four-digit year, kana, ー, ——, ……;
- an authored `<span style="text-combine-upright: all">12</span>`.

For each engine and chapter, in vertical writing, assert:
- **Orientation:** Han and kana upright; Latin letters and ASCII digits rotated; the 縦中横 span upright in one cell.
- **Fonts** (no reader font selected): Han in PingFang TC, PingFang SC or Hiragino Sans by style; kana in Hiragino Sans.
- **Position:** 。，、 centred in their cell for Traditional, in the top-right quadrant for Simplified and Japanese; ：；？！ centred in all three.
- **Width:** no two ink boxes overlap; each pair's advance is Task 7's value; both engines agree within 0.5 pt.

Read glyph boxes from the laid-out lines (`CTRunGetPositions`, `CTFontGetBoundingRectsForGlyphs`), or rasterise one line and take its ink box. Write this helper here; do not touch the locked fidelity oracle.

Wrap each group in `withKnownIssue("Task N")`, naming the task that fixes it. Each later task removes its wrapper, so the suite stays green and shows what is left.

- [ ] **Step 2: Run and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/VerticalTypographyAcceptanceTests'
git commit -m "test(vertical): pin W3C vertical typography in both engines"
```

## Task 2: UAX #50 table

**Files:**
- Create: `scripts/vertical_orientation.py`
- Create: `../YueduCoreText/Sources/YueduCoreTextTypography/VerticalOrientationTable.swift`, `VerticalOrientation.swift`
- Create: `../YueduCoreText/Tests/YueduCoreTextTypographyTests/VerticalOrientationTests.swift`
- Modify: `NOTICE`

- [ ] **Step 1: Generate**

The script downloads `VerticalOrientation.txt` from the Unicode Character Database. It pins the newest released version, records the file's SHA-256, and writes sorted ranges for `U`, `Tu` and `Tr`; everything else is `R`. Same shape as `scripts/aozora_tables.py`. `VerticalOrientation.of(_ scalar: Unicode.Scalar)` binary-searches the ranges.

- [ ] **Step 2: Tests and commit**

Spot values:
- `A`, `0`, `(` are R;
- あ, ア, 漢, Ａ, ① are U;
- 。, ， are Tu;
- （, 「, ー are Tr.

Check the em dash — and the ellipsis … against the data rather than memory: Task 1 expects —— and …… to stand along the column. Credit the Unicode data in `NOTICE`.

```bash
git commit -m "feat(typography): add the UAX #50 vertical orientation table"
```

## Task 3: Style per book

**Files:**
- Create: `../YueduCoreText/Sources/YueduCoreTextTypography/CJKTypographyStyle.swift`
- Create: `Modules/Features/Reader/ReaderTypographyStyleResolver.swift`
- Modify: `Modules/Core/AI/AIAnswerLanguage.swift`, `Modules/Services/LibraryStore/Models.swift`, `Modules/Core/ReaderCore/BrowserLayout/BrowserLayoutPageEngine.swift`
- Create: `Tests/iOS/yuedu appTests/CJKTypographyStyleTests.swift`

- [ ] **Step 1: Write the failing tests**

| Sample | Declared | 繁簡轉換 | Style |
|---|---|---|---|
| Traditional text | `zh-cn` | original | traditional |
| Simplified text | `zh-TW` | original | simplified |
| Traditional text | any | to Simplified | simplified |
| kana and Han | `zh` | original | japanese |
| only characters both scripts share | `zh-HK` | original | traditional |
| only characters both scripts share | none | original | the interface language's |

- [ ] **Step 2: Implement**

- **Script rule.** Move the rule at `AIAnswerLanguage.swift:64` into a shared `ChineseScript`: text that simplifying changes is Traditional; text that the reverse changes is Simplified. Keep one rule for both callers.
- **Detection.** `CJKTypographyStyle.detect(sample:declaredLanguage:conversion:)`:
  1. Kana in the sample means Japanese.
  2. Otherwise the script of the sample after the reader's 繁簡轉換.
  3. Otherwise the declared language: `zh-TW`, `zh-HK` or `zh-Hant` is traditional; `zh`, `zh-CN` or `zh-Hans` is simplified.
  4. Otherwise the interface language.
- **Resolver.** `ReaderTypographyStyleResolver` samples the opened book once: about 4,000 Han and kana characters from its first chapters. It caches the style by book id and 繁簡轉換. Views do not orchestrate: the reader asks the resolver.
- **Passing it on.** Add `cjkTypographyStyle` to `ReaderRenderSettings` (`Models.swift:814`), so a change re-runs layout. Add it to `BrowserLayoutConfig`, which `makeBrowserConfig` builds (`BrowserLayoutPageEngine.swift:835-852`).

- [ ] **Step 3: Run and commit**

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/CJKTypographyStyleTests'
git commit -m "feat(typography): decide each book's CJK typography from its script"
```

## Task 4: Orientation in both engines

**Files:**
- Create: `../YueduCoreText/Sources/YueduCoreTextTypography/CJKTypography.swift`
- Modify: `../YueduCoreText/Sources/YueduCoreText/Engine/InlineLayout.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift`
- Modify: `../YueduCoreText/Sources/YueduCoreTextTypography/VerticalLayoutConfig.swift`, `String+VerticalNormalization.swift`

- [ ] **Step 1: Implement**

`CJKTypography.apply` sets orientation per character:
- `U` and `Tu`: vertical forms.
- `Tr`: vertical forms when the font has a vertical alternate (`CTFont.hasVerticalAlternate`, `VerticalLayoutConfig.swift`); rotated when it has none.
- `R`: no vertical forms, so it is rotated, and centred on the column with the baseline treatment legacy uses today (`applyVerticalLatinBaselineAlignment`, which moves into the package).

Then:
- **BrowserAuto.** Replace the blanket vertical forms at `InlineLayout.swift:171-174`.
- **Legacy.** Replace steps 5 and 6 of `preparedAttributedString` (`CoreTextPaginator.swift:1772-1786`). Remove the presentation-form substitution (step 1, `:1684-1693`, `normalizeForVerticalLayoutInPlace`) and the ASCII-bracket conversion with it: a bracket without an alternate is now rotated, and Task 6 places punctuation.
- **Other callers of the normalisation.** `NodeAttributedStringRenderer.swift:2242` (inline notes) and `CalibreCFIMapper.swift:25` (CFI matching) drop it too. `ReaderTOCViews.swift:51` draws the vertical table of contents in SwiftUI and is not part of this plan.

- [ ] **Step 2: Tests and commit**

- Remove the orientation wrappers in Task 1.
- Assert the per-character vertical-forms flags in both engines, as the probe read them.
- Assert a rotated Latin run's ink is centred on the column, within 5% of an em.
- `CoreTextWritingModeTests` and `JapaneseVerticalRubyTests` pass.

```bash
bash scripts/xctest.sh -- -only-testing:'yuedu appTests/VerticalTypographyAcceptanceTests' -only-testing:'yuedu appTests/CoreTextWritingModeTests' -only-testing:'yuedu appTests/JapaneseVerticalRubyTests'
git commit -m "fix(vertical): orient characters by UAX #50 in both engines"
```

## Task 5: Fonts by style

**Files:**
- Modify: `../YueduCoreText/Sources/YueduCoreText/Engine/InlineLayout.swift`, `../YueduCoreText/Sources/YueduCoreText/Layout/ReaderFontCascade.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/CoreTextPaginator.swift`, `NodeAttributedStringRenderer.swift`

- [ ] **Step 1: Implement**

The style gives a language tag: `zh-Hant`, `zh-Hans` or `ja`; `zh-HK` when the book declares it.

**BrowserAuto:**
- the default family (`InlineLayout.swift:781`) and the CJK fallbacks (`ReaderFontCascade.swift:7-12`) come from `CTFontCopyDefaultCascadeListForLanguages` for that tag: PingFang TC, PingFang HK, PingFang SC or Hiragino Sans;
- Georgia and the emoji fallback stay.

**Legacy:**
- the text carries `kCTLanguageAttributeName`, so `locl` picks the right forms;
- the cascade puts the style's fonts before the rare-character fallbacks at `CoreTextPaginator.swift:1719-1734`.

A font the reader selected stays primary in both engines.

- [ ] **Step 2: Tests and commit**

Remove the font wrappers in Task 1. Assert the resolved fonts in horizontal writing too.

```bash
git commit -m "fix(typography): choose CJK fonts by the text's language in both engines"
```

## Task 6: Punctuation positions

**Files:**
- Create: `../YueduCoreText/Sources/YueduCoreTextTypography/CJKPunctuation.swift`
- Modify: `CJKTypography.swift`
- Create: `../YueduCoreText/Tests/YueduCoreTextTypographyTests/CJKPunctuationTests.swift`

- [ ] **Step 1: Write the failing tests**

| Font | Style | 。，、 in vertical writing |
|---|---|---|
| PingFang TC | traditional | centred, untouched |
| PingFang SC | traditional | moved to the centre |
| PingFang TC | simplified | moved to the top right |
| Hiragino Sans | japanese | top right, untouched |

Do the same in horizontal writing: centre, or bottom left. In every case ：；？！ are centred in vertical writing.

- [ ] **Step 2: Implement**

- **Targets.** The CLREQ and JLREQ positions above, per style and orientation.
- **Measure.** Measure the shaped glyph's ink box in its cell: after the vertical alternate or the rotation. Cache by font, glyph, style and orientation.
- **Move.** Use `baselineOffset` across the column, and a pair of opposite kerns along it, so the advance does not change.
- **System fonts.** Their marks are already in place, and the tests assert the move is zero.

- [ ] **Step 3: Run and commit**

```bash
git commit -m "fix(typography): place CJK punctuation where CLREQ and JLREQ put it"
```

## Task 7: Spacing between adjacent punctuation

**Files:**
- Modify: `CJKPunctuation.swift`, `CJKTypography.swift`, `CJKTypographyProcessor.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/NodeAttributedStringRenderer.swift`
- Modify: `../YueduCoreText/Sources/YueduCoreText/Engine/InlineLayout.swift`
- Modify: `Tests/iOS/yuedu appTests/CoreTextPipelineTests.swift`

- [ ] **Step 1: Write the failing tests**

For each style and orientation, the advance of each pair from Task 1 and of 」」, 「「, 」）, with no ink overlap.

| Pair | Vertical, Chinese | Japanese |
|---|---|---|
| ：「 | 1.5 em: the bracket's leading blank goes; ： is fixed | per JLREQ §3.1.4 |
| ？」 | 1.5 em: the bracket's trailing blank goes; nothing pushes into ？ | per JLREQ |
| 。」 | 1.5 em | 1.5 em, no space between |
| 」「 | 1.5 em, half an em between | 1.5 em, half an em between |

- [ ] **Step 2: Implement**

- **Classes.** Replace the lists in `CJKTypographyProcessor`. JLREQ's classes: opening brackets, closing brackets, dividing marks ？！, middle dots ・：；, full stops, commas. Each class has its blank sides per style and orientation.
- **Chinese.** Apply CLREQ's rule: a pair involving a bracket shrinks from 2 em to 1.5 em, taking the space from the side away from the enclosed text, so the bracket stays against it. Fixed marks never shrink. The Taiwan style adjusts nothing else.
- **Japanese.** Apply JLREQ §3.1.4.
- **Amounts.** They come from the class table and the measured glyph body (Task 6), never from a horizontal line.
- **Callers.** Legacy keeps its call site at `NodeAttributedStringRenderer.swift:205`. BrowserAuto calls the same pass. Its justification (`justifiedLine`) only adds space, and leaves these kerns alone.

Update `CJKTypographyProcessorTests`. It pins today's amounts.

- [ ] **Step 3: Run and commit**

Re-record `BrowserLayoutLineBreakBaselineTests` by the loop's rule: BrowserAuto's lines change wherever marks now squeeze.

```bash
git commit -m "fix(typography): squeeze adjacent punctuation as CLREQ and JLREQ allow"
```

## Task 8: Authored 縦中横

**Files:**
- Modify: `../YueduCoreText/Sources/YueduCoreText/Engine/BrowserLayoutCapabilityScanner.swift`, `InlineLayout.swift`
- Modify: `Modules/Core/ReaderCore/CoreText/` (the legacy run builder)

- [ ] **Step 1: Write the failing tests**

`text-combine-upright: all` on 「12」:
- one upright cell, centred, in both engines;
- the text is still the two characters;
- BrowserAuto keeps the chapter.

`digits 2` behaves the same for up to two digits.

- [ ] **Step 2: Implement**

- **BrowserAuto.** Lay the run out horizontally, scaled into one em, as one atomic cell. Stop rejecting the supported values at `BrowserLayoutCapabilityScanner.swift:144`.
- **Legacy.** Use the run-delegate approach of its inline notes (`docs/coretext/vertical-writing.md`, "Inline Annotation Spans"): one cell of advance on the first character, none on the rest, and the digits drawn horizontally in that cell.

Never automatic (decision 3).

- [ ] **Step 3: Run and commit**

```bash
git commit -m "feat(vertical): set authored text-combine-upright in one upright cell"
```

## Task 9: The 排版方向 control

**Files:**
- Modify: `Modules/Features/Reader/ReaderSettingsView.swift`
- Modify, if the maintainer wants it scoped: `Modules/Features/Reader/ReadingSettingsScopeView.swift`

- [ ] **Step 1: Implement**

- **Where.** 閱讀設定's 排版 section (`ReaderSettingsView.swift:492`) gains 排版方向: 橫排／直排, shown when `book.allowsVerticalWritingMode`.
- **Theme scope.** Every other reading setting follows the theme being worn, and `ReadingSettingsScopeView` lists it. Whether 排版方向 does too is the maintainer's call; ask together with the screenshot.
- **What it does.** It writes `GlobalSettings.readerWritingMode`. The reader already relayouts and turns its opening direction on that change (`ReaderView.swift:2390`).
- **Strings.** The keys 排版方向, 橫排, 直排 and both footers still exist in all five `Localizable.strings` from the deleted view. `ruby scripts/check_localizations.rb` checks them.
- **Design.** Follow `docs/design.md` through the `yuedu-ios-design` skill.
- **VoiceOver.** Label and value on the picker.
- **Preview.** Add a `#Preview`.

Show the maintainer a screenshot before committing: where the control sits is a UI decision.

- [ ] **Step 2: Tests and commit**

Unit-test the visibility rule: TXT and online books show it; a plain EPUB does not.

```bash
git commit -m "feat(reader): let readers choose 橫排 or 直排 again"
```

## Task 10: Acceptance

- [ ] `VerticalTypographyAcceptanceTests` has no known issues left.
- [ ] Regression: `CoreTextWritingModeTests`, `JapaneseVerticalRubyTests`, `BrowserVerticalReaderRouteTests`, `CoreTextPipelineTests`, the YueduCoreText test targets, and the fidelity loop's required set (`docs/browser-layout/fidelity-loop/LOOP.md`).
- [ ] `fidelity.py compare` scores for `redchamber-vertical` and `kusamakura`, before and after.
- [ ] Timings for one vertical chapter in each engine, before and after, including `cjk.typography.prepare`.
- [ ] Screenshots of the reported pages in both engines, for the maintainer: 紅樓夢's 版權頁 (`text/part0001.html`) and 第一回, from `redchamber-vertical` in the fidelity corpus.

## Task 11: Record what landed

- Add "What landed" to this plan: commits, numbers and decisions.
- Rewrite `docs/coretext/vertical-writing.md` for the shared pass.
- Aozora Phase 1d can start.

```bash
git commit -m "docs(vertical): record what the vertical typography plan landed"
```
